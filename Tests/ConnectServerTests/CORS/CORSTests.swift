// Copyright 2026 David Monagle / Monagle Pty Ltd
// SPDX-License-Identifier: MIT

import GRPCCore
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import NIOCore
import Testing

@testable import ConnectServer

// MARK: - CORS Tests

@Suite("CORS")
struct CORSTests {

    private static func makeRouter(cors: CORSConfiguration?) -> ConnectRouter {
        var router = ConnectRouter(cors: cors)
        router.registerUnary(
            method: MethodDescriptor(fullyQualifiedService: "test.EchoService", method: "Echo"),
            requestType: TestPingMessage.self,
            responseType: TestPingMessage.self
        ) { message, _ in
            TestPingMessage(text: "echo: \(message.text)")
        }
        return router
    }

    // MARK: - resolveOrigin

    @Test("AllowedOrigins.any always returns *")
    func anyOriginReturnsWildcard() {
        let cors = CORSConfiguration(allowedOrigins: .any)
        #expect(cors.resolveOrigin("https://example.com") == "*")
        #expect(cors.resolveOrigin("https://attacker.com") == "*")
    }

    @Test("AllowedOrigins.specific allows exact matches and rejects others")
    func specificOriginMatching() {
        let cors = CORSConfiguration(allowedOrigins: .specific(["https://app.example.com"]))
        #expect(cors.resolveOrigin("https://app.example.com") == "https://app.example.com")
        #expect(cors.resolveOrigin("https://other.example.com") == nil)
        #expect(cors.resolveOrigin("https://APP.example.com") == nil) // case-sensitive
    }

    @Test("AllowedOrigins.matching with predicate")
    func predicateOriginMatching() {
        let cors = CORSConfiguration(allowedOrigins: .matching { $0.hasSuffix(".example.com") })
        #expect(cors.resolveOrigin("https://app.example.com") == "https://app.example.com")
        #expect(cors.resolveOrigin("https://api.example.com") == "https://api.example.com")
        #expect(cors.resolveOrigin("https://attacker.com") == nil)
    }

    // MARK: - Preflight (OPTIONS)

    @Test("OPTIONS preflight returns 204 with CORS headers")
    func preflightSuccess() async throws {
        let app = Application(responder: Self.makeRouter(cors: .permissive()))
        try await app.test(.router) { client in
            var headers = HTTPFields()
            headers[HTTPField.Name("Origin")!] = "https://example.com"
            headers[HTTPField.Name("Access-Control-Request-Method")!] = "POST"

            let response = try await client.execute(
                uri: "/test.EchoService/Echo",
                method: .options,
                headers: headers,
                body: nil
            )
            #expect(response.status == .noContent)
            #expect(response.headers[HTTPField.Name("Access-Control-Allow-Origin")!] == "*")
            let allowedHeaders = response.headers[HTTPField.Name("Access-Control-Allow-Headers")!] ?? ""
            #expect(allowedHeaders.contains("Content-Type"))
            #expect(allowedHeaders.contains("Connect-Protocol-Version"))
            #expect(allowedHeaders.contains("X-Grpc-Web"))
            let allowedMethods = response.headers[HTTPField.Name("Access-Control-Allow-Methods")!] ?? ""
            #expect(allowedMethods.contains("POST"))
            let maxAge = response.headers[HTTPField.Name("Access-Control-Max-Age")!]
            #expect(maxAge == "7200")
            // No Allow-Credentials when not configured
            #expect(response.headers[HTTPField.Name("Access-Control-Allow-Credentials")!] == nil)
        }
    }

    @Test("OPTIONS preflight from disallowed origin returns 403")
    func preflightDisallowedOrigin() async throws {
        let cors = CORSConfiguration.strict(allowedOrigins: ["https://app.example.com"])
        let app = Application(responder: Self.makeRouter(cors: cors))
        try await app.test(.router) { client in
            var headers = HTTPFields()
            headers[HTTPField.Name("Origin")!] = "https://attacker.com"
            headers[HTTPField.Name("Access-Control-Request-Method")!] = "POST"

            let response = try await client.execute(
                uri: "/test.EchoService/Echo",
                method: .options,
                headers: headers
            )
            #expect(response.status == .forbidden)
            #expect(response.headers[HTTPField.Name("Access-Control-Allow-Origin")!] == nil)
        }
    }

    @Test("OPTIONS without Origin header is treated as non-CORS")
    func preflightNoOrigin() async throws {
        let app = Application(responder: Self.makeRouter(cors: .permissive()))
        try await app.test(.router) { client in
            let response = try await client.execute(
                uri: "/test.EchoService/Echo",
                method: .options,
                headers: HTTPFields()
            )
            #expect(response.status == .noContent)
            #expect(response.headers[HTTPField.Name("Access-Control-Allow-Origin")!] == nil)
        }
    }

