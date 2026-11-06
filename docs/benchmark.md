# Lighting Web Framework Benchmark Guide & Methodology

> **Target Version**: Zig 0.17.0
> **Default Port**: `7000` (or `8088` in multi-target benchmarks)
> **Server Binary**: `bench/zig/main.zig`

This document provides a comprehensive guide for conducting load tests, benchmarking throughput, and measuring latency characteristics of the **Lighting** web framework.

---

## 1. Concurrency Model & Architecture Notes

Lighting couples a zero-copy protocol parser with Zig 0.17 structured concurrency (`std.Io.Group.concurrent`):
* **Connection Lifecycle**: Each incoming TCP connection accepted by the listener is dispatched concurrently via `self.group.concurrent(self.io, serveConnWorker, .{ self, stream })`, matching Go's `go c.serve()` model.
* **Lightweight Concurrency & Fiber Execution**: Under `std.Io.Evented` (such as Linux `io_uring` or BSD `kqueue`), connections are handled as lightweight user-space Fibers (green threads) with non-blocking I/O. Under `std.Io.Threaded`, tasks are scheduled across available concurrency units without requiring manual thread pool tuning.
* **Zero Idle CPU**: Sockets waiting on requests or idle timeouts are managed directly by the kernel's event loop or sleep queues, consuming **strictly 0.0% CPU** when no requests are being processed.
* **Zero-Allocation Parsing**: Headers and URL paths are sliced directly from the socket buffer into the routing engine without intermediate string copies.

---

## 2. Environment Preparation & Tuning

### 2.1 File Descriptor Limits
High-concurrency benchmarks open numerous simultaneous socket file descriptors. Increase your shell's descriptor limit before running tests:

```bash
# Verify current limit
ulimit -n

# Increase limit for the current terminal session
ulimit -n 65535
```

### 2.2 Compilation Mode
Always benchmark with optimization enabled. Zig's `Debug` mode contains safety runtime assertions and unoptimized codegen intended for debugging.

```bash
# Navigate to the benchmark directory and build in ReleaseFast mode
cd bench/zig
zig build -Doptimize=ReleaseFast

# The output executable is located at:
./zig-out/bin/bench-server
```

---

## 3. Starting the Benchmark Server

Launch the test server in an independent terminal window:

```bash
# Run with ReleaseFast optimization (from bench/zig)
cd bench/zig && zig build run -Doptimize=ReleaseFast

# Or run from project root:
make bench

# Expected console output:
# info: Lighting benchmark server running on http://127.0.0.1:7000 (io=zio, threads=4)
```

The benchmark server configures the following endpoints:
* `GET /ping` — Exact match static response (`pong\n`).
* `GET /users/{id}` — Dynamic route parameter extraction (`{"user_id":"..."}\n`).
* `POST /echo` — Request body reading and echo (`Echo: ...\n`).
* `GET /files/{filepath...}` — Multi-segment catch-all wildcard routing (`Serving: ...\n`).

---

## 4. ApacheBench (`ab`) Usage Guide

ApacheBench (`ab`) is bundled by default on macOS (`/usr/sbin/ab`) and available on Linux distributions via `apache2-utils`.

### 4.1 CLI Flags Cheat Sheet

| Flag | Parameter | Description |
| :--- | :--- | :--- |
| **`-n`** | `requests` | Total number of HTTP requests to perform (e.g. `-n 10000`). |
| **`-c`** | `concurrency` | Number of concurrent requests / connections to run simultaneously (e.g. `-c 50`). |
| **`-k`** | *(none)* | Enable HTTP **Keep-Alive** (persistent connection reuse). Recommended for application-level benchmarking. |
| **`-p`** | `file` | Path to file containing data to **POST** as the request body. |
| **`-T`** | `content-type` | Content-Type header to use for POST requests (e.g. `application/json`). |
| **`-s`** | `seconds` | Maximum seconds to wait before socket timeout (default: 30s). |

---

### 4.2 Benchmark Scenarios

#### Scenario A: Short-Lived Connections (`Connection: close`)
Measures connection setup and teardown overhead alongside HTTP processing:

```bash
ab -c 20 -n 2000 http://127.0.0.1:7000/ping
```

#### Scenario B: High-Throughput Keep-Alive (`/ping`)
Measures pure HTTP parsing and response generation with connection reuse:

