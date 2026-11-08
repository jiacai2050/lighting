#!/usr/bin/env python3
"""
CPU Topology and Heterogeneous Cluster Inspector.
Detects Performance (P-core), Efficiency (E-core), and Low-Power (LP E-core)
clusters, cache hierarchy, frequencies, and provides optimal taskset core-pinning
recommendations for benchmarking.
"""

import os
import sys
import glob
import re
import platform
import subprocess
from collections import defaultdict

def read_file(path):
    try:
        with open(path, "r") as f:
            return f.read().strip()
    except Exception:
        return ""

def parse_cpulist(s):
    cpus = set()
    for part in s.strip().split(","):
        if not part:
            continue
        if "-" in part:
            lo, hi = map(int, part.split("-"))
            cpus.update(range(lo, hi + 1))
        else:
            cpus.add(int(part))
    return cpus

def format_cpulist(cpus):
    if not cpus:
        return "None"
    sorted_cpus = sorted(list(cpus))
    ranges = []
    start = prev = sorted_cpus[0]
    for c in sorted_cpus[1:]:
        if c == prev + 1:
            prev = c
        else:
            ranges.append(f"{start}-{prev}" if start != prev else f"{start}")
            start = prev = c
    ranges.append(f"{start}-{prev}" if start != prev else f"{start}")
    return ",".join(ranges)

