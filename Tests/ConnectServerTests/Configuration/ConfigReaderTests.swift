// Copyright 2026 David Monagle / Monagle Pty Ltd
// SPDX-License-Identifier: MIT

#if ConfigurationSupport

import Configuration
import Testing

@testable import ConnectServer

@Suite("ConfigReader integration")
struct ConfigReaderTests {

    @Test("ConnectRouter(reader:) reads max-message-bytes")
    func routerReadsMaxBytes() {
        let provider = InMemoryProvider(values: [
            "max-message-bytes": 1024
        ])
        let reader = ConfigReader(provider: provider)
        let router = ConnectRouter(reader: reader)
        #expect(router.maxMessageBytes == 1024)
        #expect(router.cors == nil)
    }

    @Test("ConnectRouter(reader:) defaults when keys are absent")
    func routerDefaults() {
        let reader = ConfigReader(provider: InMemoryProvider(values: [:]))
        let router = ConnectRouter(reader: reader)
        #expect(router.maxMessageBytes == 4 * 1024 * 1024)
        #expect(router.cors == nil)
    }

    @Test("ConnectRouter(reader:) builds CORS when cors.enabled is true")
    func routerEnablesCORS() {
        let provider = InMemoryProvider(values: [
            "cors.enabled": true,
            "cors.allowed-origins": ConfigValue(.stringArray(["https://app.example.com"]), isSecret: false),
            "cors.allow-credentials": true,
            "cors.max-age-seconds": 600,
        ])
        let reader = ConfigReader(provider: provider)
        let router = ConnectRouter(reader: reader)
        #expect(router.cors != nil)
        #expect(router.cors?.allowCredentials == true)
        #expect(router.cors?.maxAgeSeconds == 600)
        var matchedSpecific = false
        if case .specific(let origins) = router.cors?.allowedOrigins {
            matchedSpecific = (origins == ["https://app.example.com"])
        }
        #expect(matchedSpecific, "Expected .specific allowed origins")
    }

    @Test("CORSConfiguration(reader:) treats single '*' as .any")
    func corsAnyOrigin() {
        let reader = ConfigReader(provider: InMemoryProvider(values: [
            "allowed-origins": ConfigValue(.stringArray(["*"]), isSecret: false)
        ]))
        let cors = CORSConfiguration(reader: reader)
        var matchedAny = false
        if case .any = cors.allowedOrigins { matchedAny = true }
        #expect(matchedAny, "Expected .any allowed origins")
    }

    @Test("CORSConfiguration(reader:) defaults when keys are absent")
    func corsDefaults() {
        let reader = ConfigReader(provider: InMemoryProvider(values: [:]))
        let cors = CORSConfiguration(reader: reader)
        #expect(cors.maxAgeSeconds == 7200)
        #expect(cors.allowCredentials == false)
        var matchedAny = false
        if case .any = cors.allowedOrigins { matchedAny = true }
        #expect(matchedAny, "Expected .any default")
    }

    @Test("Router scoped reader works")
    func scopedReader() {
        let provider = InMemoryProvider(values: [
            "connect-server.max-message-bytes": 2048,
            "connect-server.cors.enabled": true,
        ])
        let reader = ConfigReader(provider: provider).scoped(to: "connect-server")
        let router = ConnectRouter(reader: reader)
        #expect(router.maxMessageBytes == 2048)
        #expect(router.cors != nil)
    }
}

#endif
