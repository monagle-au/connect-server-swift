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

// MARK: - Timeout Parser Tests

@Suite("Timeout Parsers")
struct TimeoutParserTests {
    // MARK: - Connect-Timeout-Ms

    @Test("Connect: parses positive integer milliseconds")
    func connectValidValues() {
        #expect(Timeout.parseConnect("1") == .milliseconds(1))
        #expect(Timeout.parseConnect("5000") == .milliseconds(5000))
        #expect(Timeout.parseConnect("60000") == .milliseconds(60000))
    }

    @Test("Connect: rejects empty, zero, non-numeric, too long")
    func connectInvalidValues() {
        #expect(Timeout.parseConnect(nil) == nil)
        #expect(Timeout.parseConnect("") == nil)
        #expect(Timeout.parseConnect("0") == nil)
        #expect(Timeout.parseConnect("abc") == nil)
        #expect(Timeout.parseConnect("12345678901") == nil)  // 11 digits, exceeds max
        #expect(Timeout.parseConnect("-100") == nil)
    }

    // MARK: - grpc-timeout

    @Test("gRPC: parses unit suffixes")
    func grpcUnits() {
        #expect(Timeout.parseGRPC("5S") == .seconds(5))
        #expect(Timeout.parseGRPC("100m") == .milliseconds(100))
        #expect(Timeout.parseGRPC("30M") == .seconds(30 * 60))
        #expect(Timeout.parseGRPC("1H") == .seconds(3600))
        #expect(Timeout.parseGRPC("500u") == .microseconds(500))
        #expect(Timeout.parseGRPC("1000n") == .nanoseconds(1000))
    }

    @Test("gRPC: rejects malformed values")
    func grpcInvalidValues() {
        #expect(Timeout.parseGRPC(nil) == nil)
        #expect(Timeout.parseGRPC("") == nil)
        #expect(Timeout.parseGRPC("S") == nil)        // no number
        #expect(Timeout.parseGRPC("100") == nil)      // no unit
        #expect(Timeout.parseGRPC("100x") == nil)     // unknown unit
        #expect(Timeout.parseGRPC("0S") == nil)       // zero is not positive
    }
}

// MARK: - Timeout Execution Tests

@Suite("Timeout Execution")
struct TimeoutExecutionTests {
    @Test("withDeadline: nil duration runs without timeout")
    func nilDeadlineRunsToCompletion() async throws {
        let result = try await Timeout.withDeadline(nil) { 42 }
        #expect(result == 42)
    }

    @Test("withDeadline: completes before deadline")
    func completesBeforeDeadline() async throws {
        let result = try await Timeout.withDeadline(.milliseconds(500)) {
            42
        }
        #expect(result == 42)
    }

    @Test("withDeadline: throws deadlineExceeded if operation exceeds deadline")
    func operationExceedsDeadline() async {
        do {
            _ = try await Timeout.withDeadline(.milliseconds(50)) {
                try await Task.sleep(for: .seconds(5))
                return 42
            }
            Issue.record("Expected timeout error")
        } catch let error as RPCError {
            #expect(error.code == .deadlineExceeded)
        } catch {
            Issue.record("Wrong error type: \(error)")
        }
    }

    @Test("withDeadline: propagates handler errors (not deadline)")
    func propagatesHandlerErrors() async {
        do {
            _ = try await Timeout.withDeadline(.seconds(5)) {
                throw RPCError(code: .notFound, message: "missing")
            }
            Issue.record("Expected error to propagate")
        } catch let error as RPCError {
            #expect(error.code == .notFound)
            #expect(error.message == "missing")
        } catch {
            Issue.record("Wrong error type: \(error)")
        }
    }
}

// MARK: - Integration: timeout enforced in actual request flow

@Suite("Timeout Integration")
struct TimeoutIntegrationTests {
    private static func slowRouter(sleep: Duration) -> ConnectRouter {
        var router = ConnectRouter()
        router.registerUnary(
            method: MethodDescriptor(fullyQualifiedService: "test.SlowService", method: "Slow"),
            requestType: TestPingMessage.self,
            responseType: TestPingMessage.self
        ) { (_: TestPingMessage, _: ServerContext) -> TestPingMessage in
            try await Task.sleep(for: sleep)
            return TestPingMessage(text: "done")
        }
        return router
    }

    @Test("Connect: Connect-Timeout-Ms enforces deadline")
    func connectTimeoutEnforced() async throws {
        let app = Application(responder: Self.slowRouter(sleep: .seconds(5)))
        try await app.test(.router) { client in
            var headers = HTTPFields()
            headers[.contentType] = "application/json"
            headers[HTTPField.Name("Connect-Timeout-Ms")!] = "50"

            let response = try await client.execute(
                uri: "/test.SlowService/Slow",
                method: .post,
                headers: headers,
                body: ByteBuffer(string: "{}")
            )
            #expect(response.status == .requestTimeout)
            let json = String(buffer: response.body)
            #expect(json.contains("deadline_exceeded"))
        }
    }

    @Test("gRPC-Web: grpc-timeout enforces deadline")
    func grpcWebTimeoutEnforced() async throws {
        let app = Application(responder: Self.slowRouter(sleep: .seconds(5)))
        try await app.test(.router) { client in
            var headers = HTTPFields()
            headers[.contentType] = "application/grpc-web+proto"
            headers[HTTPField.Name("grpc-timeout")!] = "50m"  // 50 milliseconds

            let response = try await client.execute(
                uri: "/test.SlowService/Slow",
                method: .post,
                headers: headers,
                body: Envelope.frameMessage(ByteBuffer())
            )
            #expect(response.status == .ok)  // gRPC-Web is always 200
            var body = response.body
            // Skip past any data frame; find the trailer frame
            while body.readableBytes > 0 {
                let (header, payload) = try Envelope.readMessage(from: &body)
                if header.isTrailerFrame {
                    let trailerStr = String(buffer: payload)
                    #expect(trailerStr.contains("grpc-status: 4"))  // 4 = deadline_exceeded
                    return
                }
            }
            Issue.record("No trailer frame found")
        }
    }

    @Test("No timeout header: handler completes normally")
    func noTimeoutHeaderNoDeadline() async throws {
        let app = Application(responder: Self.slowRouter(sleep: .milliseconds(20)))
        try await app.test(.router) { client in
            var headers = HTTPFields()
            headers[.contentType] = "application/json"

            let response = try await client.execute(
                uri: "/test.SlowService/Slow",
                method: .post,
                headers: headers,
                body: ByteBuffer(string: "{}")
            )
            #expect(response.status == .ok)
        }
    }
}
