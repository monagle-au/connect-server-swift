// Copyright 2026 David Monagle / Monagle Pty Ltd
// SPDX-License-Identifier: MIT

import ConnectServer
import GRPCCore
import HummingbirdCore
import SwiftProtobuf

// Hand-written protobuf message — equivalent to:
//   message Greeting { string name = 1; string reply = 2; }
struct Greeting: SwiftProtobuf.Message, SwiftProtobuf._ProtoNameProviding, Sendable {
    static let protoMessageName = "Greeting"
    // Field 1 = "name", field 2 = "reply"
    static let _protobuf_nameMap = SwiftProtobuf._NameMap(bytecode: "\0\u{1}name\0\u{1}reply\0")

    var name: String = ""
    var reply: String = ""
    var unknownFields = UnknownStorage()

    init() {}

    mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
        while let fieldNumber = try decoder.nextFieldNumber() {
            switch fieldNumber {
            case 1: try decoder.decodeSingularStringField(value: &name)
            case 2: try decoder.decodeSingularStringField(value: &reply)
            default: break
            }
        }
    }

    func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
        if !name.isEmpty { try visitor.visitSingularStringField(value: name, fieldNumber: 1) }
        if !reply.isEmpty { try visitor.visitSingularStringField(value: reply, fieldNumber: 2) }
    }

    func isEqualTo(message: any SwiftProtobuf.Message) -> Bool {
        guard let other = message as? Greeting else { return false }
        return self.name == other.name && self.reply == other.reply
    }
}

@main
struct SmokeTest {
    static func main() async throws {
        var router = ConnectRouter()

        // Success path: echoes name with a greeting prefix
        router.registerUnary(
            method: MethodDescriptor(fullyQualifiedService: "test.GreetService", method: "Greet"),
            requestType: Greeting.self,
            responseType: Greeting.self
        ) { (input: Greeting, _: ServerContext) -> Greeting in
            var out = Greeting()
            out.name = input.name
            out.reply = "Hello, \(input.name.isEmpty ? "stranger" : input.name)!"
            return out
        }

        // Error path: always throws notFound for testing
        router.registerUnary(
            method: MethodDescriptor(fullyQualifiedService: "test.GreetService", method: "ThrowNotFound"),
            requestType: Greeting.self,
            responseType: Greeting.self
        ) { (_: Greeting, _: ServerContext) -> Greeting in
            throw RPCError(code: .notFound, message: "intentional test error")
        }

        // Client-streaming: concat names from all inputs
        router.registerClientStreaming(
            method: MethodDescriptor(fullyQualifiedService: "test.GreetService", method: "GreetSummary"),
            requestType: Greeting.self,
            responseType: Greeting.self
        ) { (inputs: AsyncThrowingStream<Greeting, any Error>, _: ServerContext) -> Greeting in
            var names: [String] = []
            for try await msg in inputs {
                names.append(msg.name)
            }
            var out = Greeting()
            out.reply = "Hello, \(names.joined(separator: ", "))!"
            return out
        }

        // Bidirectional: echo each input as a corresponding output
        router.registerBidirectional(
            method: MethodDescriptor(fullyQualifiedService: "test.GreetService", method: "GreetEach"),
            requestType: Greeting.self,
            responseType: Greeting.self
        ) {
            (inputs: AsyncThrowingStream<Greeting, any Error>,
             _: ServerContext,
             writer: ServerStreamWriter<Greeting>) in
            for try await msg in inputs {
                var out = Greeting()
                out.name = msg.name
                out.reply = "Hi, \(msg.name)!"
                try await writer.write(out)
            }
        }

        // Server-streaming: emits N greetings
        router.registerServerStreaming(
            method: MethodDescriptor(fullyQualifiedService: "test.GreetService", method: "GreetMany"),
            requestType: Greeting.self,
            responseType: Greeting.self
        ) { (input: Greeting, _: ServerContext, writer: ServerStreamWriter<Greeting>) in
            for i in 1...3 {
                var msg = Greeting()
                msg.name = input.name
                msg.reply = "Greeting \(i) for \(input.name.isEmpty ? "stranger" : input.name)"
                try await writer.write(msg)
            }
        }

        // Health checks
        let health = HealthService()
        health.setStatus(.serving, for: "")
        health.setStatus(.serving, for: "test.GreetService")
        health.register(with: &router)

        // Enable permissive CORS for local browser testing
        router.cors = .permissive()

        let server = ConnectServer(
            address: .hostname("127.0.0.1", port: 9876),
            transportSecurity: .plaintext,
            router: router
        )

        // Modes:
        //   swift run smoke-test                — start the server and print example curl commands
        //   swift run smoke-test --self-test    — start the server, hit it via URLSession, report pass/fail, exit
        let args = CommandLine.arguments
        if args.contains("--self-test") {
            try await runSelfTest(server: server)
        } else {
            printExamples()
            try await server.serve()
        }
    }
}

// MARK: - Help text

