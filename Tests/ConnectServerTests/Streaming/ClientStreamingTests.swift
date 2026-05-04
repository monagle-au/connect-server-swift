// Copyright 2026 David Monagle / Monagle Pty Ltd
// SPDX-License-Identifier: MIT

import Foundation
import GRPCCore
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import NIOCore
import Testing

@testable import ConnectServer

@Suite("Client-Streaming")
struct ClientStreamingTests {

    /// Builds a router with a client-streaming method that concatenates input texts.
    private static func makeConcatRouter() -> ConnectRouter {
        var router = ConnectRouter()
        router.registerClientStreaming(
            method: MethodDescriptor(fullyQualifiedService: "test.Concat", method: "Run"),
            requestType: TestPingMessage.self,
            responseType: TestPingMessage.self
        ) { (inputs: AsyncThrowingStream<TestPingMessage, any Error>, _: ServerContext) async throws -> TestPingMessage in
            var combined = ""
            for try await msg in inputs {
                if !combined.isEmpty { combined += "," }
                combined += msg.text
            }
            return TestPingMessage(text: combined)
        }
        return router
    }

    /// Concatenates multiple enveloped messages into a single body.
    private static func framedBody(_ messages: [TestPingMessage], codec: any MessageCodec = ProtoCodec()) throws -> ByteBuffer {
        var buf = ByteBufferAllocator().buffer(capacity: 64)
        for m in messages {
            let bytes = try codec.serialize(m)
            var frame = Envelope.frameMessage(bytes)
            buf.writeBuffer(&frame)
        }
        return buf
    }

    @Test("gRPC-Web client-streaming: concat 3 messages")
    func grpcWebConcat() async throws {
        let app = Application(responder: Self.makeConcatRouter())
        try await app.test(.router) { client in
            var headers = HTTPFields()
            headers[.contentType] = "application/grpc-web+proto"

            let inputs = [TestPingMessage(text: "a"), TestPingMessage(text: "b"), TestPingMessage(text: "c")]
            let body = try Self.framedBody(inputs)

            let response = try await client.execute(
                uri: "/test.Concat/Run",
                method: .post,
                headers: headers,
                body: body
            )
            #expect(response.status == .ok)

            // Response: data frame + trailer frame
            var b = response.body
            let codec = ProtoCodec()
            let (dataHeader, dataPayload) = try Envelope.readMessage(from: &b)
            #expect(dataHeader.flags == 0x00)
            let result = try codec.deserialize(TestPingMessage.self, from: dataPayload)
            #expect(result.text == "a,b,c")

            let (trailerHeader, trailerPayload) = try Envelope.readMessage(from: &b)
            #expect(trailerHeader.flags == 0x80)
            #expect(String(buffer: trailerPayload).contains("grpc-status: 0"))
        }
    }

    @Test("Connect proto client-streaming: concat 2 messages")
    func connectProtoConcat() async throws {
        let app = Application(responder: Self.makeConcatRouter())
        try await app.test(.router) { client in
            var headers = HTTPFields()
            headers[.contentType] = "application/connect+proto"

            let inputs = [TestPingMessage(text: "x"), TestPingMessage(text: "y")]
            let body = try Self.framedBody(inputs)

            let response = try await client.execute(
                uri: "/test.Concat/Run",
                method: .post,
                headers: headers,
                body: body
            )
            #expect(response.status == .ok)
            #expect(response.headers[.contentType] == "application/connect+proto")

            // Response: data frame + EndStreamResponse
            var b = response.body
            let codec = ProtoCodec()
            let (dataHeader, dataPayload) = try Envelope.readMessage(from: &b)
            #expect(dataHeader.flags == 0x00)
            let result = try codec.deserialize(TestPingMessage.self, from: dataPayload)
            #expect(result.text == "x,y")

            let (endHeader, endPayload) = try Envelope.readMessage(from: &b)
            #expect(endHeader.flags == 0x02)
            let endJSON = try JSONSerialization.jsonObject(with: Data(endPayload.readableBytesView)) as? [String: Any]
            #expect(endJSON?["error"] == nil)
        }
    }