class CpuInspector:
    def __init__(self):
        self.system = platform.system()
        self.machine = platform.machine()
        self.cpu_name = "Unknown CPU"
        self.clusters = []
        self.cpus_info = {}

    def inspect(self):
        if self.system == "Linux":
            self._inspect_linux()
        elif self.system == "Darwin":
            self._inspect_darwin()

    def _inspect_linux(self):
        # 1. CPU Model Name
        try:
            with open("/proc/cpuinfo") as f:
                for line in f:
                    if "model name" in line:
                        self.cpu_name = line.split(":", 1)[1].strip()
                        break
        except Exception:
            pass

        # 2. Gather per-CPU metrics
        cpu_dirs = sorted(glob.glob("/sys/devices/system/cpu/cpu[0-9]*"), key=lambda x: int(re.search(r"\d+", x).group()))
        freq_map = {}
        core_id_map = {}
        l2_map = {}
        l3_map = {}

        for cd in cpu_dirs:
            cid = int(re.search(r"\d+", cd).group())
            max_freq_str = read_file(f"{cd}/cpufreq/cpuinfo_max_freq")
            max_freq = int(max_freq_str) / 1e6 if max_freq_str else 0.0
            freq_map[cid] = max_freq
            core_id_map[cid] = read_file(f"{cd}/topology/core_id")

            l2_info = "None"
            l3_info = "None"
            for cache_dir in glob.glob(f"{cd}/cache/index*"):
                lvl = read_file(f"{cache_dir}/level")
                size = read_file(f"{cache_dir}/size")
                shared = read_file(f"{cache_dir}/shared_cpu_list")
                if lvl == "2":
                    l2_info = f"{size} (shared: {shared})"
                elif lvl == "3":
                    l3_info = f"{size} (shared: {shared})"
            l2_map[cid] = l2_info
            l3_map[cid] = l3_info

            self.cpus_info[cid] = {
                "max_freq": max_freq,
                "core_id": core_id_map[cid],
                "l2": l2_info,
                "l3": l3_info,
            }

        # 3. Detect Topology Clusters (core vs atom)
        core_path = "/sys/devices/cpu_core/cpus"
        atom_path = "/sys/devices/cpu_atom/cpus"
        core_cpus = parse_cpulist(read_file(core_path)) if os.path.exists(core_path) else set()
        atom_cpus = parse_cpulist(read_file(atom_path)) if os.path.exists(atom_path) else set()

        if core_cpus and atom_cpus:
            # Check for LP E-cores within atom_cpus (e.g. Meteor Lake frequency split or lack of L3)
            p_cpus = core_cpus
            e_clusters = defaultdict(set)
            for c in atom_cpus:
                freq = freq_map.get(c, 0.0)
                l3 = l3_map.get(c, "None")
                e_clusters[(freq, l3 != "None")].add(c)

            # Performance cluster
            p_freq = max([freq_map.get(c, 0.0) for c in p_cpus]) if p_cpus else 0.0
            self.clusters.append({
                "type": "Performance (P-core)",
                "cpus": p_cpus,
                "max_freq": p_freq,
                "l3_shared": True,
                "desc": "High frequency, large L2/core, shared L3 cache",
            })

            # Check E-core vs LP E-core
            sorted_e = sorted(e_clusters.items(), key=lambda x: (x[0][0], x[0][1]), reverse=True)
            if len(sorted_e) > 1:
                # Main E-cores
                self.clusters.append({
                    "type": "Efficiency (E-core)",
                    "cpus": sorted_e[0][1],
                    "max_freq": sorted_e[0][0][0],
                    "l3_shared": sorted_e[0][0][1],
                    "desc": "Mid frequency, 4-core cluster shared L2, shared L3 cache",
                })
                # LP E-cores
                for (freq, has_l3), cpus in sorted_e[1:]:
                    self.clusters.append({
                        "type": "Low Power (LP E-core)",
                        "cpus": cpus,
                        "max_freq": freq,
                        "l3_shared": has_l3,
                        "desc": "Low frequency, SOC die, isolated L2, NO L3 cache",
                    })
            else:
                for (freq, has_l3), cpus in sorted_e:
                    self.clusters.append({
                        "type": "Efficiency (E-core)",
                        "cpus": cpus,
                        "max_freq": freq,
                        "l3_shared": has_l3,
                        "desc": "Efficiency cluster",
                    })
        else:
            # Fallback by frequency groups
            freq_groups = defaultdict(set)
            for cid, f in freq_map.items():
                freq_groups[f].add(cid)
            sorted_freqs = sorted(freq_groups.items(), key=lambda x: x[0], reverse=True)
            if len(sorted_freqs) > 1:
                self.clusters.append({
                    "type": "Performance (High Freq)",
                    "cpus": sorted_freqs[0][1],
                    "max_freq": sorted_freqs[0][0],
                    "l3_shared": True,
                    "desc": "Highest frequency cores",
                })
                self.clusters.append({
                    "type": "Efficiency (Mid Freq)",
                    "cpus": sorted_freqs[1][1],
                    "max_freq": sorted_freqs[1][0],
                    "l3_shared": True,
                    "desc": "Mid frequency cores",
                })
                for freq, cpus in sorted_freqs[2:]:
                    self.clusters.append({
                        "type": "Low Power (Low Freq)",
                        "cpus": cpus,
                        "max_freq": freq,
                        "l3_shared": False,
                        "desc": "Lowest frequency cores",
                    })
            else:
                all_cpus = set(freq_map.keys())
                self.clusters.append({
                    "type": "Homogeneous Cluster",
                    "cpus": all_cpus,
                    "max_freq": sorted_freqs[0][0] if sorted_freqs else 0.0,
                    "l3_shared": True,
                    "desc": "Uniform architecture across all cores",
                })

    def _inspect_darwin(self):
        try:
            self.cpu_name = subprocess.check_output(["sysctl", "-n", "machdep.cpu.brand_string"], stderr=subprocess.DEVNULL).decode().strip()
            nperf = int(subprocess.check_output(["sysctl", "-n", "hw.nperflevels"], stderr=subprocess.DEVNULL).decode().strip())
            for i in range(nperf):
                name = subprocess.check_output(["sysctl", "-n", f"hw.perflevel{i}.name"], stderr=subprocess.DEVNULL).decode().strip()
                count = int(subprocess.check_output(["sysctl", "-n", f"hw.perflevel{i}.logicalcpu"], stderr=subprocess.DEVNULL).decode().strip())
                self.clusters.append({
                    "type": f"{name} Cores",
                    "cpus": f"{count} cores",
                    "max_freq": 0.0,
                    "l3_shared": True,
                    "desc": f"Apple Silicon {name} level",
                })
        except Exception:
            pass

    def display(self):
        is_tty = sys.stdout.isatty()
        BOLD = "\033[1m" if is_tty else ""
        CYAN = "\033[36m" if is_tty else ""
        GREEN = "\033[32m" if is_tty else ""
        YELLOW = "\033[33m" if is_tty else ""
        RED = "\033[31m" if is_tty else ""
        RESET = "\033[0m" if is_tty else ""

        print("=" * 80)
        print(f" {BOLD}CPU Topology & Heterogeneous Core Inspector{RESET}")
        print("=" * 80)
        print(f"  {BOLD}Processor{RESET}     : {CYAN}{self.cpu_name}{RESET}")
        total_cpus = len(self.cpus_info) if self.cpus_info else "N/A"
        print(f"  {BOLD}Logical Cores{RESET} : {total_cpus}")
        print(f"  {BOLD}Architecture{RESET}  : {self.machine} ({self.system})")
        print("-" * 80)

        print(f"\n{BOLD}Core Clusters Detected:{RESET}\n")
        print(f"  {'Cluster Type':<26} | {'CPUs':<10} | {'Max Clock':<11} | {'L3 Cache':<9} | {'Characteristics'}")
        print("  " + "-" * 76)

        for cl in self.clusters:
            cpus_str = format_cpulist(cl["cpus"]) if isinstance(cl["cpus"], set) else str(cl["cpus"])
            freq_str = f"{cl['max_freq']:.2f} GHz" if cl['max_freq'] > 0 else "Auto (QoS)"
            l3_str = f"{GREEN}Shared{RESET}" if cl["l3_shared"] else f"{RED}None{RESET}"
            color = GREEN if "Performance" in cl["type"] else (YELLOW if "Efficiency" in cl["type"] else RED)
            print(f"  {color}{cl['type']:<26}{RESET} | {cpus_str:<10} | {freq_str:<11} | {l3_str:<18} | {cl['desc']}")

        print("\n" + "=" * 80)
        print(f" {BOLD}Benchmarking & Core Pinning Recommendations{RESET}")
        print("=" * 80)

        if len(self.clusters) > 1 and self.system == "Linux":
            p_cluster = next((c for c in self.clusters if "Performance" in c["type"]), None)
            e_cluster = next((c for c in self.clusters if "Efficiency" in c["type"]), None)
            lp_cluster = next((c for c in self.clusters if "Low Power" in c["type"]), None)

            p_list = format_cpulist(p_cluster["cpus"]) if p_cluster else "0-7"
            e_list = format_cpulist(e_cluster["cpus"]) if e_cluster else "8-11"

            # Allocate up to 4 E-cores for wrk
            wrk_cpus = sorted(list(e_cluster["cpus"]))[:4] if e_cluster else [8, 9, 10, 11]
            wrk_list = format_cpulist(set(wrk_cpus))

            print(f"\n  [✓] {BOLD}Server Binding (Under Test){RESET}:")
            print(f"      {GREEN}taskset -c {p_list} <server_binary>{RESET}")
            print(f"      -> Dedicated to {p_cluster['type']} ({p_cluster['max_freq']:.1f} GHz).")
            print(f"         Maximizes single-thread and ring-buffer I/O pipeline capacity.")

            print(f"\n  [✓] {BOLD}Client Binding (wrk Load Generator){RESET}:")
            print(f"      {CYAN}taskset -c {wrk_list} wrk -t4 -c50 ...{RESET}")
            print(f"      -> Dedicated to independent {e_cluster['type']} ({e_cluster['max_freq']:.1f} GHz).")
            print(f"         Prevents wrk client threads from stealing CPU cycles from the server.")

            if lp_cluster:
                lp_list = format_cpulist(lp_cluster["cpus"])
                print(f"\n  [!] {BOLD}{RED}Cores to Avoid / Keep Idle{RESET}:")
                print(f"      {RED}CPUs {lp_list}{RESET} ({lp_cluster['type']}, {lp_cluster['max_freq']:.1f} GHz, No L3 Cache)")
                print(f"      -> Sits on SOC die with no shared L3 cache.")
                print(f"         If worker threads wander here, throughput drops by ~78% due to head-of-line blocking.")

            print(f"\n  [★] {BOLD}Automatic run.py invocation{RESET}:")
            print(f"      {BOLD}SERVER_CORES={p_list} CLIENT_CORES={wrk_list} ./bench/run.py{RESET}")
        elif self.system == "Darwin":
            print("\n  [i] macOS Mach Kernel manages core affinity via Quality of Service (QoS).")
            print("      Foreground benchmarks are automatically dispatched to Performance cores.")
            print("      No manual taskset pinning is needed or supported on Darwin.")
        else:
            print("\n  [i] Homogeneous CPU detected. All cores share identical architecture.")
            print("      Standard unpinned execution or basic taskset partitioning works uniformly.")
        print("")

def main():
    inspector = CpuInspector()
    inspector.inspect()
    inspector.display()

if __name__ == "__main__":
    main()
