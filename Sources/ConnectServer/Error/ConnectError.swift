// Copyright 2026 David Monagle / Monagle Pty Ltd
// SPDX-License-Identifier: MIT

import Foundation
import GRPCCore
import HTTPTypes

// MARK: - ConnectError

/// The JSON error envelope returned by the Connect protocol for failed unary RPCs.
///
/// Wire format:
/// ```json
/// { "code": "not_found", "message": "...", "details": [...] }
/// ```
public struct ConnectError: Sendable, Codable {
    public let code: String
    public let message: String?
    public let details: [ErrorDetail]?

    public struct ErrorDetail: Sendable, Codable {
        public let type: String
        public let value: String  // base64-encoded proto
        public let debug: String?
    }

    public init(code: String, message: String? = nil, details: [ErrorDetail]? = nil) {
        self.code = code
        self.message = message
        self.details = details
    }

    // MARK: - Conversion from RPCError

    public init(rpcError: RPCError) {
        self.code = StatusMapping.connectCode(for: rpcError.code)
        self.message = rpcError.message.isEmpty ? nil : rpcError.message
        self.details = nil
    }

    // MARK: - JSON encoding

    func jsonBytes() throws -> [UInt8] {
        let data = try JSONEncoder().encode(self)
        return Array(data)
    }
}

// MARK: - StatusMapping

/// Maps between RPCError.Code, Connect error code strings, HTTP statuses, and gRPC status integers.
enum StatusMapping {

    // MARK: - RPCError.Code → Connect code string

    static func connectCode(for code: RPCError.Code) -> String {
        switch code {
        case .cancelled: return "canceled"
        case .unknown: return "unknown"
        case .invalidArgument: return "invalid_argument"
        case .deadlineExceeded: return "deadline_exceeded"
        case .notFound: return "not_found"
        case .alreadyExists: return "already_exists"
        case .permissionDenied: return "permission_denied"
        case .resourceExhausted: return "resource_exhausted"
        case .failedPrecondition: return "failed_precondition"
        case .aborted: return "aborted"
        case .outOfRange: return "out_of_range"
        case .unimplemented: return "unimplemented"
        case .internalError: return "internal"
        case .unavailable: return "unavailable"
        case .dataLoss: return "data_loss"
        case .unauthenticated: return "unauthenticated"
        default: return "unknown"
        }
    }

    // MARK: - RPCError.Code → HTTP status

    static func httpStatus(for code: RPCError.Code) -> HTTPResponse.Status {
        switch code {
        case .cancelled: return .requestTimeout
        case .unknown: return .internalServerError
        case .invalidArgument: return .badRequest
        case .deadlineExceeded: return .requestTimeout
        case .notFound: return .notFound
        case .alreadyExists: return .conflict
        case .permissionDenied: return .forbidden
        case .resourceExhausted: return .tooManyRequests
        case .failedPrecondition: return .preconditionFailed
        case .aborted: return .conflict
        case .outOfRange: return .badRequest
        case .unimplemented: return .notFound
        case .internalError: return .internalServerError
        case .unavailable: return .serviceUnavailable
        case .dataLoss: return .internalServerError
        case .unauthenticated: return .unauthorized
        default: return .internalServerError
        }
    }

    // MARK: - RPCError.Code → gRPC status integer

    static func grpcStatusCode(for code: RPCError.Code) -> Int {
        switch code {
        case .cancelled: return 1
        case .unknown: return 2
        case .invalidArgument: return 3
        case .deadlineExceeded: return 4
        case .notFound: return 5
        case .alreadyExists: return 6
        case .permissionDenied: return 7
        case .resourceExhausted: return 8
        case .failedPrecondition: return 9
        case .aborted: return 10
        case .outOfRange: return 11
        case .unimplemented: return 12
        case .internalError: return 13
        case .unavailable: return 14
        case .dataLoss: return 15
        case .unauthenticated: return 16
        default: return 2  // unknown
        }
    }
}
