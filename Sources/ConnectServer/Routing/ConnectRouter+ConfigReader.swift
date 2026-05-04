// Copyright 2026 David Monagle / Monagle Pty Ltd
// SPDX-License-Identifier: MIT

#if ConfigurationSupport

public import Configuration

extension ConnectRouter {
    /// Initialize a `ConnectRouter` from a `ConfigReader`.
    ///
    /// - Configuration keys (relative to the supplied reader):
    ///   - `max-message-bytes` (int, default 4194304 = 4 MiB): cap on individual RPC
    ///     message size. See `ConnectRouter.maxMessageBytes`.
    ///   - `cors.*`: optional CORS subtree. If `cors.enabled` is true (or any `cors.*`
    ///     key is present), a `CORSConfiguration` is built from the `cors` scope.
    ///     See `CORSConfiguration.init(reader:)` for the keys.
    ///
    /// Typical usage:
    /// ```swift
    /// let reader = ConfigReader(provider: ...)
    /// var router = ConnectRouter(reader: reader.scoped(to: "connect-server"))
    /// router.registerUnary(...) { ... }
    /// ```
    public init(reader: ConfigReader) {
        let max = reader.int(forKey: "max-message-bytes") ?? 4 * 1024 * 1024
        let corsEnabled = reader.bool(forKey: "cors.enabled") ?? false
        let cors: CORSConfiguration? = corsEnabled
            ? CORSConfiguration(reader: reader.scoped(to: "cors"))
            : nil
        self.init(cors: cors, maxMessageBytes: max)
    }
}

#endif
