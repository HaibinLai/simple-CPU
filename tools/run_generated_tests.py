#!/usr/bin/env python3
import argparse
import glob
import os
import re
import subprocess


PASS_TOKEN = "[TB] PASS: x31 = 0xCAFEBABE detected"
TIMEOUT_TOKEN = "[TB] simulation finished by timeout"

RE_CPI = re.compile(r"\[TB\]\s+cycles=(\d+)\s+retired=(\d+)\s+CPI=([0-9.]+)")
RE_BR = re.compile(r"\[TB\]\s+branches=(\d+)\s+mispredicts=(\d+)\s+miss_rate=([0-9.]+)")
RE_IC = re.compile(r"\[TB\]\s+I\$\s+access=(\d+)\s+hit=(\d+)\s+miss=(\d+)\s+miss_rate=([0-9.]+)")
RE_DC = re.compile(r"\[TB\]\s+D\$\s+access=(\d+)\s+hit=(\d+)\s+miss=(\d+)\s+miss_rate=([0-9.]+)")


def parse_metrics(out: str):
    m_cpi = RE_CPI.search(out)
    m_br = RE_BR.search(out)
    m_ic = RE_IC.search(out)
    m_dc = RE_DC.search(out)

    metrics = {}
    if m_cpi:
        metrics["cycles"] = int(m_cpi.group(1))
        metrics["retired"] = int(m_cpi.group(2))
        metrics["cpi"] = float(m_cpi.group(3))
    if m_br:
        metrics["branches"] = int(m_br.group(1))
        metrics["branch_mispredicts"] = int(m_br.group(2))
        metrics["branch_miss_rate"] = float(m_br.group(3))
    if m_ic:
        metrics["ic_access"] = int(m_ic.group(1))
        metrics["ic_hit"] = int(m_ic.group(2))
        metrics["ic_miss"] = int(m_ic.group(3))
        metrics["ic_miss_rate"] = float(m_ic.group(4))
    if m_dc:
        metrics["dc_access"] = int(m_dc.group(1))
        metrics["dc_hit"] = int(m_dc.group(2))
        metrics["dc_miss"] = int(m_dc.group(3))
        metrics["dc_miss_rate"] = float(m_dc.group(4))
    return metrics


def run_one(repo_root: str, prog: str, timeout_sec: int = 30):
    cmd = ["make", "run", f"PROG={prog}"]
    p = subprocess.run(
        cmd,
        cwd=repo_root,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=timeout_sec,
    )
    out = p.stdout
    ok = (p.returncode == 0) and (PASS_TOKEN in out) and (TIMEOUT_TOKEN not in out)
    return ok, p.returncode, out


def main():
    ap = argparse.ArgumentParser(description="Run generated rv32 tests via make run")
    ap.add_argument("--dir", default="tb/programs/generated", help="directory containing .hex tests")
    ap.add_argument("--glob", default="rv32_rand_*.hex", help="glob pattern under --dir")
    ap.add_argument("--repo-root", default=".", help="repo root for make run")
    ap.add_argument("--max-fail-print", type=int, default=5, help="how many failing logs to print")
    args = ap.parse_args()

    repo_root = os.path.abspath(args.repo_root)
    test_dir = os.path.join(repo_root, args.dir)
    tests = sorted(glob.glob(os.path.join(test_dir, args.glob)))
    if not tests:
        raise SystemExit(f"No tests found in {test_dir} with pattern {args.glob}")

    total = len(tests)
    passed = 0
    failed = []
    all_metrics = []

    for idx, t in enumerate(tests, 1):
        rel = os.path.relpath(t, repo_root)
        ok, rc, out = run_one(repo_root, rel)
        if ok:
            passed += 1
            mt = parse_metrics(out)
            all_metrics.append(mt)
            print(f"[{idx}/{total}] PASS {rel}")
        else:
            failed.append((rel, rc, out))
            print(f"[{idx}/{total}] FAIL {rel} (rc={rc})")

    print("\n=== Summary ===")
    print(f"Total:  {total}")
    print(f"Passed: {passed}")
    print(f"Failed: {total - passed}")

    if all_metrics:
        sum_cycles = sum(m.get("cycles", 0) for m in all_metrics)
        sum_retired = sum(m.get("retired", 0) for m in all_metrics)
        sum_br = sum(m.get("branches", 0) for m in all_metrics)
        sum_br_miss = sum(m.get("branch_mispredicts", 0) for m in all_metrics)
        sum_ic_acc = sum(m.get("ic_access", 0) for m in all_metrics)
        sum_ic_miss = sum(m.get("ic_miss", 0) for m in all_metrics)
        sum_dc_acc = sum(m.get("dc_access", 0) for m in all_metrics)
        sum_dc_miss = sum(m.get("dc_miss", 0) for m in all_metrics)

        weighted_cpi = (sum_cycles / sum_retired) if sum_retired else 0.0
        br_miss_rate = (sum_br_miss / sum_br) if sum_br else 0.0
        ic_miss_rate = (sum_ic_miss / sum_ic_acc) if sum_ic_acc else 0.0
        dc_miss_rate = (sum_dc_miss / sum_dc_acc) if sum_dc_acc else 0.0

        print("\n=== Aggregated Metrics (PASS cases) ===")
        print(f"Cycles:             {sum_cycles}")
        print(f"Retired instr:      {sum_retired}")
        print(f"Weighted CPI:       {weighted_cpi:.6f}")
        print(f"Branch miss rate:   {br_miss_rate:.6f} ({sum_br_miss}/{sum_br})")
        print(f"I$ miss rate:       {ic_miss_rate:.6f} ({sum_ic_miss}/{sum_ic_acc})")
        print(f"D$ miss rate:       {dc_miss_rate:.6f} ({sum_dc_miss}/{sum_dc_acc})")

    if failed:
        print("\n=== Failure Samples ===")
        for rel, rc, out in failed[: args.max_fail_print]:
            print(f"--- {rel} (rc={rc}) ---")
            lines = out.strip().splitlines()
            for line in lines[-25:]:
                print(line)

    raise SystemExit(0 if passed == total else 1)


if __name__ == "__main__":
    main()
