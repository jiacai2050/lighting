# Lighting Documentation

Welcome to the **Lighting** documentation.

**Lighting** is a high-performance, lightweight HTTP/1.1 server library written for **Zig 0.17**, featuring idiomatic Go-aligned ergonomics, structured concurrency via `std.Io.Group`, deterministic memory overhead, and zero external dependencies.

---

## Documentation Roadmap

The documentation is organized into five specialized sections:

* **[Getting Started](getting-started/overview.md)**: Conceptual foundations, installation instructions via `build.zig.zon`, and a minimal quick-start tutorial.
* **[User Guide](guide/server.md)**: Comprehensive, task-oriented guides for building web applications — covering server lifecycle, routing syntax, request inspection, response generation, state injection, middleware pipelines, static files, and WebSockets.
* **[Internals](internals/architecture.md)**: In-depth technical analysis for systems engineers and contributors — exploring structured concurrency dispatch, zero-copy protocol parsing, decision-tree routing algorithms, arena allocators, and TigerStyle defensive invariants.
* **[Cookbook](cookbook/hello.md)**: Real-world, end-to-end applications including REST APIs, SQLite with embedded SPAs, WebSocket chat servers, and command-line file servers.
* **[Project & Evolution](benchmark.md)**: Architecture design specifications, empirical benchmarks with comparative throughput metrics, development workflow, and protocol milestones.
