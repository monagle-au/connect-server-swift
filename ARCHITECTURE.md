# Architecture Plan: connect-swift-server

## Summary

`connect-swift-server` is a Swift package that serves grpc-swift-2 service implementations over Connect, gRPC-Web, and gRPC simultaneously on a single HTTP port. It uses Hummingbird as the HTTP server layer (handling HTTP/1.1 + HTTP/2 via ALPN), and provides its own protocol handlers for each wire format. The user writes one `SimpleServiceProtocol` conformer and registers it with `ConnectRouter`; the library handles protocol detection, codec selection (JSON or protobuf), framing, and error mapping.

---

## Design Decisions

### D1: Hummingbird vs Raw swift-nio → Hummingbird

**Decision:** Use Hummingbird (v2, Swift 6.1+) as the HTTP server layer.

**Rationale:**
- Hummingbird's `HTTP2UpgradeChannel` already handles TLS ALPN negotiation between `h2` and `http/1.1` on a single port, using `NIOTypedApplicationProtocolNegotiationHandler` internally. This is exactly what we need.
- Hummingbird provides connection management, keep-alive, routing, and middleware — all boring infrastructure we'd have to build from raw NIO.
- Hummingbird uses `swift-http-types` (`HTTPRequest`/`HTTPResponse`) — standard Apple types, not NIO-specific.
- Both Hummingbird and grpc-swift-nio-transport depend on swift-nio ≥2.96, so version compatibility is assured.
- Hummingbird also offers plaintext HTTP/2 (`.http2()` builder) for development without TLS.

**Risk: HTTP/2 trailers.** Native gRPC requires sending HTTP/2 trailers (`grpc-status`, `grpc-message`). Hummingbird's `Response` type (from `swift-http-types`) exposes `HTTPResponse.headerFields` but may not expose a trailer-writing API. NIO's HTTP/2 handler supports trailers via `HTTPResponsePart.end(HTTPHeaders?)`. **Mitigation:** If Hummingbird's response abstraction doesn't expose trailers, we can either (a) write a custom NIO channel handler that intercepts gRPC HTTP/2 streams before they reach Hummingbird's responder, or (b) defer native gRPC to Phase 2 and ship Connect + gRPC-Web first (both encode trailing metadata in the response body, not HTTP trailers). Recommend prototyping this in the first implementation spike.

### D2: Transport Architecture → Option (a): Own the socket entirely

**Decision:** We own the listening socket via Hummingbird. We do NOT use, wrap, or proxy to grpc-swift-2's `HTTP2ServerTransport`.

**Rationale:**
- **Option (b) — loopback proxy** to grpc-swift-2 on localhost: adds latency, two server lifecycles, port allocation. Rejected.
- **Option (c) — plug into grpc-swift-2 as custom transport:** `ServerTransport` is deprecated (see forums.swift.org/t/80177 — repo migration from grpc-swift to grpc-swift-2). The protocol's API (`RPCStream<Inbound, Outbound>`) operates at a transport-specific bytes level. Conforming means re-implementing all of gRPC wire format. Rejected.
- **Option (a) — own the socket:** We use Hummingbird for HTTP. For each request, we detect the wire protocol, decode the body, and call the user's handler directly. We only depend on `GRPCCore` for types (`RPCError`, `Metadata`, `ServerRequest`, `ServerResponse`, `ServerContext`, `MethodDescriptor`), not for transport or routing.

**Consequence:** `ConnectServer` and `GRPCServer` are independent. A user who wants native gRPC *alongside* Connect on the same binary can run both on different ports, or use our server which handles all three. The two servers share service implementation code (the `SimpleServiceProtocol` conformer) but not runtime state.

### D3: Service Adapter Design → Own handler registry with typed registration

**Decision:** Create our own `ConnectRouter` with a type-safe registration API. Do NOT reuse `RPCRouter<Transport>` or `RegistrableRPCService.registerMethods(with:)`.

**Rationale:**
The generated `registerMethods(with: &router)` populates an `RPCRouter<Transport>` with protobuf-binary-only serializers (from `GRPCProtobuf`). We can't reuse this because:

1. **RPCRouter is generic over `ServerTransport`**, which defines a `Bytes` associated type. Creating a dummy transport just to satisfy the generic is fragile and ties us to a deprecated protocol.
2. **The registered serializers are protobuf-only.** Connect's primary value proposition is JSON support (`application/json`). The RPCRouter handlers call the protobuf deserializer before the user's code — we can't swap in a JSON codec at request time.
3. **The handler dispatch model** (`RPCStream<Inbound, Outbound>`) uses transport-specific async sequences and writers. Constructing these from an HTTP request body adds unnecessary abstraction.

**Our approach:** `ConnectRouter` stores type-erased `MethodHandler` closures keyed by `MethodDescriptor`. At registration time, we capture the concrete `SwiftProtobuf.Message` types (`Input.Type`, `Output.Type`) in a closure, enabling runtime codec selection (JSON or proto) per request. This is the same pattern connect-go uses — each handler wraps the typed implementation with codec logic.

**Registration API for Phase 1 (manual, no codegen):**

```swift
var router = ConnectRouter()
let greeter = Greeter()

router.registerUnary(
    method: MethodDescriptor(service: "helloworld.Greeter", method: "SayHello"),
    requestType: Helloworld_HelloRequest.self,
    responseType: Helloworld_HelloReply.self
) { (message: Helloworld_HelloRequest, context: ServerContext) in
    try await greeter.sayHello(request: message, context: context)
}
```

Per-method boilerplate is ~6 lines. For a service with 5 methods, that's ~30 lines — acceptable for v1. Phase 2 introduces a protoc plugin or Swift macro to generate this automatically.

**Why we also provide a metadata-aware variant:**

```swift
router.registerUnary(
    method: MethodDescriptor(service: "helloworld.Greeter", method: "SayHello"),
    requestType: Helloworld_HelloRequest.self,
    responseType: Helloworld_HelloReply.self
) { (request: ServerRequest<Helloworld_HelloRequest>, context: ServerContext)
    -> ServerResponse<Helloworld_HelloReply> in
    // Access request.metadata (HTTP headers → gRPC metadata)
    // Return response with trailing metadata
}
```

This mirrors grpc-swift-2's `ServiceProtocol` level (not `SimpleServiceProtocol`), giving handlers access to metadata — important for passing auth tokens, request IDs, etc.

