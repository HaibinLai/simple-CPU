#!/usr/bin/env python3
import argparse
import os
import random
from dataclasses import dataclass
from typing import List, Dict


MAGIC = 0xCAFEBABE
NOP = 0x00000013  # addi x0, x0, 0


def sign_extend(value: int, bits: int) -> int:
    mask = (1 << bits) - 1
    value &= mask
    if value & (1 << (bits - 1)):
        return value - (1 << bits)
    return value


def u32(x: int) -> int:
    return x & 0xFFFFFFFF


# ---------- RV32I encoders ----------
def enc_r(opcode: int, rd: int, funct3: int, rs1: int, rs2: int, funct7: int) -> int:
    return ((funct7 & 0x7F) << 25) | ((rs2 & 0x1F) << 20) | ((rs1 & 0x1F) << 15) | ((funct3 & 0x7) << 12) | ((rd & 0x1F) << 7) | (opcode & 0x7F)


def enc_i(opcode: int, rd: int, funct3: int, rs1: int, imm12: int) -> int:
    imm = imm12 & 0xFFF
    return (imm << 20) | ((rs1 & 0x1F) << 15) | ((funct3 & 0x7) << 12) | ((rd & 0x1F) << 7) | (opcode & 0x7F)


def enc_s(opcode: int, funct3: int, rs1: int, rs2: int, imm12: int) -> int:
    imm = imm12 & 0xFFF
    imm_11_5 = (imm >> 5) & 0x7F
    imm_4_0 = imm & 0x1F
    return (imm_11_5 << 25) | ((rs2 & 0x1F) << 20) | ((rs1 & 0x1F) << 15) | ((funct3 & 0x7) << 12) | (imm_4_0 << 7) | (opcode & 0x7F)


def enc_b(opcode: int, funct3: int, rs1: int, rs2: int, imm13: int) -> int:
    # imm13 is signed byte offset, must be multiple of 2
    imm = imm13 & 0x1FFF
    b12 = (imm >> 12) & 0x1
    b10_5 = (imm >> 5) & 0x3F
    b4_1 = (imm >> 1) & 0xF
    b11 = (imm >> 11) & 0x1
    return (b12 << 31) | (b10_5 << 25) | ((rs2 & 0x1F) << 20) | ((rs1 & 0x1F) << 15) | ((funct3 & 0x7) << 12) | (b4_1 << 8) | (b11 << 7) | (opcode & 0x7F)


def enc_u(opcode: int, rd: int, imm20: int) -> int:
    return ((imm20 & 0xFFFFF) << 12) | ((rd & 0x1F) << 7) | (opcode & 0x7F)


def enc_j(opcode: int, rd: int, imm21: int) -> int:
    # imm21 is signed byte offset, must be multiple of 2
    imm = imm21 & 0x1FFFFF
    b20 = (imm >> 20) & 0x1
    b10_1 = (imm >> 1) & 0x3FF
    b11 = (imm >> 11) & 0x1
    b19_12 = (imm >> 12) & 0xFF
    return (b20 << 31) | (b19_12 << 12) | (b11 << 20) | (b10_1 << 21) | ((rd & 0x1F) << 7) | (opcode & 0x7F)


# ---------- instruction wrappers ----------
def ADD(rd, rs1, rs2): return enc_r(0x33, rd, 0x0, rs1, rs2, 0x00)
def SUB(rd, rs1, rs2): return enc_r(0x33, rd, 0x0, rs1, rs2, 0x20)
def SLL(rd, rs1, rs2): return enc_r(0x33, rd, 0x1, rs1, rs2, 0x00)
def SRL(rd, rs1, rs2): return enc_r(0x33, rd, 0x5, rs1, rs2, 0x00)
def SRA(rd, rs1, rs2): return enc_r(0x33, rd, 0x5, rs1, rs2, 0x20)
def SLT(rd, rs1, rs2): return enc_r(0x33, rd, 0x2, rs1, rs2, 0x00)
def SLTU(rd, rs1, rs2): return enc_r(0x33, rd, 0x3, rs1, rs2, 0x00)
def XOR(rd, rs1, rs2): return enc_r(0x33, rd, 0x4, rs1, rs2, 0x00)
def OR(rd, rs1, rs2): return enc_r(0x33, rd, 0x6, rs1, rs2, 0x00)
def AND(rd, rs1, rs2): return enc_r(0x33, rd, 0x7, rs1, rs2, 0x00)

