// Copyright 2026 David Monagle / Monagle Pty Ltd
// SPDX-License-Identifier: MIT

import GRPCCore
import HTTPTypes
import Hummingbird
import Instrumentation
import NIOCore
import ServiceContextModule
import SwiftProtobuf
import Tracing

// MARK: - ConnectRouter

/// Routes incoming HTTP requests to registered RPC handlers.
///
/// Conforms to Hummingbird's `HTTPResponder` so it can be used directly as the
/// top-level application responder — all routing happens here, not in Hummingbird's Router.
///
/// Usage:
/// ```swift
/// var router = ConnectRouter()
/// router.registerUnary(
///     method: MethodDescriptor(service: "hello.Greeter", method: "SayHello"),
///     requestType: HelloRequest.self,
///     responseType: HelloReply.self
/// ) { message, context in
///     HelloReply.with { $0.message = "Hello, \(message.name)!" }
/// }
/// let server = ConnectServer(address: .hostname("0.0.0.0", port: 8080), router: router)
/// try await server.serve()
/// ```
public struct ConnectRouter: Sendable {
    // MARK: - Internal state

    var handlers: [MethodDescriptor: MethodHandler] = [:]

    /// Optional CORS configuration. When set, the router handles OPTIONS preflight
    /// requests and adds CORS headers to all responses. Required for browser clients
    /// from a different origin.
    public var cors: CORSConfiguration?

    /// Maximum permitted size, in bytes, of any single RPC message — both the request
    /// body for unary calls and each individual envelope payload for streaming calls.
    ///
    /// Requests exceeding this size return `RPCError(.resourceExhausted)` (HTTP 429
    /// for Connect; `grpc-status: 8` for gRPC / gRPC-Web). Default: 4 MiB, which
    /// matches gRPC's default. Raise this for binary-payload services; lower it for
    /// services exposed to untrusted clients.
    public var maxMessageBytes: Int

    public init(
        cors: CORSConfiguration? = nil,
        maxMessageBytes: Int = 4 * 1024 * 1024
    ) {
        self.cors = cors
        self.maxMessageBytes = maxMessageBytes
    }

    // MARK: - Registration — simple (message-level, matches SimpleServiceProtocol)

    /// Registers a unary handler that receives and returns plain message types.
    ///
    /// This matches the grpc-swift-2 `SimpleServiceProtocol` method signature:
    /// `func rpc(request: InputType, context: ServerContext) async throws -> OutputType`
    public mutating func registerUnary<
        Input: Message & Sendable,
        Output: Message & Sendable
    >(
        method: MethodDescriptor,
        requestType: Input.Type,
        responseType: Output.Type,
        handler: @Sendable @escaping (Input, ServerContext) async throws -> Output
    ) {
        handlers[method] = MethodHandler.unary(descriptor: method, handler: handler)
    }

    /// Registers a unary handler that receives `ServerRequest` and returns `ServerResponse`.
    ///
    /// This matches the grpc-swift-2 `ServiceProtocol` method signature,
    /// giving access to request metadata and the ability to return trailing metadata.
    ///
    /// Use the `handler:` label explicitly to avoid ambiguity with the simple variant:
    /// ```swift
    /// router.registerUnary(method: ..., requestType: ..., responseType: ...,
    ///     handler: { (request: ServerRequest<Foo>, context) -> ServerResponse<Bar> in ... }
    /// )
    /// ```
    public mutating func registerUnary<
        Input: Message & Sendable,
        Output: Message & Sendable
    >(
        method: MethodDescriptor,
        requestType: Input.Type,
        responseType: Output.Type,
        handler: @Sendable @escaping (ServerRequest<Input>, ServerContext) async throws -> ServerResponse<Output>
    ) {
        handlers[method] = MethodHandler.unary(descriptor: method, handler: handler)
    }

    // MARK: - Server-streaming registration

