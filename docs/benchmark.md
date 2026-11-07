# Lighting Web Framework Benchmark

Automated comparative benchmarking suite comparing **Lighting** (Zig 0.17.0, `std.Io` and `lalinsky/zio` backends) against **Go** (`net/http`) and **Rust** (`actix-web`).

---

## 1. How the Benchmark Suite Works

The benchmark suite is automated via [`bench/run.py`](../bench/run.py) (or `make bench-all`), using `wrk` as the load generator across 4 typical HTTP endpoints:
1. `GET /ping` — Minimal plaintext response.
2. `GET /users/{id}` — Dynamic route parameter matching and JSON serialization.
3. `POST /echo` — Reading a 1KB request body and streaming the echo response.
4. `GET /files/{filepath...}` — Multi-segment catch-all wildcard routing.

### 1.1 Execution Flow & Features
* **Hardware & Topology Detection**: Automatically collects OS version, RAM capacity, compiler releases, and CPU core architectures (including macOS Apple Silicon Performance and Efficiency core breakdown, e.g., `8 cores: 4 Performance + 4 Efficiency`).
* **Automated Builds**: Builds all targets with peak optimizations (`zig build -Doptimize=ReleaseFast`, `go build -ldflags="-s -w"`, and `cargo build --release`).
* **Parity Timeout Alignment**: To ensure fair comparisons, all servers enforce identical transport-level timeout constraints:
  * **Header Read Timeout**: 5s (`read_header_timeout_ns` in Zig, `ReadHeaderTimeout` in Go, `client_request_timeout` in Rust).
  * **Connection Idle Timeout**: 120s (`idle_timeout_ns` in Zig, `IdleTimeout` in Go, `keep_alive` in Rust).
  * *Note on Read/Write Timeouts*: Socket-level Read/Write deadlines are intentionally omitted across all targets. Rust (`actix-web` on Tokio) operates on an asynchronous stream model without physical socket write deadlines (application Future timeouts only track handler execution, not kernel socket flush stalls). Aligning on asymmetrical Layer-4 vs Layer-7 timeouts would skew results, so all three frameworks standardize strictly on genuine transport-level Header Read (5s) and Idle (120s) timeouts.
* **Port Management & Resource Tracking**: Verifies TCP port release between test cases, applies 2s warmups before each test run, and monitors peak resident set size (Peak RSS) and CPU load.
* **Report Generation**: Outputs Markdown summaries with timestamps into `.scratch/` and updates `.scratch/latest.md`.

### 1.2 Running the Suite

**Prerequisites**: `python3`, `wrk`, and `curl`.

```bash
# Run the full comparative suite (Zig, Go, Rust)
make bench-all

# Or run directly via Python with custom parameters:
python3 bench/run.py

# Optional environment variables:
# ONLY_ZIG=1          - Benchmark only Zig backends (std.Io and zio)
# DURATION=10s        - Test duration per endpoint (default: 10s)
# CONCURRENCY=50      - Concurrent Keep-Alive connections (default: 50)
# THREADS=4           - wrk client threads (default: 4)
# PORT=8088           - Benchmark server port (default: 8088)
```

---

## 2. Benchmark Results

*Environment: Debian GNU/Linux 13 (trixie) (x86_64), Intel(R) Core(TM) i5-8500 CPU @ 3.00GHz (6 cores), 15.4 GB RAM, ReleaseFast / Release optimizations.*  
*Parameters: 4 threads, 50 concurrency, 10s per test, 2s warmup.*

| Framework / Implementation | GET `/ping`<br>*(QPS / P50 / P99)* | GET `/users/{id}`<br>*(QPS / P50 / P99)* | POST `/echo`<br>*(QPS / P50 / P99)* | GET `/files/*`<br>*(QPS / P50 / P99)* | CPU<br>*(Idle / Load)* | Peak Memory<br>*(RSS)* |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Zig (Lighting + zio)** | **333.4k**<br>(**59µs** / 7.52ms) | **329.3k**<br>(**60µs** / 7.44ms) | **289.7k**<br>(**75µs** / 5.89ms) | **321.5k**<br>(**63µs** / 7.34ms) | 0.0% / 304.1% | **6.1 MB** |
| **Rust (`actix-web`)** | **308.0k**<br>(64µs / 6.71ms) | **285.7k**<br>(70µs / 4.74ms) | **263.5k**<br>(81µs / **3.62ms**) | **276.7k**<br>(76µs / 4.34ms) | 0.0% / 314.9% | 8.0 MB |
| **Zig (Lighting + std.Io)** | **238.1k**<br>(126µs / **1.84ms**) | **225.3k**<br>(141µs / **2.11ms**) | **209.5k**<br>(152µs / **1.46ms**) | **211.5k**<br>(157µs / **0.86ms**) | 0.0% / 296.9% | 16.4 MB |
| **Go (`net/http`)** | **172.0k**<br>(195µs / 3.30ms) | **164.9k**<br>(204µs / 3.28ms) | **133.6k**<br>(249µs / 2.71ms) | **158.0k**<br>(212µs / 3.18ms) | 0.0% / 381.8% | 15.8 MB |

---

## 3. Results Interpretation

### 3.1 Why P50 and P99 Over Arithmetic Mean (`Avg`)
Traditional benchmarks reporting arithmetic mean latency (`Avg`) can be misleading: a handful of extreme outlier delays heavily distort the mean, sometimes showing higher QPS with worse average latency.
* **P50 (Median)**: Measures real latency experienced by typical requests. On Linux, Lighting (`zio`) achieves sub-60µs median latency (59µs vs Rust's 64µs and Go's 195µs), directly translating into its 333k+ QPS throughput.
* **P99 (Tail Latency)**: Evaluates worst-case event-loop delays and thread scheduling jitter under full concurrency.

### 3.2 Key Takeaways
1. **Industry-Leading Throughput**:
   On Linux x86_64, Lighting with the `zio` asynchronous engine achieves the highest throughput across all endpoints (**289.7k ~ 333.4k QPS**), outperforming Rust `actix-web` (263.5k ~ 308.0k QPS) and delivering roughly **2x the throughput** of Go `net/http` (133.6k ~ 172.0k QPS).
2. **Minimal Memory Footprint**:
   Lighting (`zio`) maintains a peak resident set size (Peak RSS) of only **6.1 MB** under 50 concurrent Keep-Alive connections, lower than Rust (8.0 MB) and nearly one-third of Go (15.8 MB).
   * Connection-level `ArenaAllocator` reuse (`request_arena_retain_limit = 64KB`) eliminates per-request OS page allocation thrashing while strictly capping maximum memory retention.
3. **I/O Engine Trade-Offs (`zio` vs `std.Io`)**:
   * **`zio` (Event-driven asynchronous fibers)**: Fully unleashes Linux event polling, delivering maximum raw QPS (333.4k) and lowest memory footprint (6.1MB).
   * **`std.Io` (Thread pool with blocking I/O)**: Provides rock-solid tail latency stability under heavy load, keeping P99 within **0.86ms ~ 2.11ms** (superior to both `zio` and `actix-web`), at the cost of lower raw throughput (238k QPS) and higher thread stack memory (16.4MB).
