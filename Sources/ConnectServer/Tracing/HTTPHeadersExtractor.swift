// Copyright 2026 David Monagle / Monagle Pty Ltd
// SPDX-License-Identifier: MIT

import HTTPTypes
import Instrumentation

// MARK: - HTTPFieldsExtractor

/// Adapts `HTTPFields` (from swift-http-types) as an `Extractor` for distributed tracing.
///
/// Used to extract W3C TraceContext (traceparent/tracestate), B3, or other
/// propagation headers from incoming HTTP request headers into `ServiceContext`.
///
/// Usage:
/// ```swift
/// var context = ServiceContext.current ?? .topLevel
/// InstrumentationSystem.instrument.extract(
///     request.headers,
///     into: &context,
///     using: HTTPFieldsExtractor()
/// )
/// ```
public struct HTTPFieldsExtractor: Extractor {
    public typealias Carrier = HTTPFields

    public init() {}

    public func extract(key: String, from carrier: HTTPFields) -> String? {
        guard let name = HTTPField.Name(key) else { return nil }
        return carrier[name]
    }
}
