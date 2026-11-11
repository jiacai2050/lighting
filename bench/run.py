#!/usr/bin/env python3
import os
import sys
import time
import socket
import shutil
import subprocess
import platform
import re
import glob
import json
import threading
from collections import defaultdict
from datetime import datetime

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
GITHUB_REPO_URL = "https://github.com/jiacai2050/lighting"

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
REPORT_HTML = os.path.splitext(REPORT_FILE)[0] + ".html"
REPORT_LATEST_HTML = os.path.join(REPORT_DIR, "latest.html")

# -----------------------------------------------------------------------------
# Prerequisites & CPU Isolation
# -----------------------------------------------------------------------------
for cmd in ["wrk", "curl"]:
    if not shutil.which(cmd):
        print(f"Error: '{cmd}' is required but not installed.", file=sys.stderr)
        sys.exit(1)

def parse_cpulist(s):
    cpus = set()
    for part in s.strip().split(','):
        if not part:
            continue
        if '-' in part:
            lo, hi = map(int, part.split('-'))
            cpus.update(range(lo, hi + 1))
        else:
            cpus.add(int(part))
    return cpus

FREQ_MAP = {}
CORE_CPUS = set()
ATOM_CPUS = set()

if platform.system() == "Linux":
    for p in glob.glob('/sys/devices/system/cpu/cpu[0-9]*/cpufreq/cpuinfo_max_freq'):
        m = re.search(r'cpu(\d+)', p)
        if m:
            try:
                with open(p) as f:
                    FREQ_MAP[int(m.group(1))] = int(f.read().strip())
            except Exception:
                pass
    if os.path.exists('/sys/devices/cpu_core/cpus'):
        try:
            with open('/sys/devices/cpu_core/cpus') as f:
                CORE_CPUS = parse_cpulist(f.read())
        except Exception:
            pass
    if os.path.exists('/sys/devices/cpu_atom/cpus'):
        try:
            with open('/sys/devices/cpu_atom/cpus') as f:
                ATOM_CPUS = parse_cpulist(f.read())
        except Exception:
            pass

def describe_cores(cores_str):
    if not cores_str:
        return "None"
    cpus = parse_cpulist(cores_str)
    if not cpus:
        return f"`{cores_str}`"
    freqs = [FREQ_MAP.get(c) for c in cpus if c in FREQ_MAP]
    max_freq = f"{max(freqs)/1e6:.1f} GHz" if freqs else None

    core_type = ""
    if CORE_CPUS and cpus.issubset(CORE_CPUS):
        core_type = "Performance P-core"
    elif ATOM_CPUS and cpus.issubset(ATOM_CPUS):
        if freqs and max(freqs) < 3.0e6:
            core_type = "Low Power LP E-core"
        else:
            core_type = "Efficiency E-core"

    desc_parts = []
    if core_type:
        desc_parts.append(core_type)
    if max_freq:
        desc_parts.append(f"up to {max_freq}")

    if desc_parts:
        return f"`{cores_str}` ({', '.join(desc_parts)})"
    return f"`{cores_str}`"

def get_cpu_affinity():
    if os.environ.get("PIN_CORES", "1") == "0":
        return None, None
    if platform.system() != "Linux" or not shutil.which("taskset"):
        return None, None

    server_cores = os.environ.get("SERVER_CORES")
    client_cores = os.environ.get("CLIENT_CORES")
    if server_cores and client_cores:
        return server_cores, client_cores

    if CORE_CPUS and ATOM_CPUS:
        s_cores = server_cores or f"{min(CORE_CPUS)}-{max(CORE_CPUS)}"
        sorted_atoms = sorted(list(ATOM_CPUS))
        c_cores = client_cores or (f"{sorted_atoms[0]}-{sorted_atoms[min(3, len(sorted_atoms)-1)]}")
        return s_cores, c_cores

    cpu_count = os.cpu_count() or 1
    if cpu_count >= 8:
        s_cores = server_cores or "0-7"
        c_cores = client_cores or f"8-{min(11, cpu_count - 1)}"
        return s_cores, c_cores

    return server_cores, client_cores

