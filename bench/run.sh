#!/usr/bin/env bash
set -euo pipefail

# Configuration
PORT=${PORT:-8088}
THREADS=${THREADS:-4}
CONCURRENCY=${CONCURRENCY:-50}
DURATION=${DURATION:-10s}
WARMUP_DURATION="2s"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Check bash version (requires Bash 4+ for associative arrays)
if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
    echo >&2 "Error: Bash 4.0 or newer is required (you are running Bash $BASH_VERSION)."
    echo >&2 "On macOS, install modern bash via 'brew install bash' and ensure it appears in your PATH."
    exit 1
fi

# Verify prerequisites
command -v wrk >/dev/null 2>&1 || { echo >&2 "Error: 'wrk' is required but not installed."; exit 1; }
command -v curl >/dev/null 2>&1 || { echo >&2 "Error: 'curl' is required but not installed."; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo >&2 "Error: 'python3' is required but not installed."; exit 1; }
command -v bc >/dev/null 2>&1 || { echo >&2 "Error: 'bc' is required but not installed."; exit 1; }
command -v lsof >/dev/null 2>&1 || { echo >&2 "Error: 'lsof' is required but not installed."; exit 1; }

echo "================================================================"
echo "           Lighting Benchmark Suite (Zig vs Go vs Rust)         "
echo "================================================================"
echo "Port:        $PORT"
echo "Threads:     $THREADS"
echo "Concurrency: $CONCURRENCY"
echo "Duration:    $DURATION per test"
echo "Platform:    $(uname -s) $(uname -m)"
echo "================================================================"
echo ""

# Build targets in their own directories
echo "[1/3] Building Zig (Lighting - ReleaseFast in bench/zig)..."
(cd "$PROJECT_ROOT/bench/zig" && zig build -Doptimize=ReleaseFast)
ZIG_BIN="$PROJECT_ROOT/bench/zig/zig-out/bin/bench-server"

if [ "${ONLY_ZIG:-0}" != "1" ]; then
    echo "[2/3] Building Go (net/http - Release in bench/go)..."
    (cd "$PROJECT_ROOT/bench/go" && go build -ldflags="-s -w" -o bench-go main.go)
    GO_BIN="$PROJECT_ROOT/bench/go/bench-go"

    echo "[3/3] Building Rust (actix-web - Release in bench/rust)..."
    (cd "$PROJECT_ROOT/bench/rust" && cargo build --release)
    RUST_BIN="$PROJECT_ROOT/bench/rust/target/release/lighting-bench-rust"
fi

# Prepare static Lua script for POST /echo benchmark
mkdir -p "$PROJECT_ROOT/.scratch"
ECHO_LUA="$PROJECT_ROOT/.scratch/echo.lua"
cat << 'EOF' > "$ECHO_LUA"
wrk.method = "POST"
wrk.body   = string.rep("A", 1024)
wrk.headers["Content-Type"] = "text/plain"
EOF

# Ensure port is released
ensure_port_free() {
    local count=0
    while lsof -i :"$PORT" >/dev/null 2>&1; do
        sleep 0.1
        count=$((count + 1))
        if [ "$count" -ge 50 ]; then
            echo "Warning: Port $PORT is still occupied after 5s." >&2
            break
        fi
    done
}

# Wait for server readiness
wait_ready() {
    local max_retries=50
    local count=0
    while ! curl -s -o /dev/null "http://127.0.0.1:$PORT/ping"; do
        sleep 0.1
        count=$((count + 1))
        if [ "$count" -ge "$max_retries" ]; then
            echo "Error: Server failed to start on port $PORT" >&2
            return 1
        fi
    done
}

get_rss_mb() {
    local pid="$1"
    local rss_kb
    rss_kb=$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ' || echo "")
    if [ -n "$rss_kb" ] && [ "$rss_kb" != "0" ]; then
        echo "scale=1; $rss_kb / 1024" | bc
    else
        echo "0"
    fi
}

