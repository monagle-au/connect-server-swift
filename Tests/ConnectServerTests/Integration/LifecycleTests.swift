// Copyright 2026 David Monagle / Monagle Pty Ltd
// SPDX-License-Identifier: MIT

import GRPCCore
import Testing

@testable import ConnectServer

@Suite("Lifecycle")
struct LifecycleTests {

    /// When the surrounding Task is cancelled, `serve()` must throw `CancellationError`
    /// rather than returning normally. swift-service-lifecycle's ServiceGroup uses the
    /// throw to classify the termination as expected; without it, every graceful
    /// shutdown is logged as "A service has finished unexpectedly".
    @Test("serve() throws CancellationError when its task is cancelled")
    func serveThrowsOnCancellation() async throws {
        var router = ConnectRouter()
        router.registerUnary(
            method: MethodDescriptor(fullyQualifiedService: "test.EchoService", method: "Echo"),
            requestType: TestPingMessage.self,
            responseType: TestPingMessage.self
        ) { msg, _ in TestPingMessage(text: msg.text) }

        let server = ConnectServer(
            address: .hostname("127.0.0.1", port: 0),
            router: router
        )

        let serverTask = Task { try await server.serve() }

        // Give Hummingbird a moment to bind before we cancel.
        try await Task.sleep(for: .milliseconds(200))
        serverTask.cancel()

        await #expect(throws: CancellationError.self) {
            try await serverTask.value
        }
    }
}
