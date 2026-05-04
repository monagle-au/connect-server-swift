// Copyright 2026 David Monagle / Monagle Pty Ltd
// SPDX-License-Identifier: MIT

import NIOCore
import Testing

@testable import ConnectServer

@Suite("Codecs")
struct CodecTests {
    let protoCodec = ProtoCodec()
    let jsonCodec = JSONCodec()

    // MARK: - ProtoCodec

    @Test("Proto codec: round-trip serialize/deserialize")
    func protoRoundTrip() throws {
        let message = TestPingMessage(text: "hello proto")
        let serialized = try protoCodec.serialize(message)
        let recovered = try protoCodec.deserialize(TestPingMessage.self, from: serialized)
        #expect(recovered == message)
    }

    @Test("Proto codec: empty message serializes to empty buffer")
    func protoEmpty() throws {
        let message = TestPingMessage()
        let serialized = try protoCodec.serialize(message)
        #expect(serialized.readableBytes == 0)
    }

    @Test("Proto codec: contentType is application/proto")
    func protoContentType() {
        #expect(protoCodec.contentType == "application/proto")
    }

    // MARK: - JSONCodec

    @Test("JSON codec: round-trip serialize/deserialize")
    func jsonRoundTrip() throws {
        let message = TestPingMessage(text: "hello json")
        let serialized = try jsonCodec.serialize(message)
        let recovered = try jsonCodec.deserialize(TestPingMessage.self, from: serialized)
        #expect(recovered == message)
    }

    @Test("JSON codec: serialized form contains field name")
    func jsonContainsField() throws {
        let message = TestPingMessage(text: "world")
        let serialized = try jsonCodec.serialize(message)
        let json = String(buffer: serialized)
        #expect(json.contains("world"))
    }

    @Test("JSON codec: contentType is application/json")
    func jsonContentType() {
        #expect(jsonCodec.contentType == "application/json")
    }

    @Test("JSON codec: throws on invalid JSON")
    func jsonInvalidInput() {
        var buf = ByteBufferAllocator().buffer(capacity: 4)
        buf.writeBytes([0xFF, 0xFE, 0x00, 0x01])  // not valid UTF-8 JSON
        #expect(throws: (any Error).self) {
            try jsonCodec.deserialize(TestPingMessage.self, from: buf)
        }
    }
}
