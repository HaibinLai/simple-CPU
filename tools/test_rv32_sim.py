#!/usr/bin/env python3
"""Directed unit tests for tools/gen_rv32_tests.py:RV32ISim.

Each test runs a short hand-built program and asserts an exact final
register/memory state. Expected values were derived from the RV32I
spec (Volume I, Unprivileged ISA) by hand, not from the simulator
itself, so a sim bug shows up as a real diff.

Coverage focuses on the corners that are most often miscoded in
hand-written ISA models:
  * shift right arithmetic on negative inputs  (SRA / SRAI)
  * signed vs unsigned comparison              (SLT/SLTI vs SLTU/SLTIU)
  * sign extension on sub-word loads           (LB / LH vs LBU / LHU)
  * byte-enable for sub-word stores            (SB / SH at every offset)
  * branch displacement direction & equality   (BEQ/BNE/BLT/BGE/BLTU/BGEU)
  * JAL/JALR link value and JALR LSB clear
  * AUIPC / LUI immediate placement
  * shift amount masking to low 5 bits
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "tools"))
from gen_rv32_tests import (  # type: ignore
    RV32ISim, MAGIC,
    ADD, SUB, SLL, SRL, SRA, SLT, SLTU, XOR, OR, AND,
    ADDI, SLTI, SLTIU, XORI, ORI, ANDI, SLLI, SRLI, SRAI,
    LB, LH, LW, LBU, LHU, SB, SH, SW,
    BEQ, BNE, BLT, BGE, BLTU, BGEU,
    LUI, AUIPC, JAL, JALR, u32,
)


def run(words, max_steps=2000, mem_init=None):
    sim = RV32ISim(words, mem_words=1024)
    sim.max_steps = max_steps
    if mem_init:
        for word_idx, val in mem_init.items():
            sim.mem[word_idx] = val & 0xFFFFFFFF
    for _ in range(max_steps):
        if not sim.step():
            break
    return sim


# -------------- helpers to load 32-bit constants ----------------
def li32(rd, value):
    """Emit instructions that materialise a 32-bit constant in rd.

    Uses LUI + ADDI, accounting for the sign extension of ADDI's 12-bit imm.
    """
    value = value & 0xFFFFFFFF
    lo = value & 0xFFF
    hi = (value >> 12) & 0xFFFFF
    if lo & 0x800:
        hi = (hi + 1) & 0xFFFFF
    out = [LUI(rd, hi)]
    if lo or (lo & 0x800):
        # sign-extend lo to 12-bit signed
        imm = lo - 0x1000 if lo & 0x800 else lo
        out.append(ADDI(rd, rd, imm))
    return out


# Sentinel epilogue: stop the sim by hitting an out-of-range PC.
HALT = [JAL(0, 0)]  # spin


# ------------------------------------------------------------------
# Each test returns (name, words, expected_dict, mem_init=None,
#                    mem_check=None)
#   expected_dict: {reg_index: expected_uint32}
#   mem_check:     {word_idx: expected_uint32}
# ------------------------------------------------------------------
TESTS = []


def test(name):
    def deco(fn):
        TESTS.append((name, fn))
        return fn
    return deco


# ---------- arithmetic ----------
@test("addi_basic")
def t():
    w = [ADDI(1, 0, 5), ADDI(2, 1, -3)] + HALT
    return w, {1: 5, 2: 2}, None, None


@test("sub_negative_result")
def t():
    w = [ADDI(1, 0, 3), ADDI(2, 0, 10), SUB(3, 1, 2)] + HALT
    # 3 - 10 = -7 = 0xFFFFFFF9
    return w, {3: u32(-7)}, None, None


# ---------- shifts ----------
@test("srai_negative")
def t():
    # x1 = 0xFFFFFFF0 (i.e. -16). SRAI by 2 -> -4 = 0xFFFFFFFC
    w = li32(1, 0xFFFFFFF0) + [SRAI(2, 1, 2)] + HALT
    return w, {2: 0xFFFFFFFC}, None, None


@test("srli_negative")
def t():
    # logical shift of 0xFFFFFFF0 >> 2 = 0x3FFFFFFC
    w = li32(1, 0xFFFFFFF0) + [SRLI(2, 1, 2)] + HALT
    return w, {2: 0x3FFFFFFC}, None, None


@test("sra_neg_via_register")
def t():
    w = li32(1, 0xFFFFFF80) + [ADDI(2, 0, 3), SRA(3, 1, 2)] + HALT
    # -128 >> 3 = -16 = 0xFFFFFFF0
    return w, {3: 0xFFFFFFF0}, None, None


@test("shift_amount_masked_to_5_bits")
def t():
    # SLL by register: shift amount must be (rs2 & 0x1F).  rs2=33 -> shift 1.
    w = [ADDI(1, 0, 1), ADDI(2, 0, 33), SLL(3, 1, 2)] + HALT
    return w, {3: 2}, None, None


# ---------- comparisons ----------
@test("slt_signed_neg_lt_pos")
def t():
    w = li32(1, 0xFFFFFFFF) + [ADDI(2, 0, 1), SLT(3, 1, 2), SLTU(4, 1, 2)] + HALT
    # signed: -1 < 1 -> 1; unsigned: 0xFFFFFFFF < 1 -> 0
    return w, {3: 1, 4: 0}, None, None


@test("sltiu_with_negative_imm")
def t():
    # SLTIU sign-extends imm then compares unsigned.
    # imm = -1 -> 0xFFFFFFFF; rs1 = 5; 5 < 0xFFFFFFFF unsigned -> 1
    w = [ADDI(1, 0, 5), SLTIU(2, 1, -1)] + HALT
    return w, {2: 1}, None, None


# ---------- loads / stores with sub-word + sign extension ----------
@test("sb_then_lb_sign_extend")
def t():
    # write byte 0xFF at address base+1, read back with LB and LBU.
    # base = 0x000  (mem[0] is in sim address 0x0)
    w = li32(10, 0x0) + [ADDI(2, 0, -1), SB(2, 10, 1), LB(3, 10, 1), LBU(4, 10, 1)] + HALT
    return w, {3: u32(-1), 4: 0xFF}, None, None


@test("sh_at_offset_2")
def t():
    # SH stores rs2[15:0] at addr; LHU reads back unsigned.
    w = li32(10, 0x0) + [ADDI(2, 0, -2), SH(2, 10, 2), LH(3, 10, 2), LHU(4, 10, 2)] + HALT
    return w, {3: u32(-2), 4: 0xFFFE}, None, None


@test("sw_then_lw")
def t():
    w = li32(10, 0x0) + li32(2, 0xDEADBEEF) + [SW(2, 10, 8), LW(3, 10, 8)] + HALT
    return w, {3: 0xDEADBEEF}, None, None


@test("byte_enable_does_not_clobber_neighbours")
def t():
    # Pre-fill mem[0] = 0x11223344, then SB 0xAA at offset 1.  Result should
    # be 0x1122AA44 (only byte 1 changes).  Verify via LW.
    w = li32(10, 0x0) + [ADDI(2, 0, 0xAA - 0x100), SB(2, 10, 1), LW(3, 10, 0)] + HALT
    return w, {3: 0x1122AA44}, {0: 0x11223344}, None


# ---------- branches ----------
@test("beq_taken_skips_one_insn")
def t():
    # If x1 == x2, branch over the "x3 = 99" instruction; else x3 = 99.
    w = [
        ADDI(1, 0, 7), ADDI(2, 0, 7),
        BEQ(1, 2, 8),       # branch +8 (skip next instr)
        ADDI(3, 0, 99),     # skipped
        ADDI(4, 0, 42),
    ] + HALT
    return w, {3: 0, 4: 42}, None, None


@test("bne_not_taken_falls_through")
def t():
    w = [
        ADDI(1, 0, 5), ADDI(2, 0, 5),
        BNE(1, 2, 8),       # not taken
        ADDI(3, 0, 11),     # executed
    ] + HALT
    return w, {3: 11}, None, None


@test("bltu_unsigned_vs_blt_signed")
def t():
    # x1 = -1 (0xFFFFFFFF), x2 = 1.
    # signed: -1 < 1 -> BLT taken;  unsigned: 0xFFFFFFFF < 1 -> BLTU not taken.
    w = li32(1, 0xFFFFFFFF) + [
        ADDI(2, 0, 1),
        BLT(1, 2, 8),       # taken -> skip "x3=1"
        ADDI(3, 0, 1),
        BLTU(1, 2, 8),      # not taken -> "x4=1" executes
        ADDI(4, 0, 1),
    ] + HALT
    return w, {3: 0, 4: 1}, None, None


@test("backward_branch_loop")
def t():
    # Loop: x1 += 1 four times via backward BNE.
    # Layout (PC):
    #   0: ADDI x1,x0,0
    #   4: ADDI x2,x0,4
    #   8: ADDI x1,x1,1     <-- loop top
    #  12: ADDI x2,x2,-1
    #  16: BNE  x2,x0, -8   (back to PC 8)
    #  20: HALT
    w = [
        ADDI(1, 0, 0),
        ADDI(2, 0, 4),
        ADDI(1, 1, 1),
        ADDI(2, 2, -1),
        BNE(2, 0, -8),
    ] + HALT
    return w, {1: 4, 2: 0}, None, None


# ---------- JAL / JALR ----------
@test("jal_link_value")
def t():
    # JAL x1, +8 -> x1 = PC+4 = 4, jumps to PC+8 = 8 (skipping insn at 4).
    w = [
        JAL(1, 8),
        ADDI(2, 0, 99),     # skipped
        ADDI(3, 0, 7),      # executed
    ] + HALT
    return w, {1: 4, 2: 0, 3: 7}, None, None


@test("jalr_clears_lsb")
def t():
    # JALR target = (rs1 + imm) & ~1.  Set rs1 = 0xC, imm = 1 -> target 0xC.
    # Layout:
    #   0: ADDI x10, x0, 0xC
    #   4: JALR x1, x10, 1     -> jumps to 0xC, link = 8
    #   8: ADDI x2,  x0, 99    (skipped)
    #  12: ADDI x3,  x0, 5     (executed)
    #  16: HALT
    w = [
        ADDI(10, 0, 0xC),
        JALR(1, 10, 1),
        ADDI(2, 0, 99),
        ADDI(3, 0, 5),
    ] + HALT
    return w, {1: 8, 2: 0, 3: 5}, None, None


# ---------- LUI / AUIPC ----------
@test("lui_places_imm_in_high_20")
def t():
    w = [LUI(1, 0xABCDE)] + HALT
    return w, {1: 0xABCDE000}, None, None


@test("auipc_adds_pc")
def t():
    # AUIPC at PC=0 with imm=1 -> 0 + 0x1000 = 0x1000.
    w = [AUIPC(1, 1)] + HALT
    return w, {1: 0x1000}, None, None


# ------------------------------------------------------------------
def main():
    fails = 0
    for name, builder in TESTS:
        words, expected, mem_init, mem_check = builder()
        sim = run(words, mem_init=mem_init)
        bad = []
        for r, ev in expected.items():
            got = sim.reg[r]
            if got != (ev & 0xFFFFFFFF):
                bad.append(("reg", r, ev & 0xFFFFFFFF, got))
        if mem_check:
            for idx, ev in mem_check.items():
                got = sim.mem[idx]
                if got != (ev & 0xFFFFFFFF):
                    bad.append(("mem", idx, ev & 0xFFFFFFFF, got))
        if bad:
            fails += 1
            print(f"[FAIL] {name}")
            for kind, idx, exp, got in bad:
                tag = f"x{idx:02d}" if kind == "reg" else f"mem[{idx}]"
                print(f"        {tag}  expected=0x{exp:08x}  got=0x{got:08x}")
        else:
            print(f"[ OK ] {name}")
    print(f"\n{len(TESTS) - fails}/{len(TESTS)} passed")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
