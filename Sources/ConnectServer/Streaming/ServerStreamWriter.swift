// Copyright 2026 David Monagle / Monagle Pty Ltd
// SPDX-License-Identifier: MIT

import NIOCore
import SwiftProtobuf

// MARK: - ServerStreamWriter

/// A typed writer used by server-streaming and bidirectional handlers
/// to send messages back to the client.
///
/// Each call to ``write(_:)`` serializes the message via the active codec
/// (proto or JSON, depending on the wire content-type) and emits it as a
/// length-prefixed data frame on the response stream.
///
/// ```swift
/// router.registerServerStreaming(
///     method: ...,
///     requestType: ListRequest.self,
///     responseType: Item.self
/// ) { request, context, writer in
///     for item in items {
///         try await writer.write(item)
///     }
/// }
/// ```
public struct ServerStreamWriter<Output: Message & Sendable>: Sendable {
    @usableFromInline
    let codec: any MessageCodec
    @usableFromInline
    let bytesWriter: @Sendable (ByteBuffer) async throws -> Void

    @inlinable
    init(
        codec: any MessageCodec,
        bytesWriter: @escaping @Sendable (ByteBuffer) async throws -> Void
    ) {
        self.codec = codec
        self.bytesWriter = bytesWriter
    }

    /// Serializes and emits one message on the response stream.
    public func write(_ message: Output) async throws {
        let bytes = try codec.serialize(message)
        try await bytesWriter(bytes)
    }
}
