#!/usr/bin/env python3
import os
import sys
import time
import socket
import shutil
import subprocess
import platform
import re
from datetime import datetime

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
PORT = int(os.environ.get("PORT", "8088"))
THREADS = int(os.environ.get("THREADS", "4"))
CONCURRENCY = int(os.environ.get("CONCURRENCY", "50"))
DURATION = os.environ.get("DURATION", "10s")
WARMUP_DURATION = "2s"
ONLY_ZIG = os.environ.get("ONLY_ZIG", "0") == "1"

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, ".."))
REPORT_DIR = os.environ.get("REPORT_DIR", os.path.join(PROJECT_ROOT, ".scratch"))
os.makedirs(REPORT_DIR, exist_ok=True)

TIMESTAMP = datetime.now().strftime("%Y%m%d_%H%M%S")
REPORT_FILE = os.environ.get("REPORT_FILE", os.path.join(REPORT_DIR, f"benchmark_{TIMESTAMP}.md"))
REPORT_LATEST = os.path.join(REPORT_DIR, "latest.md")

# -----------------------------------------------------------------------------
# Prerequisites
# -----------------------------------------------------------------------------
for cmd in ["wrk", "curl"]:
    if not shutil.which(cmd):
        print(f"Error: '{cmd}' is required but not installed.", file=sys.stderr)
        sys.exit(1)

# -----------------------------------------------------------------------------
# Hardware Specification Collection
# -----------------------------------------------------------------------------
def get_hardware_specs():
    system = platform.system()
    machine = platform.machine()

    os_name = f"{system} {platform.release()}"
    if system == "Darwin":
        try:
            pname = subprocess.check_output(["sw_vers", "-productName"], stderr=subprocess.DEVNULL).decode().strip()
            pver = subprocess.check_output(["sw_vers", "-productVersion"], stderr=subprocess.DEVNULL).decode().strip()
            os_name = f"{pname} {pver} ({machine})"
        except Exception:
            pass
    elif system == "Linux":
        if os.path.exists("/etc/os-release"):
            try:
                with open("/etc/os-release") as f:
                    for line in f:
                        if line.startswith("PRETTY_NAME="):
                            os_name = line.split("=", 1)[1].strip("\"'\n") + f" ({machine})"
                            break
            except Exception:
                pass

    cpu_model = "Unknown CPU"
    if system == "Darwin":
        try:
            cpu_model = subprocess.check_output(["sysctl", "-n", "machdep.cpu.brand_string"], stderr=subprocess.DEVNULL).decode().strip()
        except Exception:
            pass
    elif system == "Linux":
        try:
            with open("/proc/cpuinfo") as f:
                for line in f:
                    if "model name" in line:
                        cpu_model = line.split(":", 1)[1].strip()
                        break
        except Exception:
            pass
        if cpu_model == "Unknown CPU":
            try:
                lscpu = subprocess.check_output(["lscpu"], stderr=subprocess.DEVNULL).decode()
                for line in lscpu.splitlines():
                    if "Model name:" in line:
                        cpu_model = line.split(":", 1)[1].strip()
                        break
            except Exception:
                pass

    cores = os.cpu_count() or "Unknown"
    cores_desc = f"{cores} cores"
    if system == "Darwin":
        try:
            nperf = int(subprocess.check_output(["sysctl", "-n", "hw.nperflevels"], stderr=subprocess.DEVNULL).decode().strip())
            levels = []
            for i in range(nperf):
                name = subprocess.check_output(["sysctl", "-n", f"hw.perflevel{i}.name"], stderr=subprocess.DEVNULL).decode().strip()
                count = int(subprocess.check_output(["sysctl", "-n", f"hw.perflevel{i}.logicalcpu"], stderr=subprocess.DEVNULL).decode().strip())
                levels.append(f"{count} {name}")
            if len(levels) > 1:
                cores_desc = f"{cores} cores: " + " + ".join(levels)
        except Exception:
            pass

    mem_str = "Unknown"
    if system == "Darwin":
        try:
            mem_bytes = int(subprocess.check_output(["sysctl", "-n", "hw.memsize"], stderr=subprocess.DEVNULL).decode().strip())
            mem_str = f"{mem_bytes / (1024**3):.1f} GB"
        except Exception:
            pass
    elif system == "Linux":
        try:
            with open("/proc/meminfo") as f:
                for line in f:
                    if line.startswith("MemTotal:"):
                        kb = int(line.split()[1])
                        mem_str = f"{kb / (1024**2):.1f} GB"
                        break
        except Exception:
            pass

    def get_tool_version(args, idx=0):
        try:
            out = subprocess.check_output(args, stderr=subprocess.DEVNULL).decode().strip().splitlines()[0]
            parts = out.split()
            return parts[idx] if len(parts) > idx else out
        except Exception:
            return "N/A"

    zig_ver = get_tool_version(["zig", "version"], 0)
    go_ver = get_tool_version(["go", "version"], 2)
    rust_ver = get_tool_version(["rustc", "--version"], 1)

    return {
        "os": os_name,
        "cpu": cpu_model,
        "cores": str(cores),
        "cores_desc": cores_desc,
        "ram": mem_str,
        "zig": zig_ver,
        "go": go_ver,
        "rust": rust_ver,
    }