    /// Registers a server-streaming handler that receives one input and writes
    /// zero or more outputs to the supplied writer.
    public mutating func registerServerStreaming<
        Input: Message & Sendable,
        Output: Message & Sendable
    >(
        method: MethodDescriptor,
        requestType: Input.Type,
        responseType: Output.Type,
        handler: @Sendable @escaping (Input, ServerContext, ServerStreamWriter<Output>) async throws -> Void
    ) {
        handlers[method] = MethodHandler.serverStreaming(descriptor: method, handler: handler)
    }

    /// Registers a metadata-aware server-streaming handler. Returns trailing metadata.
    public mutating func registerServerStreaming<
        Input: Message & Sendable,
        Output: Message & Sendable
    >(
        method: MethodDescriptor,
        requestType: Input.Type,
        responseType: Output.Type,
        handler: @Sendable @escaping (ServerRequest<Input>, ServerContext, ServerStreamWriter<Output>) async throws -> GRPCCore.Metadata
    ) {
        handlers[method] = MethodHandler.serverStreaming(descriptor: method, handler: handler)
    }

    // MARK: - Client-streaming registration

    /// Registers a client-streaming handler. The handler reads typed inputs from an
    /// async sequence and returns a single response message.
    public mutating func registerClientStreaming<
        Input: Message & Sendable,
        Output: Message & Sendable
    >(
        method: MethodDescriptor,
        requestType: Input.Type,
        responseType: Output.Type,
        handler: @Sendable @escaping (AsyncThrowingStream<Input, any Error>, ServerContext) async throws -> Output
    ) {
        handlers[method] = MethodHandler.clientStreaming(descriptor: method, handler: handler)
    }

    // MARK: - Bidirectional registration

    /// Registers a bidirectional-streaming handler. The handler reads inputs and writes
    /// outputs concurrently. Note: full duplex requires HTTP/2; over HTTP/1.1 the request
    /// body must be fully sent before the server can write responses.
    public mutating func registerBidirectional<
        Input: Message & Sendable,
        Output: Message & Sendable
    >(
        method: MethodDescriptor,
        requestType: Input.Type,
        responseType: Output.Type,
        handler: @Sendable @escaping (AsyncThrowingStream<Input, any Error>, ServerContext, ServerStreamWriter<Output>) async throws -> Void
    ) {
        handlers[method] = MethodHandler.bidi(descriptor: method, handler: handler)
    }
}

// MARK: - HTTPResponder conformance

extension ConnectRouter: HTTPResponder {
    public typealias Context = BasicRequestContext

