// Copyright 2026 David Monagle / Monagle Pty Ltd
// SPDX-License-Identifier: MIT

import GRPCCore

// MARK: - Timeout

/// Parses timeout headers and runs operations with a deadline.
///
/// Timeout headers per protocol:
/// - **Connect**: `Connect-Timeout-Ms: <positive integer>` (max 10 digits, ~115 days).
/// - **gRPC / gRPC-Web**: `grpc-timeout: <number><unit>` where unit is `H` (hour), `M` (minute),
///   `S` (second), `m` (millisecond), `u` (microsecond), or `n` (nanosecond).
enum Timeout {

    // MARK: - Parsers

    /// Parses a Connect `Connect-Timeout-Ms` header value.
    /// Returns nil if the header is missing, empty, or malformed.
    static func parseConnect(_ value: String?) -> Duration? {
        guard let value, !value.isEmpty else { return nil }
        // Per spec: positive integer, max 10 digits.
        guard value.count <= 10, let ms = UInt64(value), ms > 0 else { return nil }
        return .milliseconds(Int64(min(ms, UInt64(Int64.max))))
    }

    /// Parses a gRPC `grpc-timeout` header value (e.g. "5S", "100m", "30M").
    /// Returns nil if the header is missing or malformed.
    static func parseGRPC(_ value: String?) -> Duration? {
        guard let value, value.count >= 2 else { return nil }
        let unit = value.last!
        let numberPart = value.dropLast()
        guard let number = UInt64(numberPart), number > 0 else { return nil }

        switch unit {
        case "H": return .seconds(Int64(number) * 3600)
        case "M": return .seconds(Int64(number) * 60)
        case "S": return .seconds(Int64(number))
        case "m": return .milliseconds(Int64(number))
        case "u": return .microseconds(Int64(number))
        case "n": return .nanoseconds(Int64(number))
        default: return nil
        }
    }

    // MARK: - Execution

    /// Runs the operation with a deadline. If `duration` is nil, runs without a deadline.
    /// On timeout, throws `RPCError(code: .deadlineExceeded)`.
    static func withDeadline<T: Sendable>(
        _ duration: Duration?,
        _ operation: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        guard let duration else {
            return try await operation()
        }
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: duration)
                throw RPCError(code: .deadlineExceeded, message: "Deadline exceeded")
            }
            // First task to complete wins. The other is cancelled.
            // (If the handler doesn't honor cancellation, it'll keep running but its result is discarded.)
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}