SPECS = get_hardware_specs()

# -----------------------------------------------------------------------------
# Build Targets
# -----------------------------------------------------------------------------
print("================================================================")
print("           Lighting Benchmark Suite (Zig vs Go vs Rust)         ")
print("================================================================")
print(f"OS:          {SPECS['os']}")
print(f"CPU:         {SPECS['cpu']} ({SPECS['cores_desc']})")
print(f"RAM:         {SPECS['ram']}")
print(f"Port:        {PORT}")
print(f"Threads:     {THREADS}")
print(f"Concurrency: {CONCURRENCY}")
print(f"Duration:    {DURATION} per test")
print("================================================================\n")

print("[1/3] Building Zig (Lighting - ReleaseFast in bench/zig)...")
subprocess.check_call(["zig", "build", "-Doptimize=ReleaseFast"], cwd=os.path.join(PROJECT_ROOT, "bench", "zig"))
ZIG_BIN = os.path.join(PROJECT_ROOT, "bench", "zig", "zig-out", "bin", "bench-server")

GO_BIN = None
RUST_BIN = None
if not ONLY_ZIG:
    print("[2/3] Building Go (net/http - Release in bench/go)...")
    subprocess.check_call(["go", "build", '-ldflags=-s -w', "-o", "bench-go", "main.go"], cwd=os.path.join(PROJECT_ROOT, "bench", "go"))
    GO_BIN = os.path.join(PROJECT_ROOT, "bench", "go", "bench-go")

    print("[3/3] Building Rust (actix-web - Release in bench/rust)...")
    subprocess.check_call(["cargo", "build", "--release"], cwd=os.path.join(PROJECT_ROOT, "bench", "rust"))
    RUST_BIN = os.path.join(PROJECT_ROOT, "bench", "rust", "target", "release", "lighting-bench-rust")

# Prepare static Lua script for POST /echo benchmark
ECHO_LUA = os.path.join(REPORT_DIR, "echo.lua")
with open(ECHO_LUA, "w") as f:
    f.write('wrk.method = "POST"\n')
    f.write('wrk.body   = string.rep("A", 1024)\n')
    f.write('wrk.headers["Content-Type"] = "text/plain"\n')

# -----------------------------------------------------------------------------
# Process & Resource Helpers
# -----------------------------------------------------------------------------
def is_port_in_use(port):
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        return s.connect_ex(("127.0.0.1", port)) == 0

def ensure_port_free(port, timeout=5.0):
    start = time.time()
    while is_port_in_use(port):
        time.sleep(0.1)
        if time.time() - start > timeout:
            print(f"Warning: Port {port} is still occupied after {timeout}s.", file=sys.stderr)
            break

