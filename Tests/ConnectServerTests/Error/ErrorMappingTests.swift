// Copyright 2026 David Monagle / Monagle Pty Ltd
// SPDX-License-Identifier: MIT

import Foundation
import GRPCCore
import HTTPTypes
import Testing

@testable import ConnectServer

@Suite("Error Mapping")
struct ErrorMappingTests {
    // MARK: - StatusMapping

    @Test("RPCError.Code maps to correct Connect codes")
    func connectCodeMapping() {
        let cases: [(RPCError.Code, String)] = [
            (.cancelled, "canceled"),
            (.unknown, "unknown"),
            (.invalidArgument, "invalid_argument"),
            (.deadlineExceeded, "deadline_exceeded"),
            (.notFound, "not_found"),
            (.alreadyExists, "already_exists"),
            (.permissionDenied, "permission_denied"),
            (.resourceExhausted, "resource_exhausted"),
            (.failedPrecondition, "failed_precondition"),
            (.aborted, "aborted"),
            (.outOfRange, "out_of_range"),
            (.unimplemented, "unimplemented"),
            (.internalError, "internal"),
            (.unavailable, "unavailable"),
            (.dataLoss, "data_loss"),
            (.unauthenticated, "unauthenticated"),
        ]
        for (code, expected) in cases {
            #expect(StatusMapping.connectCode(for: code) == expected, "Code \(code) should map to \(expected)")
        }
    }

    @Test("RPCError.Code maps to correct HTTP statuses")
    func httpStatusMapping() {
        #expect(StatusMapping.httpStatus(for: .notFound) == .notFound)
        #expect(StatusMapping.httpStatus(for: .unauthenticated) == .unauthorized)
        #expect(StatusMapping.httpStatus(for: .permissionDenied) == .forbidden)
        #expect(StatusMapping.httpStatus(for: .internalError) == .internalServerError)
        #expect(StatusMapping.httpStatus(for: .unavailable) == .serviceUnavailable)
        #expect(StatusMapping.httpStatus(for: .unimplemented) == .notFound)
        #expect(StatusMapping.httpStatus(for: .resourceExhausted) == .tooManyRequests)
    }

    @Test("RPCError.Code maps to correct gRPC integer codes")
    func grpcCodeMapping() {
        #expect(StatusMapping.grpcStatusCode(for: .cancelled) == 1)
        #expect(StatusMapping.grpcStatusCode(for: .unknown) == 2)
        #expect(StatusMapping.grpcStatusCode(for: .invalidArgument) == 3)
        #expect(StatusMapping.grpcStatusCode(for: .notFound) == 5)
        #expect(StatusMapping.grpcStatusCode(for: .internalError) == 13)
        #expect(StatusMapping.grpcStatusCode(for: .unauthenticated) == 16)
    }

    // MARK: - ConnectError JSON serialization

    @Test("ConnectError serializes to JSON correctly")
    func connectErrorJSON() throws {
        let rpcError = RPCError(code: .notFound, message: "user not found")
        let connectError = ConnectError(rpcError: rpcError)

        #expect(connectError.code == "not_found")
        #expect(connectError.message == "user not found")

        let jsonBytes = try connectError.jsonBytes()
        let decoded = try JSONDecoder().decode(ConnectError.self, from: Data(jsonBytes))
        #expect(decoded.code == "not_found")
        #expect(decoded.message == "user not found")
    }

    @Test("ConnectError with empty message omits message field")
    func connectErrorEmptyMessage() throws {
        let rpcError = RPCError(code: .internalError, message: "")
        let connectError = ConnectError(rpcError: rpcError)
        #expect(connectError.message == nil)
    }
}
