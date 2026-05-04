// Copyright 2026 David Monagle / Monagle Pty Ltd
// SPDX-License-Identifier: MIT

import Foundation
import GRPCCore
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import NIOCore
import Testing

@testable import ConnectServer

@Suite("Health Service")
struct HealthServiceTests {

    @Test("setStatus / status round-trip")
    func setAndQueryStatus() {
        let health = HealthService()
        #expect(health.status(for: "") == .serviceUnknown)

        health.setStatus(.serving, for: "")
        #expect(health.status(for: "") == .serving)

        health.setStatus(.notServing, for: "foo.Bar")
        #expect(health.status(for: "foo.Bar") == .notServing)
        // Unrelated services still unknown
        #expect(health.status(for: "other.Service") == .serviceUnknown)
    }

    @Test("Connect JSON: Check returns serving status")
    func checkOverServingConnectJSON() async throws {
        let health = HealthService()
        health.setStatus(.serving, for: "helloworld.Greeter")

        var router = ConnectRouter()
        health.register(with: &router)

        let app = Application(responder: router)
        try await app.test(.router) { client in
            var headers = HTTPFields()
            headers[.contentType] = "application/json"

            let response = try await client.execute(
                uri: "/grpc.health.v1.Health/Check",
                method: .post,
                headers: headers,
                body: ByteBuffer(string: #"{"service":"helloworld.Greeter"}"#)
            )
            #expect(response.status == .ok)
            let json = try JSONSerialization.jsonObject(with: Data(response.body.readableBytesView)) as? [String: Any]
            // status: 1 = SERVING (note: proto JSON encodes int32 as number, but enums serialize as their integer too here)
            #expect(json?["status"] as? Int == 1 || json?["status"] as? String == "1")
        }
    }

    @Test("Watch streams initial status, then change")
    func watchStreamsChanges() async throws {
        let health = HealthService()
        health.setStatus(.serving, for: "foo")

        var router = ConnectRouter()
        health.register(with: &router)

        let app = Application(responder: router)

        try await app.test(.router) { client in
            // Kick off Watch in a task; mutate status mid-flight; verify two responses come back.
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    var headers = HTTPFields()
                    headers[.contentType] = "application/connect+proto"

                    // Build enveloped request body: {service:"foo"}
                    let codec = ProtoCodec()
                    var req = HealthCheckRequest()
                    req.service = "foo"
                    let reqBytes = try codec.serialize(req)
                    let body = Envelope.frameMessage(reqBytes)

                    let response = try await client.execute(
                        uri: "/grpc.health.v1.Health/Watch",
                        method: .post,
                        headers: headers,
                        body: body
                    )
                    #expect(response.status == .ok)

                    // Parse all frames; expect at least 2 data frames + EndStreamResponse
                    var b = response.body
                    var statuses: [Int] = []
                    while b.readableBytes > 0 {
                        let (header, payload) = try Envelope.readMessage(from: &b)
                        if header.flags == 0x00 {
                            let resp = try codec.deserialize(HealthCheckResponse.self, from: payload)
                            statuses.append(resp.statusValue)
                        }
                    }
                    // First status: serving (1). Then notServing (2).
                    #expect(statuses.contains(1))
                    #expect(statuses.contains(2))
                }
                // Give the watch a moment to subscribe, then change status
                try await Task.sleep(for: .milliseconds(50))
                health.setStatus(.notServing, for: "foo")
                // Give the watcher a moment to receive, then end the stream
                try await Task.sleep(for: .milliseconds(50))
                health.cancelAllWatchers()
                try await group.waitForAll()
            }
        }
    }

    @Test("Unknown service returns SERVICE_UNKNOWN (3)")
    func checkUnknownService() async throws {
        let health = HealthService()
        var router = ConnectRouter()
        health.register(with: &router)

        let app = Application(responder: router)
        try await app.test(.router) { client in
            var headers = HTTPFields()
            headers[.contentType] = "application/json"

            let response = try await client.execute(
                uri: "/grpc.health.v1.Health/Check",
                method: .post,
                headers: headers,
                body: ByteBuffer(string: #"{"service":"never.registered"}"#)
            )
            #expect(response.status == .ok)
            let json = try JSONSerialization.jsonObject(with: Data(response.body.readableBytesView)) as? [String: Any]
            #expect(json?["status"] as? Int == 3 || json?["status"] as? String == "3")
        }
    }
}
