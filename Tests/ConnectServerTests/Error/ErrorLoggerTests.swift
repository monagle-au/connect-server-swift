// Copyright 2026 David Monagle / Monagle Pty Ltd
// SPDX-License-Identifier: MIT

import Foundation
import GRPCCore
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import NIOCore
import Synchronization
import Testing

@testable import ConnectServer

/// Captures invocations for assertions. Sendable via `Mutex`.
private final class CapturedInvocations: Sendable {
    private let invocations = Mutex<[(error: any Error, descriptor: MethodDescriptor)]>([])

    func record(_ error: any Error, _ descriptor: MethodDescriptor) {
        invocations.withLock { $0.append((error, descriptor)) }
    }

    var snapshot: [(error: any Error, descriptor: MethodDescriptor)] {
        invocations.withLock { $0 }
    }

    var count: Int {
        invocations.withLock { $0.count }
    }
}

@Suite("ConnectRouter.errorLogger")
struct ErrorLoggerTests {

    private static let echoMethod = MethodDescriptor(
        fullyQualifiedService: "test.EchoService",
        method: "Echo"
    )

    private static func makeRouter(
        captured: CapturedInvocations,
        thrownError: @Sendable @escaping () -> any Error
    ) -> ConnectRouter {
        var router = ConnectRouter(errorLogger: { error, descriptor in
            captured.record(error, descriptor)
        })
        router.registerUnary(
            method: echoMethod,
            requestType: TestPingMessage.self,
            responseType: TestPingMessage.self
        ) { (_: TestPingMessage, _: ServerContext) -> TestPingMessage in
            throw thrownError()
        }
        return router
    }

    @Test("errorLogger fires on RPCError thrown from a unary handler — Connect protocol")
    func loggerFiresOnRPCErrorConnect() async throws {
        let captured = CapturedInvocations()
        let router = Self.makeRouter(captured: captured) {
            RPCError(code: .notFound, message: "missing")
        }
        let app = Application(responder: router)
        try await app.test(.router) { client in
            var headers = HTTPFields()
            headers[.contentType] = "application/json"
            _ = try await client.execute(
                uri: "/test.EchoService/Echo",
                method: .post,
                headers: headers,
                body: ByteBuffer(string: "{}")
            )
        }
        #expect(captured.count == 1)
        let invocation = captured.snapshot[0]
        #expect(invocation.descriptor == Self.echoMethod)
        let rpcError = invocation.error as? RPCError
        #expect(rpcError?.code == .notFound)
        #expect(rpcError?.message == "missing")
    }

    @Test("errorLogger fires on non-RPCError thrown from a unary handler")
    func loggerFiresOnGenericError() async throws {
        struct MyError: Error, Equatable {
            let tag: String
        }
        let captured = CapturedInvocations()
        let router = Self.makeRouter(captured: captured) { MyError(tag: "boom") }
        let app = Application(responder: router)
        try await app.test(.router) { client in
            var headers = HTTPFields()
            headers[.contentType] = "application/json"
            _ = try await client.execute(
                uri: "/test.EchoService/Echo",
                method: .post,
                headers: headers,
                body: ByteBuffer(string: "{}")
            )
        }
        #expect(captured.count == 1)
        let myError = captured.snapshot[0].error as? MyError
        #expect(myError == MyError(tag: "boom"))
    }

    @Test("errorLogger does not fire on success")
    func loggerSilentOnSuccess() async throws {
        let captured = CapturedInvocations()
        var router = ConnectRouter(errorLogger: { error, descriptor in
            captured.record(error, descriptor)
        })
        router.registerUnary(
            method: Self.echoMethod,
            requestType: TestPingMessage.self,
            responseType: TestPingMessage.self
        ) { message, _ in
            TestPingMessage(text: "echo: \(message.text)")
        }
        let app = Application(responder: router)
        try await app.test(.router) { client in
            var headers = HTTPFields()
            headers[.contentType] = "application/json"
            _ = try await client.execute(
                uri: "/test.EchoService/Echo",
                method: .post,
                headers: headers,
                body: ByteBuffer(string: #"{"text":"world"}"#)
            )
        }
        #expect(captured.count == 0)
    }

    @Test("absent errorLogger preserves existing behaviour — error still serialized to wire")
    func absentLoggerSilent() async throws {
        var router = ConnectRouter()
        router.registerUnary(
            method: Self.echoMethod,
            requestType: TestPingMessage.self,
            responseType: TestPingMessage.self
        ) { (_: TestPingMessage, _: ServerContext) -> TestPingMessage in
            throw RPCError(code: .notFound, message: "missing")
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
        }
    }
}
