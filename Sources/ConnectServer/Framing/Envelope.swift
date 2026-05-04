// Copyright 2026 David Monagle / Monagle Pty Ltd
// SPDX-License-Identifier: MIT

import NIOCore

// MARK: - Envelope

/// 5-byte length-prefixed envelope shared by gRPC, gRPC-Web, and Connect streaming.
///
/// Wire format: [1-byte flags][4-byte big-endian message length][payload]
///
/// Flags (bit 0): compression flag — set if payload is compressed.
/// Flags (bit 1): end-stream flag (Connect streaming only) — set on the final EndStreamResponse.
enum Envelope {
    static let headerSize = 5

    struct Header {
        let flags: UInt8
        let messageLength: UInt32

        var isCompressed: Bool { flags & 0x01 != 0 }
        var isEndStream: Bool { flags & 0x02 != 0 }
        var isTrailerFrame: Bool { flags & 0x80 != 0 }
    }

    enum ReadError: Error {
        case insufficientBytes
        case messageTooLarge(declared: UInt32, available: Int)
    }

    static func readHeader(from buffer: inout ByteBuffer) throws -> Header {
        guard buffer.readableBytes >= headerSize else {
            throw ReadError.insufficientBytes
        }
        let flags = buffer.readInteger(as: UInt8.self)!
        let length = buffer.readInteger(endianness: .big, as: UInt32.self)!
        return Header(flags: flags, messageLength: length)
    }

    static func readMessage(from buffer: inout ByteBuffer) throws -> (Header, ByteBuffer) {
        var copy = buffer
        let header = try readHeader(from: &copy)
        let msgLen = Int(header.messageLength)
        guard copy.readableBytes >= msgLen else {
            throw ReadError.messageTooLarge(declared: header.messageLength, available: copy.readableBytes)
        }
        let payload = copy.readSlice(length: msgLen)!
        buffer = copy
        return (header, payload)
    }

    static func write(flags: UInt8, payload: ByteBuffer, into buffer: inout ByteBuffer) {
        let length = UInt32(payload.readableBytes)
        buffer.writeInteger(flags, as: UInt8.self)
        buffer.writeInteger(length, endianness: .big, as: UInt32.self)
        var mutablePayload = payload
        buffer.writeBuffer(&mutablePayload)
    }

    static func frameMessage(_ payload: ByteBuffer, compressed: Bool = false) -> ByteBuffer {
        var out = ByteBufferAllocator().buffer(capacity: headerSize + payload.readableBytes)
        let flags: UInt8 = compressed ? 0x01 : 0x00
        write(flags: flags, payload: payload, into: &out)
        return out
    }
}
