// Copyright 2026 David Monagle / Monagle Pty Ltd
// SPDX-License-Identifier: MIT

import NIOCore
import SwiftProtobuf

// MARK: - MessageCodec

/// A codec that can serialize and deserialize protobuf messages.
public protocol MessageCodec: Sendable {
    func deserialize<M: Message>(_ type: M.Type, from buffer: ByteBuffer) throws -> M
    func serialize<M: Message>(_ message: M) throws -> ByteBuffer
    var contentType: String { get }
}

// MARK: - ProtoCodec

/// Codec for binary protobuf encoding.
public struct ProtoCodec: MessageCodec {
    public init() {}

    public var contentType: String { "application/proto" }

    public func deserialize<M: Message>(_ type: M.Type, from buffer: ByteBuffer) throws -> M {
        // Convert to [UInt8] for SwiftProtobufContiguousBytes conformance.
        let bytes = Array(buffer.readableBytesView)
        return try M(serializedBytes: bytes)
    }

    public func serialize<M: Message>(_ message: M) throws -> ByteBuffer {
        let bytes: [UInt8] = try message.serializedBytes()
        var buffer = ByteBufferAllocator().buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        return buffer
    }
}

// MARK: - JSONCodec

/// Codec for JSON protobuf encoding.
public struct JSONCodec: MessageCodec {
    public init() {}

    public var contentType: String { "application/json" }

    public func deserialize<M: Message>(_ type: M.Type, from buffer: ByteBuffer) throws -> M {
        // Convert to [UInt8] — SwiftProtobufContiguousBytes conformance is assured.
        let bytes = Array(buffer.readableBytesView)
        return try M(jsonUTF8Bytes: bytes)
    }

    public func serialize<M: Message>(_ message: M) throws -> ByteBuffer {
        let bytes: [UInt8] = try message.jsonUTF8Bytes()
        var buffer = ByteBufferAllocator().buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        return buffer
    }
}
