// Copyright 2026 David Monagle / Monagle Pty Ltd
// SPDX-License-Identifier: MIT

import GRPCCore
import HTTPTypes

// MARK: - HTTP header ↔ GRPCCore.Metadata conversion

/// HTTP headers that carry framing information and should NOT be forwarded to service handlers.
private let skippedRequestHeaders: Set<String> = [
    "content-type", "content-length", "transfer-encoding",
    "connection", "host", "te", "trailer", "upgrade",
    ":method", ":path", ":scheme", ":authority", ":status",
]

extension GRPCCore.Metadata {
    /// Build a Metadata instance from incoming request HTTP headers.
    /// Standard framing headers are filtered out.
    init(httpHeaders: HTTPFields) {
        self.init()
        for field in httpHeaders {
            let key = field.name.rawName.lowercased()
            guard !skippedRequestHeaders.contains(key) else { continue }
            self.addString(field.value, forKey: key)
        }
    }
}

extension HTTPFields {
    /// Append gRPC-style trailing metadata as `Trailer-*` prefixed response headers.
    /// Per the Connect spec, trailing metadata keys are prefixed with `trailer-`.
    mutating func appendTrailingMetadata(_ metadata: GRPCCore.Metadata) {
        for element in metadata {
            let key = "trailer-\(element.key)"
            switch element.value {
            case .string(let v):
                if let name = HTTPField.Name(key) {
                    append(HTTPField(name: name, value: v))
                }
            case .binary(let bytes):
                let encoded = Data(bytes).base64EncodedString()
                if let name = HTTPField.Name(key) {
                    append(HTTPField(name: name, value: encoded))
                }
            }
        }
    }
}

import Foundation
