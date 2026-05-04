// Copyright 2026 David Monagle / Monagle Pty Ltd
// SPDX-License-Identifier: MIT

import GRPCCore
import HummingbirdCore
import NIOCore

// MARK: - EnvelopeStream

/// Parses a stream of length-prefixed envelopes from an async sequence of byte chunks.
///
/// Yields the payload of each non-trailer, uncompressed data frame.
/// Trailer frames (flag `0x80`) and end-stream frames (flag `0x02`) are skipped — those
/// only appear on the response side and are invalid in a request body.
/// Compressed frames (flag `0x01`) cause the stream to fail with `unimplemented` until
/// compression is shipped.
enum EnvelopeStream {
    /// - Parameter maxMessageBytes: Per-envelope payload size cap. Exceeding it terminates
    ///   the stream with `RPCError(.resourceExhausted)`. The accumulator buffer is also
    ///   capped at `maxMessageBytes + headerSize` to prevent slowloris-style memory growth.
    static func messages(
        from body: RequestBody,
        maxMessageBytes: Int
    ) -> AsyncThrowingStream<ByteBuffer, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var buffer = ByteBufferAllocator().buffer(capacity: 0)
                let bufferCap = maxMessageBytes + Envelope.headerSize
                do {
                    for try await chunk in body {
                        var c = chunk
                        buffer.writeBuffer(&c)
                        // Drain as many complete envelopes as we have.
                        while buffer.readableBytes >= Envelope.headerSize {
                            let saved = buffer.readerIndex
                            let flags = buffer.readInteger(as: UInt8.self)!
                            let length = buffer.readInteger(endianness: .big, as: UInt32.self)!
                            // Reject oversized declared message length up front — don't wait for the bytes.
                            if Int(length) > maxMessageBytes {
                                continuation.finish(
                                    throwing: RPCError(
                                        code: .resourceExhausted,
                                        message: "Message size \(length) exceeds max of \(maxMessageBytes) bytes"
                                    )
                                )
                                return
                            }
                            if buffer.readableBytes < Int(length) {
                                buffer.moveReaderIndex(to: saved)
                                break
                            }
                            let payload = buffer.readSlice(length: Int(length))!
                            // Skip trailer / end-stream frames in requests (invalid but tolerate).
                            if flags & 0x80 != 0 || flags & 0x02 != 0 {
                                continue
                            }
                            if flags & 0x01 != 0 {
                                continuation.finish(
                                    throwing: RPCError(code: .unimplemented, message: "Compression not supported")
                                )
                                return
                            }
                            continuation.yield(payload)
                        }
                        // Even if no full envelope arrived, the partial buffer must not exceed
                        // bufferCap (a 5-byte header + 1 message worth of data).
                        if buffer.readableBytes > bufferCap {
                            continuation.finish(
                                throwing: RPCError(
                                    code: .resourceExhausted,
                                    message: "Pending request bytes exceed max of \(bufferCap) bytes"
                                )
                            )
                            return
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
