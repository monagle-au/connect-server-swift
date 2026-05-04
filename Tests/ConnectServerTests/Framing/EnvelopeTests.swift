// Copyright 2026 David Monagle / Monagle Pty Ltd
// SPDX-License-Identifier: MIT

import NIOCore
import Testing

@testable import ConnectServer

@Suite("Envelope Framing")
struct EnvelopeTests {
    @Test("Writes and reads back a simple message frame")
    func roundTrip() throws {
        let payload = ByteBuffer(string: "hello world")
        let framed = Envelope.frameMessage(payload)
        var buffer = framed

        let (header, recovered) = try Envelope.readMessage(from: &buffer)
        #expect(header.flags == 0x00)
        #expect(header.messageLength == 11)
        #expect(header.isCompressed == false)
        #expect(header.isEndStream == false)
        #expect(String(buffer: recovered) == "hello world")
        #expect(buffer.readableBytes == 0)
    }

    @Test("Zero-length message frame")
    func zeroLength() throws {
        let payload = ByteBuffer()
        let framed = Envelope.frameMessage(payload)
        var buffer = framed

        let (header, recovered) = try Envelope.readMessage(from: &buffer)
        #expect(header.messageLength == 0)
        #expect(recovered.readableBytes == 0)
    }

    @Test("Compressed flag is preserved")
    func compressedFlag() throws {
        let payload = ByteBuffer(string: "compressed data")
        var buffer = ByteBufferAllocator().buffer(capacity: 64)
        Envelope.write(flags: 0x01, payload: payload, into: &buffer)

        let (header, _) = try Envelope.readMessage(from: &buffer)
        #expect(header.isCompressed == true)
        #expect(header.flags == 0x01)
    }

    @Test("Trailer frame flag (0x80) is detected")
    func trailerFlag() throws {
        let payload = ByteBuffer(string: "grpc-status: 0\r\n")
        var buffer = ByteBufferAllocator().buffer(capacity: 64)
        Envelope.write(flags: 0x80, payload: payload, into: &buffer)

        let (header, _) = try Envelope.readMessage(from: &buffer)
        #expect(header.isTrailerFrame == true)
        #expect(header.flags == 0x80)
    }

    @Test("Throws on insufficient bytes for header")
    func insufficientHeader() {
        var buffer = ByteBuffer(bytes: [0x00, 0x00]) // only 2 bytes, need 5
        #expect(throws: (any Error).self) {
            try Envelope.readHeader(from: &buffer)
        }
    }
}
