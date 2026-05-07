#!/usr/bin/env python3
"""Cross-check tools/gen_rv32_tests.py:RV32ISim against the RTL CPU.

For each .hex program:
  - run it on the Python sim, capture final x0..x31
  - run it on the RTL via iverilog, capture [TB] REG x.. lines
  - diff the two dumps

This treats the (already heavily exercised) RTL as the de-facto golden;
disagreements imply either a sim bug or an RTL bug.
"""
import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
from gen_rv32_tests import RV32ISim, MAGIC  # type: ignore


def load_hex(path: Path) -> list[int]:
    words = []
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("//") or line.startswith("@"):
            continue
        words.append(int(line, 16) & 0xFFFFFFFF)
    return words


def run_python_sim(words: list[int], max_steps: int) -> list[int]:
    # Bench programs need a much larger memory + step budget than the
    # random-test default.
    sim = RV32ISim(words, mem_words=1 << 18)  # 1 MiB of word-mem
    sim.max_steps = max_steps
    for _ in range(max_steps):
        if sim.reg[31] == MAGIC:
            break
        if not sim.step():
            break
    return list(sim.reg)


def run_rtl(hex_path: Path, build_dir: Path, timeout_ns: int) -> list[int]:
    vvp = build_dir / "cpu_xcheck.vvp"
    src_files = sorted((ROOT / "rtl" / "core").glob("*.v")) + \
                sorted((ROOT / "rtl" / "mem").glob("*.v")) + \
                [ROOT / "tb" / "tb_cpu.v"]
    cmd = [
        "iverilog", "-g2012",
        "-I", str(ROOT / "rtl" / "core"),
        f"-DPROG_HEX=\"{hex_path}\"",
        f"-DSIM_TIMEOUT_NS={timeout_ns}",
        "-o", str(vvp), "-s", "tb_cpu",
        *[str(p) for p in src_files],
    ]
    subprocess.run(cmd, check=True, capture_output=True)
    res = subprocess.run(["vvp", str(vvp)], capture_output=True, text=True, check=False)
    out = res.stdout
    # Parse "[TB] REG x07=0x000000ab"
    regs = [None] * 32
    pat = re.compile(r"\[TB\]\s+REG\s+x(\d+)=0x([0-9a-fA-F]+)")
    for m in pat.finditer(out):
        idx = int(m.group(1))
        if 0 <= idx < 32:
            regs[idx] = int(m.group(2), 16)
    if any(r is None for r in regs):
        raise RuntimeError(f"RTL did not dump all 32 regs for {hex_path.name}\n--- stdout tail ---\n" + "\n".join(out.splitlines()[-40:]))
    pass_seen = "PASS: x31 = 0xCAFEBABE" in out
    return regs, pass_seen


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--hex-dir", default="tb/programs/bench")
    ap.add_argument("--only", nargs="*", help="only run these stems")
    ap.add_argument("--max-steps", type=int, default=2_000_000)
    ap.add_argument("--rtl-timeout-ns", type=int, default=20_000_000)
    ap.add_argument("--build-dir", default="sim")
    args = ap.parse_args()

    hex_dir = ROOT / args.hex_dir
    build_dir = ROOT / args.build_dir
    build_dir.mkdir(exist_ok=True)

    files = sorted(hex_dir.glob("*.hex"))
    if args.only:
        wanted = set(args.only)
        files = [f for f in files if f.stem in wanted]

    fail = 0
    for hp in files:
        words = load_hex(hp)
        try:
            sim_regs = run_python_sim(words, args.max_steps)
        except Exception as e:
            print(f"[{hp.stem}] PY SIM ERROR: {e}")
            fail += 1
            continue
        sim_pass = sim_regs[31] == MAGIC
        try:
            rtl_regs, rtl_pass = run_rtl(hp, build_dir, args.rtl_timeout_ns)
        except Exception as e:
            print(f"[{hp.stem}] RTL ERROR: {e}")
            fail += 1
            continue

        diffs = [(i, sim_regs[i], rtl_regs[i])
                 for i in range(32) if sim_regs[i] != rtl_regs[i]]
        status = "OK " if not diffs and sim_pass and rtl_pass else "FAIL"
        if status != "OK ":
            fail += 1
        print(f"[{status}] {hp.stem:20s}  sim_pass={sim_pass}  rtl_pass={rtl_pass}  diffs={len(diffs)}")
        for i, sv, rv in diffs:
            print(f"        x{i:02d}  sim=0x{sv:08x}  rtl=0x{rv:08x}")

    print(f"\nTotal: {len(files)} programs, {fail} failures")
    sys.exit(1 if fail else 0)


if __name__ == "__main__":
    main()
