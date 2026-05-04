# Browser smoke test

A static HTML page that drives the smoke-test server from a browser via `fetch()`,
demonstrating that the actual browser → server path works (including CORS preflight
for cross-origin loads).

## Usage

In one terminal:

```sh
swift run smoke-test
```

In another, serve this directory over a different origin (so CORS actually fires):

```sh
cd Examples/Browser
python3 -m http.server 8000
```

Open <http://127.0.0.1:8000/> in any modern browser. The page exercises:

1. **Connect JSON unary** — POSTs `{"name": "World"}` to `/test.GreetService/Greet`.
2. **Connect JSON error** — verifies HTTP 404 + Connect error envelope.
3. **Health check** — calls `/grpc.health.v1.Health/Check`.
4. **Connect server-streaming** — manually frames an input envelope and parses the
   data frames + `EndStreamResponse` from the response.

Browsers will issue an `OPTIONS` preflight on each cross-origin request. The smoke-test
server has `cors: .permissive()` set, so this works out of the box. Compare what your
DevTools network panel shows for `OPTIONS` and `POST` against the
[Connect CORS spec](https://connectrpc.com/docs/cors).

## What this is *not*

This page uses raw `fetch()`, not `@connectrpc/connect-web`. To validate against the
real connect-web client library, set up a Node project with `@connectrpc/connect`,
`@connectrpc/connect-web`, `@bufbuild/protobuf`, and `@bufbuild/protoc-gen-es`, then
generate TypeScript bindings from your `.proto` and call them from the browser. This
file is for "does it talk HTTP correctly to a browser" rather than "does the official
client work end-to-end."
