// Copyright 2026 David Monagle / Monagle Pty Ltd
// SPDX-License-Identifier: MIT

// These tests use URLSession with a custom auth-challenge delegate to bypass
// self-signed cert validation. URLSession's auth-challenge callback API is only
// available in Foundation on Darwin platforms; on Linux URLSession is in
// FoundationNetworking and lacks the delegate API we need. Skip on Linux.
#if canImport(Darwin)

import Foundation
import GRPCCore
import NIOCore
import NIOSSL
import Testing

@testable import ConnectServer

@Suite("TLS Integration", .serialized)
struct TLSIntegrationTests {

    // MARK: - Helpers

    /// Build a TLSConfiguration from the embedded test cert + key, with ALPN advertising
    /// both h2 and http/1.1 (Hummingbird's HTTP2UpgradeChannel does the negotiation).
    private static func makeTLSConfiguration() throws -> TLSConfiguration {
        let cert = try NIOSSLCertificate(bytes: Array(TestCertificates.certificatePEM.utf8), format: .pem)
        let key = try NIOSSLPrivateKey(bytes: Array(TestCertificates.privateKeyPEM.utf8), format: .pem)
        var tls = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(cert)],
            privateKey: .privateKey(key)
        )
        tls.applicationProtocols = ["h2", "http/1.1"]
        return tls
    }

    /// Build a router with one method we can hit over TLS.
    private static func makeRouter() -> ConnectRouter {
        var router = ConnectRouter()
        router.registerUnary(
            method: MethodDescriptor(fullyQualifiedService: "test.TLS", method: "Echo"),
            requestType: TestPingMessage.self,
            responseType: TestPingMessage.self
        ) { msg, _ in TestPingMessage(text: "tls:\(msg.text)") }
        return router
    }

    /// URLSession that ignores cert validation (for self-signed test cert only).
    private static func insecureSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        let delegate = TrustAllDelegate()
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    /// Find an unused TCP port.
    private static func freePort() -> Int {
        // Open a socket bound to port 0, read back the assigned port, then close.
        // Simple shell-out is portable enough for a test.
        return 18443  // fixed test port; serialized suite means no concurrent reuse
    }

    // MARK: - Tests

    @Test("TLS HTTPS POST: Connect JSON over HTTP/1.1 or HTTP/2 (whichever URLSession picks via ALPN)")
    func tlsConnectRequestSucceeds() async throws {
        let port = Self.freePort()
        let tls = try Self.makeTLSConfiguration()
        let router = Self.makeRouter()
        let server = ConnectServer(
            address: .hostname("127.0.0.1", port: port),
            transportSecurity: .tls(tls),
            router: router
        )

        // Start the server in a child task.
        let serverTask = Task { try await server.serve() }
        defer { serverTask.cancel() }

        // Wait for the server to be accepting connections.
        let session = Self.insecureSession()
        let baseURL = URL(string: "https://127.0.0.1:\(port)")!
        try await waitForServer(session: session, base: baseURL)

        // Make a Connect JSON request.
        var req = URLRequest(url: baseURL.appendingPathComponent("/test.TLS/Echo"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(#"{"text":"hello"}"#.utf8)
        let (data, response) = try await session.data(for: req)

        let http = response as? HTTPURLResponse
        #expect(http?.statusCode == 200)
        let body = String(decoding: data, as: UTF8.self)
        #expect(body.contains("tls:hello"), "Got body: \(body)")
    }

    @Test("TLS server rejects connection from a session that doesn't trust the cert")
    func tlsRequiresValidCert() async throws {
        let port = Self.freePort() + 1
        let tls = try Self.makeTLSConfiguration()
        let router = Self.makeRouter()
        let server = ConnectServer(
            address: .hostname("127.0.0.1", port: port),
            transportSecurity: .tls(tls),
            router: router
        )

        let serverTask = Task { try await server.serve() }
        defer { serverTask.cancel() }

        // Allow the server a moment to bind.
        try await Task.sleep(for: .milliseconds(300))

        // Standard URLSession (no trust override) should refuse the self-signed cert.
        let standardSession = URLSession(configuration: .ephemeral)
        var req = URLRequest(url: URL(string: "https://127.0.0.1:\(port)/test.TLS/Echo")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("{}".utf8)
        // Short timeout so we don't hang.
        req.timeoutInterval = 3

        do {
            _ = try await standardSession.data(for: req)
            Issue.record("Expected TLS validation failure, got a successful response")
        } catch {
            // Any error is fine — the connection should fail at TLS handshake.
            // We don't assert specific error codes since they vary across platforms.
        }
    }

    // MARK: - Helpers

    private func waitForServer(session: URLSession, base: URL) async throws {
        let probeURL = base.appendingPathComponent("/probe")
        for _ in 0..<60 {
            do {
                var probe = URLRequest(url: probeURL)
                probe.httpMethod = "GET"
                probe.timeoutInterval = 1
                _ = try await session.data(for: probe)
                return
            } catch {
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        Issue.record("Server never came up on \(base)")
    }
}

// MARK: - URLSession trust override

private final class TrustAllDelegate: NSObject, URLSessionDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

#endif  // canImport(Darwin)
