# Lighting Benchmark Suite: Zig vs Go vs Rust

This directory contains comparative micro-benchmarks comparing **Lighting (Zig)** against industry-standard web servers in **Go** and **Rust**:

1. **Zig (Lighting)**: Standalone build in `bench/zig/`. Supports pluggable I/O runtime via the `IO` environment variable:
   - `IO=zio` (default): powered by [`lalinsky/zio`](https://github.com/lalinsky/zio) asynchronous runtime with work-stealing executors.
   - `IO=std`: powered by Zig standard library `std.Io` and `std.Io.Group.concurrent`.
2. **Go (`net/http`)**: Go 1.22+ standard library `http.NewServeMux` with native pattern matching (`{id}` and `{filepath...}`) and Goroutine-per-connection scheduling.
3. **Rust (`actix-web`)**: Actix-web 4.x on Tokio multi-threaded runtime, representing one of the fastest web frameworks in the Rust ecosystem.

---

## Benchmark Scenarios

The suite evaluates four distinct workloads to measure both raw I/O throughput and framework routing/parsing overhead:

| Scenario | HTTP Method & Path | Payload / Response | Primary Metric Tested |
| :--- | :--- | :--- | :--- |
| **Case 1: Minimal Ping** | `GET /ping` | `text/plain`<br>`"pong\n"` | **Raw HTTP Framing & I/O Loop**: Evaluates baseline connection handling, keep-alive reuse, and minimal response overhead. |
| **Case 2: Dynamic Route & JSON** | `GET /users/{id}` (e.g. `42`) | `application/json`<br>`{"user_id":"42"}` | **Trie Routing & Parameter Extraction**: Evaluates path parameter matching, URL parsing, and JSON serialization overhead. |
| **Case 3: Request Body Echo** | `POST /echo` (1KB payload) | `text/plain`<br>`"Echo: ...\n"` | **Stream Buffering & Payload Handling**: Evaluates incoming request body reading, chunk buffering, and payload write-back. |
| **Case 4: Wildcard Catch-All** | `GET /files/{filepath...}` | `text/plain`<br>`"Serving: ...\n"` | **Deep Path Routing & Backtracking**: Evaluates multi-segment wildcard matching across deep nested URL segments. |

---

## Timeout Alignment Across Frameworks

To guarantee an apples-to-apples comparison, connection and request timeout configurations are strictly harmonized across all three implementations:

| Timeout Dimension | Zig (Lighting) | Go (`net/http`) | Rust (`actix-web`) | Configured Value | Description |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Header Read Timeout** | `read_header_timeout_ns` | `ReadHeaderTimeout` | `client_request_timeout` | **5s** | Slowloris defense; maximum time window allowed for the client to complete sending HTTP request headers. |
| **Connection Idle Timeout** | `idle_timeout_ns` | `IdleTimeout` | `keep_alive` | **120s** | Maximum idle duration to keep an inactive persistent Keep-Alive connection open before closing. |

> [!NOTE]
> **Why socket-level Read / Write timeouts are omitted**:
> - In **Go** and **Zig**, `ReadTimeout` and `WriteTimeout` enforce deadlines directly at the physical socket transport layer (Layer 4), terminating connections when kernel socket buffers stall.
> - In **Rust (actix-web / Tokio)**, the server operates on a purely asynchronous, non-blocking Future stream without socket-level write deadlines. While application-layer middleware (`wrap_fn`) can enforce a handler execution timeout, it completes as soon as `HttpResponse` is constructed and cannot track whether subsequent socket `writev` flushes are blocked by network congestion.
> - Because application-layer Future timeouts and transport-layer socket deadlines are fundamentally asymmetrical, the benchmark aligns strictly on the two genuine transport-level lifecycles: **Header Read Timeout (5s)** and **Keep-Alive Idle Timeout (120s)**.

---

## Directory Structure

```
bench/
├── zig/                       # Standalone Zig project (Lighting + pluggable I/O)
│   ├── build.zig
│   ├── build.zig.zon
│   └── main.zig
├── go/                        # Standalone Go 1.22+ net/http project
│   ├── go.mod
│   └── main.go
├── rust/                      # Standalone Rust actix-web 4.x project
│   ├── Cargo.toml
│   └── src/
│       └── main.rs
├── run.py                     # Automated benchmark runner and comparative report generator
└── README.md                  # This documentation
```

---

## Prerequisites

- Python 3.8+
- [wrk](https://github.com/wg/wrk) (`brew install wrk` on macOS, or `apt-get install wrk` on Linux)
- Zig 0.17.0+
- Go 1.22.0+
- Rust 1.80+ (with Cargo)
- `curl`, `lsof`

---

## Running the Automated Benchmark Suite

Run the full comparative suite across all configurations:

```bash
python3 bench/run.py
# or from root:
make bench-all
```

### Configurable Environment Variables

```bash
PORT=8088 THREADS=4 CONCURRENCY=50 DURATION=10s python3 bench/run.py
```

The script will:
1. Compile all implementations in optimal release mode (`ReleaseFast` for Zig, `-ldflags="-s -w"` for Go, `--release` for Rust).
2. Sequentially boot each server, verify HTTP readiness, and perform a 2s warmup.
3. Execute `wrk` load tests for each of the 4 benchmark cases.
4. Track CPU utilization (both idle and under active load) and memory RSS (idle vs peak).
5. Print a comparative Markdown table with QPS, average latency, CPU usage, and memory consumption.

---

## Running Individual Servers

### 1. Zig (Lighting)
```bash
cd bench/zig

# Run with lalinsky/zio runtime (default)
IO=zio zig build run -Doptimize=ReleaseFast

# Or run with Zig standard library std.Io
IO=std zig build run -Doptimize=ReleaseFast
```

### 2. Go (`net/http`)
```bash
cd bench/go
go build -ldflags="-s -w" -o bench-go main.go
PORT=8088 ./bench-go
```

### 3. Rust (`actix-web`)
```bash
cd bench/rust
cargo build --release
PORT=8088 ./target/release/lighting-bench-rust
```
