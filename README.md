# Lighting

<div align="center">

**A High-Performance, Lightweight Web Framework for Zig**

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

A minimal web application with pattern-based routing and request logging:

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

## Benchmark

Automated comparative benchmark against Go (`net/http`) and Rust (`actix-web`) with aligned timeout policies (Header Read Timeout: 5s, Connection Idle Timeout: 120s):

*Environment: Debian GNU/Linux 13 (x86_64), Intel i5-8500 (6 cores), 15.4 GB RAM | 4 threads, 50 concurrency, 10s per test, 2s warmup.*

| Framework / Implementation | GET `/ping`<br>*(QPS / P50 / P99)* | GET `/users/{id}`<br>*(QPS / P50 / P99)* | POST `/echo`<br>*(QPS / P50 / P99)* | GET `/files/*`<br>*(QPS / P50 / P99)* | CPU<br>*(Idle / Load)* | Peak Memory<br>*(RSS)* |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Zig (Lighting + zio)** | **333.4k**<br>(**59µs** / 7.52ms) | **329.3k**<br>(**60µs** / 7.44ms) | **289.7k**<br>(**75µs** / 5.89ms) | **321.5k**<br>(**63µs** / 7.34ms) | 0.0% / 304.1% | **6.1 MB** |
| **Rust (`actix-web`)** | **308.0k**<br>(64µs / 6.71ms) | **285.7k**<br>(70µs / 4.74ms) | **263.5k**<br>(81µs / **3.62ms**) | **276.7k**<br>(76µs / 4.34ms) | 0.0% / 314.9% | 8.0 MB |
| **Zig (Lighting + std.Io)** | **238.1k**<br>(126µs / **1.84ms**) | **225.3k**<br>(141µs / **2.11ms**) | **209.5k**<br>(152µs / **1.46ms**) | **211.5k**<br>(157µs / **0.86ms**) | 0.0% / 296.9% | 16.4 MB |
| **Go (`net/http`)** | **172.0k**<br>(195µs / 3.30ms) | **164.9k**<br>(204µs / 3.28ms) | **133.6k**<br>(249µs / 2.71ms) | **158.0k**<br>(212µs / 3.18ms) | 0.0% / 381.8% | 15.8 MB |

* **High Throughput**: Lighting (`zio`) achieves **333k+ QPS** with sub-60µs median latency (P50: 59µs), outperforming Rust `actix-web` and nearly doubling Go `net/http`.
* **Low Memory**: Peak resident memory stays at **6.1 MB** across 50 concurrent Keep-Alive connections via connection-scoped Arena reuse (`request_arena_retain_limit = 64KB`).
* **Tail Latency**: Lighting (`std.Io`) maintains rock-solid tail latency (P99: **0.86ms ~ 2.11ms**) across all endpoints.

For full methodology, script details,  see [docs/benchmark.md](docs/benchmark.md).

---

## License

[MIT](./LICENSE)