SERVER_CORES, CLIENT_CORES = get_cpu_affinity()
if SERVER_CORES or CLIENT_CORES:
    print(f"[*] CPU Core Pinning Active: Server -> taskset -c {describe_cores(SERVER_CORES)}, wrk -> taskset -c {describe_cores(CLIENT_CORES)}")


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
    elif system == "Linux":
        try:
            levels = []
            if CORE_CPUS and ATOM_CPUS:
                atom_freqs = defaultdict(int)
                for c in ATOM_CPUS:
                    atom_freqs[FREQ_MAP.get(c, 0)] += 1
                levels.append(f"{len(CORE_CPUS)} Performance")
                if len(atom_freqs) > 1:
                    sorted_atom = sorted(atom_freqs.items(), key=lambda x: x[0], reverse=True)
                    levels.append(f"{sorted_atom[0][1]} Efficiency")
                    for _, count in sorted_atom[1:]:
                        levels.append(f"{count} Low Power Efficiency")
                else:
                    levels.append(f"{len(ATOM_CPUS)} Efficiency")

            if not levels and FREQ_MAP:
                freq_groups = defaultdict(int)
                for _, freq in FREQ_MAP.items():
                    freq_groups[freq] += 1
                if len(freq_groups) > 1:
                    sorted_freqs = sorted(freq_groups.items(), key=lambda x: x[0], reverse=True)
                    levels.append(f"{sorted_freqs[0][1]} Performance")
                    levels.append(f"{sorted_freqs[1][1]} Efficiency")
                    for _, count in sorted_freqs[2:]:
                        levels.append(f"{count} Low Power Efficiency")

            if not levels:
                cap_map = {}
                for p in glob.glob('/sys/devices/system/cpu/cpu[0-9]*/cpu_capacity'):
                    m = re.search(r'cpu(\d+)', p)
                    if m:
                        try:
                            with open(p) as f:
                                cap_map[int(m.group(1))] = int(f.read().strip())
                        except Exception:
                            pass
                if cap_map:
                    cap_groups = defaultdict(int)
                    for _, cap in cap_map.items():
                        cap_groups[cap] += 1
                    if len(cap_groups) > 1:
                        sorted_caps = sorted(cap_groups.items(), key=lambda x: x[0], reverse=True)
                        levels.append(f"{sorted_caps[0][1]} Performance")
                        for _, count in sorted_caps[1:]:
                            levels.append(f"{count} Efficiency")

            if not levels:
                try:
                    out = subprocess.check_output(['lscpu', '-e=CPU,MAXMHZ'], stderr=subprocess.DEVNULL).decode()
                    lscpu_freqs = defaultdict(int)
                    for line in out.strip().splitlines()[1:]:
                        parts = line.split()
                        if len(parts) >= 2:
                            try:
                                lscpu_freqs[float(parts[1])] += 1
                            except ValueError:
                                pass
                    if len(lscpu_freqs) > 1:
                        sorted_lf = sorted(lscpu_freqs.items(), key=lambda x: x[0], reverse=True)
                        levels.append(f"{sorted_lf[0][1]} Performance")
                        levels.append(f"{sorted_lf[1][1]} Efficiency")
                        for _, count in sorted_lf[2:]:
                            levels.append(f"{count} Low Power Efficiency")
                except Exception:
                    pass

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

    def get_git_info():
        try:
            full_commit = subprocess.check_output(
                ["git", "rev-parse", "HEAD"],
                cwd=PROJECT_ROOT,
                stderr=subprocess.DEVNULL,
            ).decode().strip()
            short_commit = full_commit[:7]
            status = subprocess.check_output(
                ["git", "status", "--porcelain"],
                cwd=PROJECT_ROOT,
                stderr=subprocess.DEVNULL,
            ).decode().strip()
            is_dirty = bool(status)

            commit_url = f"{GITHUB_REPO_URL}/commit/{full_commit}"
            return {
                "full": full_commit,
                "short": short_commit,
                "dirty": is_dirty,
                "url": commit_url,
                "display": f"{short_commit} (dirty)" if is_dirty else short_commit,
            }
        except Exception:
            return {
                "full": "",
                "short": "Unknown",
                "dirty": False,
                "url": "",
                "display": "Unknown",
            }

    zig_ver = get_tool_version(["zig", "version"], 0)
    go_ver = get_tool_version(["go", "version"], 2)
    rust_ver = get_tool_version(["rustc", "--version"], 1)

    kernel_ver = platform.release()
    if system == "Darwin":
        kernel_ver = f"Darwin {platform.release()}"
    elif system == "Windows":
        kernel_ver = f"Windows NT {platform.version()}"

    git_info = get_git_info()
    return {
        "os": os_name,
        "kernel": kernel_ver,
        "commit": git_info["display"],
        "git": git_info,
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
if SPECS.get("kernel"):
    print(f"Kernel:      {SPECS['kernel']}")
print(f"Commit:      {SPECS['commit']}")
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
    if CLIENT_CORES:
        cmd = ["taskset", "-c", CLIENT_CORES] + cmd

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

class ResourceSampler:
    def __init__(self, pid, interval=0.1):
        self.pid = pid
        self.interval = interval
        self.stop_event = threading.Event()
        self.peak_rss = 0.0
        self.thread = threading.Thread(target=self._monitor, daemon=True)

    def _monitor(self):
        while not self.stop_event.is_set():
            rss = get_rss_mb(self.pid)
            if rss > self.peak_rss:
                self.peak_rss = rss
            self.stop_event.wait(self.interval)

    def start(self):
        self.peak_rss = get_rss_mb(self.pid)
        self.thread.start()

    def stop(self):
        self.stop_event.set()
        self.thread.join()
        rss = get_rss_mb(self.pid)
        if rss > self.peak_rss:
            self.peak_rss = rss
        return self.peak_rss

def run_benchmark_case(proc_pid, url, duration, lua_script=None):
    sampler = ResourceSampler(proc_pid)
    sampler.start()
    t_start = time.time()
    c_start = get_cpu_time(proc_pid)

    res = run_wrk(url, duration, lua_script=lua_script)

    c_end = get_cpu_time(proc_pid)
    t_end = time.time()
    peak_rss = sampler.stop()

    dt = t_end - t_start
    dc = c_end - c_start
    cpu_pct = round((dc / dt) * 100.0, 1) if dt > 0 else 0.0

    res["cpu"] = f"{cpu_pct:.1f}%"
    res["cpu_num"] = cpu_pct
    res["rss"] = f"{peak_rss:.1f} MB"
    res["rss_num"] = peak_rss
    return res

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
    pin_info = f" [taskset -c {SERVER_CORES}]" if SERVER_CORES else ""
    print(f">>> Testing {name}{desc}{pin_info}...")

    server_cmd = [bin_path]
    if SERVER_CORES:
        server_cmd = ["taskset", "-c", SERVER_CORES] + server_cmd
    proc = subprocess.Popen(server_cmd, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        wait_ready(PORT)

        # Warmup
        warmup_cmd = ["wrk", f"-t{THREADS}", f"-c{CONCURRENCY}", f"-d{WARMUP_DURATION}", "-H", "Connection: keep-alive", f"http://127.0.0.1:{PORT}/ping"]
        if CLIENT_CORES:
            warmup_cmd = ["taskset", "-c", CLIENT_CORES] + warmup_cmd
        subprocess.call(
            warmup_cmd,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

        # Case 1: GET /ping
        print("  [1/4] Running Case 1: GET /ping...")
        res_ping = run_benchmark_case(proc.pid, f"http://127.0.0.1:{PORT}/ping", DURATION)

        # Case 2: GET /users/42
        print("  [2/4] Running Case 2: GET /users/42 (Dynamic Route & JSON)...")
        res_user = run_benchmark_case(proc.pid, f"http://127.0.0.1:{PORT}/users/42", DURATION)

        # Case 3: POST /echo
        print("  [3/4] Running Case 3: POST /echo (1KB Body Read)...")
        res_echo = run_benchmark_case(proc.pid, f"http://127.0.0.1:{PORT}/echo", DURATION, lua_script=ECHO_LUA)

        # Case 4: GET /files/static/css/theme/dark.min.css
        print("  [4/4] Running Case 4: GET /files/... (Wildcard Catch-all)...")
        res_files = run_benchmark_case(proc.pid, f"http://127.0.0.1:{PORT}/files/static/css/theme/dark.min.css", DURATION)

        results[name] = {
            "ping": res_ping,
            "user": res_user,
            "echo": res_echo,
            "files": res_files,
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
table_header = "| Framework / Language | GET /ping | GET /users/{id} | POST /echo | GET /files/* |"
table_sep = "| :--- | :--- | :--- | :--- | :--- |"
table_rows = []

def format_md_cell(r):
    return f"{r['qps']} req/s (P50: {r['p50']}, P99: {r['p99']}, CPU: {r['cpu']}, RSS: {r['rss']})"

for t in targets:
    d = results[t]
    p_str = format_md_cell(d["ping"])
    u_str = format_md_cell(d["user"])
    e_str = format_md_cell(d["echo"])
    f_str = format_md_cell(d["files"])
    row = f"| **{t}** | {p_str} | {u_str} | {e_str} | {f_str} |"
    table_rows.append(row)

pinning_note = ""
if SERVER_CORES or CLIENT_CORES:
    server_desc = describe_cores(SERVER_CORES)
    client_desc = describe_cores(CLIENT_CORES)
    pinning_note = f"""
> [!NOTE]
> **CPU Core Pinning & Topology Allocation Active**:
> - **Server**: Bound to {server_desc} via `taskset -c {SERVER_CORES or 'None'}`
> - **Client (wrk)**: Bound to {client_desc} via `taskset -c {CLIENT_CORES or 'None'}`
> Separates server processing onto maximum-frequency cores while isolating client load generation onto independent cores to eliminate scheduling jitter and prevent cross-die latency penalties.
"""

cpu_pinning_desc = (
    f"Server: {describe_cores(SERVER_CORES)} / Client: {describe_cores(CLIENT_CORES)}"
    if (SERVER_CORES or CLIENT_CORES)
    else "None (OS managed / unpinned)"
)

kernel_row = f"| **Kernel** | {SPECS['kernel']} |\n" if SPECS.get("kernel") else ""

git_spec = SPECS.get("git", {})
if git_spec.get("url"):
    dirty_label = " (dirty)" if git_spec.get("dirty") else ""
    commit_md = f"[{git_spec.get('short')}]({git_spec.get('url')}){dirty_label}"
else:
    commit_md = SPECS["commit"]

markdown_content = f"""# Lighting Benchmark Report

**Date**: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}

## Machine Specifications

| Item | Specification |
| :--- | :--- |
| **OS** | {SPECS['os']} |
{kernel_row}| **Commit** | {commit_md} |
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
| **CPU Pinning** | {cpu_pinning_desc} |
{pinning_note}
## Benchmark Results

{table_header}
{table_sep}
""" + "\n".join(table_rows) + "\n"

with open(REPORT_FILE, "w") as f:
    f.write(markdown_content)

shutil.copyfile(REPORT_FILE, REPORT_LATEST)

# -----------------------------------------------------------------------------
# HTML Report Generation (with Interactive Charts)
# -----------------------------------------------------------------------------
def generate_html_report(results_map, target_list, specs, date_str):
    def parse_float(val, default=0.0):
        try:
            cleaned = re.sub(r"[^\d.]", "", str(val))
            return float(cleaned) if cleaned else default
        except Exception:
            return default

    def parse_latency_us(val):
        if not val:
            return 0.0
        val_str = str(val).strip().lower()
        m = re.match(r"^([\d.]+)\s*(us|µs|ms|s)?", val_str)
        if not m:
            return 0.0
        num = float(m.group(1))
        unit = m.group(2) or "us"
        if unit in ("us", "µs"):
            return round(num, 1)
        elif unit == "ms":
            return round(num * 1000.0, 1)
        elif unit == "s":
            return round(num * 1000000.0, 1)
        return round(num, 1)

    def parse_peak_rss(val):
        try:
            parts = str(val).split("/")
            target_part = parts[1] if len(parts) > 1 else parts[0]
            cleaned = re.sub(r"[^\d.]", "", target_part)
            return float(cleaned) if cleaned else 0.0
        except Exception:
            return 0.0

    color_palette = {
        "Zig_Lighting_zio": "#f59e0b",
        "Zig_Lighting_std": "#fbbf24",
        "Rust_actix_web": "#ef4444",
        "Go_net_http": "#06b6d4",
    }
    fallback_colors = ["#f59e0b", "#ef4444", "#06b6d4", "#10b981", "#8b5cf6", "#ec4899"]

    target_colors = [
        color_palette.get(t, fallback_colors[i % len(fallback_colors)])
        for i, t in enumerate(target_list)
    ]

    def parse_load_cpu(val):
        try:
            parts = str(val).split("/")
            load_part = parts[1] if len(parts) > 1 else parts[0]
            cleaned = re.sub(r"[^\d.]", "", load_part)
            return float(cleaned) if cleaned else 0.0
        except Exception:
            return 0.0

    # Datasets for Chart.js
    route_labels = ["GET /ping", "GET /users/{id}", "POST /echo", "GET /files/*"]
    route_keys = ["ping", "user", "echo", "files"]

    throughput_datasets = []
    p50_datasets = []
    p99_datasets = []
    cpu_datasets = []
    memory_datasets = []

    for i, t in enumerate(target_list):
        d = results_map[t]
        qps_data = [parse_float(d[rk]["qps"]) for rk in route_keys]
        p50_data = [parse_latency_us(d[rk]["p50"]) for rk in route_keys]
        p99_data = [parse_latency_us(d[rk]["p99"]) for rk in route_keys]
        cpu_data = [d[rk].get("cpu_num", parse_float(d[rk].get("cpu", 0.0))) for rk in route_keys]
        mem_data = [d[rk].get("rss_num", parse_float(d[rk].get("rss", 0.0))) for rk in route_keys]

        throughput_datasets.append({
            "label": t,
            "data": qps_data,
            "backgroundColor": target_colors[i],
            "borderRadius": 6,
        })
        p50_datasets.append({
            "label": t,
            "data": p50_data,
            "backgroundColor": target_colors[i],
            "borderRadius": 6,
        })
        p99_datasets.append({
            "label": t,
            "data": p99_data,
            "backgroundColor": target_colors[i],
            "borderRadius": 6,
        })
        cpu_datasets.append({
            "label": t,
            "data": cpu_data,
            "backgroundColor": target_colors[i],
            "borderRadius": 6,
        })
        memory_datasets.append({
            "label": t,
            "data": mem_data,
            "backgroundColor": target_colors[i],
            "borderRadius": 6,
        })

    def format_html_cell(r):
        return (
            f'<div class="cell-main">{r["qps"]} req/s</div>'
            f'<div class="cell-sub">P50: {r["p50"]} · P99: {r["p99"]}</div>'
            f'<div class="cell-sub">CPU: {r["cpu"]} · RSS: {r["rss"]}</div>'
        )

    # Table rows
    table_rows_html = []
    for t in target_list:
        d = results_map[t]
        badge_cls = "badge-zig" if "Zig" in t else ("badge-rust" if "Rust" in t else "badge-go")
        badge_name = "Zig" if "Zig" in t else ("Rust" if "Rust" in t else "Go")
        row_html = f"""                    <tr>
                        <td><span class="badge {badge_cls}">{badge_name}</span><br><strong>{t}</strong></td>
                        <td>{format_html_cell(d['ping'])}</td>
                        <td>{format_html_cell(d['user'])}</td>
                        <td>{format_html_cell(d['echo'])}</td>
                        <td>{format_html_cell(d['files'])}</td>
                    </tr>"""
        table_rows_html.append(row_html)
    table_body = "\n".join(table_rows_html)

    kernel_meta = f"<span><strong>Kernel:</strong> {specs['kernel']}</span>" if specs.get("kernel") else ""

    git_info = specs.get("git", {})
    if git_info.get("url"):
        dirty_badge = ' <span style="color: var(--accent-zig); font-size: 0.85em;">(dirty)</span>' if git_info.get("dirty") else ""
        commit_html = f'<a href="{git_info["url"]}" target="_blank" rel="noopener noreferrer" style="color: var(--highlight); text-decoration: none;"><code>{git_info["short"]}</code></a>{dirty_badge}'
    else:
        commit_html = f'<code>{specs["commit"]}</code>'

    template_path = os.path.join(SCRIPT_DIR, "template.html")
    if not os.path.exists(template_path):
        print(f"Warning: HTML template not found at {template_path}, skipping HTML report.", file=sys.stderr)
        return ""

    with open(template_path, "r", encoding="utf-8") as f:
        html = f.read()

    context = {
        "DATE_STR": date_str,
        "OS": specs["os"],
        "KERNEL_META": kernel_meta,
        "COMMIT": commit_html,
        "CPU": specs["cpu"],
        "CORES_DESC": specs["cores_desc"],
        "CONCURRENCY": str(CONCURRENCY),
        "THREADS": str(THREADS),
        "DURATION": str(DURATION),
        "TABLE_BODY": table_body,
        "ROUTE_LABELS_JSON": json.dumps(route_labels),
        "TARGET_LIST_JSON": json.dumps(target_list),
        "TARGET_COLORS_JSON": json.dumps(target_colors),
        "THROUGHPUT_DATASETS_JSON": json.dumps(throughput_datasets),
        "P50_DATASETS_JSON": json.dumps(p50_datasets),
        "P99_DATASETS_JSON": json.dumps(p99_datasets),
        "CPU_DATASETS_JSON": json.dumps(cpu_datasets),
        "MEMORY_DATASETS_JSON": json.dumps(memory_datasets),
    }

    for key, val in context.items():
        html = html.replace(f"{{{{{key}}}}}", str(val))

    return html

html_content = generate_html_report(
    results,
    targets,
    SPECS,
    datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
)

if html_content:
    with open(REPORT_HTML, "w", encoding="utf-8") as f:
        f.write(html_content)
    shutil.copyfile(REPORT_HTML, REPORT_LATEST_HTML)

print("================================================================================")
print("                             Benchmark Results                                  ")
print("================================================================================")
if SERVER_CORES or CLIENT_CORES:
    print(f"[*] CPU Core Pinning: Server -> taskset -c {describe_cores(SERVER_CORES)}, wrk -> taskset -c {describe_cores(CLIENT_CORES)}")
print("")
print(table_header)
print(table_sep)
for row in table_rows:
    print(row)
print("")
print("Benchmark report saved to:")
print(f"  - Markdown: {REPORT_FILE}")
print(f"  - Markdown (latest): {REPORT_LATEST}")
print(f"  - HTML:     {REPORT_HTML}")
print(f"  - HTML (latest):     {REPORT_LATEST_HTML}")
print("")
