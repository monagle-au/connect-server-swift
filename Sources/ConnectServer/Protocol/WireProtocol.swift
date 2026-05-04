// Copyright 2026 David Monagle / Monagle Pty Ltd
// SPDX-License-Identifier: MIT

// MARK: - WireProtocol

/// The RPC wire protocol detected from a request's Content-Type.
public enum WireProtocol: Hashable, Sendable {
    case connect
    case grpcWeb
    case grpc
}

// MARK: - DetectedProtocol

/// Result of protocol detection: which protocol and which codec to use.
struct DetectedProtocol: Sendable {
    let wireProtocol: WireProtocol
    let codec: any MessageCodec
    /// True only for `application/grpc-web-text` (base64 body) — deferred to Phase 2.
    let isTextEncoded: Bool

    // MARK: - Detection

    /// Detect wire protocol and codec from a Content-Type string.
    ///
    /// Decision tree (evaluated in order):
    /// 1. Starts with "application/grpc-web"  → gRPC-Web
    /// 2. Starts with "application/grpc"       → gRPC
    /// 3. "application/json"                   → Connect unary, JSON codec
    /// 4. "application/proto"                  → Connect unary, proto codec
    /// 5. Starts with "application/connect+"   → Connect streaming (codec from suffix)
    /// 6. Otherwise                            → nil (415 Unsupported Media Type)
    static func detect(contentType: String) -> DetectedProtocol? {
        let ct = contentType.lowercased()
        if ct.hasPrefix("application/grpc-web") {
            let isText = ct.hasPrefix("application/grpc-web-text")
            return DetectedProtocol(
                wireProtocol: .grpcWeb,
                codec: ProtoCodec(),
                isTextEncoded: isText
            )
        }
        if ct.hasPrefix("application/grpc") {
            return DetectedProtocol(wireProtocol: .grpc, codec: ProtoCodec(), isTextEncoded: false)
        }
        if ct == "application/json" {
            return DetectedProtocol(wireProtocol: .connect, codec: JSONCodec(), isTextEncoded: false)
        }
        if ct == "application/proto" {
            return DetectedProtocol(wireProtocol: .connect, codec: ProtoCodec(), isTextEncoded: false)
        }
        if ct.hasPrefix("application/connect+") {
            let suffix = ct.dropFirst("application/connect+".count)
            let codec: any MessageCodec = suffix == "json" ? JSONCodec() : ProtoCodec()
            return DetectedProtocol(wireProtocol: .connect, codec: codec, isTextEncoded: false)
        }
        return nil
    }
}