    @Test("Strict CORS preflight echoes specific origin (not *)")
    func strictPreflightEchoesOrigin() async throws {
        let cors = CORSConfiguration.strict(allowedOrigins: ["https://app.example.com"])
        let app = Application(responder: Self.makeRouter(cors: cors))
        try await app.test(.router) { client in
            var headers = HTTPFields()
            headers[HTTPField.Name("Origin")!] = "https://app.example.com"

            let response = try await client.execute(
                uri: "/test.EchoService/Echo",
                method: .options,
                headers: headers
            )
            #expect(response.status == .noContent)
            #expect(response.headers[HTTPField.Name("Access-Control-Allow-Origin")!] == "https://app.example.com")
        }
    }

    @Test("Allow-Credentials sent when configured")
    func allowCredentials() async throws {
        let cors = CORSConfiguration(
            allowedOrigins: .specific(["https://app.example.com"]),
            allowCredentials: true
        )
        let app = Application(responder: Self.makeRouter(cors: cors))
        try await app.test(.router) { client in
            var headers = HTTPFields()
            headers[HTTPField.Name("Origin")!] = "https://app.example.com"

            let response = try await client.execute(
                uri: "/test.EchoService/Echo",
                method: .options,
                headers: headers
            )
            #expect(response.headers[HTTPField.Name("Access-Control-Allow-Credentials")!] == "true")
        }
    }

    // MARK: - CORS headers on actual responses

    @Test("Successful response includes CORS headers when Origin is present")
    func successResponseHasCORS() async throws {
        let app = Application(responder: Self.makeRouter(cors: .permissive()))
        try await app.test(.router) { client in
            var headers = HTTPFields()
            headers[.contentType] = "application/json"
            headers[HTTPField.Name("Origin")!] = "https://example.com"

            let response = try await client.execute(
                uri: "/test.EchoService/Echo",
                method: .post,
                headers: headers,
                body: ByteBuffer(string: #"{"text":"hi"}"#)
            )
            #expect(response.status == .ok)
            #expect(response.headers[HTTPField.Name("Access-Control-Allow-Origin")!] == "*")
            let exposed = response.headers[HTTPField.Name("Access-Control-Expose-Headers")!] ?? ""
            #expect(exposed.contains("Grpc-Status"))
        }
    }

    @Test("Response without Origin header has no CORS headers")
    func responseWithoutOriginNoCORS() async throws {
        let app = Application(responder: Self.makeRouter(cors: .permissive()))
        try await app.test(.router) { client in
            var headers = HTTPFields()
            headers[.contentType] = "application/json"

            let response = try await client.execute(
                uri: "/test.EchoService/Echo",
                method: .post,
                headers: headers,
                body: ByteBuffer(string: #"{"text":"hi"}"#)
            )
            #expect(response.status == .ok)
            #expect(response.headers[HTTPField.Name("Access-Control-Allow-Origin")!] == nil)
        }
    }

    @Test("Strict CORS adds Vary: Origin to actual responses")
    func strictResponseHasVary() async throws {
        let cors = CORSConfiguration.strict(allowedOrigins: ["https://app.example.com"])
        let app = Application(responder: Self.makeRouter(cors: cors))
        try await app.test(.router) { client in
            var headers = HTTPFields()
            headers[.contentType] = "application/json"
            headers[HTTPField.Name("Origin")!] = "https://app.example.com"

            let response = try await client.execute(
                uri: "/test.EchoService/Echo",
                method: .post,
                headers: headers,
                body: ByteBuffer(string: #"{"text":"hi"}"#)
            )
            #expect(response.status == .ok)
            #expect(response.headers[HTTPField.Name("Vary")!] == "Origin")
        }
    }

    @Test("CORS disabled (nil): no CORS headers on response")
    func corsDisabled() async throws {
        let app = Application(responder: Self.makeRouter(cors: nil))
        try await app.test(.router) { client in
            var headers = HTTPFields()
            headers[.contentType] = "application/json"
            headers[HTTPField.Name("Origin")!] = "https://example.com"

            let response = try await client.execute(
                uri: "/test.EchoService/Echo",
                method: .post,
                headers: headers,
                body: ByteBuffer(string: #"{"text":"hi"}"#)
            )
            #expect(response.status == .ok)
            #expect(response.headers[HTTPField.Name("Access-Control-Allow-Origin")!] == nil)
        }
    }

    // MARK: - Error responses also get CORS headers

    @Test("415 Unsupported Media Type response includes CORS headers")
    func errorResponseHasCORS() async throws {
        let app = Application(responder: Self.makeRouter(cors: .permissive()))
        try await app.test(.router) { client in
            var headers = HTTPFields()
            headers[.contentType] = "text/plain"
            headers[HTTPField.Name("Origin")!] = "https://example.com"

            let response = try await client.execute(
                uri: "/test.EchoService/Echo",
                method: .post,
                headers: headers,
                body: ByteBuffer(string: "hi")
            )
            #expect(response.status == .unsupportedMediaType)
            #expect(response.headers[HTTPField.Name("Access-Control-Allow-Origin")!] == "*")
        }
    }
}
