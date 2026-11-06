# Overview & Philosophy

**Lighting** is a modern web framework for **Zig**. It bridges two worlds: the proven, ergonomic developer experience of Go's `net/http` and the low-level mechanical sympathy, zero-allocation control, and deterministic memory safety of Zig.

---

## Core Tenets

### 1. Idiomatic Web Ergonomics
Zig is a low-level systems language, but web APIs do not have to be convoluted. Lighting adapts the battle-tested conventions popularized by Go's `net/http`:
* `*ResponseWriter`: Intuitive response streaming with built-in 4KB stack buffer optimization.
* `*Request`: Clean URL inspection, path parameter lookup, header parsing, and body streaming.
* Fat-Pointer `Handler`: Universal handler interface with zero-overhead state injection (`Handler.bind`).
* `ServeMux`: Pattern-based request router with Go 1.22+ wildcard and method-prefix support.

### 2. Structured Concurrency via `std.Io.Group`
Rather than relying on thread pools with task queues or heavy OS thread-per-connection architectures, Lighting embraces Zig 0.17's native structured concurrency:
* Each accepted connection is dispatched using `std.Io.Group.concurrent`.
* Connections run as lightweight fibers / coroutines without OS thread starvation.
* Connection lifetimes are strictly bounded by their parent `Server.serve` scope, guaranteeing clean cancellation and resource reclamation on shutdown.

### 3. Deterministic Memory & Zero Unbounded Allocation
* **Zero Heap Fast Path**: Small HTTP responses (<= 4KB) are buffered directly on the stack and flushed to the socket without invoking GPA.
* **Per-Request Arena**: All allocations generated during request parsing, path parameter extraction, and route dispatch live within a single per-request arena allocator. At the end of the request cycle, the arena is reset in $O(1)$ time.
* **Bounded Connection Buffers**: Incoming socket buffers are fixed-size (8KB–16KB) to prevent unbounded memory amplification attacks.

### 4. TigerStyle Robustness
Lighting adheres to the TigerStyle engineering ethos:
* Strict assertion of preconditions and invariants at every layer.
* Explicit limits on header count, URI length, chunk framing, and body draining.
* Strict RFC 9110 / RFC 9112 protocol compliance.
* Zero external third-party dependencies.
