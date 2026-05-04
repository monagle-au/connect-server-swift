// Copyright 2026 David Monagle / Monagle Pty Ltd
// SPDX-License-Identifier: MIT

import GRPCCore
import NIOCore
import SwiftProtobuf

// MARK: - MethodHandler

/// A type-erased handler for a single RPC method.
///
/// Created at registration time by capturing concrete Input/Output message types in a closure,
/// enabling runtime codec selection (JSON or proto) per request.
struct MethodHandler: Sendable {
    let descriptor: MethodDescriptor
    let kind: MethodKind

    /// Set for `.unary` methods. Bytes in → bytes + trailing metadata out.
    let handleUnary: UnaryHandlerClosure?

    /// Set for `.serverStreaming` methods. The protocol handler provides a `bytesWriter`
    /// (which emits each serialized message as a data frame on the wire). The closure
    /// returns trailing metadata when streaming completes successfully.
    let handleServerStreaming: ServerStreamingHandlerClosure?

    /// Set for `.clientStreaming` methods. Receives a stream of input bytes (de-enveloped
    /// per-message); returns one response message + trailing metadata.
    let handleClientStreaming: ClientStreamingHandlerClosure?

    /// Set for `.bidirectional` methods. Receives an input stream and a writer; returns
    /// trailing metadata when streaming completes.
    let handleBidi: BidiHandlerClosure?

    typealias UnaryHandlerClosure = @Sendable (
        _ inputBytes: ByteBuffer,
        _ metadata: GRPCCore.Metadata,
        _ codec: any MessageCodec,
        _ context: ServerContext
    ) async throws -> (outputBytes: ByteBuffer, trailingMetadata: GRPCCore.Metadata)

    typealias ServerStreamingHandlerClosure = @Sendable (
        _ inputBytes: ByteBuffer,
        _ metadata: GRPCCore.Metadata,
        _ codec: any MessageCodec,
        _ context: ServerContext,
        _ bytesWriter: @Sendable @escaping (ByteBuffer) async throws -> Void
    ) async throws -> GRPCCore.Metadata

    typealias ClientStreamingHandlerClosure = @Sendable (
        _ inputBytesStream: AsyncThrowingStream<ByteBuffer, any Error>,
        _ metadata: GRPCCore.Metadata,
        _ codec: any MessageCodec,
        _ context: ServerContext
    ) async throws -> (outputBytes: ByteBuffer, trailingMetadata: GRPCCore.Metadata)

    typealias BidiHandlerClosure = @Sendable (
        _ inputBytesStream: AsyncThrowingStream<ByteBuffer, any Error>,
        _ metadata: GRPCCore.Metadata,
        _ codec: any MessageCodec,
        _ context: ServerContext,
        _ bytesWriter: @Sendable @escaping (ByteBuffer) async throws -> Void
    ) async throws -> GRPCCore.Metadata

    // MARK: - Unary factories

    /// Creates a MethodHandler for a simple (message-only) unary handler.
    static func unary<Input: Message & Sendable, Output: Message & Sendable>(
        descriptor: MethodDescriptor,
        handler: @Sendable @escaping (Input, ServerContext) async throws -> Output
    ) -> MethodHandler {
        MethodHandler(
            descriptor: descriptor,
            kind: .unary,
            handleUnary: { inputBytes, _, codec, context in
                let message = try codec.deserialize(Input.self, from: inputBytes)
                let response = try await handler(message, context)
                let outputBytes = try codec.serialize(response)
                return (outputBytes, GRPCCore.Metadata())
            },
            handleServerStreaming: nil,
            handleClientStreaming: nil,
            handleBidi: nil
        )
    }

    /// Creates a MethodHandler for a metadata-aware unary handler.
    static func unary<Input: Message & Sendable, Output: Message & Sendable>(
        descriptor: MethodDescriptor,
        handler: @Sendable @escaping (ServerRequest<Input>, ServerContext) async throws -> ServerResponse<Output>
    ) -> MethodHandler {
        MethodHandler(
            descriptor: descriptor,
            kind: .unary,
            handleUnary: { inputBytes, metadata, codec, context in
                let message = try codec.deserialize(Input.self, from: inputBytes)
                let request = ServerRequest(metadata: metadata, message: message)
                let serverResponse = try await handler(request, context)
                switch serverResponse.accepted {
                case .success(let contents):
                    let outputBytes = try codec.serialize(contents.message)
                    return (outputBytes, contents.trailingMetadata)
                case .failure(let error):
                    throw error
                }
            },
            handleServerStreaming: nil,
            handleClientStreaming: nil,
            handleBidi: nil
        )
    }

