# Lighting

<div align="center">

**A High-Performance, Lightweight HTTP/1.1 Server for Zig 0.17**

*Fast throughput, minimal memory overhead, zero external dependencies.*

</div>

---

## Design Philosophy

* **First-Principles Implementation**: Core HTTP/1.1 framing, socket scheduling, and keep-alive state machines are built from scratch without relying on `std.http.Server`.
* **Deterministic Resource Management**: Request lifecycles use bounded per-request arena allocators, and idle connections sleep in the OS kernel with zero CPU overhead.
* **Developer Familiarity**: Adopts Go's battle-tested `net/http` interface conventions to provide an intuitive and predictable API.
* **TigerStyle Robustness**: Emphasizes explicit preconditions, bounded buffer limits, and strict RFC protocol compliance.

---

## Key Features

* **Go `net/http` Parity**: Full API equivalence with Go's `ResponseWriter`, `Request`, fat-pointer `Handler` interfaces, and `ServeMux`.
* **Go 1.22+ Pattern Routing**: Expressive routing tree supporting HTTP method matching, path parameters (`{id}` via zero-copy `req.pathValue()`), wildcards (`{filepath...}`), exact roots (`/{$}`), and automatic `405 Method Not Allowed`.
* **Zero-Copy Parser**: Request lines, paths, and headers are sliced directly from the socket buffer without heap allocations.
* **Dual-Mode ResponseWriter**: Automatically buffers small responses (< 4KB) to emit `Content-Length` in a single vectored write; streams larger responses via chunked transfer encoding.
* **Production Defenses**: Built-in Slowloris mitigation with absolute header deadlines, idle Keep-Alive connection harvesting, and strict RFC 9112 request smuggling prevention.
* **Go-Style Structured Concurrency**: Built on Zig 0.17's `std.Io.Group.concurrent` to dispatch connections concurrently (paralleling Go's `go c.serve()`), enabling lightweight Fiber coroutine execution with zero OS thread starvation.

---

## Quick Start

```zig
const std = @import("std");
const http = @import("lighting");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const port: u16 = if (init.environ_map.get("PORT")) |p| std.fmt.parseInt(u16, p, 10) catch 7000 else 7000;

    var mux = http.ServeMux.init(allocator);
    defer mux.deinit();

    // 1. Exact match with method restriction
    try mux.handleFunc("GET /ping", struct {
        fn handle(w: *http.ResponseWriter, _: *http.Request) anyerror!void {
            try w.header().set("Content-Type", "text/plain; charset=utf-8");
            try w.writeAll("pong\n");
        }
    }.handle);

    // 2. Go 1.22 path parameter: /users/{id}
    try mux.handleFunc("GET /users/{id}", struct {
        fn handle(w: *http.ResponseWriter, req: *http.Request) anyerror!void {
            try w.header().set("Content-Type", "application/json");
            const id = req.pathValue("id") orelse "unknown";
            try w.writer().print("{{\"user_id\":\"{s}\"}}\n", .{id});
        }
    }.handle);

    // 3. POST endpoint with request body extraction (guards with 405 on wrong method)
    try mux.handleFunc("POST /users", struct {
        fn handle(w: *http.ResponseWriter, req: *http.Request) anyerror!void {
            const body = try req.readBodyAlloc(16 * 1024);
            w.writeHeader(.created);
            try w.header().set("Content-Type", "application/json");
            try w.writer().print("{{\"status\":\"created\",\"data\":\"{s}\"}}\n", .{body});
        }
    }.handle);

    // 4. Catch-all multi-segment wildcard: /files/{filepath...}
    try mux.handleFunc("GET /files/{filepath...}", struct {
        fn handle(w: *http.ResponseWriter, req: *http.Request) anyerror!void {
            const fp = req.pathValue("filepath") orelse "";
            try w.writer().print("Serving: {s}\n", .{fp});
        }
    }.handle);

    // 5. Exact root path: /{$}
    try mux.handleFunc("/{$}", struct {
        fn handle(w: *http.ResponseWriter, req: *http.Request) anyerror!void {
            try w.header().set("Content-Type", "text/plain; charset=utf-8");
            try w.writer().print("Welcome to Lighting! Path: {s}\n", .{req.url.path});
        }
    }.handle);

    // 6. Configure production timeouts and start the server
    var server = http.Server.init(allocator, io, .{
        .handler = mux.handler(),
        .max_header_bytes = 16 * 1024,
        .read_header_timeout_ns = 5 * std.time.ns_per_s,  // 5s header deadline (Slowloris defense)
        .read_timeout_ns = 30 * std.time.ns_per_s,         // 30s body read deadline
        .write_timeout_ns = 30 * std.time.ns_per_s,        // 30s response write deadline
        .idle_timeout_ns = 120 * std.time.ns_per_s,        // 120s keep-alive idle connection timeout
    });
    defer server.deinit();

    std.log.info("Server listening on http://127.0.0.1:{d}...", .{port});
    try server.listenAndServe("127.0.0.1", port);
}
```

---

## Examples

* **[hello](examples/hello)**: Minimal starter demonstrating Juicy Main, Go 1.22+ routing with path parameters (`/hello/{name}`), request logging, and `PORT` configuration.

* **[todo](examples/todo)**: Full-stack Todo app showcasing state injection (`http.Handler.bind`), [`zig-sqlite`](https://github.com/nDimensional/zig-sqlite) persistence, REST API, and an embedded dark-mode SPA frontend (`index.html`).

---

## Benchmarks

Benchmark executed on a 12-core Apple M2 Pro MacBook using [wrk](https://github.com/wg/wrk):

```text
$ wrk -t4 -c50 -d10s -H "Connection: keep-alive" http://127.0.0.1:7000/ping
Running 10s test @ http://127.0.0.1:7000/ping
  4 threads and 50 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency     1.24ms    1.45ms  20.95ms   87.93%
    Req/Sec    13.12k     2.97k   22.32k    73.76%
  527537 requests in 10.10s, 72.95MB read
Requests/sec:  52208.26
Transfer/sec:      7.22MB
```

Detailed benchmarking methodologies, parameters, and results are available in [docs/benchmark.md](docs/benchmark.md).

---

## License

[MIT](./LICENSE)
