// Copyright 2026 David Monagle / Monagle Pty Ltd
// SPDX-License-Identifier: MIT

// A minimal hand-written proto3 message with one string field (field 1).
// Avoids requiring protoc in the test environment.

import SwiftProtobuf
import NIOCore

struct TestPingMessage: SwiftProtobuf.Message, SwiftProtobuf._ProtoNameProviding, Equatable, Sendable {
    static let protoMessageName = "TestPingMessage"
    // Bytecode: leading \0 = format specifier 0, then \u{1} = sameNext opcode, then "text\0"
    static let _protobuf_nameMap = SwiftProtobuf._NameMap(bytecode: "\0\u{1}text\0")

    var text: String = ""
    var unknownFields = UnknownStorage()

    init() {}
    init(text: String) { self.text = text }

    mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
        while let fieldNumber = try decoder.nextFieldNumber() {
            switch fieldNumber {
            case 1: try decoder.decodeSingularStringField(value: &text)
            default: break
            }
        }
    }

    func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
        if !text.isEmpty { try visitor.visitSingularStringField(value: text, fieldNumber: 1) }
        try unknownFields.traverse(visitor: &visitor)
    }

    func isEqualTo(message: any SwiftProtobuf.Message) -> Bool {
        guard let other = message as? TestPingMessage else { return false }
        return self == other
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text == rhs.text && lhs.unknownFields == rhs.unknownFields
    }
}
