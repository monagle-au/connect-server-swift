// Copyright 2026 David Monagle / Monagle Pty Ltd
// SPDX-License-Identifier: MIT

import GRPCCore
import NIOCore

// MARK: - GRPCWebTrailers

/// Encodes and decodes gRPC-Web trailer frames.
///
/// gRPC-Web trailers are sent as a final body frame with flags byte `0x80`.
/// The payload is an HTTP/1 headers block: `key: value\r\n` pairs.
enum GRPCWebTrailers {
    /// Encodes a trailer frame body for a successful response.
    static func encode(status: Int, message: String? = nil, metadata: GRPCCore.Metadata) -> ByteBuffer {
        var payload = ""
        payload += "grpc-status: \(status)\r\n"
        if let message, !message.isEmpty {
            payload += "grpc-message: \(percentEncode(message))\r\n"
        }
        for element in metadata {
            let key = element.key.lowercased()
            // Skip reserved gRPC status headers — we write those ourselves.
            guard key != "grpc-status", key != "grpc-message" else { continue }
            switch element.value {
            case .string(let v):
                payload += "\(key): \(v)\r\n"
            case .binary(let bytes):
                let encoded = Data(bytes).base64EncodedString()
                payload += "\(key): \(encoded)\r\n"
            }
        }
        var buffer = ByteBufferAllocator().buffer(capacity: payload.utf8.count)
        buffer.writeString(payload)
        return buffer
    }

    /// Builds a full trailer frame (flag 0x80 + length-prefix + payload).
    static func frame(status: Int, message: String? = nil, metadata: GRPCCore.Metadata) -> ByteBuffer {
        let payload = encode(status: status, message: message, metadata: metadata)
        var out = ByteBufferAllocator().buffer(capacity: Envelope.headerSize + payload.readableBytes)
        Envelope.write(flags: 0x80, payload: payload, into: &out)
        return out
    }

    // MARK: - Private

    /// Percent-encodes a gRPC-message value per RFC 3986.
    private static func percentEncode(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.utf8.count)
        for byte in value.utf8 {
            // Allow printable ASCII except % and space
            if byte >= 0x20, byte <= 0x7E, byte != 0x25 {
                result.append(Character(UnicodeScalar(byte)))
            } else {
                result += String(format: "%%%02X", byte)
            }
        }
        return result
    }
}

// Bring Data into scope without a full Foundation import at the module boundary
import Foundation
