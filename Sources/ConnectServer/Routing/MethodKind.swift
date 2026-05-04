// Copyright 2026 David Monagle / Monagle Pty Ltd
// SPDX-License-Identifier: MIT

// MARK: - MethodKind

/// The streaming shape of an RPC method.
public enum MethodKind: Sendable {
    case unary
    case serverStreaming
    case clientStreaming
    case bidirectional
}
