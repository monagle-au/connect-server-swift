// Copyright 2026 David Monagle / Monagle Pty Ltd
// SPDX-License-Identifier: MIT

import Tracing

// MARK: - RPCSpanAttributes

/// OpenTelemetry RPC semantic convention attribute keys.
///
/// Reference: https://opentelemetry.io/docs/specs/semconv/rpc/
enum RPCSpanAttributes {
    static let system = "rpc.system"
    static let service = "rpc.service"
    static let method = "rpc.method"
    static let grpcStatusCode = "rpc.grpc.status_code"
    static let connectStatusCode = "rpc.connect.status_code"
    static let connectCodec = "rpc.connect.codec"

    // MARK: - rpc.system values
    static let systemConnect = "connect"
    static let systemGRPCWeb = "grpc_web"
    static let systemGRPC = "grpc"
}

extension SpanAttributes {
    /// Sets all standard RPC span attributes for a ConnectServer request.
    mutating func setRPC(
        system: String,
        service: String,
        method: String,
        codec: (any MessageCodec)? = nil
    ) {
        self[RPCSpanAttributes.system] = system
        self[RPCSpanAttributes.service] = service
        self[RPCSpanAttributes.method] = method
        if let codec {
            self[RPCSpanAttributes.connectCodec] = codec.contentType.split(separator: "/").last.map(String.init) ?? codec.contentType
        }
    }
}
