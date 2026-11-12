# Lighting Benchmark Suite: Zig vs Go vs Rust

This directory contains comparative micro-benchmarks comparing **Lighting (Zig)** against industry-standard web servers in **Go** and **Rust**:

1. **Zig (Lighting)**: Standalone build in `bench/zig/`. Supports pluggable I/O runtime via the `IO` environment variable:
   - `IO=zio` (default): powered by [`lalinsky/zio`](https://github.com/lalinsky/zio) asynchronous runtime with work-stealing executors.
   - `IO=std`: powered by Zig standard library `std.Io` and `std.Io.Group.concurrent`.
2. **Go (`net/http`)**: Go 1.22+ standard library `http.NewServeMux` with native pattern matching (`{id}` and `{filepath...}`) and Goroutine-per-connection scheduling.
3. **Go (`fasthttp`)**: Standalone build in `bench/go-fasthttp/` using [`valyala/fasthttp`](https://github.com/valyala/fasthttp), optimized for high throughput and minimal memory allocations.
4. **Rust (`actix-web`)**: Actix-web 4.x on Tokio multi-threaded runtime, representing one of the fastest web frameworks in the Rust ecosystem.

Interactive charts are available at [Benchmark Report](https://jiacai2050.github.io/lighting/bench/latest.html).

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

To guarantee an apples-to-apples comparison, connection and request timeout configurations are strictly harmonized across all implementations:

| Timeout Dimension | Zig (Lighting) | Go (`net/http`) | Go (`fasthttp`) | Rust (`actix-web`) | Configured Value | Description |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Header Read Timeout** | `read_header_timeout_ns` | `ReadHeaderTimeout` | `ReadTimeout` (full request)* | `client_request_timeout` | **5s** | Slowloris defense; maximum time window allowed for the client to complete sending HTTP request headers. |
| **Connection Idle Timeout** | `idle_timeout_ns` | `IdleTimeout` | `IdleTimeout` | `keep_alive` | **120s** | Maximum idle duration to keep an inactive persistent Keep-Alive connection open before closing. |

> [!NOTE]
> **Timeout Alignment Details & Framework Differences**:
> - In **fasthttp**, there is no standalone `ReadHeaderTimeout`. Because `fasthttp` eagerly reads the entire incoming request (header + body) into pre-allocated memory pool buffers before calling the user handler, its `ReadTimeout` covers the full request transfer. In this benchmark (where payloads are <= 1KB), `ReadTimeout = 5s` provides equivalent Slowloris protection without distorting latency.
> - In **Go** and **Zig**, `ReadTimeout` and `WriteTimeout` enforce deadlines directly at the physical socket transport layer (Layer 4), terminating connections when kernel socket buffers stall.
> - In **Rust (actix-web / Tokio)**, the server operates on a purely asynchronous, non-blocking Future stream without socket-level write deadlines. While application-layer middleware (`wrap_fn`) can enforce a handler execution timeout, it completes as soon as `HttpResponse` is constructed and cannot track whether subsequent socket `writev` flushes are blocked by network congestion.
> - Because application-layer Future timeouts and transport-layer socket deadlines are fundamentally asymmetrical, the benchmark aligns strictly on the two genuine transport-level lifecycles: **Header Read Timeout (5s)** and **Keep-Alive Idle Timeout (120s)**.

---

## CPU Isolation & Core Pinning Strategy

On modern Linux architectures featuring heterogeneous CPU clusters (e.g., Intel Core Ultra / Meteor Lake with P-cores, E-cores, and LP E-cores on separate SOC dies), running unpinned benchmarks results in unpredictable CFS thread migrations. If a server event loop thread wanders onto a low-frequency LP E-core without shared L3 cache, head-of-line blocking can degrade throughput by up to 5x.

To eliminate scheduling noise and guarantee scientific reproducibility, `bench/run.py` implements **automatic hardware topology detection and core isolation via `taskset`**:

1. **Topology Detection**: Inspects `/sys/devices/cpu_core/cpus` and `/sys/devices/cpu_atom/cpus` (or frequency clusters).
2. **Dedicated Server Cores**: The HTTP server under test is automatically pinned to the Performance cores (`taskset -c 0-7` by default).
3. **Dedicated Client Cores**: The `wrk` load generator is pinned to independent, non-overlapping cores (`taskset -c 8-11` by default), completely isolating client-side generation load from server-side request processing.
4. **Driver & Scheduling Defaults**: On Linux, `bench/zig/build.zig` defaults to `zio`'s native `io_uring` backend with `work_stealing` scheduler, which delivers peak throughput (~710k+ QPS on dedicated P-cores).

### Core Pinning Controls

| Environment Variable | Default Behavior | Description |
| :--- | :--- | :--- |
| `SERVER_CORES` | Auto-detected P-cores (e.g. `0-7`) | Explicit CPU core list for the server process (`taskset -c <SERVER_CORES>`). |
| `CLIENT_CORES` | Auto-detected E-cores (e.g. `8-11`) | Explicit CPU core list for `wrk` load generation (`taskset -c <CLIENT_CORES>`). |
| `PIN_CORES` | `1` (on Linux with `taskset`) | Set `PIN_CORES=0` to disable core pinning and run under default OS scheduler. |

### Inspecting CPU Topology

A dedicated utility script is provided to inspect your machine's physical core hierarchy, frequencies, L2/L3 cache domains, and print optimal `taskset` pinning recommendations:

```bash
python3 bench/cpu_topology.py
```

---

## Directory Structure

```
bench/
├── cpu_topology.py            # Inspector for CPU clusters, frequencies, and cache domains
├── zig/                       # Standalone Zig project (Lighting + pluggable I/O)
│   ├── build.zig
│   ├── build.zig.zon
│   └── main.zig
├── go/                        # Standalone Go 1.22+ net/http project
│   ├── go.mod
│   └── main.go
├── go-fasthttp/               # Standalone Go fasthttp project
│   ├── go.mod
│   ├── go.sum
│   └── main.go
├── rust/                      # Standalone Rust actix-web 4.x project
│   ├── Cargo.toml
│   └── src/
│       └── main.rs
├── report/                    # Generated benchmark reports and interactive HTML files
│   └── latest.html
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

# Run with lalinsky/zio runtime (defaults to io_uring + work_stealing on Linux)
IO=zio zig build run -Doptimize=ReleaseFast

# Optional: Override zio event loop backend or scheduling discipline
IO=zio zig build run -Doptimize=ReleaseFast -Dbackend=epoll -Dscheduling=pinned

# Or run with Zig standard library std.Io
IO=std zig build run -Doptimize=ReleaseFast
```

### 2. Go (`net/http`)
```bash
cd bench/go
go build -ldflags="-s -w" -o bench-go main.go
PORT=8088 ./bench-go
```

### 3. Go (`fasthttp`)
```bash
cd bench/go-fasthttp
go build -ldflags="-s -w" -o bench-fasthttp main.go
PORT=8088 ./bench-fasthttp
```

### 4. Rust (`actix-web`)
```bash
cd bench/rust
cargo build --release
PORT=8088 ./target/release/lighting-bench-rust
```