```bash
ab -k -c 50 -n 10000 http://127.0.0.1:7000/ping
```

#### Scenario C: Dynamic Go 1.22+ Parameter Routing (`/users/{id}`)
Measures pattern matching and zero-copy path parameter extraction:

```bash
ab -k -c 50 -n 10000 http://127.0.0.1:7000/users/42
```

#### Scenario D: POST Endpoint with Request Body
Measures streamed body reading and echo response generation:

```bash
# 1. Create temporary test payload in repository scratch directory
mkdir -p .scratch
echo -n "Lighting benchmark request payload" > .scratch/payload.txt

# 2. Run POST benchmark
ab -k -c 50 -n 10000 -p .scratch/payload.txt -T "text/plain" http://127.0.0.1:7000/echo
```

#### Scenario E: Multi-Segment Catch-All Wildcard (`/files/{filepath...}`)
Measures recursive prefix tree traversal and greedy path capturing:

```bash
ab -k -c 50 -n 10000 http://127.0.0.1:7000/files/docs/2026/q3/quarterly_report.pdf
```

---

## 5. Interpreting ApacheBench Reports

When `ab` finishes, examine the following key performance indicators:

```text
Server Hostname:        127.0.0.1
Server Port:            7000

Document Path:          /users/42
Concurrency Level:      50
Time taken for tests:   0.120 seconds
Complete requests:      10000
Failed requests:        0
Keep-Alive requests:    10000
Requests per second:    83434.15 [#/sec] (mean)
Time per request:       0.599 [ms] (mean)
Time per request:       0.012 [ms] (mean, across all concurrent requests)
Transfer rate:          9125.61 [Kbytes/sec] received

Connection Times (ms)
              min  mean[+/-sd] median   max
Connect:        0    0   0.1      0       1
Processing:     0    1   0.3      0       3
Waiting:        0    0   0.2      0       2
Total:          0    1   0.4      0       3

Percentage of the requests served within a certain time (ms)
  50%      0ms   # 50th percentile (median latency)
  90%      1ms
  99%      1ms   # 99th percentile (long-tail latency)
 100%      3ms   # Maximum latency observed
```

### Key Metrics Defined:
* **Requests per second (RPS / QPS)**: Average number of requests completed per second. Higher is better.
* **Failed requests**: Must strictly be **0**. Any non-zero count indicates dropped connections or socket errors.
* **Time per request (across concurrent requests)**: Real single-request processing latency experienced by the server core (e.g. `0.012 ms`).
* **Percentage served (Percentiles)**: Evaluates latency tail distribution. A P99 of `1 ms` confirms zero tail latency spikes under heavy concurrent load.

---

## 6. Workstation Benchmark Results

The following measurements were captured on an Apple Silicon M-series workstation running macOS in `ReleaseFast` mode:

| Benchmark Route | Request Type | Concurrency (`-c`) | Total Requests (`-n`) | Throughput (QPS) | Latency (Mean per Req) | Failed Requests |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `GET /ping` | Short-lived | 20 | 2,000 | **28,279.34** | 0.035 ms | 0 |
| `GET /ping` | Keep-Alive | 50 | 10,000 | **73,934.97** | 0.014 ms | 0 |
| `GET /users/42` | Keep-Alive (Params) | 50 | 10,000 | **83,434.15** | 0.012 ms | 0 |
| `POST /echo` | Keep-Alive (Body) | 50 | 10,000 | **76,489.44** | 0.013 ms | 0 |

---

## 7. Automated Multi-Target Benchmark Suite (Zig vs Go vs Rust)

To run the automated comparative benchmark comparing Lighting against Go (`net/http`) and Rust (`actix-web`):

```bash
# Run all targets with wrk
make bench-all
# or directly:
./bench/run.sh
```

See [`bench/README.md`](../bench/README.md) for full details on parameters, per-target builds, and CPU/memory tracking.

---

## 8. Alternative Multi-Threaded Tools

If benchmarking from multiple CPU client cores with tools such as `wrk` or `bombardier`:

### `wrk`
```bash
# 4 client threads, 50 concurrent connections, 10 second duration
wrk -t4 -c50 -d10s -H "Connection: keep-alive" http://127.0.0.1:7000/users/42
```

### `bombardier`
```bash
# Fast Go-based load generator
bombardier -c 50 -n 10000 -k http://127.0.0.1:7000/ping
```
