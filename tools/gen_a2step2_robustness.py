"""A2-step2 robustness test (regression).

Constructs a tiny program where a JAL is at slot1 (PC % 8 == 4) and the
words *after* it are POISON STORES that write known sentinel values to
a data area. After the JAL, the test loads that data area into x6/x7/x8.

If the front-end correctly squashes everything fetched after a slot1
JAL, M[0x100..0x108] stays zero and we observe x6 = x7 = x8 = 0.

If wrong-path instructions reach commit (e.g. an "IFQ-only" prediction
hack that doesn't actually redirect PC), the poisons land in DMEM and
we observe x6=0x6AD, x7=0x6AE, x8=0x6AF.

This was the test that caught commit 61208f3 (A2-step2) silently
committing wrong-path stores while still printing PASS.

Run:
    python3 tools/gen_a2step2_robustness.py tb/programs/a2step2_robust.hex
    python3 tools/run_a2step2_robustness.py
"""
from __future__ import annotations
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from asm import Asm  # noqa: E402
from gen_benchmarks import write_hex, append_epilogue  # noqa: E402


def build() -> list[int]:
    a = Asm()
    # 0..4: padding (slot0, slot1)
    a.addi(0, 0, 0)             # nop @ 0   (slot0)
    a.addi(0, 0, 0)             # nop @ 4   (slot1)
    # 8..12: load data base (one ADDI fits since 0x100 < 2048)
    a.addi(10, 0, 0x100)        # x10 = 0x100  @ 8 (slot0)
    a.addi(0, 0, 0)             # nop @ 12 (slot1)  -- JAL goes to next slot1
    a.addi(0, 0, 0)             # nop @ 16 (slot0)
    a.jal(0, "target")          # @ 20 (slot1) <<<<< slot1 JAL
    # ---- wrong-path region (must NOT execute) ----
    a.addi(5, 0, 0x6AD)         # x5 = 0x6AD          @ 24 (slot0)
    a.sw(5, 10, 0)              # M[x10+0] = x5       @ 28 (slot1)
    a.addi(5, 0, 0x6AE)         # x5 = 0x6AE          @ 32 (slot0)
    a.sw(5, 10, 4)              # M[x10+4] = x5       @ 36 (slot1)
    a.addi(5, 0, 0x6AF)         # x5 = 0x6AF          @ 40 (slot0)
    a.sw(5, 10, 8)              # M[x10+8] = x5       @ 44 (slot1)
    # ---- target ----
    a.label("target")
    a.lw(6, 10, 0)              # x6 = M[0x100]
    a.lw(7, 10, 4)              # x7 = M[0x104]
    a.lw(8, 10, 8)              # x8 = M[0x108]
    append_epilogue(a)
    return a.assemble()


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "tb/programs/a2step2_robust.hex"
    words = build()
    write_hex(out, words)
    print(f"wrote {out}: {len(words)} words")
    # Pretty print
    for i, w in enumerate(words):
        print(f"  PC=0x{i*4:04x}  {w:08x}")
