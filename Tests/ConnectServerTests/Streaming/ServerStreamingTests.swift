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

// MARK: - Server-Streaming Integration Tests

@Suite("Server-Streaming")
struct ServerStreamingTests {

    /// Builds a router with a single server-streaming method that emits 3 numbered messages.
    private static func makeRouter(
        emit: Int = 3,
        throwError: RPCError? = nil
    ) -> ConnectRouter {
        var router = ConnectRouter()
        router.registerServerStreaming(
            method: MethodDescriptor(fullyQualifiedService: "test.Numbers", method: "Range"),
            requestType: TestPingMessage.self,
            responseType: TestPingMessage.self
        ) { (_: TestPingMessage, _: ServerContext, writer: ServerStreamWriter<TestPingMessage>) in
            for i in 0..<emit {
                try await writer.write(TestPingMessage(text: "msg-\(i)"))
            }
            if let error = throwError {
                throw error
            }
        }
        return router
    }

    // Reads all data and trailer/end-stream frames from a streaming response body.
    private static func readAllFrames(_ body: ByteBuffer) throws -> [(flags: UInt8, payload: ByteBuffer)] {
        var b = body
        var frames: [(UInt8, ByteBuffer)] = []
        while b.readableBytes > 0 {
            let (header, payload) = try Envelope.readMessage(from: &b)
            frames.append((header.flags, payload))
        }
        return frames
    }

    // MARK: - gRPC-Web

    @Test("gRPC-Web: emits N data frames + trailer frame")
    func grpcWebSuccess() async throws {
        let app = Application(responder: Self.makeRouter(emit: 3))
        try await app.test(.router) { client in
            var headers = HTTPFields()
            headers[.contentType] = "application/grpc-web+proto"

            let response = try await client.execute(
                uri: "/test.Numbers/Range",
                method: .post,
                headers: headers,
                body: Envelope.frameMessage(ByteBuffer())
            )
            #expect(response.status == .ok)

            let frames = try Self.readAllFrames(response.body)
            #expect(frames.count == 4)  // 3 data + 1 trailer
            #expect(frames[0].flags == 0x00)
            #expect(frames[1].flags == 0x00)
            #expect(frames[2].flags == 0x00)
            #expect(frames[3].flags == 0x80)

            let codec = ProtoCodec()
            for i in 0..<3 {
                let msg = try codec.deserialize(TestPingMessage.self, from: frames[i].payload)
                #expect(msg.text == "msg-\(i)")
            }
            let trailerString = String(buffer: frames[3].payload)
            #expect(trailerString.contains("grpc-status: 0"))
        }
    }

    @Test("gRPC-Web: error mid-stream produces trailer with grpc-status set")
    func grpcWebErrorMidStream() async throws {
        let app = Application(
            responder: Self.makeRouter(emit: 2, throwError: RPCError(code: .aborted, message: "mid-stream abort"))
        )
        try await app.test(.router) { client in
            var headers = HTTPFields()
            headers[.contentType] = "application/grpc-web+proto"

            let response = try await client.execute(
                uri: "/test.Numbers/Range",
                method: .post,
                headers: headers,
                body: Envelope.frameMessage(ByteBuffer())
            )
            #expect(response.status == .ok)

            let frames = try Self.readAllFrames(response.body)
            // 2 data + 1 trailer
            #expect(frames.count == 3)
            let trailerString = String(buffer: frames.last!.payload)
            #expect(trailerString.contains("grpc-status: 10"))  // 10 = aborted
            #expect(trailerString.contains("mid-stream abort"))
        }
    }

    // MARK: - Connect server-streaming

