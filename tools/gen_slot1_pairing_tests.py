#!/usr/bin/env python3
"""Generate micro-tests for 2-issue slot1 pairing logic validation.

Tests:
1. Two ALU instructions (both should be issuable)
2. ALU + LOAD (LOAD not allowed in slot1)
3. ALU with RAW dependency (slot1 blocked by RAW)
4. Two non-ALU instructions (both blocked or slot1 blocked)

Output .hex programs under tb/programs/micro_slot1/
"""
import argparse
import os
import sys
from typing import List

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


def build_s1p_two_alu() -> List[int]:
    """Two ALU instructions: both can pair (slot0=ADD, slot1=ADDI).
    
    Expected behavior: id2_issue_slot1 = 1 (valid1 && alu_only && no_raw)
    """
    a = Asm()
    a.add(5, 0, 0)      # slot0: ADD x5, x0, x0
    a.addi(6, 0, 42)    # slot1: ADDI x6, x0, 42 (no dependency on x5)
    a.bne(5, 0, "fail")
    a.addi(7, 6, -42)   # Verify x6=42
    a.bne(7, 0, "fail")
    append_pass(a)
    a.label("fail")
    a.j("fail")
    return a.assemble()


def build_s1p_alu_load() -> List[int]:
    """ALU + LOAD: slot1 blocked (LOAD not ALU-only).
    
    Expected behavior: id2_issue_slot1 = 0 (not alu_only)
    """
    a = Asm()
    a.li(10, 0x1000)
    a.add(5, 0, 0)      # slot0: ADD x5, x0, x0
    a.lw(6, 10, 0)      # slot1: LW x6, 0(x10) - LOAD not allowed
    a.bne(5, 0, "fail")
    append_pass(a)
    a.label("fail")
    a.j("fail")
    return a.assemble()


def build_s1p_raw_dependency() -> List[int]:
    """ALU with RAW dependency: slot1 reads slot0's write.
    
    Note: With single-issue backend, slot0 is executed, slot1 is not.
    This test verifies the pairing logic detects RAW hazard (id2_issue_slot1=0).
    Future Milestone 2 tests will verify actual dual execution with forwarding.
    """
    a = Asm()
    a.add(5, 0, 0)      # slot0: ADD x5, x0, x0 (writes x5)
    a.addi(6, 5, 1)     # slot1: ADDI x6, x5, 1 (reads x5 - RAW hazard)
    # Verify slot0 result independent of slot1
    a.bne(5, 0, "fail")
    a.addi(7, 0, 0)
    a.bne(7, 0, "fail")
    append_pass(a)
    a.label("fail")
    a.j("fail")
    return a.assemble()


def build_s1p_no_raw_forward() -> List[int]:
    """ALU instructions without RAW: independent registers.
    
    Note: With single-issue backend, only slot0 is executed.
    This test verifies no false positive on pairing logic (id2_issue_slot1=1).
    When Milestone 2 dual execution is implemented, both slots will execute.
    """
    a = Asm()
    a.addi(5, 0, 10)    # slot0: ADDI x5, x0, 10
    a.addi(6, 0, 20)    # slot1: ADDI x6, x0, 20 (independent)
    # Verify slot0 result directly
    a.addi(7, 5, -10)   # x7 = x5 - 10 = 0
    a.bne(7, 0, "fail")
    append_pass(a)
    a.label("fail")
    a.j("fail")
    return a.assemble()


def build_s1p_branch_not_alu() -> List[int]:
    """Branch instruction in slot1: not allowed (not ALU-only).
    
    Expected behavior: id2_issue_slot1 = 0 (not alu_only)
    """
    a = Asm()
    a.addi(5, 0, 5)     # slot0: ADDI x5, x0, 5
    a.beq(5, 5, "ok")   # slot1: BEQ - branch not allowed
    a.j("fail")
    a.label("ok")
    append_pass(a)
    a.label("fail")
    a.j("fail")
    return a.assemble()


def main():
    parser = argparse.ArgumentParser(
        description="Generate 2-issue slot1 pairing micro-tests."
    )
    parser.add_argument(
        "--output-dir",
        default="tb/programs/micro_slot1",
        help="Output directory for .hex files",
    )
    args = parser.parse_args()

    os.makedirs(args.output_dir, exist_ok=True)

    tests = {
        "s1p_two_alu": build_s1p_two_alu,
        "s1p_alu_load": build_s1p_alu_load,
        "s1p_raw_dep": build_s1p_raw_dependency,
        "s1p_no_raw": build_s1p_no_raw_forward,
        "s1p_branch": build_s1p_branch_not_alu,
    }

    for name, builder in tests.items():
        path = os.path.join(args.output_dir, f"{name}.hex")
        words = builder()
        write_hex(path, words)
        print(f"[gen] {name}: {len(words)} words -> {path}")

    print(f"[gen] Total: {len(tests)} tests")


if __name__ == "__main__":
    main()
