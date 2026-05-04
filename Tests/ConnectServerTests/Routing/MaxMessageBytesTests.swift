// Copyright 2026 David Monagle / Monagle Pty Ltd
// SPDX-License-Identifier: MIT

import GRPCCore
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import NIOCore
import Testing

@testable import ConnectServer

@Suite("Max message size enforcement")
struct MaxMessageBytesTests {

    private static func makeRouter(maxBytes: Int) -> ConnectRouter {
        var router = ConnectRouter(maxMessageBytes: maxBytes)
        router.registerUnary(
            method: MethodDescriptor(fullyQualifiedService: "test.Echo", method: "Echo"),
            requestType: TestPingMessage.self,
            responseType: TestPingMessage.self
        ) { msg, _ in TestPingMessage(text: "echo:\(msg.text)") }

        router.registerClientStreaming(
            method: MethodDescriptor(fullyQualifiedService: "test.Echo", method: "Concat"),
            requestType: TestPingMessage.self,
            responseType: TestPingMessage.self
        ) { (inputs: AsyncThrowingStream<TestPingMessage, any Error>, _: ServerContext) -> TestPingMessage in
            var combined = ""
            for try await m in inputs { combined += m.text }
            return TestPingMessage(text: combined)
        }
        return router
    }

    // MARK: - Default value

    @Test("Default max is 4 MiB")
    func defaultMaxIsReasonable() {
        let router = ConnectRouter()
        #expect(router.maxMessageBytes == 4 * 1024 * 1024)
    }

    // MARK: - Unary body size

    @Test("Connect unary: oversized body returns resource_exhausted")
    func unaryOversized() async throws {
        let app = Application(responder: Self.makeRouter(maxBytes: 32))
        try await app.test(.router) { client in
            var headers = HTTPFields()
            headers[.contentType] = "application/json"
            // Body comfortably larger than 32 bytes.
            let big = String(repeating: "a", count: 500)
            let body = ByteBuffer(string: #"{"text":"\#(big)"}"#)
            let response = try await client.execute(
                uri: "/test.Echo/Echo", method: .post, headers: headers, body: body
            )
            #expect(response.status == .tooManyRequests)
            let json = String(buffer: response.body)
            #expect(json.contains("resource_exhausted"))
        }
    }

    @Test("Connect unary: body within limit succeeds")
    func unaryWithinLimit() async throws {
        let app = Application(responder: Self.makeRouter(maxBytes: 4096))
        try await app.test(.router) { client in
            var headers = HTTPFields()
            headers[.contentType] = "application/json"
            let response = try await client.execute(
                uri: "/test.Echo/Echo", method: .post, headers: headers,
                body: ByteBuffer(string: #"{"text":"hi"}"#)
            )
            #expect(response.status == .ok)
        }
    }

    // MARK: - Streaming per-message size

    @Test("Client-streaming: single message exceeding limit terminates the stream")
    func streamingOversized() async throws {
        let app = Application(responder: Self.makeRouter(maxBytes: 64))
        try await app.test(.router) { client in
            var headers = HTTPFields()
            headers[.contentType] = "application/grpc-web+proto"

            // Build an envelope with a declared length > 64 (we lie about the length;
            // the parser must reject as soon as it reads the header, before reading payload).
            var body = ByteBufferAllocator().buffer(capacity: 5)
            body.writeInteger(UInt8(0x00))                              // flags
            body.writeInteger(UInt32(1024), endianness: .big)           // length: 1024 > 64
            body.writeBytes([UInt8](repeating: 0x42, count: 1024))      // padding to satisfy length

            let response = try await client.execute(
                uri: "/test.Echo/Concat", method: .post, headers: headers, body: body
            )
            // gRPC-Web always returns 200 with status in trailer
            #expect(response.status == .ok)
            // Inside the trailer frame, grpc-status: 8 (resource_exhausted)
            var b = response.body
            var sawError = false
            while b.readableBytes > 0 {
                let (header, payload) = try Envelope.readMessage(from: &b)
                if header.flags & 0x80 != 0 {
                    let trailer = String(buffer: payload)
                    if trailer.contains("grpc-status: 8") { sawError = true }
                }
            }
            #expect(sawError)
        }
    }

    @Test("Client-streaming: messages within limit are processed normally")
    func streamingWithinLimit() async throws {
        let app = Application(responder: Self.makeRouter(maxBytes: 4096))
        try await app.test(.router) { client in
            var headers = HTTPFields()
            headers[.contentType] = "application/grpc-web+proto"

            let codec = ProtoCodec()
            let inputs = [TestPingMessage(text: "a"), TestPingMessage(text: "b")]
            var body = ByteBufferAllocator().buffer(capacity: 64)
            for m in inputs {
                let bytes = try codec.serialize(m)
                var frame = Envelope.frameMessage(bytes)
                body.writeBuffer(&frame)
            }

            let response = try await client.execute(
                uri: "/test.Echo/Concat", method: .post, headers: headers, body: body
            )
            #expect(response.status == .ok)
            // First frame should be the data response with text "ab"
            var b = response.body
            let (_, payload) = try Envelope.readMessage(from: &b)
            let result = try codec.deserialize(TestPingMessage.self, from: payload)
            #expect(result.text == "ab")
        }
    }
}
