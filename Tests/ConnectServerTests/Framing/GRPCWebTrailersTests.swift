// Copyright 2026 David Monagle / Monagle Pty Ltd
// SPDX-License-Identifier: MIT

import GRPCCore
import NIOCore
import Testing

@testable import ConnectServer

@Suite("gRPC-Web Trailer Encoding")
struct GRPCWebTrailersTests {
    @Test("Success trailer frame has grpc-status: 0")
    func successTrailer() {
        let frame = GRPCWebTrailers.frame(status: 0, message: nil, metadata: Metadata())
        var buffer = frame

        // Parse the 5-byte header
        let flags = buffer.readInteger(as: UInt8.self)!
        let length = buffer.readInteger(endianness: .big, as: UInt32.self)!
        #expect(flags == 0x80)
        #expect(length > 0)

        let trailerBytes = buffer.readSlice(length: Int(length))!
        let trailerString = String(buffer: trailerBytes)
        #expect(trailerString.contains("grpc-status: 0"))
    }

    @Test("Error trailer frame includes grpc-message")
    func errorTrailer() {
        let frame = GRPCWebTrailers.frame(status: 5, message: "not found", metadata: Metadata())
        var buffer = frame

        _ = buffer.readInteger(as: UInt8.self)!
        let length = buffer.readInteger(endianness: .big, as: UInt32.self)!
        let trailerBytes = buffer.readSlice(length: Int(length))!
        let trailerString = String(buffer: trailerBytes)

        #expect(trailerString.contains("grpc-status: 5"))
        #expect(trailerString.contains("grpc-message: not found"))
    }

    @Test("Custom trailing metadata appears in trailer frame")
    func customMetadata() {
        var metadata = Metadata()
        metadata.addString("test-value", forKey: "x-custom")
        let frame = GRPCWebTrailers.frame(status: 0, message: nil, metadata: metadata)
        var buffer = frame

        _ = buffer.readInteger(as: UInt8.self)!
        let length = buffer.readInteger(endianness: .big, as: UInt32.self)!
        let trailerBytes = buffer.readSlice(length: Int(length))!
        let trailerString = String(buffer: trailerBytes)

        #expect(trailerString.contains("x-custom: test-value"))
    }

    @Test("Metadata keys are lowercased in trailer")
    func lowercaseKeys() {
        var metadata = Metadata()
        metadata.addString("val", forKey: "X-UPPER-KEY")
        let frame = GRPCWebTrailers.frame(status: 0, message: nil, metadata: metadata)
        var buffer = frame

        _ = buffer.readInteger(as: UInt8.self)!
        let length = buffer.readInteger(endianness: .big, as: UInt32.self)!
        let trailerBytes = buffer.readSlice(length: Int(length))!
        let trailerString = String(buffer: trailerBytes)

        #expect(trailerString.contains("x-upper-key: val"))
        #expect(!trailerString.contains("X-UPPER-KEY"))
    }

    @Test("Payload without message omits grpc-message")
    func noGrpcMessage() {
        let payload = GRPCWebTrailers.encode(status: 0, message: nil, metadata: Metadata())
        let trailerString = String(buffer: payload)
        #expect(!trailerString.contains("grpc-message"))
    }
}
