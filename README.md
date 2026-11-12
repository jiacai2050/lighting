# Lighting

<div align="center">

**A High-Performance, Lightweight Web Framework for Zig**

*Fast throughput, deterministic memory overhead, zero external dependencies.*

[![Documentation](https://img.shields.io/badge/docs-GitHub%20Pages-blue.svg)](https://jiacai2050.github.io/lighting/)
[![Discussions](https://img.shields.io/badge/Discussions-GitHub-blue.svg)](https://github.com/jiacai2050/lighting/discussions)
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

*Environment: Debian GNU/Linux 13 (x86_64), Intel Core Ultra 5 125H (18 cores: 8P + 8E + 2LP-E), 15.1 GB RAM | 4 threads, 50 concurrency, 10s per test, 2s warmup.*
*CPU Pinning: Server on `0-7` (Performance P-core, up to 4.5 GHz) / Client on `8-11` (Efficiency E-core, up to 3.6 GHz).*

| Framework / Implementation | GET `/ping`<br>*(QPS / P50 / P99)* | GET `/users/{id}`<br>*(QPS / P50 / P99)* | POST `/echo`<br>*(QPS / P50 / P99)* | GET `/files/*`<br>*(QPS / P50 / P99)* | CPU<br>*(Idle / Load)* | Peak Memory<br>*(RSS)* |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Zig (Lighting + zio)** | **741.5k**<br>(43µs / **73µs**) | **654.6k**<br>(53µs / **90µs**) | **528.9k**<br>(73µs / **101µs**) | **574.0k**<br>(67µs / **93µs**) | 0.0% / 691.6% | **6.8 MB** |
| **Rust (`actix-web`)** | **604.1k**<br>(**40µs** / 87µs) | **607.3k**<br>(**40µs** / **90µs**) | **541.0k**<br>(**45µs** / 116µs) | **589.5k**<br>(**41µs** / 98µs) | 0.0% / **525.5%** | 9.0 MB |
| **Zig (Lighting + std.Io)** | **501.7k**<br>(49µs / 106µs) | **497.2k**<br>(49µs / 107µs) | **453.9k**<br>(54µs / 117µs) | **495.6k**<br>(49µs / 108µs) | 0.0% / 583.6% | 16.7 MB |
| **Go (`net/http`)** | **357.8k**<br>(103µs / 1.70ms) | **348.1k**<br>(108µs / 1.55ms) | **235.9k**<br>(147µs / 2.02ms) | **317.2k**<br>(120µs / 1.73ms) | 0.0% / 687.5% | 17.5 MB |

* **High Peak Throughput**: Lighting (`zio`) reaches **741k+ QPS** on `/ping` and **654k+ QPS** on dynamic routes with sub-100µs P99 tail latency (**73µs ~ 101µs**), outperforming Rust `actix-web` by up to **22.7%** and more than doubling Go `net/http`.
* **Ultra-Low Memory**: Peak resident set size remains at just **6.8 MB** across 50 concurrent Keep-Alive connections via connection-scoped Arena reuse (`request_arena_retain_limit = 64KB`), 24% lower than Rust (9.0 MB) and 61% lower than Go (17.5 MB).
* **Deterministic Core Isolation**: Leverages hardware-aware core pinning (`taskset -c 0-7` for server, `taskset -c 8-11` for `wrk`) to isolate server processing onto high-frequency Performance cores without scheduling migration noise or client contention.

For complete methodology, runner scripts, and reproduction steps, see the [Benchmark Guide](bench/README.md).

---

## Community & Support

Have questions, ideas, or feedback? Feel free to start a thread on [GitHub Discussions](https://github.com/jiacai2050/lighting/discussions)!

---

## License

[MIT](./LICENSE)
