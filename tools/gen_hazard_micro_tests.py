#!/usr/bin/env python3
"""Generate focused 8-stage hazard micro-tests.

Covers:
- load-use windows (rs1 and rs2 consumers)
- branch dependency windows (load->branch and alu->branch)

Outputs .hex programs under tb/programs/micro_hazard.
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


def build_hz8_load_use_rs1() -> List[int]:
    a = Asm()
    a.li(10, 0x1000)

    # Immediate consumer through rs1.
    a.lw(5, 10, 0)
    a.add(6, 5, 0)
    a.addi(7, 6, 1)

    # Backing memory is zero-initialized in this environment.
    a.bne(6, 0, "fail")
    a.addi(9, 0, 1)
    a.bne(7, 9, "fail")

    append_pass(a)
    a.label("fail")
    a.j("fail")
    return a.assemble()


def build_hz8_load_use_rs2() -> List[int]:
    a = Asm()
    a.li(10, 0x1000)

    # Immediate consumer through rs2.
    a.lw(5, 10, 0)
    a.addi(6, 0, 1)
    a.add(7, 6, 5)

    a.bne(7, 6, "fail")

    append_pass(a)
    a.label("fail")
    a.j("fail")
    return a.assemble()


def build_hz8_load_branch_taken() -> List[int]:
    a = Asm()
    a.li(10, 0x1000)

    # load -> branch compare, should take (zero == zero).
    a.lw(5, 10, 0)
    a.beq(5, 0, "taken")
    a.j("fail")

    a.label("taken")
    a.addi(7, 0, 1)
    a.bne(7, 0, "ok")
    a.j("fail")

    a.label("ok")
    append_pass(a)
    a.label("fail")
    a.j("fail")
    return a.assemble()


def build_hz8_load_branch_not_taken() -> List[int]:
    a = Asm()
    a.li(10, 0x1000)

    # load -> branch compare, should NOT take (zero != one).
    a.lw(5, 10, 0)
    a.addi(6, 0, 1)
    a.beq(5, 6, "fail")

    a.bne(5, 0, "fail")

    append_pass(a)
    a.label("fail")
    a.j("fail")
    return a.assemble()


def build_hz8_alu_branch_dep() -> List[int]:
    a = Asm()

    # ALU result consumed immediately by branch comparator.
    a.addi(5, 0, 7)
    a.addi(6, 5, 1)
    a.beq(6, 0, "fail")

    a.addi(7, 6, -8)
    a.bne(7, 0, "fail")

    append_pass(a)
    a.label("fail")
    a.j("fail")
    return a.assemble()


def build_hz8_branch_chain_dep() -> List[int]:
    a = Asm()

    # Back-to-back branch dependency updates.
    a.addi(5, 0, 3)
    a.addi(6, 0, 3)
    a.beq(5, 6, "l1")
    a.j("fail")

    a.label("l1")
    a.addi(5, 5, 1)      # 4
    a.beq(5, 6, "fail") # must not take
    a.addi(6, 6, 1)      # 4
    a.bne(5, 6, "fail") # must not take

    append_pass(a)
    a.label("fail")
    a.j("fail")
    return a.assemble()


TESTS: Dict[str, Callable[[], List[int]]] = {
    "hz8_load_use_rs1": build_hz8_load_use_rs1,
    "hz8_load_use_rs2": build_hz8_load_use_rs2,
    "hz8_load_branch_taken": build_hz8_load_branch_taken,
    "hz8_load_branch_not_taken": build_hz8_load_branch_not_taken,
    "hz8_alu_branch_dep": build_hz8_alu_branch_dep,
    "hz8_branch_chain_dep": build_hz8_branch_chain_dep,
}


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out-dir", default="tb/programs/micro_hazard")
    args = ap.parse_args()

    os.makedirs(args.out_dir, exist_ok=True)
    for name, builder in TESTS.items():
        words = builder()
        path = os.path.join(args.out_dir, f"{name}.hex")
        write_hex(path, words)
        print(f"  wrote {path}  ({len(words)} words)")


if __name__ == "__main__":
    main()