    public func respond(to request: Request, context: BasicRequestContext) async throws -> Response {
        // CORS preflight: handle before anything else, no body collection.
        if request.method == .options, let cors = self.cors {
            return preflightResponse(for: request, cors: cors)
        }

        // Parse path: /ServiceName/MethodName
        let path = request.uri.path
        guard let descriptor = parseMethodDescriptor(from: path) else {
            return addingCORSHeaders(Response(status: .notFound), for: request)
        }

        // Look up handler.
        guard let handler = handlers[descriptor] else {
            return addingCORSHeaders(connectErrorResponse(
                RPCError(code: .unimplemented, message: "Unknown method: \(path)")
            ), for: request)
        }

        // Detect wire protocol.
        let contentType = request.headers[.contentType] ?? ""
        guard let detected = DetectedProtocol.detect(contentType: contentType) else {
            return addingCORSHeaders(Response(status: .unsupportedMediaType), for: request)
        }

        // For unary and server-streaming: collect body up-front (single input).
        // For client-streaming and bidi: keep the body as a stream.
        let collectedBody: ByteBuffer
        switch handler.kind {
        case .unary, .serverStreaming:
            var mutableRequest = request
            do {
                // Cap the body at maxMessageBytes plus the 5-byte envelope header
                // (so callers don't need to subtract the header from their limit).
                collectedBody = try await mutableRequest.collectBody(upTo: maxMessageBytes + Envelope.headerSize)
            } catch {
                return addingCORSHeaders(connectErrorResponse(
                    RPCError(code: .resourceExhausted, message: "Request body exceeds max message size of \(maxMessageBytes) bytes")
                ), for: request)
            }
        case .clientStreaming, .bidirectional:
            // Body will be iterated inside the protocol handler; per-message limits
            // are enforced by EnvelopeStream.messages.
            collectedBody = ByteBuffer()
        }
        let body = collectedBody

        // Extract incoming trace context and start a span.
        var serviceContext = ServiceContext.current ?? .topLevel
        InstrumentationSystem.instrument.extract(request.headers, into: &serviceContext, using: HTTPFieldsExtractor())

        let spanName = "\(descriptor.service.fullyQualifiedService)/\(descriptor.method)"
        let systemName = rpcSystemName(for: detected.wireProtocol)

        return await withSpan(spanName, context: serviceContext, ofKind: .server) { span in
            span.attributes.setRPC(
                system: systemName,
                service: descriptor.service.fullyQualifiedService,
                method: descriptor.method,
                codec: detected.codec
            )

            let response: Response
            switch (detected.wireProtocol, handler.kind) {
            case (.connect, .unary):
                // For Connect, only the unary content types are supported in Phase 2.
                // application/connect+* (streaming envelope) is reserved for client/bidi streaming, not yet shipped.
                if contentType.hasPrefix("application/connect+") {
                    let err = RPCError(code: .unimplemented, message: "Connect streaming envelope not yet supported")
                    span.setStatus(.init(code: .error, message: err.message))
                    return addingCORSHeaders(connectErrorResponse(err), for: request)
                }
                response = await ConnectProtocolHandler().handle(
                    request: request, body: body, handler: handler, codec: detected.codec
                )
            case (.connect, .serverStreaming):
                response = await ConnectProtocolHandler().handleServerStreaming(
                    request: request, body: body, handler: handler, codec: detected.codec
                )
            case (.grpcWeb, .unary):
                response = await GRPCWebProtocolHandler().handle(
                    request: request, body: body, handler: handler, codec: detected.codec
                )
            case (.grpcWeb, .serverStreaming):
                response = await GRPCWebProtocolHandler().handleServerStreaming(
                    request: request, body: body, handler: handler, codec: detected.codec
                )
            case (.grpc, .unary):
                response = await GRPCProtocolHandler().handle(
                    request: request, body: body, handler: handler, codec: detected.codec
                )
            case (.grpc, .serverStreaming):
                response = await GRPCProtocolHandler().handleServerStreaming(
                    request: request, body: body, handler: handler, codec: detected.codec
                )
            case (.connect, .clientStreaming):
                response = await ConnectProtocolHandler().handleClientStreaming(
                    request: request, handler: handler, codec: detected.codec, maxMessageBytes: maxMessageBytes
                )
            case (.grpcWeb, .clientStreaming):
                response = await GRPCWebProtocolHandler().handleClientStreaming(
                    request: request, handler: handler, codec: detected.codec, maxMessageBytes: maxMessageBytes
                )
            case (.grpc, .clientStreaming):
                response = await GRPCProtocolHandler().handleClientStreaming(
                    request: request, handler: handler, codec: detected.codec, maxMessageBytes: maxMessageBytes
                )
            case (.connect, .bidirectional):
                response = await ConnectProtocolHandler().handleBidi(
                    request: request, handler: handler, codec: detected.codec, maxMessageBytes: maxMessageBytes
                )
            case (.grpcWeb, .bidirectional):
                let err = RPCError(code: .unimplemented, message: "gRPC-Web does not support bidirectional streaming")
                span.setStatus(.init(code: .error, message: err.message))
                return addingCORSHeaders(connectErrorResponse(err), for: request)
            case (.grpc, .bidirectional):
                response = await GRPCProtocolHandler().handleBidi(
                    request: request, handler: handler, codec: detected.codec, maxMessageBytes: maxMessageBytes
                )
            }

            if response.status == .ok {
                span.setStatus(.init(code: .ok))
            }
            return addingCORSHeaders(response, for: request)
        }
    }

    // MARK: - Helpers

