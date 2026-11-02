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
* **Futex Worker Pool**: Powered by Zig 0.17 kernel futexes (`std.Io.Mutex` and `std.Io.Condition`), guaranteeing true 0.0% idle CPU and amortized $O(1)$ task dispatch.

---

## Quick Start

```zig
const std = @import("std");
const http = @import("lighting");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

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
    var server = http.Server.init(allocator, .{
        .handler = mux.handler(),
        .num_threads = 64,
        .max_header_bytes = 16 * 1024,
        .read_header_timeout_ns = 5 * std.time.ns_per_s,  // 5s header deadline (Slowloris defense)
        .read_timeout_ns = 30 * std.time.ns_per_s,         // 30s body read deadline
        .write_timeout_ns = 30 * std.time.ns_per_s,        // 30s response write deadline
        .idle_timeout_ns = 120 * std.time.ns_per_s,        // 120s keep-alive idle connection timeout
    });
    defer server.deinit();

    std.log.info("Server listening on http://127.0.0.1:9090...", .{});
    try server.listenAndServe("127.0.0.1", 9090);
}
```

---

## Benchmarks

Benchmark executed on an 8-core Apple Silicon developer workstation using ApacheBench (`ab -k -c 50 -n 10000`):

```text
Server Hostname:        127.0.0.1
Server Port:            9090

Document Path:          /users/42
Document Length:        17 bytes

Concurrency Level:      50
Time taken for tests:   0.120 seconds
Complete requests:      10000
Failed requests:        0
Keep-Alive requests:    10000
Requests per second:    83,434.15 [#/sec] (mean)
Time per request:       0.599 [ms] (mean)
Time per request:       0.012 [ms] (mean, across all concurrent requests)
Transfer rate:          9125.61 [Kbytes/sec] received
```

Detailed benchmarking methodologies, parameters, and results are available in [docs/benchmark.md](docs/benchmark.md).

---

## Testing

Lighting includes an end-to-end integration test suite verifying HTTP pipelining, request smuggling defenses, timeout terminations, and chunked encoding trailers:

```bash
zig build test --summary all
```

```text
Build Summary: 5/5 steps succeeded; 19/19 tests passed
test success
+- run test 19 pass (19 total) 232ms MaxRSS:3M
```

---

## Technical Documentation

* [docs/design.md](docs/design.md) - System Architecture, RFC Compliance, and Decision Tree Specifications.
* [docs/benchmark.md](docs/benchmark.md) - Benchmarking Guide, Performance Methodology, and Metric Analysis.

---

## License

[MIT](./LICENSE)