def ADDI(rd, rs1, imm): return enc_i(0x13, rd, 0x0, rs1, imm)
def SLTI(rd, rs1, imm): return enc_i(0x13, rd, 0x2, rs1, imm)
def SLTIU(rd, rs1, imm): return enc_i(0x13, rd, 0x3, rs1, imm)
def XORI(rd, rs1, imm): return enc_i(0x13, rd, 0x4, rs1, imm)
def ORI(rd, rs1, imm): return enc_i(0x13, rd, 0x6, rs1, imm)
def ANDI(rd, rs1, imm): return enc_i(0x13, rd, 0x7, rs1, imm)
def SLLI(rd, rs1, shamt): return enc_i(0x13, rd, 0x1, rs1, shamt & 0x1F)
def SRLI(rd, rs1, shamt): return enc_i(0x13, rd, 0x5, rs1, shamt & 0x1F)
def SRAI(rd, rs1, shamt): return enc_i(0x13, rd, 0x5, rs1, 0x400 | (shamt & 0x1F))

def LB(rd, rs1, imm): return enc_i(0x03, rd, 0x0, rs1, imm)
def LH(rd, rs1, imm): return enc_i(0x03, rd, 0x1, rs1, imm)
def LW(rd, rs1, imm): return enc_i(0x03, rd, 0x2, rs1, imm)
def LBU(rd, rs1, imm): return enc_i(0x03, rd, 0x4, rs1, imm)
def LHU(rd, rs1, imm): return enc_i(0x03, rd, 0x5, rs1, imm)

def SB(rs2, rs1, imm): return enc_s(0x23, 0x0, rs1, rs2, imm)
def SH(rs2, rs1, imm): return enc_s(0x23, 0x1, rs1, rs2, imm)
def SW(rs2, rs1, imm): return enc_s(0x23, 0x2, rs1, rs2, imm)

def BEQ(rs1, rs2, imm): return enc_b(0x63, 0x0, rs1, rs2, imm)
def BNE(rs1, rs2, imm): return enc_b(0x63, 0x1, rs1, rs2, imm)
def BLT(rs1, rs2, imm): return enc_b(0x63, 0x4, rs1, rs2, imm)
def BGE(rs1, rs2, imm): return enc_b(0x63, 0x5, rs1, rs2, imm)
def BLTU(rs1, rs2, imm): return enc_b(0x63, 0x6, rs1, rs2, imm)
def BGEU(rs1, rs2, imm): return enc_b(0x63, 0x7, rs1, rs2, imm)

def LUI(rd, imm20): return enc_u(0x37, rd, imm20)
def AUIPC(rd, imm20): return enc_u(0x17, rd, imm20)
def JAL(rd, imm): return enc_j(0x6F, rd, imm)
def JALR(rd, rs1, imm): return enc_i(0x67, rd, 0x0, rs1, imm)


@dataclass
class Program:
    words: List[int]