    @Test("Connect proto streaming: emits N data frames + EndStreamResponse")
    func connectProtoStreamingSuccess() async throws {
        let app = Application(responder: Self.makeRouter(emit: 3))
        try await app.test(.router) { client in
            var headers = HTTPFields()
            headers[.contentType] = "application/connect+proto"

            let response = try await client.execute(
                uri: "/test.Numbers/Range",
                method: .post,
                headers: headers,
                body: Envelope.frameMessage(ByteBuffer())
            )
            #expect(response.status == .ok)
            #expect(response.headers[.contentType] == "application/connect+proto")

            let frames = try Self.readAllFrames(response.body)
            #expect(frames.count == 4)  // 3 data + EndStreamResponse
            #expect(frames[3].flags == 0x02)  // end-stream flag

            let codec = ProtoCodec()
            for i in 0..<3 {
                let msg = try codec.deserialize(TestPingMessage.self, from: frames[i].payload)
                #expect(msg.text == "msg-\(i)")
            }
            let endStream = try JSONSerialization.jsonObject(with: Data(frames[3].payload.readableBytesView)) as? [String: Any]
            #expect(endStream != nil)
            #expect(endStream?["error"] == nil)  // success: no error field
        }
    }

    @Test("Connect proto streaming: error in EndStreamResponse")
    func connectProtoStreamingError() async throws {
        let app = Application(
            responder: Self.makeRouter(emit: 1, throwError: RPCError(code: .resourceExhausted, message: "out of capacity"))
        )
        try await app.test(.router) { client in
            var headers = HTTPFields()
            headers[.contentType] = "application/connect+proto"

            let response = try await client.execute(
                uri: "/test.Numbers/Range",
                method: .post,
                headers: headers,
                body: Envelope.frameMessage(ByteBuffer())
            )
            #expect(response.status == .ok)  // streaming is always 200

            let frames = try Self.readAllFrames(response.body)
            // 1 data + 1 EndStreamResponse with error
            #expect(frames.count == 2)
            #expect(frames[1].flags == 0x02)
            let endStream = try JSONSerialization.jsonObject(with: Data(frames[1].payload.readableBytesView)) as? [String: Any]
            let err = endStream?["error"] as? [String: Any]
            #expect(err?["code"] as? String == "resource_exhausted")
            #expect(err?["message"] as? String == "out of capacity")
        }
    }

    @Test("Connect JSON streaming: emits N data frames + EndStreamResponse")
    func connectJSONStreamingSuccess() async throws {
        let app = Application(responder: Self.makeRouter(emit: 2))
        try await app.test(.router) { client in
            var headers = HTTPFields()
            headers[.contentType] = "application/connect+json"

            // Input is enveloped JSON
            let inputJSON = ByteBuffer(string: "{}")
            let response = try await client.execute(
                uri: "/test.Numbers/Range",
                method: .post,
                headers: headers,
                body: Envelope.frameMessage(inputJSON)
            )
            #expect(response.status == .ok)
            #expect(response.headers[.contentType] == "application/connect+json")

            let frames = try Self.readAllFrames(response.body)
            #expect(frames.count == 3)  // 2 data + EndStreamResponse
            #expect(frames[2].flags == 0x02)

            // Each data frame should contain a JSON object
            for i in 0..<2 {
                let json = String(buffer: frames[i].payload)
                #expect(json.contains("msg-\(i)"))
            }
        }
    }

    // MARK: - Empty / zero-emit cases

    @Test("Server-streaming with zero outputs still produces valid trailer/end-stream")
    func zeroOutputs() async throws {
        let app = Application(responder: Self.makeRouter(emit: 0))
        try await app.test(.router) { client in
            var headers = HTTPFields()
            headers[.contentType] = "application/grpc-web+proto"

            let response = try await client.execute(
                uri: "/test.Numbers/Range",
                method: .post,
                headers: headers,
                body: Envelope.frameMessage(ByteBuffer())
            )
            #expect(response.status == .ok)
            let frames = try Self.readAllFrames(response.body)
            #expect(frames.count == 1)  // just the trailer frame
            #expect(frames[0].flags == 0x80)
        }
    }
}
