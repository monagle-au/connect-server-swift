// Copyright 2026 David Monagle / Monagle Pty Ltd
// SPDX-License-Identifier: MIT

// MARK: - CORSConfiguration

/// CORS configuration for browser-originated Connect / gRPC-Web requests.
///
/// Defaults are spec-compliant for `@connectrpc/connect-web` and `grpc-web` clients
/// per https://connectrpc.com/docs/cors.
///
/// Usage:
/// ```swift
/// // Permissive (any origin, no credentials)
/// var router = ConnectRouter(cors: .permissive())
///
/// // Strict (specific origins)
/// var router = ConnectRouter(cors: .strict(allowedOrigins: ["https://app.example.com"]))
///
/// // Custom matcher
/// var router = ConnectRouter(cors: CORSConfiguration(
///     allowedOrigins: .matching { origin in origin.hasSuffix(".example.com") }
/// ))
/// ```
public struct CORSConfiguration: Sendable {

    /// How allowed origins are matched.
    public enum AllowedOrigins: Sendable {
        /// Allow any origin. Sends `Access-Control-Allow-Origin: *`.
        /// Note: incompatible with `allowCredentials = true` per CORS spec.
        case any
        /// Allow only the listed origins (exact match, case-sensitive).
        case specific([String])
        /// Allow any origin for which the predicate returns true.
        case matching(@Sendable (String) -> Bool)
    }

    public var allowedOrigins: AllowedOrigins
    public var allowedHeaders: [String]
    public var exposedHeaders: [String]
    public var allowCredentials: Bool
    public var maxAgeSeconds: Int

    public init(
        allowedOrigins: AllowedOrigins,
        allowedHeaders: [String] = CORSConfiguration.standardAllowedHeaders,
        exposedHeaders: [String] = CORSConfiguration.standardExposedHeaders,
        allowCredentials: Bool = false,
        maxAgeSeconds: Int = 7200
    ) {
        self.allowedOrigins = allowedOrigins
        self.allowedHeaders = allowedHeaders
        self.exposedHeaders = exposedHeaders
        self.allowCredentials = allowCredentials
        self.maxAgeSeconds = maxAgeSeconds
    }

    // MARK: - Spec-required headers

    /// Headers that connect-web / grpc-web clients send and must be allowed.
    /// Per https://connectrpc.com/docs/cors.
    public static let standardAllowedHeaders: [String] = [
        "Content-Type",
        "Connect-Protocol-Version",
        "Connect-Timeout-Ms",
        "X-User-Agent",
        "X-Grpc-Web",
        "Grpc-Timeout",
    ]

    /// Headers that gRPC-Web reads from responses and must be exposed.
    /// `*` covers `trailer-*` Connect headers; if you need `allowCredentials`,
    /// `*` is invalid per CORS spec — list specific trailer names instead.
    public static let standardExposedHeaders: [String] = [
        "Grpc-Status",
        "Grpc-Message",
        "Grpc-Status-Details-Bin",
        "*",
    ]

    // MARK: - Convenience factories

    /// Permissive: any origin, default headers, no credentials.
    /// Suitable for development or public APIs.
    public static func permissive() -> Self {
        CORSConfiguration(allowedOrigins: .any)
    }

    /// Strict: only the listed origins, default headers, no credentials.
    public static func strict(allowedOrigins: [String]) -> Self {
        CORSConfiguration(allowedOrigins: .specific(allowedOrigins))
    }

    // MARK: - Internal

    /// Resolves the value to send in `Access-Control-Allow-Origin`, or nil if the
    /// request origin is not allowed.
    func resolveOrigin(_ requestOrigin: String) -> String? {
        switch allowedOrigins {
        case .any:
            return "*"
        case .specific(let allowed):
            return allowed.contains(requestOrigin) ? requestOrigin : nil
        case .matching(let predicate):
            return predicate(requestOrigin) ? requestOrigin : nil
        }
    }

    /// Whether the configuration requires `Vary: Origin` in responses
    /// (true when allowed origin depends on the request origin).
    var requiresVaryOrigin: Bool {
        switch allowedOrigins {
        case .any: return false
        case .specific, .matching: return true
        }
    }
}