class RV32ISim:
    def __init__(self, words: List[int], mem_words: int = 16384, pc_base: int = 0):
        self.reg = [0] * 32
        self.mem = [0] * mem_words
        self.imem = list(words)
        self.pc_base = pc_base & 0xFFFFFFFF
        self.pc = self.pc_base
        self.steps = 0
        self.max_steps = 10000

    def mem_read_word(self, addr: int) -> int:
        idx = (addr >> 2) & (len(self.mem) - 1)
        return self.mem[idx]

    def mem_write_word(self, addr: int, w: int, be: int):
        idx = (addr >> 2) & (len(self.mem) - 1)
        old = self.mem[idx]
        b0 = (w >> 0) & 0xFF
        b1 = (w >> 8) & 0xFF
        b2 = (w >> 16) & 0xFF
        b3 = (w >> 24) & 0xFF
        if be & 0x1:
            old = (old & ~0x000000FF) | b0
        if be & 0x2:
            old = (old & ~0x0000FF00) | (b1 << 8)
        if be & 0x4:
            old = (old & ~0x00FF0000) | (b2 << 16)
        if be & 0x8:
            old = (old & ~0xFF000000) | (b3 << 24)
        self.mem[idx] = u32(old)

    def load_val(self, funct3: int, addr: int) -> int:
        w = self.mem_read_word(addr)
        off = addr & 0x3
        if funct3 == 0x2:  # LW
            return w
        if funct3 == 0x0:  # LB
            b = (w >> (8 * off)) & 0xFF
            return u32(sign_extend(b, 8))
        if funct3 == 0x4:  # LBU
            return (w >> (8 * off)) & 0xFF
        if funct3 == 0x1:  # LH
            if (off & 0x1) == 0:
                h = (w >> (8 * off)) & 0xFFFF
            else:
                h = (w >> 16) & 0xFFFF
            return u32(sign_extend(h, 16))
        if funct3 == 0x5:  # LHU
            if (off & 0x1) == 0:
                return (w >> (8 * off)) & 0xFFFF
            return (w >> 16) & 0xFFFF
        raise ValueError(f"Unsupported load funct3={funct3}")

    def store_val(self, funct3: int, addr: int, rs2v: int):
        off = addr & 0x3
        if funct3 == 0x2:  # SW
            self.mem_write_word(addr, rs2v, 0xF)
            return
        if funct3 == 0x0:  # SB
            be = 1 << off
            w = (rs2v & 0xFF) << (8 * off)
            self.mem_write_word(addr, w, be)
            return
        if funct3 == 0x1:  # SH
            if (off & 0x2) == 0:
                be = 0x3
                w = rs2v & 0xFFFF
            else:
                be = 0xC
                w = (rs2v & 0xFFFF) << 16
            self.mem_write_word(addr, w, be)
            return
        raise ValueError(f"Unsupported store funct3={funct3}")

    def step(self) -> bool:
        if self.steps > self.max_steps:
            raise RuntimeError("simulation step overflow")
        self.steps += 1

        idx = (u32(self.pc - self.pc_base)) >> 2
        if idx >= len(self.imem):
            return False
        instr = self.imem[idx]

        opcode = instr & 0x7F
        rd = (instr >> 7) & 0x1F
        funct3 = (instr >> 12) & 0x7
        rs1 = (instr >> 15) & 0x1F
        rs2 = (instr >> 20) & 0x1F
        funct7 = (instr >> 25) & 0x7F

        rs1v = self.reg[rs1]
        rs2v = self.reg[rs2]
        npc = u32(self.pc + 4)

        def wr(xrd: int, val: int):
            if xrd != 0:
                self.reg[xrd] = u32(val)

        if opcode == 0x33:  # R
            if funct3 == 0x0:
                if funct7 == 0x20:
                    wr(rd, rs1v - rs2v)
                else:
                    wr(rd, rs1v + rs2v)
            elif funct3 == 0x1:
                wr(rd, rs1v << (rs2v & 0x1F))
            elif funct3 == 0x2:
                wr(rd, 1 if sign_extend(rs1v, 32) < sign_extend(rs2v, 32) else 0)
            elif funct3 == 0x3:
                wr(rd, 1 if u32(rs1v) < u32(rs2v) else 0)
            elif funct3 == 0x4:
                wr(rd, rs1v ^ rs2v)
            elif funct3 == 0x5:
                if funct7 == 0x20:
                    wr(rd, u32(sign_extend(rs1v, 32) >> (rs2v & 0x1F)))
                else:
                    wr(rd, u32(rs1v) >> (rs2v & 0x1F))
            elif funct3 == 0x6:
                wr(rd, rs1v | rs2v)
            elif funct3 == 0x7:
                wr(rd, rs1v & rs2v)
            else:
                raise ValueError("Unsupported R")

        elif opcode == 0x13:  # I-ALU
            imm = sign_extend(instr >> 20, 12)
            if funct3 == 0x0:
                wr(rd, rs1v + imm)
            elif funct3 == 0x2:
                wr(rd, 1 if sign_extend(rs1v, 32) < imm else 0)
            elif funct3 == 0x3:
                wr(rd, 1 if u32(rs1v) < u32(imm) else 0)
            elif funct3 == 0x4:
                wr(rd, rs1v ^ imm)
            elif funct3 == 0x6:
                wr(rd, rs1v | imm)
            elif funct3 == 0x7:
                wr(rd, rs1v & imm)
            elif funct3 == 0x1:
                wr(rd, rs1v << (imm & 0x1F))
            elif funct3 == 0x5:
                if (instr >> 30) & 0x1:
                    wr(rd, u32(sign_extend(rs1v, 32) >> (imm & 0x1F)))
                else:
                    wr(rd, u32(rs1v) >> (imm & 0x1F))
            else:
                raise ValueError("Unsupported I-ALU")

        elif opcode == 0x03:  # LOAD
            imm = sign_extend(instr >> 20, 12)
            addr = u32(rs1v + imm)
            wr(rd, self.load_val(funct3, addr))

        elif opcode == 0x23:  # STORE
            imm = ((instr >> 7) & 0x1F) | (((instr >> 25) & 0x7F) << 5)
            imm = sign_extend(imm, 12)
            addr = u32(rs1v + imm)
            self.store_val(funct3, addr, rs2v)

        elif opcode == 0x63:  # BRANCH
            imm = (((instr >> 31) & 0x1) << 12) | (((instr >> 7) & 0x1) << 11) | (((instr >> 25) & 0x3F) << 5) | (((instr >> 8) & 0xF) << 1)
            imm = sign_extend(imm, 13)
            take = False
            if funct3 == 0x0:
                take = (rs1v == rs2v)
            elif funct3 == 0x1:
                take = (rs1v != rs2v)
            elif funct3 == 0x4:
                take = sign_extend(rs1v, 32) < sign_extend(rs2v, 32)
            elif funct3 == 0x5:
                take = sign_extend(rs1v, 32) >= sign_extend(rs2v, 32)
            elif funct3 == 0x6:
                take = u32(rs1v) < u32(rs2v)
            elif funct3 == 0x7:
                take = u32(rs1v) >= u32(rs2v)
            else:
                raise ValueError("Unsupported branch")
            if take:
                npc = u32(self.pc + imm)

        elif opcode == 0x37:  # LUI
            wr(rd, instr & 0xFFFFF000)

        elif opcode == 0x17:  # AUIPC
            wr(rd, u32(self.pc + (instr & 0xFFFFF000)))

        elif opcode == 0x6F:  # JAL
            imm = (((instr >> 31) & 0x1) << 20) | (((instr >> 12) & 0xFF) << 12) | (((instr >> 20) & 0x1) << 11) | (((instr >> 21) & 0x3FF) << 1)
            imm = sign_extend(imm, 21)
            wr(rd, self.pc + 4)
            npc = u32(self.pc + imm)

        elif opcode == 0x67:  # JALR
            imm = sign_extend(instr >> 20, 12)
            tgt = u32((rs1v + imm) & ~1)
            wr(rd, self.pc + 4)
            npc = tgt

        elif opcode == 0x0F:  # FENCE
            pass

        elif opcode == 0x73:  # ECALL/EBREAK: treat as nop in this random test context
            pass

        else:
            raise ValueError(f"Unsupported opcode 0x{opcode:02x}")

        self.reg[0] = 0
        self.pc = npc
        return True

    def run_until_magic(self) -> bool:
        for _ in range(self.max_steps):
            if self.reg[31] == MAGIC:
                return True
            if not self.step():
                return False
        return False


