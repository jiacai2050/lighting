# Lighting

<div align="center">

**A High-Performance, Lightweight HTTP/1.1 Server for Zig 0.17**

*Fast throughput, deterministic memory overhead, zero external dependencies.*

[![Documentation](https://img.shields.io/badge/docs-GitHub%20Pages-blue.svg)](https://jiacai2050.github.io/lighting/)
[![Zig](https://img.shields.io/badge/Zig-0.17.0-orange.svg)](https://ziglang.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](./LICENSE)

</div>

---

## Design Philosophy

* **Idiomatic Web Ergonomics**: Adopts Go's battle-tested `net/http` conventions (`ResponseWriter`, `Request`, fat-pointer `Handler`, and `ServeMux`) for an intuitive, predictable API.
* **Structured Concurrency**: Powered by Zig 0.17's `std.Io.Group.concurrent` to dispatch connection tasks concurrently, enabling lightweight Fiber coroutine execution without OS thread starvation.
* **Deterministic Resource Management**: Request lifecycles utilize bounded per-request arena allocators. Idle connections sleep in the OS kernel with zero CPU overhead.
* **First-Principles Implementation**: Core HTTP/1.1 framing, socket scheduling, and keep-alive state machines are built from scratch without relying on `std.http.Server`.
* **TigerStyle Robustness**: Enforces explicit preconditions, bounded buffer limits, and strict RFC protocol compliance.

---

## Quick Start

A minimal HTTP server with pattern-based routing and request logging:

```zig
const std = @import("std");
const http = @import("lighting");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var mux = http.ServeMux.init(allocator);
    defer mux.deinit();

    try mux.handleFunc("GET /ping", struct {
        fn handle(w: *http.ResponseWriter, _: *http.Request) anyerror!void {
            try w.header().set("Content-Type", "text/plain; charset=utf-8");
            try w.writeAll("pong\n");
        }
    }.handle);

    try mux.handleFunc("GET /users/{id}", struct {
        fn handle(w: *http.ResponseWriter, req: *http.Request) anyerror!void {
            const id = req.pathValue("id") orelse "unknown";
            try w.writer().print("Hello, user {s}!\n", .{id});
        }
    }.handle);

    var logging = http.LoggingHandler{ .next = mux.handler() };

    var server = http.Server.init(allocator, io, .{
        .handler = logging.handler(),
        .read_header_timeout_ns = 5 * std.time.ns_per_s,  // Slowloris defense
        .idle_timeout_ns = 120 * std.time.ns_per_s,        // Keep-Alive harvest
    });
    defer server.deinit();

    std.log.info("Server listening on http://127.0.0.1:7000...", .{});
    try server.listenAndServe("127.0.0.1", 7000);
}
```

---

## Runnable Examples

Each example in the `examples/` directory is self-contained and demonstrates specific patterns:

| Example | Highlights |
| :--- | :--- |
| **[hello](examples/hello)** | Minimal routing, path parameters, request logging, and environment configuration |
| **[todo](examples/todo)** | State injection (`Handler.bind`), SQLite database, REST API, embedded dark-mode SPA |
| **[ws](examples/ws)** | Real-time WebSocket echo server with adaptive dark-mode interactive web client |
| **[fs](examples/fs)** | Static file server with Range seeking, ETag caching, and adaptive directory browser |

---

## Benchmarks

Benchmarked on an Apple M2 Pro (12-core) using [wrk](https://github.com/wg/wrk):

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

Detailed benchmarking methodologies and comparative charts are available in [docs/benchmark.md](docs/benchmark.md).

---

## License

[MIT](./LICENSE)