def wait_ready(port, timeout=5.0):
    start = time.time()
    while time.time() - start < timeout:
        try:
            code = subprocess.call(
                ["curl", "-s", "-o", os.devnull, f"http://127.0.0.1:{port}/ping"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            if code == 0:
                return True
        except Exception:
            pass
        time.sleep(0.1)
    raise RuntimeError(f"Server failed to start on port {port}")

def get_rss_mb(pid):
    try:
        out = subprocess.check_output(["ps", "-o", "rss=", "-p", str(pid)], stderr=subprocess.DEVNULL).decode().strip()
        kb = float(out)
        return round(kb / 1024.0, 1)
    except Exception:
        return 0.0

def get_cpu_time(pid):
    try:
        out = subprocess.check_output(["ps", "-o", "time=", "-p", str(pid)], stderr=subprocess.DEVNULL).decode().strip()
        parts = out.split(":")
        if len(parts) == 2:
            return float(parts[0]) * 60.0 + float(parts[1])
        elif len(parts) == 3:
            return float(parts[0]) * 3600.0 + float(parts[1]) * 60.0 + float(parts[2])
    except Exception:
        pass
    return 0.0

def run_wrk(url, duration, lua_script=None):
    cmd = ["wrk", f"-t{THREADS}", f"-c{CONCURRENCY}", f"-d{duration}", "--latency", "-H", "Connection: keep-alive"]
    if lua_script:
        cmd.extend(["-s", lua_script])
    cmd.append(url)

    out = subprocess.check_output(cmd, stderr=subprocess.STDOUT).decode("utf-8", errors="replace")

    qps = "0"
    p50 = "0us"
    p99 = "0us"

    for line in out.splitlines():
        if "Requests/sec:" in line:
            parts = line.split()
            if len(parts) >= 2:
                qps = parts[1]
        elif re.search(r"^\s*50%\s+", line):
            parts = line.split()
            if len(parts) >= 2:
                p50 = parts[1]
        elif re.search(r"^\s*99%\s+", line):
            parts = line.split()
            if len(parts) >= 2:
                p99 = parts[1]

    return {"qps": qps, "p50": p50, "p99": p99}

# -----------------------------------------------------------------------------
# Benchmark Runner
# -----------------------------------------------------------------------------
results = {}

def bench_target(name, bin_path, env_extra=None):
    ensure_port_free(PORT)
    env = os.environ.copy()
    env["PORT"] = str(PORT)
    if env_extra:
        env.update(env_extra)

    desc = f" ({env_extra})" if env_extra else ""
    print(f">>> Testing {name}{desc}...")

    proc = subprocess.Popen([bin_path], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        wait_ready(PORT)

        # Measure idle metrics over 1s
        t_idle_start = time.time()
        c_idle_start = get_cpu_time(proc.pid)
        time.sleep(1.0)
        t_idle_end = time.time()
        c_idle_end = get_cpu_time(proc.pid)

        dt_idle = t_idle_end - t_idle_start
        dc_idle = c_idle_end - c_idle_start
        idle_cpu = f"{(dc_idle / dt_idle) * 100:.1f}%" if dt_idle > 0 else "0.0%"
        idle_rss = get_rss_mb(proc.pid)

        # Warmup
        subprocess.call(
            ["wrk", f"-t{THREADS}", f"-c{CONCURRENCY}", f"-d{WARMUP_DURATION}", "-H", "Connection: keep-alive", f"http://127.0.0.1:{PORT}/ping"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

        # Active load tracking
        t_load_start = time.time()
        c_load_start = get_cpu_time(proc.pid)

        # Case 1: GET /ping
        print("  [1/4] Running Case 1: GET /ping...")
        res_ping = run_wrk(f"http://127.0.0.1:{PORT}/ping", DURATION)

        # Case 2: GET /users/42
        print("  [2/4] Running Case 2: GET /users/42 (Dynamic Route & JSON)...")
        res_user = run_wrk(f"http://127.0.0.1:{PORT}/users/42", DURATION)

        # Case 3: POST /echo
        print("  [3/4] Running Case 3: POST /echo (1KB Body Read)...")
        res_echo = run_wrk(f"http://127.0.0.1:{PORT}/echo", DURATION, lua_script=ECHO_LUA)

        # Case 4: GET /files/static/css/theme/dark.min.css
        print("  [4/4] Running Case 4: GET /files/... (Wildcard Catch-all)...")
        res_files = run_wrk(f"http://127.0.0.1:{PORT}/files/static/css/theme/dark.min.css", DURATION)

        t_load_end = time.time()
        c_load_end = get_cpu_time(proc.pid)
        dt_load = t_load_end - t_load_start
        dc_load = c_load_end - c_load_start
        load_cpu = f"{(dc_load / dt_load) * 100:.1f}%" if dt_load > 0 else "0.0%"
        peak_rss = get_rss_mb(proc.pid)

        results[name] = {
            "ping": res_ping,
            "user": res_user,
            "echo": res_echo,
            "files": res_files,
            "cpu": f"{idle_cpu} / {load_cpu}",
            "rss": f"{idle_rss} MB / {peak_rss} MB",
        }
        print(f"  Completed {name}.\n")

    finally:
        proc.kill()
        proc.wait()
        ensure_port_free(PORT)

# Execute all benchmark targets
targets = []

bench_target("Zig_Lighting_zio", ZIG_BIN, {"IO": "zio"})
targets.append("Zig_Lighting_zio")

bench_target("Zig_Lighting_std", ZIG_BIN, {"IO": "std"})
targets.append("Zig_Lighting_std")

if not ONLY_ZIG:
    bench_target("Go_net_http", GO_BIN)
    targets.append("Go_net_http")

    bench_target("Rust_actix_web", RUST_BIN)
    targets.append("Rust_actix_web")

# -----------------------------------------------------------------------------
# Markdown Report Generation
# -----------------------------------------------------------------------------
table_header = "| Framework / Language | GET /ping (QPS / P50 / P99) | GET /users/{id} (QPS / P50 / P99) | POST /echo (QPS / P50 / P99) | GET /files/* (QPS / P50 / P99) | CPU (Idle / Load Avg) | Memory (Idle / Peak RSS) |"
table_sep = "| :--- | :--- | :--- | :--- | :--- | :--- | :--- |"
table_rows = []

for t in targets:
    d = results[t]
    p = d["ping"]
    u = d["user"]
    e = d["echo"]
    f = d["files"]
    row = f"| **{t}** | {p['qps']} req/s ({p['p50']} / {p['p99']}) | {u['qps']} req/s ({u['p50']} / {u['p99']}) | {e['qps']} req/s ({e['p50']} / {e['p99']}) | {f['qps']} req/s ({f['p50']} / {f['p99']}) | {d['cpu']} | {d['rss']} |"
    table_rows.append(row)

markdown_content = f"""# Lighting Benchmark Report

**Date**: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}

## Machine Specifications

| Item | Specification |
| :--- | :--- |
| **OS** | {SPECS['os']} |
| **CPU** | {SPECS['cpu']} ({SPECS['cores_desc']}) |
| **RAM** | {SPECS['ram']} |
| **Zig** | {SPECS['zig']} |
| **Go** | {SPECS['go']} |
| **Rust** | {SPECS['rust']} |

## Benchmark Parameters

| Parameter | Value |
| :--- | :--- |
| **Port** | {PORT} |
| **Threads** | {THREADS} |
| **Concurrency** | {CONCURRENCY} |
| **Duration** | {DURATION} per test |
| **Warmup** | {WARMUP_DURATION} |

## Benchmark Results

{table_header}
{table_sep}
""" + "\n".join(table_rows) + "\n"

with open(REPORT_FILE, "w") as f:
    f.write(markdown_content)

shutil.copyfile(REPORT_FILE, REPORT_LATEST)

print("================================================================================")
print("                             Benchmark Results                                  ")
print("================================================================================")
print("")
print(table_header)
print(table_sep)
for row in table_rows:
    print(row)
print("")
print("Benchmark report saved to:")
print(f"  - {REPORT_FILE}")
print(f"  - {REPORT_LATEST}")
print("")