    // MARK: - Server-streaming factories

    /// Creates a MethodHandler for a simple (message-only) server-streaming handler.
    /// The handler receives one input and writes zero or more outputs to the writer.
    static func serverStreaming<Input: Message & Sendable, Output: Message & Sendable>(
        descriptor: MethodDescriptor,
        handler: @Sendable @escaping (Input, ServerContext, ServerStreamWriter<Output>) async throws -> Void
    ) -> MethodHandler {
        MethodHandler(
            descriptor: descriptor,
            kind: .serverStreaming,
            handleUnary: nil,
            handleServerStreaming: { inputBytes, _, codec, context, bytesWriter in
                let input = try codec.deserialize(Input.self, from: inputBytes)
                let writer = ServerStreamWriter<Output>(codec: codec, bytesWriter: bytesWriter)
                try await handler(input, context, writer)
                return GRPCCore.Metadata()
            },
            handleClientStreaming: nil,
            handleBidi: nil
        )
    }

    /// Creates a MethodHandler for a metadata-aware server-streaming handler.
    /// The handler returns trailing metadata after writing all messages.
    static func serverStreaming<Input: Message & Sendable, Output: Message & Sendable>(
        descriptor: MethodDescriptor,
        handler: @Sendable @escaping (ServerRequest<Input>, ServerContext, ServerStreamWriter<Output>) async throws -> GRPCCore.Metadata
    ) -> MethodHandler {
        MethodHandler(
            descriptor: descriptor,
            kind: .serverStreaming,
            handleUnary: nil,
            handleServerStreaming: { inputBytes, metadata, codec, context, bytesWriter in
                let input = try codec.deserialize(Input.self, from: inputBytes)
                let request = ServerRequest(metadata: metadata, message: input)
                let writer = ServerStreamWriter<Output>(codec: codec, bytesWriter: bytesWriter)
                return try await handler(request, context, writer)
            },
            handleClientStreaming: nil,
            handleBidi: nil
        )
    }

    // MARK: - Client-streaming factory

    /// Creates a MethodHandler for a client-streaming handler.
    /// The handler reads from `inputs` (an async stream of typed messages)
    /// and returns one response message.
    static func clientStreaming<Input: Message & Sendable, Output: Message & Sendable>(
        descriptor: MethodDescriptor,
        handler: @Sendable @escaping (AsyncThrowingStream<Input, any Error>, ServerContext) async throws -> Output
    ) -> MethodHandler {
        MethodHandler(
            descriptor: descriptor,
            kind: .clientStreaming,
            handleUnary: nil,
            handleServerStreaming: nil,
            handleClientStreaming: { inputBytesStream, _, codec, context in
                let typedInputs = AsyncThrowingStream<Input, any Error> { continuation in
                    let task = Task {
                        do {
                            for try await bytes in inputBytesStream {
                                let msg = try codec.deserialize(Input.self, from: bytes)
                                continuation.yield(msg)
                            }
                            continuation.finish()
                        } catch {
                            continuation.finish(throwing: error)
                        }
                    }
                    continuation.onTermination = { _ in task.cancel() }
                }
                let response = try await handler(typedInputs, context)
                let outputBytes = try codec.serialize(response)
                return (outputBytes, GRPCCore.Metadata())
            },
            handleBidi: nil
        )
    }

    // MARK: - Bidirectional factory

    /// Creates a MethodHandler for a bidirectional-streaming handler.
    static func bidi<Input: Message & Sendable, Output: Message & Sendable>(
        descriptor: MethodDescriptor,
        handler: @Sendable @escaping (AsyncThrowingStream<Input, any Error>, ServerContext, ServerStreamWriter<Output>) async throws -> Void
    ) -> MethodHandler {
        MethodHandler(
            descriptor: descriptor,
            kind: .bidirectional,
            handleUnary: nil,
            handleServerStreaming: nil,
            handleClientStreaming: nil,
            handleBidi: { inputBytesStream, _, codec, context, bytesWriter in
                let typedInputs = AsyncThrowingStream<Input, any Error> { continuation in
                    let task = Task {
                        do {
                            for try await bytes in inputBytesStream {
                                let msg = try codec.deserialize(Input.self, from: bytes)
                                continuation.yield(msg)
                            }
                            continuation.finish()
                        } catch {
                            continuation.finish(throwing: error)
                        }
                    }
                    continuation.onTermination = { _ in task.cancel() }
                }
                let writer = ServerStreamWriter<Output>(codec: codec, bytesWriter: bytesWriter)
                try await handler(typedInputs, context, writer)
                return GRPCCore.Metadata()
            }
        )
    }
}
