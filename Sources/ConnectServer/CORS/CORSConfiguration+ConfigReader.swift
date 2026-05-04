// Copyright 2026 David Monagle / Monagle Pty Ltd
// SPDX-License-Identifier: MIT

#if ConfigurationSupport

public import Configuration

extension CORSConfiguration {
    /// Initialize a `CORSConfiguration` from a `ConfigReader`.
    ///
    /// - Configuration keys (relative to the supplied reader):
    ///   - `allowed-origins` (string array, optional): list of allowed origins. If omitted,
    ///     `["*"]` is used (any origin). A single literal `"*"` element selects `.any`.
    ///     Otherwise the entries become `.specific(...)`.
    ///   - `allow-credentials` (bool, default false): whether to send `Access-Control-Allow-Credentials: true`.
    ///   - `max-age-seconds` (int, default 7200): the value of `Access-Control-Max-Age`.
    ///   - `allowed-headers` (string array, optional): overrides the spec defaults.
    ///   - `exposed-headers` (string array, optional): overrides the spec defaults.
    ///
    /// Typical usage:
    /// ```swift
    /// let reader = ConfigReader(provider: ...)
    /// let cors = CORSConfiguration(reader: reader.scoped(to: "cors"))
    /// ```
    public init(reader: ConfigReader) {
        let originList = reader.stringArray(forKey: "allowed-origins") ?? ["*"]
        let allowed: AllowedOrigins
        if originList == ["*"] {
            allowed = .any
        } else {
            allowed = .specific(originList)
        }
        self.init(
            allowedOrigins: allowed,
            allowedHeaders: reader.stringArray(forKey: "allowed-headers") ?? Self.standardAllowedHeaders,
            exposedHeaders: reader.stringArray(forKey: "exposed-headers") ?? Self.standardExposedHeaders,
            allowCredentials: reader.bool(forKey: "allow-credentials") ?? false,
            maxAgeSeconds: reader.int(forKey: "max-age-seconds") ?? 7200
        )
    }
}

#endif
