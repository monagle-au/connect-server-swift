// Copyright 2026 David Monagle / Monagle Pty Ltd
// SPDX-License-Identifier: MIT

import Foundation
import GRPCCore
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import NIOCore
import Testing

@testable import ConnectServer

// MARK: - Integration Tests

@Suite("Unary Integration Tests")
struct UnaryIntegrationTests {

    // Build a test router with a single echo method.
    private static func makeRouter() -> ConnectRouter {
        var router = ConnectRouter()
        router.registerUnary(
            method: MethodDescriptor(fullyQualifiedService: "test.EchoService", method: "Echo"),
            requestType: TestPingMessage.self,
            responseType: TestPingMessage.self
        ) { message, _ in
            TestPingMessage(text: "echo: \(message.text)")
        }
        return router
    }

    private static func makeApp() -> Application<ConnectRouter> {
        Application(responder: makeRouter())
    }

    // MARK: - Connect JSON

    @Test("Connect JSON: success path")
    func connectJSONSuccess() async throws {
        let app = Self.makeApp()
        try await app.test(.router) { client in
            var headers = HTTPFields()
            headers[.contentType] = "application/json"
            let requestBody = ByteBuffer(string: #"{"text":"world"}"#)

            let response = try await client.execute(
                uri: "/test.EchoService/Echo",
                method: .post,
                headers: headers,
                body: requestBody
            )
            #expect(response.status == .ok)
            let body = String(buffer: response.body)
            #expect(body.contains("echo: world"))
        }
    }

    @Test("Connect JSON: error response has JSON error envelope")
    func connectJSONError() async throws {
        var router = ConnectRouter()
        router.registerUnary(
            method: MethodDescriptor(fullyQualifiedService: "test.EchoService", method: "Echo"),
            requestType: TestPingMessage.self,
            responseType: TestPingMessage.self
        ) { (_: TestPingMessage, _: ServerContext) -> TestPingMessage in
            throw RPCError(code: .notFound, message: "item missing")
        }
        let app = Application(responder: router)
        try await app.test(.router) { client in
            var headers = HTTPFields()
            headers[.contentType] = "application/json"

            let response = try await client.execute(
                uri: "/test.EchoService/Echo",
                method: .post,
                headers: headers,
                body: ByteBuffer(string: "{}")
            )
            #expect(response.status == .notFound)
            let decoded = try JSONDecoder().decode(ConnectError.self, from: Data(response.body.readableBytesView))
            #expect(decoded.code == "not_found")
            #expect(decoded.message == "item missing")
        }
    }

    // MARK: - Connect Proto

    @Test("Connect proto: success path")
    func connectProtoSuccess() async throws {
        let codec = ProtoCodec()
        let app = Self.makeApp()
        let request = TestPingMessage(text: "proto-test")
        let requestBytes = try codec.serialize(request)

        try await app.test(.router) { client in
            var headers = HTTPFields()
            headers[.contentType] = "application/proto"

            let response = try await client.execute(
                uri: "/test.EchoService/Echo",
                method: .post,
                headers: headers,
                body: requestBytes
            )
            #expect(response.status == .ok)
            let responseMsg = try codec.deserialize(TestPingMessage.self, from: response.body)
            #expect(responseMsg.text == "echo: proto-test")
        }
    }

    // MARK: - gRPC-Web

    @Test("gRPC-Web: success path with trailer frame")
    func grpcWebSuccess() async throws {
        let codec = ProtoCodec()
        let app = Self.makeApp()
        let request = TestPingMessage(text: "grpc-web-test")
        let msgBytes = try codec.serialize(request)
        let framedRequest = Envelope.frameMessage(msgBytes)

        try await app.test(.router) { client in
            var headers = HTTPFields()
            headers[.contentType] = "application/grpc-web+proto"

            let response = try await client.execute(
                uri: "/test.EchoService/Echo",
                method: .post,
                headers: headers,
                body: framedRequest
            )
            #expect(response.status == .ok)
            #expect(response.headers[.contentType] == "application/grpc-web+proto")

            // Parse response body: data frame + trailer frame
            var body = response.body
            let (dataHeader, dataPayload) = try Envelope.readMessage(from: &body)
            #expect(dataHeader.flags == 0x00)
            let responseMsg = try codec.deserialize(TestPingMessage.self, from: dataPayload)
            #expect(responseMsg.text == "echo: grpc-web-test")

            // Trailer frame
            let (trailerHeader, trailerPayload) = try Envelope.readMessage(from: &body)
            #expect(trailerHeader.flags == 0x80)
            let trailerString = String(buffer: trailerPayload)
            #expect(trailerString.contains("grpc-status: 0"))
        }
    }

    @Test("gRPC-Web: error path has trailer frame with grpc-status")
    func grpcWebError() async throws {
        var router = ConnectRouter()
        router.registerUnary(
            method: MethodDescriptor(fullyQualifiedService: "test.EchoService", method: "Echo"),
            requestType: TestPingMessage.self,
            responseType: TestPingMessage.self
        ) { (_: TestPingMessage, _: ServerContext) -> TestPingMessage in
            throw RPCError(code: .invalidArgument, message: "bad input")
        }
        let app = Application(responder: router)
        let framedRequest = Envelope.frameMessage(ByteBuffer())

        try await app.test(.router) { client in
            var headers = HTTPFields()
            headers[.contentType] = "application/grpc-web+proto"

            let response = try await client.execute(
                uri: "/test.EchoService/Echo",
                method: .post,
                headers: headers,
                body: framedRequest
            )
            #expect(response.status == .ok)  // gRPC-Web always returns 200

            var body = response.body
            let (trailerHeader, trailerPayload) = try Envelope.readMessage(from: &body)
            #expect(trailerHeader.flags == 0x80)
            let trailerString = String(buffer: trailerPayload)
            #expect(trailerString.contains("grpc-status: 3"))   // invalidArgument = 3
            #expect(trailerString.contains("grpc-message"))
        }
    }

    // MARK: - Protocol rejection

    @Test("Unknown Content-Type returns 415")
    func unknownContentType() async throws {
        let app = Self.makeApp()
        try await app.test(.router) { client in
            var headers = HTTPFields()
            headers[.contentType] = "text/plain"

            let response = try await client.execute(
                uri: "/test.EchoService/Echo",
                method: .post,
                headers: headers,
                body: ByteBuffer(string: "hello")
            )
            #expect(response.status == .unsupportedMediaType)
        }
    }

    @Test("Unknown method path returns unimplemented error")
    func unknownMethod() async throws {
        let app = Self.makeApp()
        try await app.test(.router) { client in
            var headers = HTTPFields()
            headers[.contentType] = "application/json"

            let response = try await client.execute(
                uri: "/test.EchoService/NonExistent",
                method: .post,
                headers: headers,
                body: ByteBuffer(string: "{}")
            )
            // Should return a Connect error envelope
            #expect(response.status != .ok)
        }
    }

    @Test("Malformed path (no method) returns 404")
    func malformedPath() async throws {
        let app = Self.makeApp()
        try await app.test(.router) { client in
            var headers = HTTPFields()
            headers[.contentType] = "application/json"

            let response = try await client.execute(
                uri: "/no-slash-in-path",
                method: .post,
                headers: headers,
                body: ByteBuffer(string: "{}")
            )
            #expect(response.status == .notFound)
        }
    }

    // MARK: - Metadata round-trip

    @Test("Trailing metadata is returned as trailer-* headers (Connect)")
    func trailingMetadata() async throws {
        var router = ConnectRouter()
        router.registerUnary(
            method: MethodDescriptor(fullyQualifiedService: "test.EchoService", method: "Echo"),
            requestType: TestPingMessage.self,
            responseType: TestPingMessage.self,
            handler: { (request: ServerRequest<TestPingMessage>, _: ServerContext)
                -> ServerResponse<TestPingMessage> in
                ServerResponse(
                    message: TestPingMessage(text: "done"),
                    trailingMetadata: ["x-cost": "42"]
                )
            }
        )
        let app = Application(responder: router)
        try await app.test(.router) { client in
            var headers = HTTPFields()
            headers[.contentType] = "application/json"

            let response = try await client.execute(
                uri: "/test.EchoService/Echo",
                method: .post,
                headers: headers,
                body: ByteBuffer(string: #"{"text":"hello"}"#)
            )
            #expect(response.status == .ok)
            // Connect unary trailing metadata is sent as "Trailer-X-Cost: 42"
            let trailerCost = response.headers[HTTPField.Name("trailer-x-cost")!]
            #expect(trailerCost == "42")
        }
    }
}