### D4: Protocol Detection → Content-Type decision tree

**Decision tree (evaluated in this order):**

```
1. Content-Type starts with "application/grpc-web"  →  gRPC-Web
2. Content-Type starts with "application/grpc"       →  gRPC
3. Content-Type is "application/json"                →  Connect unary (JSON codec)
4. Content-Type is "application/proto"               →  Connect unary (proto codec)
5. Content-Type starts with "application/connect+"   →  Connect streaming
6. GET with query param "connect=v1"                 →  Connect unary GET
7. Otherwise                                         →  415 Unsupported Media Type
```

**Rationale:** Content-Type is the primary discriminator per all three specs. The order matters — `"application/grpc-web"` is a prefix of `"application/grpc-web+proto"` and must be checked before `"application/grpc"` to avoid false matches. Connect's `Connect-Protocol-Version: 1` header is a secondary confirmation but is not required for detection since the content types are disjoint across protocols.

**Content-Type details per protocol:**

| Protocol | Content-Types |
|----------|---------------|
| Connect unary | `application/json`, `application/proto` |
| Connect streaming | `application/connect+json`, `application/connect+proto` |
| gRPC | `application/grpc`, `application/grpc+proto` |
| gRPC-Web binary | `application/grpc-web`, `application/grpc-web+proto` |
| gRPC-Web text | `application/grpc-web-text`, `application/grpc-web-text+proto` |

### D5: Error Mapping

**RPCError.Code ↔ Connect error code ↔ HTTP status:**

| RPCError.Code | Connect Code | HTTP Status | gRPC Status Int |
|---|---|---|---|
| `.cancelled` | `canceled` | 408 | 1 |
| `.unknown` | `unknown` | 500 | 2 |
| `.invalidArgument` | `invalid_argument` | 400 | 3 |
| `.deadlineExceeded` | `deadline_exceeded` | 408 | 4 |
| `.notFound` | `not_found` | 404 | 5 |
| `.alreadyExists` | `already_exists` | 409 | 6 |
| `.permissionDenied` | `permission_denied` | 403 | 7 |
| `.resourceExhausted` | `resource_exhausted` | 429 | 8 |
| `.failedPrecondition` | `failed_precondition` | 412 | 9 |
| `.aborted` | `aborted` | 409 | 10 |
| `.outOfRange` | `out_of_range` | 400 | 11 |
| `.unimplemented` | `unimplemented` | 404 | 12 |
| `.internalError` | `internal` | 500 | 13 |
| `.unavailable` | `unavailable` | 503 | 14 |
| `.dataLoss` | `data_loss` | 500 | 15 |
| `.unauthenticated` | `unauthenticated` | 401 | 16 |

**Connect unary error response:**
```
HTTP/1.1 <HTTP-status>
Content-Type: application/json

{
  "code": "<connect-code>",
  "message": "<RPCError.message>",
  "details": [
    {
      "type": "<protobuf type URL>",
      "value": "<base64-encoded proto>",
      "debug": { ... }
    }
  ]
}
```

**gRPC-Web error response:** Trailer frame (flag byte `0x80`) containing:
```
grpc-status: <integer>\r\n
grpc-message: <percent-encoded message>\r\n
```

### D6: Streaming → Phase 2, structured for it now

**Decision:** Phase 1 ships unary only for all protocols. Streaming is Phase 2.

**Rationale:** Unary covers the primary browser use case (form submissions, data fetches, mutations). Streaming would roughly double the implementation scope:
- **Connect streaming** uses a 5-byte envelope per message (`[1-byte flags][4-byte big-endian length][payload]`). The final response message has flags bit 1 set and contains an `EndStreamResponse` JSON envelope with optional error + trailing metadata.
- **gRPC-Web streaming** uses the same 5-byte framing as gRPC, with trailers as a body frame (flag `0x80`).
- **gRPC streaming** uses HTTP/2 DATA frames with the same 5-byte framing, plus HTTP/2 trailers.

**How we structure for streaming now:**
1. `MethodHandler` has a `kind: MethodKind` enum (`.unary`, `.serverStreaming`, `.clientStreaming`, `.bidirectional`).
2. `ConnectRouter` provides `registerServerStreaming(...)`, `registerClientStreaming(...)`, `registerBidirectional(...)` registration methods. In Phase 1, calling a streaming method returns `RPCError(.unimplemented)`.
3. The `ProtocolHandler` protocol has both `handleUnary(...)` and `handleStreaming(...)` methods. Phase 1 implements `handleUnary`; `handleStreaming` returns unimplemented.
4. The `Envelope` framing type (for 5-byte headers) is implemented in Phase 1 as it's shared between gRPC-Web unary (which uses it) and future streaming support.

---

## Data Flow: Connect Unary Request (JSON)

```
Browser POST /helloworld.Greeter/SayHello HTTP/1.1
Content-Type: application/json
Connect-Protocol-Version: 1
Connect-Timeout-Ms: 5000
Authorization: Bearer <token>

{"name": "World"}
```

**Step 1 — Hummingbird receives the request.**
HTTP/1.1 or HTTP/2 (via ALPN). Hummingbird parses headers and body, creates an `HTTPRequest` + `ByteBuffer` body.

**Step 2 — ConnectRouter.handle(request, context).**
- Parses URL path `/helloworld.Greeter/SayHello` → `MethodDescriptor(service: "helloworld.Greeter", method: "SayHello")`.
- Looks up `MethodHandler` in the `handlers` dictionary. If not found → `RPCError(.unimplemented)`.
- Detects wire protocol from Content-Type: `application/json` → `.connect`, codec = `.json`.

**Step 3 — ConnectProtocolHandler.handleUnary(...).**
- Extracts metadata from HTTP headers. Standard headers (`Authorization`, etc.) become metadata entries. The `Connect-Protocol-Version` header is validated (must be `"1"`).
- Reads `Connect-Timeout-Ms: 5000` → sets a task deadline of 5 seconds.
- Reads the full request body as `ByteBuffer`.
- Calls `methodHandler.handleUnary(inputBytes: body, metadata: metadata, codec: jsonCodec, context: serverContext)`.

