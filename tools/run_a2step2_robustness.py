#!/usr/bin/env python3
"""Regression runner for A2-step2 wrong-path robustness test.

Builds the hex (idempotent) and runs it through iverilog/vvp. Asserts:
  * x31 == 0xCAFEBABE (epilogue reached)
  * x06 == 0          (no wrong-path store at M[0x100])
  * x07 == 0          (no wrong-path store at M[0x104])
  * x08 == 0          (no wrong-path store at M[0x108])

Exits 0 on PASS, non-zero on FAIL.
"""
from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HEX = ROOT / "tb" / "programs" / "a2step2_robust.hex"
GEN = ROOT / "tools" / "gen_a2step2_robustness.py"
BUILD = ROOT / "sim" / "cpu_a2step2_robust.vvp"

POISONS = {6: 0x6AD, 7: 0x6AE, 8: 0x6AF}
TIMEOUT_NS = 200_000


def build_hex() -> None:
    subprocess.run([sys.executable, str(GEN), str(HEX)], check=True,
                   capture_output=True)


def build_vvp() -> None:
    src = sorted((ROOT / "rtl" / "core").glob("*.v")) + \
          sorted((ROOT / "rtl" / "mem").glob("*.v")) + \
          [ROOT / "tb" / "tb_cpu.v"]
    # Use a relative hex path so iverilog's `+PROG_HEX="..."` macro doesn't
    # contain spaces (workspace path has Chinese chars + spaces).
    rel_hex = HEX.relative_to(ROOT)
    cmd = [
        "iverilog", "-g2012",
        "-I", "rtl/core",
        f"-DPROG_HEX=\"{rel_hex}\"",
        f"-DSIM_TIMEOUT_NS={TIMEOUT_NS}",
        "-o", str(BUILD), "-s", "tb_cpu",
        *[str(p.relative_to(ROOT)) for p in src],
    ]
    subprocess.run(cmd, check=True, capture_output=True, cwd=ROOT)


def run() -> dict[int, int]:
    res = subprocess.run(["vvp", str(BUILD)], capture_output=True,
                         text=True, check=False, timeout=30, cwd=ROOT)
    regs: dict[int, int] = {}
    pat = re.compile(r"\[TB\]\s+REG\s+x(\d+)=0x([0-9a-fA-F]+)")
    for m in pat.finditer(res.stdout):
        regs[int(m.group(1))] = int(m.group(2), 16)
    if not regs:
        print(res.stdout[-2000:], file=sys.stderr)
        raise RuntimeError("no REG output from vvp")
    return regs


def main() -> int:
    build_hex()
    build_vvp()
    regs = run()
    fails: list[str] = []
    if regs.get(31) != 0xCAFEBABE:
        fails.append(f"x31={regs.get(31):#x} != 0xCAFEBABE (epilogue not reached)")
    for r, poison in POISONS.items():
        v = regs.get(r, -1)
        if v != 0:
            fails.append(f"x{r:02d}={v:#x}: wrong-path store leaked "
                         f"(expected 0, poison was {poison:#x})")
    if fails:
        print("[FAIL] A2-step2 robustness:")
        for f in fails:
            print(f"   {f}")
        return 1
    print("[PASS] A2-step2 robustness: x6=x7=x8=0, x31=0xCAFEBABE")
    return 0


if __name__ == "__main__":
    sys.exit(main())
