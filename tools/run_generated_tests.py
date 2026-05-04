#!/usr/bin/env python3
import argparse
import glob
import os
import re
import subprocess
import shutil
import sys

# Reuse the reference ISA simulator
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_rv32_tests import RV32ISim


PASS_TOKEN = "[TB] PASS: x31 = 0xCAFEBABE detected"
TIMEOUT_TOKEN = "[TB] simulation finished by timeout"

RE_REG = re.compile(r"\[TB\]\s+REG\s+x(\d+)=0x([0-9a-fA-F]+)")
RE_CPI = re.compile(r"\[TB\]\s+cycles=(\d+)\s+retired=(\d+)\s+CPI=([0-9.]+)")
RE_BR = re.compile(r"\[TB\]\s+branches=(\d+)\s+mispredicts=(\d+)\s+miss_rate=([0-9.]+)")
RE_IC = re.compile(r"\[TB\]\s+I\$\s+access=(\d+)\s+hit=(\d+)\s+miss=(\d+)\s+miss_rate=([0-9.]+)")
RE_DC = re.compile(r"\[TB\]\s+D\$\s+access=(\d+)\s+hit=(\d+)\s+miss=(\d+)\s+miss_rate=([0-9.]+)")


def parse_rtl_regs(out: str):
    regs = [None] * 32
    for m in RE_REG.finditer(out):
        idx = int(m.group(1))
        if 0 <= idx < 32:
            regs[idx] = int(m.group(2), 16)
    return regs


def load_hex(path: str):
    words = []
    with open(path, "r") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("//") or line.startswith("#"):
                continue
            words.append(int(line, 16))
    return words


def expected_regs(hex_path: str):
    words = load_hex(hex_path)
    sim = RV32ISim(words)
    if not sim.run_until_magic():
        return None
    return list(sim.reg)


def diff_regs(expected, actual):
    """Return list of (idx, exp, act) for mismatching registers, ignoring None entries."""
    diffs = []
    for i in range(32):
        e = expected[i] if expected else None
        a = actual[i] if actual else None
        if e is None or a is None:
            continue
        if (e & 0xFFFFFFFF) != (a & 0xFFFFFFFF):
            diffs.append((i, e & 0xFFFFFFFF, a & 0xFFFFFFFF))
    return diffs


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


def is_probable_simulator_flake(out: str) -> bool:
    pats = [
        "Program not runnable",
        "unresolved functor reference",
        "Unable to resolve label",
        "unresolved vvp_net reference",
        "syntax error",
        "Abort trap",
    ]
    text = out.lower()
    return any(p.lower() in text for p in pats)


def run_one(repo_root: str, prog: str, sim_dir: str, timeout_sec: int = 30):
    cmd = ["make", "run", f"PROG={prog}", f"SIM_DIR={sim_dir}"]
    p = subprocess.run(
        cmd,
        cwd=repo_root,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=timeout_sec,
    )
    out = p.stdout
    pass_token_ok = (p.returncode == 0) and (PASS_TOKEN in out) and (TIMEOUT_TOKEN not in out)
    return pass_token_ok, p.returncode, out


def main():
    ap = argparse.ArgumentParser(description="Run generated rv32 tests via make run")
    ap.add_argument("--dir", default="tb/programs/generated", help="directory containing .hex tests")
    ap.add_argument("--glob", default="rv32_rand_*.hex", help="glob pattern under --dir")
    ap.add_argument("--repo-root", default=".", help="repo root for make run")
    ap.add_argument("--max-fail-print", type=int, default=5, help="how many failing logs to print")
    ap.add_argument("--retries", type=int, default=2, help="retry count for probable simulator flakes")
    ap.add_argument("--sim-dir", default=None, help="dedicated SIM_DIR for this run (default: sim/generated_<pid>)")
    ap.add_argument("--keep-sim-dir", action="store_true", help="do not delete temporary sim dir after run")
    ap.add_argument("--progress-every", type=int, default=100,
                    help="print a progress line every N passing tests (0 to disable)")
    ap.add_argument("--verbose", action="store_true",
                    help="print one line per test (default: only milestones, retries, failures)")
    args = ap.parse_args()

    repo_root = os.path.abspath(args.repo_root)
    sim_dir = args.sim_dir or f"sim/generated_{os.getpid()}"
    test_dir = os.path.join(repo_root, args.dir)
    tests = sorted(glob.glob(os.path.join(test_dir, args.glob)))
    if not tests:
        raise SystemExit(f"No tests found in {test_dir} with pattern {args.glob}")

    total = len(tests)
    passed = 0
    failed = []
    regdiff_failed = 0
    all_metrics = []

    print(f"[run] {total} tests under {args.dir}")

    for idx, t in enumerate(tests, 1):
        rel = os.path.relpath(t, repo_root)
        ok, rc, out = run_one(repo_root, rel, sim_dir)

        attempts = 0
        while (not ok) and attempts < args.retries and is_probable_simulator_flake(out):
            attempts += 1
            ok, rc, out = run_one(repo_root, rel, sim_dir)

        # Cross-check final architectural register state against the
        # independent Python ISS. This is much stronger than just looking
        # at x31 == 0xCAFEBABE.
        diffs = []
        if ok:
            try:
                exp = expected_regs(t)
            except Exception as e:
                exp = None
                diffs = [("ISS_ERROR", str(e), "")]
            actual = parse_rtl_regs(out)
            if exp is not None:
                diffs = diff_regs(exp, actual)
            if diffs:
                ok = False
                regdiff_failed += 1

        if ok:
            passed += 1
            mt = parse_metrics(out)
            all_metrics.append(mt)
            # Quiet by default: only emit a line for retries, verbose mode,
            # or every --progress-every passes.
            if args.verbose:
                suffix = f" (after {attempts} retry)" if attempts else ""
                print(f"[{idx}/{total}] PASS {rel}{suffix}")
            elif attempts > 0:
                print(f"[{idx}/{total}] PASS {rel} (after {attempts} retry)")
            elif args.progress_every and (passed % args.progress_every == 0):
                print(f"[progress] {passed}/{total} passed")
        else:
            failed.append((rel, rc, out, diffs))
            reason = f"regdiff x{len(diffs)}" if diffs else f"rc={rc}"
            print(f"[{idx}/{total}] FAIL {rel} ({reason})")

    print("\n=== Summary ===")
    print(f"Total:           {total}")
    print(f"Passed:          {passed}")
    print(f"Failed:          {total - passed}")
    print(f"  regdiff fails: {regdiff_failed}")

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
        for rel, rc, out, diffs in failed[: args.max_fail_print]:
            print(f"--- {rel} (rc={rc}) ---")
            if diffs and isinstance(diffs[0], tuple) and isinstance(diffs[0][0], int):
                print(f"  register mismatches: {len(diffs)}")
                for i, e, a in diffs[:16]:
                    print(f"    x{i:02d}: expected=0x{e:08x}  rtl=0x{a:08x}")
                if len(diffs) > 16:
                    print(f"    ... ({len(diffs) - 16} more)")
            else:
                lines = out.strip().splitlines()
                for line in lines[-25:]:
                    print(line)

    if not args.keep_sim_dir:
        try:
            shutil.rmtree(os.path.join(repo_root, sim_dir), ignore_errors=True)
        except Exception:
            pass

    raise SystemExit(0 if passed == total else 1)


if __name__ == "__main__":
    main()