    @Test("Empty input stream: handler receives 0 messages, returns empty result")
    func emptyInputStream() async throws {
        let app = Application(responder: Self.makeConcatRouter())
        try await app.test(.router) { client in
            var headers = HTTPFields()
            headers[.contentType] = "application/grpc-web+proto"

            let response = try await client.execute(
                uri: "/test.Concat/Run",
                method: .post,
                headers: headers,
                body: ByteBuffer()
            )
            #expect(response.status == .ok)

            var b = response.body
            let codec = ProtoCodec()
            let (_, dataPayload) = try Envelope.readMessage(from: &b)
            let result = try codec.deserialize(TestPingMessage.self, from: dataPayload)
            #expect(result.text == "")
        }
    }
}

@Suite("Bidirectional")
struct BidirectionalStreamingTests {

    /// Echo each input as a corresponding output.
    private static func makeEchoRouter() -> ConnectRouter {
        var router = ConnectRouter()
        router.registerBidirectional(
            method: MethodDescriptor(fullyQualifiedService: "test.Echo", method: "Echo"),
            requestType: TestPingMessage.self,
            responseType: TestPingMessage.self
        ) {
            (inputs: AsyncThrowingStream<TestPingMessage, any Error>,
             _: ServerContext,
             writer: ServerStreamWriter<TestPingMessage>) in
            for try await msg in inputs {
                try await writer.write(TestPingMessage(text: "echo: \(msg.text)"))
            }
        }
        return router
    }

    private static func framedBody(_ messages: [TestPingMessage], codec: any MessageCodec = ProtoCodec()) throws -> ByteBuffer {
        var buf = ByteBufferAllocator().buffer(capacity: 64)
        for m in messages {
            let bytes = try codec.serialize(m)
            var frame = Envelope.frameMessage(bytes)
            buf.writeBuffer(&frame)
        }
        return buf
    }

    @Test("Connect bidi: 2 inputs → 2 echoed outputs (half-duplex over HTTP/1.1)")
    func connectBidi() async throws {
        let app = Application(responder: Self.makeEchoRouter())
        try await app.test(.router) { client in
            var headers = HTTPFields()
            headers[.contentType] = "application/connect+proto"

            let inputs = [TestPingMessage(text: "one"), TestPingMessage(text: "two")]
            let body = try Self.framedBody(inputs)

            let response = try await client.execute(
                uri: "/test.Echo/Echo",
                method: .post,
                headers: headers,
                body: body
            )
            #expect(response.status == .ok)
            #expect(response.headers[.contentType] == "application/connect+proto")

            var b = response.body
            let codec = ProtoCodec()
            var outputs: [String] = []
            while b.readableBytes > 0 {
                let (header, payload) = try Envelope.readMessage(from: &b)
                if header.flags == 0x00 {
                    let msg = try codec.deserialize(TestPingMessage.self, from: payload)
                    outputs.append(msg.text)
                } else if header.flags == 0x02 {
                    break  // EndStreamResponse
                }
            }
            #expect(outputs == ["echo: one", "echo: two"])
        }
    }

    @Test("gRPC-Web bidi is rejected with unimplemented (per spec)")
    func grpcWebBidiRejected() async throws {
        let app = Application(responder: Self.makeEchoRouter())
        try await app.test(.router) { client in
            var headers = HTTPFields()
            headers[.contentType] = "application/grpc-web+proto"

            let body = try Self.framedBody([TestPingMessage(text: "hi")])
            let response = try await client.execute(
                uri: "/test.Echo/Echo",
                method: .post,
                headers: headers,
                body: body
            )
            #expect(response.status != .ok)
            let json = try JSONSerialization.jsonObject(with: Data(response.body.readableBytesView)) as? [String: Any]
            #expect(json?["code"] as? String == "unimplemented")
        }
    }
}