def gen_random_program(rng: random.Random, body_len: int, mem_base: int = 0x1000) -> Program:
    words: List[int] = []

    # init base pointers and some seeds
    words.append(LUI(10, mem_base >> 12))      # x10 = memory base
    words.append(ADDI(11, 0, rng.randint(-16, 16)))
    words.append(ADDI(12, 0, rng.randint(-16, 16)))
    words.append(ADDI(13, 0, rng.randint(-16, 16)))

    regs_pool = [1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20]
    mem_offsets = [0, 4, 8, 12, 16, 20, 24, 28, 32, 36, 40, 44]

    alu_r = [ADD, SUB, SLL, SRL, SRA, SLT, SLTU, XOR, OR, AND]
    alu_i = [ADDI, SLTI, SLTIU, XORI, ORI, ANDI]
    shifts_i = [SLLI, SRLI, SRAI]
    branches = [BEQ, BNE, BLT, BGE, BLTU, BGEU]

    while len(words) < body_len:
        kind = rng.choice(["alu_r", "alu_i", "shift", "load", "store", "branch", "auipc"])

        if kind == "alu_r":
            f = rng.choice(alu_r)
            rd = rng.choice(regs_pool)
            rs1 = rng.choice(regs_pool)
            rs2 = rng.choice(regs_pool)
            words.append(f(rd, rs1, rs2))

        elif kind == "alu_i":
            f = rng.choice(alu_i)
            rd = rng.choice(regs_pool)
            rs1 = rng.choice(regs_pool)
            imm = rng.randint(-2048, 2047)
            words.append(f(rd, rs1, imm))

        elif kind == "shift":
            f = rng.choice(shifts_i)
            rd = rng.choice(regs_pool)
            rs1 = rng.choice(regs_pool)
            shamt = rng.randint(0, 31)
            words.append(f(rd, rs1, shamt))

        elif kind == "store":
            rs2 = rng.choice(regs_pool)
            off = rng.choice(mem_offsets)
            stype = rng.choice(["sb", "sh", "sw"])
            if stype == "sb":
                words.append(SB(rs2, 10, off))
            elif stype == "sh":
                words.append(SH(rs2, 10, off))
            else:
                words.append(SW(rs2, 10, off))

        elif kind == "load":
            rd = rng.choice(regs_pool)
            off = rng.choice(mem_offsets)
            ltype = rng.choice(["lb", "lbu", "lh", "lhu", "lw"])
            if ltype == "lb":
                words.append(LB(rd, 10, off))
            elif ltype == "lbu":
                words.append(LBU(rd, 10, off))
            elif ltype == "lh":
                words.append(LH(rd, 10, off))
            elif ltype == "lhu":
                words.append(LHU(rd, 10, off))
            else:
                words.append(LW(rd, 10, off))

        elif kind == "branch":
            # Keep control-flow local and finite: branch over exactly one instruction
            rs1 = rng.choice(regs_pool)
            rs2 = rng.choice(regs_pool)
            bf = rng.choice(branches)
            words.append(bf(rs1, rs2, 8))
            words.append(ADDI(rng.choice(regs_pool), rng.choice(regs_pool), rng.randint(-8, 8)))

        elif kind == "auipc":
            rd = rng.choice(regs_pool)
            words.append(AUIPC(rd, rng.randint(0, 0x7FF)))

    # deterministic epilogue to force PASS condition
    words.append(LUI(1, 0xCAFEC))
    words.append(ADDI(1, 1, 0xABE))
    words.append(ADD(31, 1, 0))
    words.append(JAL(0, 0))

    return Program(words)