func printExamples() {
    let url = "http://127.0.0.1:9876"
    print("""

    smoke-test server listening on \(url)

    Try these in another terminal:

    # Connect JSON (unary success)
    curl -s \(url)/test.GreetService/Greet \\
      -H 'Content-Type: application/json' -H 'Connect-Protocol-Version: 1' \\
      -d '{"name":"World"}'

    # Connect JSON (intentional error)
    curl -s -i \(url)/test.GreetService/ThrowNotFound \\
      -H 'Content-Type: application/json' -d '{}'

    # Health check
    curl -s \(url)/grpc.health.v1.Health/Check \\
      -H 'Content-Type: application/json' -d '{"service":"test.GreetService"}'

    # CORS preflight
    curl -s -i -X OPTIONS \(url)/test.GreetService/Greet \\
      -H 'Origin: https://example.com' -H 'Access-Control-Request-Method: POST'

    # Server-streaming (3 enveloped responses + EndStreamResponse)
    python3 -c 'import struct,sys;m=b"{\\"name\\":\\"World\\"}";sys.stdout.buffer.write(b"\\x00"+struct.pack(">I",len(m))+m)' \\
      | curl -s \(url)/test.GreetService/GreetMany \\
        -H 'Content-Type: application/connect+json' --data-binary @- | xxd | head

    # Or run the built-in self-test (server + URLSession client + pass/fail report):
    #   swift run smoke-test --self-test

    """)
}

// MARK: - Self-test

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

func runSelfTest(server: ConnectServer) async throws {
    // Start the server in a child task; cancel when self-test is done.
    let serverTask = Task { try await server.serve() }
    defer { serverTask.cancel() }

    // Wait for the server to be accepting connections.
    let baseURL = URL(string: "http://127.0.0.1:9876")!
    for _ in 0..<60 {
        do {
            var probe = URLRequest(url: baseURL.appendingPathComponent("/probe"))
            probe.httpMethod = "GET"
            _ = try await URLSession.shared.data(for: probe)
            break
        } catch {
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    var passes = 0
    var failures: [String] = []

    func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if ok {
            print("  PASS  \(name)")
            passes += 1
        } else {
            print("  FAIL  \(name) \(detail)")
            failures.append(name)
        }
    }

    // 1. Connect JSON unary success
    do {
        var req = URLRequest(url: baseURL.appendingPathComponent("/test.GreetService/Greet"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(#"{"name":"World"}"#.utf8)
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let body = String(decoding: data, as: UTF8.self)
        check("Connect JSON unary",
              status == 200 && body.contains("Hello, World!"),
              "status=\(status) body=\(body)")
    }

    // 2. Connect JSON unary error
    do {
        var req = URLRequest(url: baseURL.appendingPathComponent("/test.GreetService/ThrowNotFound"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("{}".utf8)
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let body = String(decoding: data, as: UTF8.self)
        check("Connect JSON error envelope (404 + not_found)",
              status == 404 && body.contains(#""code":"not_found""#),
              "status=\(status) body=\(body)")
    }

    // 3. CORS preflight
    do {
        var req = URLRequest(url: baseURL.appendingPathComponent("/test.GreetService/Greet"))
        req.httpMethod = "OPTIONS"
        req.setValue("https://example.com", forHTTPHeaderField: "Origin")
        req.setValue("POST", forHTTPHeaderField: "Access-Control-Request-Method")
        let (_, response) = try await URLSession.shared.data(for: req)
        let http = response as? HTTPURLResponse
        let allowOrigin = http?.value(forHTTPHeaderField: "Access-Control-Allow-Origin") ?? ""
        let allowMethods = http?.value(forHTTPHeaderField: "Access-Control-Allow-Methods") ?? ""
        check("CORS preflight (204 + headers)",
              http?.statusCode == 204 && allowOrigin == "*" && allowMethods.contains("POST"),
              "status=\(http?.statusCode ?? -1) allow-origin=\(allowOrigin)")
    }

    // 4. Health check
    do {
        var req = URLRequest(url: baseURL.appendingPathComponent("/grpc.health.v1.Health/Check"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(#"{"service":"test.GreetService"}"#.utf8)
        let (data, _) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        check("Health Check (status: 1 = SERVING)", (json?["status"] as? Int) == 1, "json=\(String(decoding: data, as: UTF8.self))")
    }

    // 5. Connect server-streaming JSON
    do {
        var req = URLRequest(url: baseURL.appendingPathComponent("/test.GreetService/GreetMany"))
        req.httpMethod = "POST"
        req.setValue("application/connect+json", forHTTPHeaderField: "Content-Type")
        // Enveloped input: 5-byte header + JSON
        let inputJSON = Data(#"{"name":"Streamy"}"#.utf8)
        var body = Data()
        body.append(0x00)
        body.append(contentsOf: withUnsafeBytes(of: UInt32(inputJSON.count).bigEndian) { Array($0) })
        body.append(inputJSON)
        req.httpBody = body
        let (respData, _) = try await URLSession.shared.data(for: req)

        // Parse frames out of the response: expect 3 data frames + EndStreamResponse
        var idx = 0
        var dataFrames = 0
        var sawEndStream = false
        while idx + 5 <= respData.count {
            let flags = respData[idx]
            let len = (UInt32(respData[idx + 1]) << 24)
                | (UInt32(respData[idx + 2]) << 16)
                | (UInt32(respData[idx + 3]) << 8)
                | UInt32(respData[idx + 4])
            idx += 5 + Int(len)
            if flags == 0x00 { dataFrames += 1 }
            if flags & 0x02 != 0 { sawEndStream = true }
        }
        check("Connect server-streaming (3 data frames + EndStreamResponse)",
              dataFrames == 3 && sawEndStream,
              "data=\(dataFrames) end=\(sawEndStream)")
    }

    print("\n  \(passes) passed, \(failures.count) failed")
    if !failures.isEmpty {
        // Non-zero exit so CI catches it.
        exit(1)
    }
}
