#!/usr/bin/env python3
"""Run RV32I performance benchmarks and report CPI / branch / cache stats.

Workflow per benchmark:
  1. (optional) regenerate .hex via tools/gen_benchmarks.py
  2. invoke `make run PROG=... TIMEOUT_NS=...`
  3. parse the testbench output for cycles/retired/CPI/branch/cache lines
  4. print a summary table

Run:
    python3 tools/run_benchmarks.py
    python3 tools/run_benchmarks.py --regen --timeout-ns 2000000
"""
import argparse
import glob
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from typing import List, Optional

PASS_TOKEN = "[TB] PASS: x31 = 0xCAFEBABE detected"
TIMEOUT_TOKEN = "[TB] simulation finished by timeout"

RE_CPI = re.compile(r"\[TB\] cycles=(\d+)\s+retired=(\d+)\s+CPI=([\d.]+)")
RE_CMT = re.compile(r"\[TB\] committed=(\d+)\s+CPI_c=([\d.]+)")
RE_STL = re.compile(r"\[TB\] stalls: load_use=(\d+)\s+flush_br=(\d+)\s+flush_jump=(\d+)\s+flush_exc=(\d+)")
RE_BR = re.compile(r"\[TB\] branches=(\d+)\s+mispredicts=(\d+)\s+miss_rate=([\d.]+)")
RE_IC = re.compile(r"\[TB\] I\$ access=(\d+) hit=(\d+) miss=(\d+) miss_rate=([\d.]+)")
RE_DC = re.compile(r"\[TB\] D\$ access=(\d+) hit=(\d+) miss=(\d+) miss_rate=([\d.]+)")


@dataclass
class BenchResult:
    name: str
    passed: bool
    cycles: Optional[int] = None
    retired: Optional[int] = None
    cpi: Optional[float] = None
    committed: Optional[int] = None
    cpi_c: Optional[float] = None
    load_use: Optional[int] = None
    flush_br: Optional[int] = None
    flush_jump: Optional[int] = None
    flush_exc: Optional[int] = None
    branches: Optional[int] = None
    mispred: Optional[int] = None
    br_miss_rate: Optional[float] = None
    ic_miss_rate: Optional[float] = None
    dc_miss_rate: Optional[float] = None
    raw_tail: str = ""


def parse_output(out: str) -> BenchResult:
    res = BenchResult(name="", passed=PASS_TOKEN in out and TIMEOUT_TOKEN not in out)
    m = RE_CPI.search(out)
    if m:
        res.cycles = int(m.group(1))
        res.retired = int(m.group(2))
        res.cpi = float(m.group(3))
    m = RE_CMT.search(out)
    if m:
        res.committed = int(m.group(1))
        res.cpi_c = float(m.group(2))
    m = RE_STL.search(out)
    if m:
        res.load_use   = int(m.group(1))
        res.flush_br   = int(m.group(2))
        res.flush_jump = int(m.group(3))
        res.flush_exc  = int(m.group(4))
    m = RE_BR.search(out)
    if m:
        res.branches = int(m.group(1))
        res.mispred = int(m.group(2))
        res.br_miss_rate = float(m.group(3))
    m = RE_IC.search(out)
    if m:
        res.ic_miss_rate = float(m.group(4))
    m = RE_DC.search(out)
    if m:
        res.dc_miss_rate = float(m.group(4))
    res.raw_tail = "\n".join(out.strip().splitlines()[-15:])
    return res


def run_one(repo_root: str, prog: str, timeout_ns: int, wall_timeout_s: int) -> BenchResult:
    # Force a fully fresh build per benchmark. Reusing sim/cpu.vvp across many
    # back-to-back invocations was observed to occasionally yield stale
    # simulation behavior.
    subprocess.run(
        ["make", "clean"], cwd=repo_root,
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False,
    )
    cmd = ["make", "run", f"PROG={prog}", f"TIMEOUT_NS={timeout_ns}"]
    p = subprocess.run(
        cmd,
        cwd=repo_root,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=wall_timeout_s,
    )
    res = parse_output(p.stdout)
    return res