def write_hex(path: str, words: List[int]):
    with open(path, "w", encoding="ascii") as f:
        for w in words:
            f.write(f"{w & 0xFFFFFFFF:08X}\n")


def main():
    ap = argparse.ArgumentParser(description="Generate random RV32I tests and self-validate with an ISA simulator")
    ap.add_argument("--out-dir", default="tb/programs/generated", help="output directory for generated .hex")
    ap.add_argument("--count", type=int, default=100, help="number of tests to generate")
    ap.add_argument("--seed", type=int, default=20260505, help="random seed")
    ap.add_argument("--min-body", type=int, default=20, help="min random body length")
    ap.add_argument("--max-body", type=int, default=40, help="max random body length")
    args = ap.parse_args()

    os.makedirs(args.out_dir, exist_ok=True)
    rng = random.Random(args.seed)

    passed = 0
    for i in range(args.count):
        body_len = rng.randint(args.min_body, args.max_body)
        prog = gen_random_program(rng, body_len=body_len)
        sim = RV32ISim(prog.words)
        ok = sim.run_until_magic()
        if not ok:
            raise RuntimeError(f"Generator internal sim failed at test {i}")
        out = os.path.join(args.out_dir, f"rv32_rand_{i:03d}.hex")
        write_hex(out, prog.words)
        passed += 1

    print(f"Generated {passed} tests under {args.out_dir}")


if __name__ == "__main__":
    main()