**Step 4 — MethodHandler.handleUnary (type-erased closure).**
- The closure captured `Input = Helloworld_HelloRequest` at registration time.
- Calls `jsonCodec.deserialize(Helloworld_HelloRequest.self, from: body)`:
  - Internally: `try Helloworld_HelloRequest(jsonUTF8Data: Data(buffer: body))` (SwiftProtobuf's JSON decoder).
- Constructs `ServerRequest<Helloworld_HelloRequest>(metadata: metadata, message: deserializedMessage)` (or just the message for the simple variant).
- Calls the user's handler: `greeter.sayHello(request: message, context: context)`.
- User returns `Helloworld_HelloReply`.
- Calls `jsonCodec.serialize(reply)`:
  - Internally: `try reply.jsonUTF8Data()` (SwiftProtobuf's JSON encoder).
- Returns `(responseBytes: ByteBuffer, trailingMetadata: Metadata)`.

**Step 5 — ConnectProtocolHandler writes response.**

Success:
```
HTTP/1.1 200 OK
Content-Type: application/json
Trailer-Acme-Cost: 237    ← trailing metadata with "trailer-" prefix

{"message": "Hello, World!"}
```

Error (handler throws `RPCError(.notFound, message: "user not found")`):
```
HTTP/1.1 404 Not Found
Content-Type: application/json

{"code": "not_found", "message": "user not found"}
```

---

## Data Flow: gRPC-Web Unary Request

```
Browser POST /helloworld.Greeter/SayHello HTTP/1.1
Content-Type: application/grpc-web+proto
X-User-Agent: grpc-web-javascript/0.1
X-Grpc-Web: 1

[0x00][0x00 0x00 0x00 0x0B][...11 bytes protobuf...]
 flag    length (BE)          message payload
```

**Step 1 — Hummingbird receives request.** Same as Connect.

**Step 2 — ConnectRouter.handle(request, context).**
- Path → `MethodDescriptor` (same).
- Content-Type `application/grpc-web+proto` → `.grpcWeb`, codec = `.proto`.

**Step 3 — GRPCWebProtocolHandler.handleUnary(...).**
- Extracts metadata from HTTP headers. `grpc-timeout` → deadline. Custom headers → metadata.
- Reads the request body.
- Parses the 5-byte envelope header:
  - Byte 0: flags. `0x00` = uncompressed data frame.
  - Bytes 1-4: message length as 32-bit big-endian unsigned integer.
- Extracts the message payload (next N bytes).
- Calls `methodHandler.handleUnary(inputBytes: payload, metadata: metadata, codec: protoCodec, context: serverContext)`.

**Step 4 — MethodHandler.handleUnary.**
- `protoCodec.deserialize(Helloworld_HelloRequest.self, from: payload)`:
  - Internally: `try Helloworld_HelloRequest(serializedBytes: payload)`.
- Calls user handler, gets response.
- `protoCodec.serialize(reply)`:
  - Internally: `try reply.serializedBytes()`.
- Returns response bytes + trailing metadata.

**Step 5 — GRPCWebProtocolHandler writes response.**

```
HTTP/1.1 200 OK
Content-Type: application/grpc-web+proto

[0x00][0x00 0x00 0x00 0x0F][...15 bytes protobuf response...]
[0x80][0x00 0x00 0x00 0x1A][grpc-status: 0\r\ngrpc-message: \r\n]
 ^trailer flag  ^length      ^HTTP/1 headers block (lowercase)
```

The trailer frame (flag `0x80`) is always the last frame in the body. It contains an HTTP/1 headers block (per RFC 7230 §3.2) with `grpc-status`, `grpc-message`, and any trailing metadata.

Error case: Same response structure, but the trailer frame has `grpc-status: <integer>` and `grpc-message: <percent-encoded error>`.

---

## Package Layout

```
connect-swift-server/
├── Package.swift
├── ARCHITECTURE.md
├── README.md
├── LICENSE (MIT)
│
├── Sources/
│   └── ConnectServer/
│       │
│       ├── Server/
│       │   ├── ConnectServer.swift                 // Main server entry point
│       │   └── ConnectServerConfiguration.swift    // Address, TLS, CORS config
│       │
│       ├── Routing/
│       │   ├── ConnectRouter.swift                 // Method dispatch + protocol detection
│       │   ├── MethodHandler.swift                 // Type-erased handler wrapper
│       │   └── MethodKind.swift                    // unary/serverStreaming/clientStreaming/bidi
│       │
│       ├── Protocol/
│       │   ├── WireProtocol.swift                  // Enum: .connect, .grpcWeb, .grpc
│       │   ├── ConnectProtocolHandler.swift        // Connect request/response handling
│       │   ├── GRPCWebProtocolHandler.swift        // gRPC-Web request/response handling
│       │   └── GRPCProtocolHandler.swift           // Native gRPC request/response handling
│       │
│       ├── Codec/
│       │   ├── MessageCodec.swift                  // Protocol: serialize/deserialize Message
│       │   ├── ProtoCodec.swift                    // Binary protobuf codec
│       │   └── JSONCodec.swift                     // JSON protobuf codec (via SwiftProtobuf)
│       │
│       ├── Error/
│       │   ├── ConnectError.swift                  // Connect error envelope JSON
│       │   └── StatusMapping.swift                 // RPCError.Code ↔ Connect/HTTP/gRPC codes
│       │
│       ├── Framing/
│       │   ├── Envelope.swift                      // 5-byte envelope read/write
│       │   └── GRPCWebTrailers.swift               // Trailer frame encoding/decoding
│       │
│       └── Tracing/
│           ├── HTTPHeadersExtractor.swift          // Extractor: HTTPFields → ServiceContext
│           └── RPCSpanAttributes.swift             // OTel RPC attribute key constants
│
├── Tests/
│   └── ConnectServerTests/
│       ├── Routing/
│       │   └── ProtocolDetectionTests.swift
│       ├── Protocol/
│       │   ├── ConnectProtocolTests.swift
│       │   └── GRPCWebProtocolTests.swift
│       ├── Codec/
│       │   └── CodecTests.swift
│       ├── Error/
│       │   └── ErrorMappingTests.swift
│       ├── Framing/
│       │   └── EnvelopeTests.swift
│       └── Integration/
│           └── UnaryIntegrationTests.swift
│
└── Examples/
    └── HelloWorld/
        ├── Package.swift
        └── Sources/
            └── HelloWorld.swift
```

---

## Dependencies

```swift
// swift-tools-version: 6.1

dependencies: [
    // HTTP server
    .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
    
    // grpc-swift-2 core types (RPCError, Metadata, ServerRequest, etc.)
    .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.3.0"),
    
    // Protobuf serialization (JSON + binary)
    .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.28.0"),

    // Distributed tracing (spans, baggage, ServiceContext propagation)
    .package(url: "https://github.com/apple/swift-distributed-tracing.git", from: "1.0.0"),
]

targets: [
    .target(
        name: "ConnectServer",
        dependencies: [
            .product(name: "Hummingbird", package: "hummingbird"),
            .product(name: "HummingbirdHTTP2", package: "hummingbird"),
            .product(name: "GRPCCore", package: "grpc-swift-2"),
            .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            .product(name: "Tracing", package: "swift-distributed-tracing"),
        ]
    ),
    .testTarget(
        name: "ConnectServerTests",
        dependencies: [
            "ConnectServer",
            .product(name: "HummingbirdTesting", package: "hummingbird"),
        ]
    ),
]
```

**What we depend on and why:**
| Dependency | We use | We do NOT use |
|---|---|---|
| `GRPCCore` | `RPCError`, `Metadata`, `ServerRequest`, `ServerResponse`, `ServerContext`, `MethodDescriptor`, `ServiceDescriptor` | `RPCRouter`, `ServerTransport`, `GRPCServer`, `RegistrableRPCService` |
| `SwiftProtobuf` | `Message` protocol (for JSON codec: `init(jsonUTF8Data:)`, `jsonUTF8Data()`, `init(serializedBytes:)`, `serializedBytes()`) | protoc compiler, code generation |
| `Hummingbird` | HTTP/1.1+HTTP/2 server, routing, request/response types | Hummingbird Router (we use a flat handler, not HB's path-based routing) |
| `HummingbirdHTTP2` | `HTTP2UpgradeChannel` for ALPN negotiation | — |
| `Tracing` (swift-distributed-tracing) | `withSpan`, `ServiceContext`, `Instrumentation` extractor/injector for HTTP headers ↔ trace context | The tracing backend (Jaeger, OTel, etc. — that's the consumer's choice via bootstrap) |

**What we do NOT depend on:**
- `grpc-swift-nio-transport` / `GRPCNIOTransportHTTP2` — we replace this entirely with Hummingbird.
- `grpc-swift-protobuf` / `GRPCProtobuf` — we use SwiftProtobuf directly for our codecs. The GRPCProtobuf package provides serializers for RPCRouter, which we don't use.
- A specific tracer backend — we depend only on the `Tracing` API. The application bootstraps a backend (`InstrumentationSystem.bootstrap(...)`) at startup; we use `withSpan` and let the bootstrapped backend decide whether/how to record.

---

## Public API Sketch

### Minimal usage (Phase 1, manual registration)

```swift
import ConnectServer
import GRPCCore

// 1. Define service (exact same code as with GRPCServer)
struct Greeter: Helloworld_Greeter.SimpleServiceProtocol {
    func sayHello(
        request: Helloworld_HelloRequest,
        context: ServerContext
    ) async throws -> Helloworld_HelloReply {
        .with { $0.message = "Hello, \(request.name)!" }
    }
}

// 2. Register methods with ConnectRouter
let greeter = Greeter()
var router = ConnectRouter()

router.registerUnary(
    method: MethodDescriptor(service: "helloworld.Greeter", method: "SayHello"),
    requestType: Helloworld_HelloRequest.self,
    responseType: Helloworld_HelloReply.self
) { message, context in
    try await greeter.sayHello(request: message, context: context)
}

// 3. Start server
let server = ConnectServer(
    address: .ipv4(host: "0.0.0.0", port: 8080),
    transportSecurity: .plaintext,
    router: router
)
try await server.serve()
```

### With metadata access

```swift
router.registerUnary(
    method: MethodDescriptor(service: "helloworld.Greeter", method: "SayHello"),
    requestType: Helloworld_HelloRequest.self,
    responseType: Helloworld_HelloReply.self
) { (request: ServerRequest<Helloworld_HelloRequest>, context: ServerContext)
    -> ServerResponse<Helloworld_HelloReply> in
    
    let authToken = request.metadata["authorization"]
    let reply = Helloworld_HelloReply.with { $0.message = "Hello!" }
    
    return ServerResponse(
        metadata: Metadata(),
        message: reply,
        trailingMetadata: Metadata()
    )
}
```

### Future: with codegen (Phase 2+)

```swift
// Generated code provides this:
// extension Helloworld_Greeter {
//     static func connectServiceHandler(_ service: some SimpleServiceProtocol) -> ConnectServiceHandler
// }

let server = ConnectServer(
    address: .ipv4(host: "0.0.0.0", port: 8080),
    transportSecurity: .tls(TLSConfiguration.makeServerConfiguration(...)),
    services: [
        Helloworld_Greeter.connectServiceHandler(Greeter()),
        Acumen_Sessions.connectServiceHandler(SessionService()),
    ]
)
try await server.serve()
```

---

## New Types

### ConnectServer (struct, Sendable) — `Server/ConnectServer.swift`

The main server entry point. Wraps a Hummingbird `Application`.

**Properties:**
- `configuration: ConnectServerConfiguration`
- `router: ConnectRouter` (internal, set from init)
- `application: Application<...>` (internal, Hummingbird app)

**Methods:**
- `init(address: SocketAddress, transportSecurity: TransportSecurity, router: ConnectRouter)`
- `func serve() async throws` — starts the Hummingbird server, blocks until shutdown
- `func beginGracefulShutdown()` — stops accepting new connections, drains existing

**Concurrency:** `Sendable`. The `serve()` method is called once; the router is shared across request handlers via Hummingbird's responder model.

### ConnectServerConfiguration (struct, Sendable) — `Server/ConnectServerConfiguration.swift`

- `address: SocketAddress` — bind address (IPv4/IPv6/Unix)
- `transportSecurity: TransportSecurity` — `.plaintext` or `.tls(TLSConfiguration)`
- `enabledProtocols: Set<WireProtocol>` — which protocols to accept (default: all three)
- `corsConfiguration: CORSConfiguration?` — CORS headers for browser requests

### ConnectRouter (struct, Sendable) — `Routing/ConnectRouter.swift`

Routes requests to handlers by method descriptor. Serves as Hummingbird's responder.

**Internal state:**
- `handlers: [MethodDescriptor: MethodHandler]` — registered method handlers

**Registration methods:**
```swift
// Simple (message-level, matches SimpleServiceProtocol)
mutating func registerUnary<
    Input: SwiftProtobuf.Message & Sendable,
    Output: SwiftProtobuf.Message & Sendable
>(
    method: MethodDescriptor,
    requestType: Input.Type,
    responseType: Output.Type,
    handler: @Sendable @escaping (Input, ServerContext) async throws -> Output
)

// Full (with metadata, matches ServiceProtocol)
mutating func registerUnary<
    Input: SwiftProtobuf.Message & Sendable,
    Output: SwiftProtobuf.Message & Sendable
>(
    method: MethodDescriptor,
    requestType: Input.Type,
    responseType: Output.Type,
    handler: @Sendable @escaping (ServerRequest<Input>, ServerContext) async throws -> ServerResponse<Output>
)

// Phase 2 stubs
mutating func registerServerStreaming<...>(...)
mutating func registerClientStreaming<...>(...)
mutating func registerBidirectional<...>(...)
```

**Request handling (called by Hummingbird):**
```swift
func handle(request: HTTPRequest, body: ByteBuffer, context: some RequestContext) async -> Response
```
This method:
1. Parses the URL path to extract `MethodDescriptor`
2. Detects the wire protocol from Content-Type
3. Delegates to the appropriate `ProtocolHandler`

### MethodHandler (struct, Sendable) — `Routing/MethodHandler.swift`

Type-erased wrapper for a single RPC method's handler. Created at registration time by capturing concrete message types in a closure.

**Properties:**
- `descriptor: MethodDescriptor`
- `kind: MethodKind`

**Internal closure:**
```swift
let handleUnary: @Sendable (
    _ inputBytes: ByteBuffer,
    _ metadata: Metadata,
    _ codec: any MessageCodec,
    _ context: ServerContext
) async throws -> (outputBytes: ByteBuffer, trailingMetadata: Metadata)
```

**Construction (called by ConnectRouter.registerUnary):**
```swift
static func unary<Input: Message & Sendable, Output: Message & Sendable>(
    descriptor: MethodDescriptor,
    handler: @Sendable @escaping (ServerRequest<Input>, ServerContext) async throws -> ServerResponse<Output>
) -> MethodHandler
```
The factory captures `Input.Type` and `Output.Type` in the closure, enabling the correct `codec.deserialize(Input.self, ...)` and `codec.serialize(output)` calls.

### WireProtocol (enum, Sendable) — `Protocol/WireProtocol.swift`

```swift
enum WireProtocol: Hashable, Sendable {
    case connect
    case grpcWeb
    case grpc
}
```

**Static detection:**
```swift
struct DetectedProtocol {
    let wireProtocol: WireProtocol
    let codec: any MessageCodec
    let isTextEncoded: Bool  // for grpc-web-text
}

static func detect(contentType: String, method: HTTPRequest.Method, queryItems: ...) -> DetectedProtocol?
```

### ConnectProtocolHandler — `Protocol/ConnectProtocolHandler.swift`

Handles Connect protocol wire format for unary RPCs.

**Responsibilities:**
- Validates `Connect-Protocol-Version: 1` header
- Reads `Connect-Timeout-Ms` header → task deadline
- For success: writes HTTP 200 with response body + `trailer-*` headers
- For errors: writes HTTP error status + JSON error envelope
- Passes request metadata (HTTP headers → `Metadata`)

**Key implementation detail — trailing metadata prefix:**
Per the Connect spec, trailing metadata keys are prefixed with `trailer-` in unary responses:
```
Trailer-My-Custom-Key: value
```
Keys beginning with `trailer-connect-` are reserved for protocol use.

### GRPCWebProtocolHandler — `Protocol/GRPCWebProtocolHandler.swift`

Handles gRPC-Web wire format.

**Responsibilities:**
- Reads 5-byte envelope from request body → extracts message payload
- Writes response as: data frame (flag `0x00`) + trailer frame (flag `0x80`)
- Trailer frame body: HTTP/1 headers block with lowercase keys:
  ```
  grpc-status: 0\r\n
  grpc-message: \r\n
  custom-trailer: value\r\n
  ```
- For `application/grpc-web-text`: base64-encode/decode the entire body

### GRPCProtocolHandler — `Protocol/GRPCProtocolHandler.swift`

Handles native gRPC wire format over HTTP/2.

**Responsibilities:**
- Same 5-byte envelope as gRPC-Web for message framing
- Sends `grpc-status` and `grpc-message` as HTTP/2 trailers (not in body)
- Requires HTTP/2 (returns error for HTTP/1.1 gRPC requests)
- Uses `X-User-Agent` instead of `User-Agent` for gRPC-Web compat

**Phase 1 risk:** Depends on Hummingbird exposing HTTP/2 trailer writing capability. If not available, this handler is deferred to Phase 2.

### MessageCodec (protocol) — `Codec/MessageCodec.swift`

```swift
protocol MessageCodec: Sendable {
    func deserialize<M: SwiftProtobuf.Message>(_ type: M.Type, from buffer: ByteBuffer) throws -> M
    func serialize<M: SwiftProtobuf.Message>(_ message: M, into allocator: ByteBufferAllocator) throws -> ByteBuffer
    var contentType: String { get }
}
```

### ProtoCodec (struct, Sendable) — `Codec/ProtoCodec.swift`

- `contentType = "application/proto"`
- `deserialize`: `M(serializedBytes: [UInt8](buffer: buffer))`
- `serialize`: `message.serializedBytes()` → ByteBuffer

### JSONCodec (struct, Sendable) — `Codec/JSONCodec.swift`

- `contentType = "application/json"`
- `deserialize`: `M(jsonUTF8Data: Data(buffer: buffer))`
- `serialize`: `message.jsonUTF8Data()` → ByteBuffer

### ConnectError (struct, Sendable) — `Error/ConnectError.swift`

Represents the Connect error envelope JSON format.

```swift
struct ConnectError: Sendable, Codable {
    let code: String          // Connect error code string
    let message: String?
    let details: [ErrorDetail]?
    
    struct ErrorDetail: Sendable, Codable {
        let type: String      // Protobuf type URL
        let value: String     // Base64-encoded proto bytes
        let debug: String?    // Optional JSON debug info
    }
}
```

**Conversion methods:**
- `init(rpcError: RPCError)` — maps RPCError → ConnectError
- `func toRPCError() -> RPCError` — maps ConnectError → RPCError
- `static func httpStatus(for code: RPCError.Code) -> HTTPResponse.Status`

### Envelope (struct) — `Framing/Envelope.swift`

Reads and writes the 5-byte length-prefixed envelope used by gRPC, gRPC-Web, and Connect streaming.

```swift
struct Envelope {
    struct Header {
        let flags: UInt8       // Bit 0: compressed, Bit 1: end-stream (Connect)
        let messageLength: UInt32
    }
    
    static func readHeader(from buffer: inout ByteBuffer) throws -> Header
    static func writeHeader(_ header: Header, to buffer: inout ByteBuffer)
    static func readMessage(from buffer: inout ByteBuffer) throws -> (Header, ByteBuffer)
    static func writeMessage(flags: UInt8, payload: ByteBuffer, to buffer: inout ByteBuffer)
}
```

### GRPCWebTrailers — `Framing/GRPCWebTrailers.swift`

Encodes/decodes the gRPC-Web trailer frame body.

```swift
struct GRPCWebTrailers {
    static func encode(status: Int, message: String?, metadata: Metadata) -> ByteBuffer
    static func decode(from buffer: ByteBuffer) throws -> (status: Int, message: String?, metadata: Metadata)
}
```

---

## Distributed Tracing

`swift-distributed-tracing` is a first-class concern, integrated in Phase 1. RPC handling is the canonical use case for tracing — every OpenTelemetry RPC semantic convention attribute maps directly to data we already extract per request.

### When tracing fires

Each incoming RPC request creates exactly one span, regardless of which wire protocol is used. The span is created **after** the wire protocol is detected and the method is resolved (so we have all the attributes available), and it wraps the user's handler invocation.

### Span lifecycle (per request)

```
1. Hummingbird receives HTTP request
2. ConnectRouter.handle:
   a. Parse path → MethodDescriptor
   b. Detect wire protocol + codec
   c. Extract incoming trace context from HTTP headers via Instrumentation extractor
      (W3C traceparent/tracestate, B3, etc. — handled by the bootstrapped tracer)
   d. ServiceContext.current is set with the extracted parent context
3. Start span: withSpan("\(serviceName)/\(methodName)", ofKind: .server) { span in
   a. Set attributes:
      - rpc.system = "connect" | "grpc_web" | "grpc"
      - rpc.service = "helloworld.Greeter"
      - rpc.method = "SayHello"
      - rpc.connect.codec = "json" | "proto"   (Connect-specific)
      - net.peer.ip, net.peer.port from Hummingbird's request channel info
   b. Delegate to ProtocolHandler → MethodHandler → user handler
   c. On success: span ends with .ok status
   d. On RPCError: span records the error and sets:
      - rpc.connect.status_code = "not_found"  (string for Connect)
      - rpc.grpc.status_code = 5               (integer for gRPC/gRPC-Web)
      - span.setStatus(.error, description: error.message)
}
4. Span ends. Hummingbird sends HTTP response.
```

### Coordination with Hummingbird's tracing

Hummingbird ships `HummingbirdTracing` middleware that creates a span per HTTP request. To avoid double-spans:

**Decision:** ConnectServer does NOT use HummingbirdTracing. The HTTP-level span (`POST /helloworld.Greeter/SayHello`) is replaced by our RPC-level span (`helloworld.Greeter/SayHello` with rich RPC attributes). HTTP-level information (peer IP, status code) is added as attributes on the RPC span.

**Why:** An RPC server's primary observability unit is the RPC, not the HTTP request. Users tracing an RPC service want to see "SayHello took 47ms," not "POST request took 47ms." Tools like OpenTelemetry's RPC dashboards expect spans named after RPC methods.

**Consequence:** Users who want HTTP-level spans (e.g. for non-RPC routes mounted alongside ConnectServer) need to install Hummingbird's tracing middleware separately on those routes. ConnectServer's path is a flat handler at the responder level, so it bypasses path-based middleware.

### Trace context propagation outbound

If the user's handler makes outbound RPC calls (e.g. to a downstream service), they should use `connect-swift` or `grpc-swift-2` clients within the handler's `withSpan` scope. The current `ServiceContext` carries the active span ID, and those clients will inject `traceparent` (or whichever propagator the bootstrapped tracer uses) into outbound metadata automatically.

Our responsibility is only the **server-side extraction** at request entry. We use `Instrumentation`'s extractor against the incoming HTTP headers:

```swift
var serviceContext = ServiceContext.topLevel
InstrumentationSystem.instrument.extract(
    request.headerFields,
    into: &serviceContext,
    using: HTTPHeadersExtractor()
)
```

`HTTPHeadersExtractor` is a small `Extractor` conformance we provide that adapts `HTTPFields` (from swift-http-types, used by Hummingbird) to `Instrumentation`'s extraction interface.

### Zero-overhead default

If no tracer is bootstrapped, `swift-distributed-tracing` uses a NoOpTracer that:
- `withSpan` just runs the closure with no allocation
- `extract`/`inject` are no-ops
- Attribute setters are no-ops

So users who don't need tracing pay no runtime cost. Users who do bootstrap a tracer (e.g. `OTel`, `Jaeger`) get full RPC observability with no additional configuration on our side.

### New types added for tracing

| Type | Module path | Purpose |
|---|---|---|
| `HTTPHeadersExtractor` | `Tracing/HTTPHeadersExtractor.swift` | `Extractor` conformance bridging `HTTPFields` → ServiceContext |
| `RPCSpanAttributes` | `Tracing/RPCSpanAttributes.swift` | Constants for OTel RPC attribute keys (`rpc.system`, `rpc.service`, etc.) |

The actual span creation logic lives in `ConnectRouter.handle` (one place, applies to all protocols) — we don't need a separate tracing middleware type.

---

## Concurrency Model

| Type | Concurrency primitive | Rationale |
|---|---|---|
| `ConnectServer` | `struct, Sendable` | Immutable config + Hummingbird app handles concurrency internally |
| `ConnectRouter` | `struct, Sendable` | Built once (mutating registration), then shared immutably across requests |
| `MethodHandler` | `struct, Sendable` | Captures `@Sendable` closures only |
| `ConnectProtocolHandler` | `struct, Sendable` | Stateless — all state is per-request |
| `GRPCWebProtocolHandler` | `struct, Sendable` | Stateless |
| `GRPCProtocolHandler` | `struct, Sendable` | Stateless |
| `ProtoCodec`, `JSONCodec` | `struct, Sendable` | Stateless |
| `ConnectError` | `struct, Sendable` | Data type |
| `Envelope` | static methods only | No state |
| `HTTPHeadersExtractor` | `struct, Sendable` | Stateless adapter for `Instrumentation` extraction |

No actors are needed. All types are either immutable value types or stateless. Request handling is fully concurrent via Swift structured concurrency (Hummingbird dispatches each request as a task). Service handler closures are `@Sendable` — the user's service must be `Sendable` (same requirement as `GRPCServer`).

---

## Test Strategy

### 1. Unit tests (no network, no server)

- **Protocol detection:** Given Content-Type strings → assert correct `WireProtocol` + `MessageCodec` detection. Cover all Content-Type variants from the table above, plus edge cases (missing Content-Type, unknown types, case sensitivity).
- **Error mapping:** RPCError.Code → Connect error code string, HTTP status, gRPC status integer. Round-trip: RPCError → ConnectError JSON → parse back → RPCError.
- **Envelope framing:** Write a 5-byte header + payload → read it back. Test edge cases: zero-length messages, maximum length (2^32 - 1), compressed flag set.
- **gRPC-Web trailers:** Encode `grpc-status` + `grpc-message` + custom metadata → decode back. Test lowercase key enforcement. Test percent-encoding of messages.
- **JSON/Proto codec round-trip:** Serialize a protobuf message to JSON → deserialize back → compare. Same for proto binary.
- **Connect error envelope JSON:** Serialize ConnectError with details → deserialize → compare.

### 2. Integration tests (embedded server, real HTTP)

Use Hummingbird's `HummingbirdTesting` module to create an embedded test server:

```swift
let app = buildApplication(router: router)
try await app.test(.live) { client in
    // Send raw HTTP requests
    let response = try await client.post("/helloworld.Greeter/SayHello") { request in
        request.headers[.contentType] = "application/json"
        request.body = ByteBuffer(string: "{\"name\": \"World\"}")
    }
    XCTAssertEqual(response.status, .ok)
    // Parse JSON response
}
```

**Test cases:**
- **Connect JSON success:** POST with `application/json` → verify 200 + JSON response body
- **Connect proto success:** POST with `application/proto` → verify 200 + proto response body
- **gRPC-Web success:** POST with `application/grpc-web+proto` + framed body → verify framed response + trailer frame with `grpc-status: 0`
- **Connect error:** Trigger an RPCError → verify HTTP status + JSON error envelope
- **gRPC-Web error:** Trigger an RPCError → verify trailer frame with `grpc-status` + `grpc-message`
- **Unknown method:** POST to non-registered path → verify 404 / unimplemented error
- **Wrong Content-Type:** Send `text/plain` → verify 415
- **Metadata round-trip:** Send custom header → verify it appears in handler's `Metadata` → verify trailing metadata appears as `trailer-*` headers (Connect) or in trailer frame (gRPC-Web)

### 3. External tool tests (manual/CI)

- **`buf curl`** (Connect client): `buf curl --protocol connect --http2-prior-knowledge http://localhost:8080/helloworld.Greeter/SayHello -d '{"name":"World"}'`
- **`grpcurl`** (gRPC client): `grpcurl -plaintext -d '{"name":"World"}' localhost:8080 helloworld.Greeter/SayHello` (Phase 2 if gRPC is deferred)
- **Browser test page**: A minimal HTML file using `@connectrpc/connect-web` to call the server. Useful for validating CORS + actual browser behavior.

---

## Phased Rollout

### Phase 1: Unary Connect + gRPC-Web (first release, target for Acumen MVP)

**Decisions locked in:**
- ✅ Manual method registration is acceptable for Phase 1.
- ✅ Native gRPC may be deferred to Phase 2 if the Hummingbird HTTP/2 trailer investigation finds it costly. Connect + gRPC-Web are the must-ship.

**Delivers:**
- `ConnectServer` with Hummingbird (HTTP/1.1 + HTTP/2 via ALPN)
- Connect protocol: unary POST, `application/json` + `application/proto`
- gRPC-Web: unary, `application/grpc-web+proto`
- Error mapping (Connect JSON envelope, gRPC-Web trailer frame)
- Manual method registration via `ConnectRouter`
- Metadata propagation (headers → metadata → trailing metadata)
- **Distributed tracing** via swift-distributed-tracing: one span per RPC, OTel RPC semantic conventions, W3C TraceContext extraction from headers, zero overhead with NoOpTracer
- Integration test suite (including a tracing test that asserts span attributes)
- README with hello-world example
- MIT license

**Does NOT deliver:**
- Streaming (returns `.unimplemented` if attempted)
- Native gRPC (deferred pending Hummingbird trailer investigation; flagged in Phase 2)
- Connect GET requests
- gRPC-Web text mode (base64)
- Compression
- CORS middleware (document the required headers; users add their own)
- Codegen plugin or macro

**First implementation spike to validate before full Phase 1:**
1. Hummingbird HTTP/2 trailer support — write a minimal handler that tries to send response trailers. If trailers are exposed via Hummingbird's `Response`, native gRPC stays in Phase 1's reach. If not, document the workaround (NIO-level handler) and confirm gRPC moves to Phase 2.
2. Hummingbird streaming response body — confirm `Response.body` accepts an `AsyncSequence<ByteBuffer>` for incremental writes (needed for Phase 2 streaming, but worth confirming early).

### Phase 2: Streaming + gRPC + gRPC-Web text

- Server streaming for Connect + gRPC-Web
- Client streaming for Connect + gRPC-Web  
- Bidirectional streaming (Connect over HTTP/2, gRPC-Web not supported per spec)
- Native gRPC over HTTP/2 (with trailers — resolve Hummingbird trailer support)
- Connect GET requests for idempotent unary RPCs
- gRPC-Web text mode (`application/grpc-web-text`, base64)
- Connect streaming `EndStreamResponse` envelope (error + trailing metadata)

### Phase 3: Production polish + codegen

**Codegen ships in Phase 3 as a protoc plugin only** — see "Codegen strategy" below for why we dropped the Swift macro option:
- **Protoc plugin** (`protoc-gen-connect-swift-server`) — works for all workflows (polyglot, `buf generate`, pure-Swift, SwiftPM build plugins)

Other Phase 3 items:
- Compression support (`gzip`, `zstd` for Connect; `gzip` for gRPC/gRPC-Web)
- Built-in CORS middleware with spec-compliant defaults:
  - Allow headers: `Content-Type, Connect-Protocol-Version, Connect-Timeout-Ms, X-User-Agent, X-Grpc-Web, Grpc-Timeout`
  - Expose headers: `Grpc-Status, Grpc-Message, Grpc-Status-Details-Bin, trailer-*`
- Timeout enforcement (`connect-timeout-ms`, `grpc-timeout`)
- Logging + metrics integration (swift-log, swift-metrics)
- Health check service (gRPC health v1)
- Server reflection (gRPC reflection v1)

---

## Codegen strategy: protoc plugin only (Swift macro rejected)

### The bridging problem

The codegen step we're replacing is the manual registration boilerplate from Phase 1:
```swift
router.registerUnary(
    method: MethodDescriptor(service: "helloworld.Greeter", method: "SayHello"),
    requestType: Helloworld_HelloRequest.self,
    responseType: Helloworld_HelloReply.self
) { message, context in
    try await greeter.sayHello(request: message, context: context)
}
```
…repeated once per RPC method. We turn a `Helloworld_Greeter.SimpleServiceProtocol` conformer into a `ConnectServiceHandler`, generating one such block per RPC.

### Why protoc, and only protoc

The decisive observation: **protoc is a hard prerequisite for using this library at all.** Users need `protoc-gen-grpc-swift-2` to produce the message types (`Helloworld_HelloRequest`) and the service protocol (`Helloworld_Greeter.SimpleServiceProtocol`) that our handlers conform to. Without protoc, there's nothing to bridge — and a Swift macro can't generate `SimpleServiceProtocol` itself.

So protoc is already running. Adding `protoc-gen-connect-swift-server` to the same toolchain is one line in `buf.gen.yaml` (or one extra `--connect_swift_out=` flag to a `protoc` invocation). That's the entire integration cost.

### Protoc plugin: `protoc-gen-connect-swift-server`

Reads the `.proto` file at build time, emits a `<service>.connect.swift` file containing a registration extension:

```swift
// Foo.connect.swift (generated)
extension Helloworld_Greeter {
    static func connectServiceHandler(
        _ service: some Helloworld_Greeter.SimpleServiceProtocol
    ) -> ConnectServiceHandler {
        var handler = ConnectServiceHandler(...)
        handler.registerUnary(
            method: MethodDescriptor(service: "helloworld.Greeter", method: "SayHello"),
            requestType: Helloworld_HelloRequest.self,
            responseType: Helloworld_HelloReply.self
        ) { message, context in
            try await service.sayHello(request: message, context: context)
        }
        return handler
    }
}
```

User code:
```swift
let server = ConnectServer(
    address: ...,
    services: [Helloworld_Greeter.connectServiceHandler(Greeter())]
)
```

### Why we rejected a Swift macro alternative

A `@ConnectService` macro was considered. It loses on every dimension:

| Claimed macro benefit | Why it doesn't hold |
|---|---|
| "Don't need to install protoc" | Users already need `protoc-gen-grpc-swift-2`. The macro doesn't eliminate the protoc dependency. |
| "Pure-Swift project" | Pure-Swift means no `.proto`, which means no `SimpleServiceProtocol` to bridge. The library doesn't apply. |
| "Better Swift diagnostics" | Real but minor. Protoc plugin errors are perfectly readable, and the generated code's compile errors appear at the call site anyway. |
| "Avoids extra build step" | The build step is already running for `protoc-gen-grpc-swift-2`. Adding another plugin to the same step costs ~one line of config. |
| "Works with SwiftPM build plugins" | Protoc plugins work fine as SwiftPM build plugins (that's how grpc-swift-2 ships its own codegen). |

**Cost of shipping both:** two codegen test surfaces, two doc paths, two divergence points to maintain. Real cost, no commensurate user benefit.

### Required for protoc-only workflows

These workflows require the protoc path (and a macro would not have served them):
1. **Polyglot codebases** generating Go + TypeScript + Python + Swift from one `.proto`.
2. **`buf generate`** workflows — Acumen specifically.
3. **CI "generated code up-to-date" checks** that gate on `git diff` being empty.
4. **Cross-package proto types** — when proto-generated types live in a shared Swift package consumed by N projects, the bridging code needs to be regenerated into the shared package, not into each consumer.

The protoc plugin handles all of these uniformly.

---

## Open Questions / Risks

1. **Hummingbird HTTP/2 trailer support.** Must verify during implementation. If trailers are not exposed, native gRPC is deferred to Phase 2 (with a NIO-level workaround). Connect + gRPC-Web are unaffected since they encode trailers in the response body or as `trailer-*` headers.

2. **Hummingbird streaming body support.** For streaming RPCs (Phase 2), we need to incrementally write response body chunks. Hummingbird's `Response` body supports `AsyncSequence<ByteBuffer>` for streaming responses — this should work but needs validation.

3. **swift-protobuf JSON codec performance.** `SwiftProtobuf.Message.jsonUTF8Data()` allocates a `Data`. For hot paths, we may want a version that writes directly to a `ByteBuffer`. Profile in Phase 1; optimize in Phase 3 if needed.

4. **GRPCCore type stability.** We depend on `GRPCCore` types (`ServerRequest`, `ServerResponse`, `Metadata`, etc.) from grpc-swift-2. These are public API and should be stable, but the repo migration (grpc-swift → grpc-swift-2) introduced deprecation annotations. We pin to grpc-swift-2 ≥2.3.0. Monitor for breaking changes.

5. **Plaintext HTTP/2 for development.** TLS ALPN requires certificates. For local development, Hummingbird's `.http2()` server builder provides plaintext HTTP/2. Verify that `connect-web` can connect to a plaintext h2c server (most browsers only support h2 with TLS, but Node.js-based dev servers often proxy). The simpler dev path: use HTTP/1.1 (Connect + gRPC-Web both work over HTTP/1.1).

6. **Codegen strategy.** Phase 3 needs either a protoc plugin or a Swift macro. A protoc plugin integrates with existing protobuf toolchains but is another binary to maintain. A Swift macro (`@ConnectService`) is more ergonomic but requires Swift 5.9+ and adds macro compilation overhead. Recommend starting with the protoc plugin (consistent with grpc-swift-2's approach), then evaluating a macro as an alternative.