def fmt(v, prec=3, width=10):
    if v is None:
        return "-".rjust(width)
    if isinstance(v, float):
        return f"{v:.{prec}f}".rjust(width)
    return str(v).rjust(width)


def print_table(results: List[BenchResult]) -> None:
    cols = [
        ("benchmark",  20, "left"),
        ("status",      6, "right"),
        ("cycles",     10, "right"),
        ("retired",    10, "right"),
        ("CPI",         8, "right"),
        ("committed",  10, "right"),
        ("CPI_c",       8, "right"),
        ("lu",          6, "right"),
        ("f_br",        6, "right"),
        ("f_jmp",       6, "right"),
        ("f_exc",       6, "right"),
        ("branches",    9, "right"),
        ("mispred",     8, "right"),
        ("br_miss",     8, "right"),
        ("I$_miss",     8, "right"),
        ("D$_miss",     8, "right"),
    ]
    header = "  ".join(
        (h.ljust(w) if a == "left" else h.rjust(w))
        for h, w, a in cols
    )
    print(header)
    print("-" * len(header))

    for r in results:
        status = "PASS" if r.passed else "FAIL"
        row = [
            r.name.ljust(20),
            status.rjust(6),
            fmt(r.cycles, width=10),
            fmt(r.retired, width=10),
            fmt(r.cpi, prec=3, width=8),
            fmt(r.committed, width=10),
            fmt(r.cpi_c, prec=3, width=8),
            fmt(r.load_use, width=6),
            fmt(r.flush_br, width=6),
            fmt(r.flush_jump, width=6),
            fmt(r.flush_exc, width=6),
            fmt(r.branches, width=9),
            fmt(r.mispred, width=8),
            fmt(r.br_miss_rate, prec=3, width=8),
            fmt(r.ic_miss_rate, prec=3, width=8),
            fmt(r.dc_miss_rate, prec=3, width=8),
        ]
        print("  ".join(row))


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo-root", default=".")
    ap.add_argument("--bench-dir", default="tb/programs/bench")
    ap.add_argument("--regen", action="store_true",
                    help="regenerate .hex via tools/gen_benchmarks.py before running")
    ap.add_argument("--timeout-ns", type=int, default=2_000_000,
                    help="simulation timeout in ns (default 2,000,000 = 2 ms sim time)")
    ap.add_argument("--wall-timeout-s", type=int, default=120)
    ap.add_argument("--filter", default="*", help="glob filter on benchmark file stem")
    args = ap.parse_args()

    repo_root = os.path.abspath(args.repo_root)
    bench_dir = os.path.join(repo_root, args.bench_dir)

    if args.regen:
        rc = subprocess.call(
            [sys.executable, "tools/gen_benchmarks.py", "--out-dir", args.bench_dir],
            cwd=repo_root,
        )
        if rc != 0:
            raise SystemExit(f"gen_benchmarks.py exited with {rc}")

    pattern = os.path.join(bench_dir, f"{args.filter}.hex")
    progs = sorted(glob.glob(pattern))
    if not progs:
        raise SystemExit(f"No benchmarks found at {pattern}. Use --regen first?")

    results: List[BenchResult] = []
    for p in progs:
        rel = os.path.relpath(p, repo_root)
        name = os.path.splitext(os.path.basename(p))[0]
        print(f"[run] {name}")
        try:
            r = run_one(repo_root, rel, args.timeout_ns, args.wall_timeout_s)
        except subprocess.TimeoutExpired:
            r = BenchResult(name=name, passed=False, raw_tail="<wall-clock timeout>")
        r.name = name
        results.append(r)

    print()
    print_table(results)

    failed = [r for r in results if not r.passed]
    if failed:
        print("\n=== Failure Tails ===")
        for r in failed:
            print(f"--- {r.name} ---")
            print(r.raw_tail)
        raise SystemExit(1)


if __name__ == "__main__":
    main()