get_cpu_time() {
    local pid="$1"
    python3 -c "
import subprocess
try:
    out = subprocess.check_output(['ps', '-o', 'time=', '-p', '$pid'], stderr=subprocess.DEVNULL).decode().strip()
    parts = out.split(':')
    if len(parts) == 2:
        print(float(parts[0]) * 60 + float(parts[1]))
    elif len(parts) == 3:
        print(float(parts[0]) * 3600 + float(parts[1]) * 60 + float(parts[2]))
    else:
        print(0.0)
except Exception:
    print(0.0)
"
}

get_time_sec() {
    python3 -c "import time; print(f'{time.time():.4f}')"
}

SRV_PID=""
cleanup() {
    if [ -n "${SRV_PID:-}" ]; then
        kill -9 "$SRV_PID" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT INT TERM

declare -A RESULTS_QPS
declare -A RESULTS_LAT
declare -A RESULTS_RSS
declare -A RESULTS_CPU

bench_target() {
    local name="$1"
    local bin="$2"
    local env_extra="${3:-}"

    ensure_port_free

    echo ">>> Testing $name ($env_extra)..."
    if [ -n "$env_extra" ]; then
        env PORT="$PORT" $env_extra "$bin" > /dev/null 2>&1 &
    else
        env PORT="$PORT" "$bin" > /dev/null 2>&1 &
    fi
    local srv_pid=$!
    SRV_PID="$srv_pid"

    wait_ready

    # Measure initial idle RSS and idle CPU (1.0s window)
    local t_idle_start c_idle_start t_idle_end c_idle_end
    t_idle_start=$(get_time_sec)
    c_idle_start=$(get_cpu_time "$srv_pid")
    sleep 1.0
    t_idle_end=$(get_time_sec)
    c_idle_end=$(get_cpu_time "$srv_pid")

    local idle_cpu
    idle_cpu=$(python3 -c "
dt = float($t_idle_end) - float($t_idle_start)
dc = float($c_idle_end) - float($c_idle_start)
if dt > 0:
    print(f'{max(0.0, (dc / dt) * 100):.1f}%')
else:
    print('0.0%')
")
    local idle_rss
    idle_rss=$(get_rss_mb "$srv_pid")

    # Warmup
    wrk -t"$THREADS" -c"$CONCURRENCY" -d"$WARMUP_DURATION" -H "Connection: keep-alive" "http://127.0.0.1:$PORT/ping" >/dev/null 2>&1

    # Start tracking CPU time under active load
    local t_load_start c_load_start
    t_load_start=$(get_time_sec)
    c_load_start=$(get_cpu_time "$srv_pid")

    # Case 1: GET /ping
    echo "  [1/4] Running Case 1: GET /ping..."
    local out_ping
    out_ping=$(wrk -t"$THREADS" -c"$CONCURRENCY" -d"$DURATION" -H "Connection: keep-alive" "http://127.0.0.1:$PORT/ping")
    local qps_ping
    qps_ping=$(echo "$out_ping" | awk '/Requests\/sec:/ {print $2}')
    local lat_ping
    lat_ping=$(echo "$out_ping" | awk '/Latency/ {print $2}')

    # Case 2: GET /users/42
    echo "  [2/4] Running Case 2: GET /users/42 (Dynamic Route & JSON)..."
    local out_user
    out_user=$(wrk -t"$THREADS" -c"$CONCURRENCY" -d"$DURATION" -H "Connection: keep-alive" "http://127.0.0.1:$PORT/users/42")
    local qps_user
    qps_user=$(echo "$out_user" | awk '/Requests\/sec:/ {print $2}')
    local lat_user
    lat_user=$(echo "$out_user" | awk '/Latency/ {print $2}')

    # Case 3: POST /echo
    echo "  [3/4] Running Case 3: POST /echo (1KB Body Read)..."
    local out_echo
    out_echo=$(wrk -t"$THREADS" -c"$CONCURRENCY" -d"$DURATION" -H "Connection: keep-alive" -s "$ECHO_LUA" "http://127.0.0.1:$PORT/echo")
    local qps_echo
    qps_echo=$(echo "$out_echo" | awk '/Requests\/sec:/ {print $2}')
    local lat_echo
    lat_echo=$(echo "$out_echo" | awk '/Latency/ {print $2}')

    # Case 4: GET /files/static/css/theme/dark.min.css
    echo "  [4/4] Running Case 4: GET /files/... (Wildcard Catch-all)..."
    local out_files
    out_files=$(wrk -t"$THREADS" -c"$CONCURRENCY" -d"$DURATION" -H "Connection: keep-alive" "http://127.0.0.1:$PORT/files/static/css/theme/dark.min.css")
    local qps_files
    qps_files=$(echo "$out_files" | awk '/Requests\/sec:/ {print $2}')
    local lat_files
    lat_files=$(echo "$out_files" | awk '/Latency/ {print $2}')

    local t_load_end c_load_end
    t_load_end=$(get_time_sec)
    c_load_end=$(get_cpu_time "$srv_pid")

    local load_cpu
    load_cpu=$(python3 -c "
dt = float($t_load_end) - float($t_load_start)
dc = float($c_load_end) - float($c_load_start)
if dt > 0:
    print(f'{(dc / dt) * 100:.1f}%')
else:
    print('0.0%')
")

    local peak_rss
    peak_rss=$(get_rss_mb "$srv_pid")

    # Stop server forcefully and verify port release
    kill -9 "$srv_pid" >/dev/null 2>&1 || true
    wait "$srv_pid" 2>/dev/null || true
    SRV_PID=""
    ensure_port_free

    RESULTS_QPS["${name}_ping"]=${qps_ping:-0}
    RESULTS_LAT["${name}_ping"]=${lat_ping:-0}
    RESULTS_QPS["${name}_user"]=${qps_user:-0}
    RESULTS_LAT["${name}_user"]=${lat_user:-0}
    RESULTS_QPS["${name}_echo"]=${qps_echo:-0}
    RESULTS_LAT["${name}_echo"]=${lat_echo:-0}
    RESULTS_QPS["${name}_files"]=${qps_files:-0}
    RESULTS_LAT["${name}_files"]=${lat_files:-0}
    RESULTS_RSS["${name}"]="$idle_rss MB / $peak_rss MB"
    RESULTS_CPU["${name}"]="$idle_cpu / $load_cpu"

    echo "  Completed $name."
    echo ""
}

# Run benchmarks for all configurations
TARGETS=()

bench_target "Zig_Lighting_zio" "$ZIG_BIN" "IO=zio"
TARGETS+=("Zig_Lighting_zio")

bench_target "Zig_Lighting_std" "$ZIG_BIN" "IO=std"
TARGETS+=("Zig_Lighting_std")

if [ "${ONLY_ZIG:-0}" != "1" ]; then
    bench_target "Go_net_http" "$GO_BIN" ""
    TARGETS+=("Go_net_http")

    bench_target "Rust_actix_web" "$RUST_BIN" ""
    TARGETS+=("Rust_actix_web")
fi

# Print Formatted Markdown Table
echo "================================================================================"
echo "                             Benchmark Results                                  "
echo "================================================================================"
echo ""
echo "| Framework / Language | GET /ping (QPS / Lat) | GET /users/{id} (QPS / Lat) | POST /echo (QPS / Lat) | GET /files/* (QPS / Lat) | CPU (Idle / Load Avg) | Memory (Idle / Peak RSS) |"
echo "| :--- | :--- | :--- | :--- | :--- | :--- | :--- |"
for t in "${TARGETS[@]}"; do
    kp="${t}_ping"
    ku="${t}_user"
    ke="${t}_echo"
    kf="${t}_files"
    echo "| **$t** | ${RESULTS_QPS[$kp]} req/s (${RESULTS_LAT[$kp]}) | ${RESULTS_QPS[$ku]} req/s (${RESULTS_LAT[$ku]}) | ${RESULTS_QPS[$ke]} req/s (${RESULTS_LAT[$ke]}) | ${RESULTS_QPS[$kf]} req/s (${RESULTS_LAT[$kf]}) | ${RESULTS_CPU[$t]} | ${RESULTS_RSS[$t]} |"
done
echo ""
