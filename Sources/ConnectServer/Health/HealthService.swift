// Copyright 2026 David Monagle / Monagle Pty Ltd
// SPDX-License-Identifier: MIT

import Foundation
import GRPCCore
import SwiftProtobuf
import Synchronization

// MARK: - Public health-status type

/// Health status for a service.
///
/// Mirrors the standard `grpc.health.v1.HealthCheckResponse.ServingStatus` enum.
public enum ServingStatus: Int, Sendable {
    case unknown = 0
    case serving = 1
    case notServing = 2
    case serviceUnknown = 3
}

// MARK: - HealthService

/// gRPC health-checking v1 service implementation.
///
/// Implements the standard `grpc.health.v1.Health` service:
/// - `Check`: returns the current status of a named service
/// - `Watch`: server-streams the status of a named service whenever it changes
///
/// Usage:
/// ```swift
/// let health = HealthService()
/// health.setStatus(.serving, for: "")                          // overall server status
/// health.setStatus(.serving, for: "helloworld.Greeter")        // per-service status
///
/// var router = ConnectRouter()
/// health.register(with: &router)
/// ```
///
/// `grpc-health-probe`, `grpcurl --plaintext localhost:8080 grpc.health.v1.Health/Check`,
/// and any standard gRPC health client work without further configuration.
public final class HealthService: Sendable {
    private let state: Mutex<State>

    private struct State {
        var statuses: [String: ServingStatus] = [:]
        var watchers: [UUID: Watcher] = [:]
    }

    private struct Watcher: Sendable {
        let service: String
        let continuation: AsyncStream<ServingStatus>.Continuation
    }

    public init() {
        self.state = Mutex(State())
    }

    /// Sets the status for a service name and notifies any active Watch streams.
    /// Pass an empty string for the overall server status.
    public func setStatus(_ status: ServingStatus, for service: String) {
        let toNotify: [AsyncStream<ServingStatus>.Continuation] = state.withLock { state in
            state.statuses[service] = status
            return state.watchers.values.filter { $0.service == service }.map(\.continuation)
        }
        for cont in toNotify {
            cont.yield(status)
        }
    }

    /// Returns the current status for a service name.
    /// - Returns: `.serviceUnknown` if no status was set for the given name.
    public func status(for service: String) -> ServingStatus {
        state.withLock { $0.statuses[service] ?? .serviceUnknown }
    }

    /// Removes all watchers — useful during shutdown.
    public func cancelAllWatchers() {
        let toCancel: [AsyncStream<ServingStatus>.Continuation] = state.withLock { state in
            let conts = state.watchers.values.map(\.continuation)
            state.watchers.removeAll()
            return conts
        }
        for c in toCancel { c.finish() }
    }

    // MARK: - Watch helpers

    fileprivate func watchStream(for service: String) -> AsyncStream<ServingStatus> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<ServingStatus>.makeStream()
        let initialStatus: ServingStatus = state.withLock { state in
            let status = state.statuses[service] ?? .serviceUnknown
            state.watchers[id] = Watcher(service: service, continuation: continuation)
            return status
        }
        // Always send the current state on subscription, before any subsequent change.
        continuation.yield(initialStatus)
        continuation.onTermination = { [weak self] _ in
            self?.removeWatcher(id: id)
        }
        return stream
    }

    private func removeWatcher(id: UUID) {
        state.withLock { _ = $0.watchers.removeValue(forKey: id) }
    }

    // MARK: - Registration

    /// Registers `grpc.health.v1.Health/Check` and `grpc.health.v1.Health/Watch` on the router.
    public func register(with router: inout ConnectRouter) {
        let service = self

        router.registerUnary(
            method: MethodDescriptor(fullyQualifiedService: "grpc.health.v1.Health", method: "Check"),
            requestType: HealthCheckRequest.self,
            responseType: HealthCheckResponse.self
        ) { (request: HealthCheckRequest, _: ServerContext) -> HealthCheckResponse in
            HealthCheckResponse(status: service.status(for: request.service))
        }

        router.registerServerStreaming(
            method: MethodDescriptor(fullyQualifiedService: "grpc.health.v1.Health", method: "Watch"),
            requestType: HealthCheckRequest.self,
            responseType: HealthCheckResponse.self
        ) {
            (request: HealthCheckRequest, _: ServerContext, writer: ServerStreamWriter<HealthCheckResponse>) in
            for await status in service.watchStream(for: request.service) {
                try await writer.write(HealthCheckResponse(status: status))
            }
        }
    }
}

// MARK: - Wire types (hand-written to match grpc.health.v1)

/// Field 1 = `service: string`. Matches `grpc.health.v1.HealthCheckRequest`.
struct HealthCheckRequest: SwiftProtobuf.Message, SwiftProtobuf._ProtoNameProviding, Sendable {
    static let protoMessageName = "grpc.health.v1.HealthCheckRequest"
    static let _protobuf_nameMap = SwiftProtobuf._NameMap(bytecode: "\0\u{1}service\0")

    var service: String = ""
    var unknownFields = UnknownStorage()

    init() {}

    mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
        while let fieldNumber = try decoder.nextFieldNumber() {
            switch fieldNumber {
            case 1: try decoder.decodeSingularStringField(value: &service)
            default: break
            }
        }
    }

    func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
        if !service.isEmpty { try visitor.visitSingularStringField(value: service, fieldNumber: 1) }
    }

    func isEqualTo(message: any SwiftProtobuf.Message) -> Bool {
        guard let other = message as? HealthCheckRequest else { return false }
        return self.service == other.service
    }
}

/// Field 1 = `status: ServingStatus`. Matches `grpc.health.v1.HealthCheckResponse`.
struct HealthCheckResponse: SwiftProtobuf.Message, SwiftProtobuf._ProtoNameProviding, Sendable {
    static let protoMessageName = "grpc.health.v1.HealthCheckResponse"
    static let _protobuf_nameMap = SwiftProtobuf._NameMap(bytecode: "\0\u{1}status\0")

    var statusValue: Int = 0
    var unknownFields = UnknownStorage()

    init() {}
    init(status: ServingStatus) { self.statusValue = status.rawValue }

    mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
        while let fieldNumber = try decoder.nextFieldNumber() {
            switch fieldNumber {
            case 1: try decoder.decodeSingularInt32Field(value: &(statusValue.toInt32))
            default: break
            }
        }
    }

    func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
        if statusValue != 0 {
            try visitor.visitSingularInt32Field(value: Int32(statusValue), fieldNumber: 1)
        }
    }

    func isEqualTo(message: any SwiftProtobuf.Message) -> Bool {
        guard let other = message as? HealthCheckResponse else { return false }
        return self.statusValue == other.statusValue
    }
}

// Helper for the inout convertion — Swift complains otherwise.
extension Int {
    fileprivate var toInt32: Int32 {
        get { Int32(self) }
        set { self = Int(newValue) }
    }
}