    private func parseMethodDescriptor(from path: String) -> MethodDescriptor? {
        // Path format: /ServiceName/MethodName or /package.ServiceName/MethodName
        var stripped = path
        if stripped.hasPrefix("/") { stripped = String(stripped.dropFirst()) }
        let parts = stripped.split(separator: "/", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let service = String(parts[0])
        let method = String(parts[1])
        guard !service.isEmpty, !method.isEmpty else { return nil }
        return MethodDescriptor(fullyQualifiedService: service, method: method)
    }

    private func rpcSystemName(for protocol: WireProtocol) -> String {
        switch `protocol` {
        case .connect: return RPCSpanAttributes.systemConnect
        case .grpcWeb: return RPCSpanAttributes.systemGRPCWeb
        case .grpc: return RPCSpanAttributes.systemGRPC
        }
    }

    private func connectErrorResponse(_ error: RPCError) -> Response {
        let connectError = ConnectError(rpcError: error)
        let httpStatus = StatusMapping.httpStatus(for: error.code)
        guard let jsonBytes = try? connectError.jsonBytes() else {
            return Response(status: .internalServerError)
        }
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        var body = ByteBufferAllocator().buffer(capacity: jsonBytes.count)
        body.writeBytes(jsonBytes)
        return Response(status: httpStatus, headers: headers, body: ResponseBody(byteBuffer: body))
    }

    // MARK: - CORS

    /// Builds the response to a CORS preflight (OPTIONS) request.
    private func preflightResponse(for request: Request, cors: CORSConfiguration) -> Response {
        var headers = HTTPFields()

        guard let origin = request.headers[.origin] else {
            // Not a CORS preflight (no Origin header). Just acknowledge.
            return Response(status: .noContent)
        }
        guard let allowedOrigin = cors.resolveOrigin(origin) else {
            // Origin not allowed — no CORS headers, browser will block.
            return Response(status: .forbidden)
        }

        headers[.accessControlAllowOrigin] = allowedOrigin
        headers[.accessControlAllowMethods] = "POST, GET, OPTIONS"
        headers[.accessControlAllowHeaders] = cors.allowedHeaders.joined(separator: ", ")
        headers[.accessControlMaxAge] = "\(cors.maxAgeSeconds)"
        if cors.allowCredentials {
            headers[.accessControlAllowCredentials] = "true"
        }
        // Vary instructs caches that the response varies based on these request headers.
        headers[.vary] = "Origin, Access-Control-Request-Method, Access-Control-Request-Headers"

        return Response(status: .noContent, headers: headers)
    }

    /// Adds CORS response headers to a response if CORS is configured and the request has an Origin.
    private func addingCORSHeaders(_ response: Response, for request: Request) -> Response {
        guard let cors = self.cors else { return response }
        guard let origin = request.headers[.origin] else { return response }
        guard let allowedOrigin = cors.resolveOrigin(origin) else { return response }

        var modified = response
        modified.headers[.accessControlAllowOrigin] = allowedOrigin
        modified.headers[.accessControlExposeHeaders] = cors.exposedHeaders.joined(separator: ", ")
        if cors.allowCredentials {
            modified.headers[.accessControlAllowCredentials] = "true"
        }
        if cors.requiresVaryOrigin {
            modified.headers[.vary] = "Origin"
        }
        return modified
    }
}

// MARK: - HTTPField.Name CORS extensions

extension HTTPField.Name {
    fileprivate static let origin = HTTPField.Name("Origin")!
    fileprivate static let accessControlAllowOrigin = HTTPField.Name("Access-Control-Allow-Origin")!
    fileprivate static let accessControlAllowMethods = HTTPField.Name("Access-Control-Allow-Methods")!
    fileprivate static let accessControlAllowHeaders = HTTPField.Name("Access-Control-Allow-Headers")!
    fileprivate static let accessControlAllowCredentials = HTTPField.Name("Access-Control-Allow-Credentials")!
    fileprivate static let accessControlExposeHeaders = HTTPField.Name("Access-Control-Expose-Headers")!
    fileprivate static let accessControlMaxAge = HTTPField.Name("Access-Control-Max-Age")!
    fileprivate static let vary = HTTPField.Name("Vary")!
}
