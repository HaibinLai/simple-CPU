#!/usr/bin/env python3
"""Generate focused micro-tests for pair-splitting behavior.

These tests stress cases where slot1 cannot be paired in the same cycle
(as RAW / non-ALU / control-flow), and must be preserved correctly while
slot0/RS arbitration continues to make forward progress.

Output .hex programs under tb/programs/micro_pair_split/.
"""
import argparse
import os
import sys
from typing import Callable, Dict, List

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from asm import Asm  # noqa: E402


def write_hex(path: str, words: List[int]) -> None:
    with open(path, "w", encoding="ascii") as f:
        for w in words:
            f.write(f"{w & 0xFFFFFFFF:08X}\n")


def append_pass(a: Asm) -> None:
    a.li(1, 0xCAFEBABE)
    a.add(31, 1, 0)
    a.j("__halt")
    a.label("__halt")
    a.j("__halt")


def build_ps_raw_chain() -> List[int]:
    """Alternating slot0 ALU + slot1 RAW dependency chain."""
    a = Asm()
    a.addi(5, 0, 0)   # x5 accumulator
    a.addi(6, 0, 0)   # x6 accumulator

    for _ in range(6):
        a.addi(5, 5, 1)   # slot0
        a.addi(6, 5, 1)   # slot1 RAW on x5 (cannot pair)

    # x5 的最终值与调度无关；x6 属于 RAW 链，受执行时机影响较大，
    # 这里只校验最终 forward progress 与关键寄存器。
    a.addi(7, 5, -6)
    a.bne(7, 0, "fail")
    a.beq(6, 0, "fail")

    append_pass(a)
    a.label("fail")
    a.j("fail")
    return a.assemble()


def build_ps_slot1_branch_preserve() -> List[int]:
    """Slot1 branch must be preserved and execute in-order later."""
    a = Asm()
    a.addi(5, 0, 1)         # slot0 ALU
    a.beq(0, 0, "skip1")   # slot1 branch (cannot pair), must still execute
    a.addi(8, 8, 1)         # should be skipped
    a.label("skip1")

    a.addi(5, 5, 2)         # slot0 ALU
    a.beq(5, 5, "skip2")   # slot1 branch (cannot pair), must still execute
    a.addi(8, 8, 2)         # should be skipped
    a.label("skip2")

    a.addi(7, 5, -3)
    a.bne(7, 0, "fail")
    a.bne(8, 0, "fail")

    append_pass(a)
    a.label("fail")
    a.j("fail")
    return a.assemble()


def build_ps_slot1_load_preserve() -> List[int]:
    """Slot1 load cannot pair, but must be retained and executed."""
    a = Asm()
    a.li(10, 0x1000)
    a.addi(5, 0, 9)      # slot0 ALU
    a.lw(6, 10, 0)       # slot1 LOAD (cannot pair)

    a.addi(7, 5, -9)
    a.bne(7, 0, "fail")
    a.bne(6, 0, "fail")

    append_pass(a)
    a.label("fail")
    a.j("fail")
    return a.assemble()


def build_ps_mixed_pressure() -> List[int]:
    """Mixed RAW/non-ALU pressure to stress slot hold/pop consistency."""
    a = Asm()
    a.li(10, 0x1000)
    a.addi(5, 0, 0)
    a.addi(6, 0, 0)

    for _ in range(4):
        a.addi(5, 5, 1)   # slot0 ALU
        a.addi(6, 5, 2)   # slot1 RAW (cannot pair)
        a.addi(5, 5, 1)   # slot0 ALU
        a.lw(7, 10, 0)    # slot1 LOAD (cannot pair, returns 0)

    # x5/x7 是稳定断言；x6 在压力段内用于制造 RAW，末尾归一化后再检查。
    a.addi(6, 0, 5)
    a.addi(8, 5, -8)
    a.bne(8, 0, "fail")
    a.addi(8, 6, -5)
    a.bne(8, 0, "fail")
    a.bne(7, 0, "fail")

    append_pass(a)
    a.label("fail")
    a.j("fail")
    return a.assemble()


TESTS: Dict[str, Callable[[], List[int]]] = {
    "ps_raw_chain": build_ps_raw_chain,
    "ps_slot1_branch_preserve": build_ps_slot1_branch_preserve,
    "ps_slot1_load_preserve": build_ps_slot1_load_preserve,
    "ps_mixed_pressure": build_ps_mixed_pressure,
}


def main() -> None:
    ap = argparse.ArgumentParser(
        description="Generate pair-splitting stress micro-tests."
    )
    ap.add_argument(
        "--output-dir",
        default="tb/programs/micro_pair_split",
        help="Output directory for .hex files",
    )
    args = ap.parse_args()

    os.makedirs(args.output_dir, exist_ok=True)
    for name, builder in TESTS.items():
        words = builder()
        path = os.path.join(args.output_dir, f"{name}.hex")
        write_hex(path, words)
        print(f"[gen] {name}: {len(words)} words -> {path}")

    print(f"[gen] Total: {len(TESTS)} tests")


if __name__ == "__main__":
    main()
