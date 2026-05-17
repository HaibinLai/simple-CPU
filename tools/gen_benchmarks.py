#!/usr/bin/env python3
"""Hand-written RV32I performance kernels.

Each builder returns a list of 32-bit instruction words. Every kernel ends
with the standard PASS epilogue (x31 <- 0xCAFEBABE) so we reuse the existing
tb_cpu.v PASS detection.

Run:
    python3 tools/gen_benchmarks.py --out-dir tb/programs/bench
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


def append_epilogue(a: Asm) -> None:
    """x1 = 0xCAFEBABE; x31 = x1; spin forever."""
    a.li(1, 0xCAFEBABE)
    a.add(31, 1, 0)
    a.j("__halt")
    a.label("__halt")
    a.j("__halt")


def emit_mul_routine(a: Asm, label: str = "mul") -> None:
    """Software 32x32 -> 32 unsigned multiply, callable with `jal x1, mul`.

    Inputs:  x10 (a), x11 (b)
    Output:  x10 (a*b mod 2^32)
    Clobbers: x10, x11, x12, x13, x14
    """
    a.label(label)
    a.addi(13, 0, 0)        # acc = 0
    a.addi(12, 0, 32)       # ctr = 32
    a.label(label + "_loop")
    a.beq(12, 0, label + "_done")
    a.andi(14, 11, 1)
    a.beq(14, 0, label + "_skip")
    a.add(13, 13, 10)
    a.label(label + "_skip")
    a.slli(10, 10, 1)
    a.srli(11, 11, 1)
    a.addi(12, 12, -1)
    a.j(label + "_loop")
    a.label(label + "_done")
    a.add(10, 13, 0)
    a.ret()


# ---------- benchmarks ----------
def bench_fib(n: int = 20) -> List[int]:
    """Iterative Fibonacci(N), result kept in registers."""
    a = Asm()
    a.addi(5, 0, n)         # N
    a.addi(6, 0, 0)         # a
    a.addi(7, 0, 1)         # b
    a.addi(8, 0, 0)         # i
    a.label("loop")
    a.beq(8, 5, "end")
    a.add(9, 6, 7)
    a.add(6, 7, 0)
    a.add(7, 9, 0)
    a.addi(8, 8, 1)
    a.j("loop")
    a.label("end")
    append_epilogue(a)
    return a.assemble()


def bench_sum_1_to_n(n: int = 100) -> List[int]:
    """sum = 1+2+...+N."""
    a = Asm()
    a.addi(5, 0, n)
    a.addi(6, 0, 0)
    a.addi(7, 0, 1)
    a.label("loop")
    a.blt(5, 7, "end")
    a.add(6, 6, 7)
    a.addi(7, 7, 1)
    a.j("loop")
    a.label("end")
    append_epilogue(a)
    return a.assemble()


def bench_memcpy_words(n: int = 64) -> List[int]:
    """Copy n words from 0x1000 to 0x2000."""
    a = Asm()
    a.li(5, 0x1000)
    a.li(6, 0x2000)
    a.addi(7, 0, n)
    a.label("loop")
    a.beq(7, 0, "end")
    a.lw(8, 5, 0)
    a.sw(8, 6, 0)
    a.addi(5, 5, 4)
    a.addi(6, 6, 4)
    a.addi(7, 7, -1)
    a.j("loop")
    a.label("end")
    append_epilogue(a)
    return a.assemble()


def bench_popcount_loop(n: int = 64) -> List[int]:
    """Brian Kernighan popcount over 1..N."""
    a = Asm()
    a.addi(5, 0, n)
    a.addi(6, 0, 0)         # total
    a.addi(7, 0, 1)         # i
    a.label("outer")
    a.blt(5, 7, "outer_end")
    a.add(8, 7, 0)          # tmp = i
    a.label("inner")
    a.beq(8, 0, "inner_end")
    a.addi(9, 8, -1)
    a.and_(8, 8, 9)
    a.addi(6, 6, 1)
    a.j("inner")
    a.label("inner_end")
    a.addi(7, 7, 1)
    a.j("outer")
    a.label("outer_end")
    append_epilogue(a)
    return a.assemble()


def bench_matmul_4x4() -> List[int]:
    """Integer 4x4 matrix multiply C = A*B, with software multiply.

    Layout (each 16 words = 64 bytes): A@0x1000, B@0x1100, C@0x1200.
    Stresses triple-nested loops, strided LW/SW, plus a long shift+add
    multiply chain inside the innermost loop.
    """
    a = Asm()
    A_BASE, B_BASE, C_BASE = 0x1000, 0x1100, 0x1200

    # init A[i] = i+1
    a.li(20, A_BASE)
    a.addi(21, 0, 0)
    a.addi(22, 0, 1)
    a.addi(23, 0, 16)
    a.label("init_A")
    a.beq(21, 23, "init_A_end")
    a.sw(22, 20, 0)
    a.addi(20, 20, 4)
    a.addi(21, 21, 1)
    a.addi(22, 22, 1)
    a.j("init_A")
    a.label("init_A_end")

    # init B[i] = 16-i
    a.li(20, B_BASE)
    a.addi(21, 0, 0)
    a.addi(22, 0, 16)
    a.label("init_B")
    a.beq(21, 23, "init_B_end")
    a.sw(22, 20, 0)
    a.addi(20, 20, 4)
    a.addi(21, 21, 1)
    a.addi(22, 22, -1)
    a.j("init_B")
    a.label("init_B_end")

    # main loop
    a.addi(28, 0, 4)            # constant 4
    a.addi(5, 0, 0)             # i
    a.label("i_loop")
    a.beq(5, 28, "i_loop_end")
    a.addi(6, 0, 0)             # j
    a.label("j_loop")
    a.beq(6, 28, "j_loop_end")
    a.addi(7, 0, 0)             # k
    a.addi(8, 0, 0)             # accum
    a.label("k_loop")
    a.beq(7, 28, "k_loop_end")
    # &A[i*4 + k]
    a.slli(15, 5, 4)
    a.slli(16, 7, 2)
    a.add(15, 15, 16)
    a.li(17, A_BASE)
    a.add(15, 17, 15)
    a.lw(18, 15, 0)
    # &B[k*4 + j]
    a.slli(15, 7, 4)
    a.slli(16, 6, 2)
    a.add(15, 15, 16)
    a.li(17, B_BASE)
    a.add(15, 17, 15)
    a.lw(19, 15, 0)
    # x10 = a, x11 = b ; jal mul -> x10 = a*b
    a.add(10, 18, 0)
    a.add(11, 19, 0)
    a.jal(1, "mul")
    a.add(8, 8, 10)
    a.addi(7, 7, 1)
    a.j("k_loop")
    a.label("k_loop_end")
    # store C[i*4 + j]
    a.slli(15, 5, 4)
    a.slli(16, 6, 2)
    a.add(15, 15, 16)
    a.li(17, C_BASE)
    a.add(15, 17, 15)
    a.sw(8, 15, 0)
    a.addi(6, 6, 1)
    a.j("j_loop")
    a.label("j_loop_end")
    a.addi(5, 5, 1)
    a.j("i_loop")
    a.label("i_loop_end")
    a.j("done")

    emit_mul_routine(a, "mul")
    a.label("done")
    append_epilogue(a)
    return a.assemble()


def bench_bsort_16() -> List[int]:
    """Bubble-sort 16 ints @ 0x1000 (initially reverse-sorted)."""
    a = Asm()
    BASE = 0x1000
    N = 16

    a.li(20, BASE)
    a.addi(21, 0, 0)
    a.addi(22, 0, N - 1)
    a.addi(23, 0, N)
    a.label("init")
    a.beq(21, 23, "init_end")
    a.sw(22, 20, 0)
    a.addi(20, 20, 4)
    a.addi(21, 21, 1)
    a.addi(22, 22, -1)
    a.j("init")
    a.label("init_end")

    a.addi(5, 0, N)             # n
    a.addi(6, 0, 0)             # i
    a.label("outer")
    a.bge(6, 5, "outer_end")
    a.addi(7, 0, 0)             # j
    a.sub(8, 5, 6)
    a.addi(8, 8, -1)            # n - i - 1
    a.label("inner")
    a.bge(7, 8, "inner_end")
    a.slli(9, 7, 2)
    a.li(10, BASE)
    a.add(9, 10, 9)
    a.lw(11, 9, 0)
    a.lw(12, 9, 4)
    a.bge(12, 11, "no_swap")
    a.sw(12, 9, 0)
    a.sw(11, 9, 4)
    a.label("no_swap")
    a.addi(7, 7, 1)
    a.j("inner")
    a.label("inner_end")
    a.addi(6, 6, 1)
    a.j("outer")
    a.label("outer_end")
    append_epilogue(a)
    return a.assemble()


def bench_crc32_64b() -> List[int]:
    """CRC32 (poly 0xEDB88320) over a 64-byte buffer @ 0x1000."""
    a = Asm()
    BASE = 0x1000
    NBYTES = 64

    # init buffer: bytes 0,1,2,...,63 packed into 16 words
    a.li(20, BASE)
    a.addi(21, 0, 0)
    a.addi(22, 0, NBYTES // 4)
    a.label("buf_loop")
    a.beq(21, 22, "buf_end")
    a.slli(23, 21, 2)
    a.add(24, 23, 0)
    a.addi(25, 23, 1)
    a.slli(25, 25, 8)
    a.or_(24, 24, 25)
    a.addi(25, 23, 2)
    a.slli(25, 25, 16)
    a.or_(24, 24, 25)
    a.addi(25, 23, 3)
    a.slli(25, 25, 24)
    a.or_(24, 24, 25)
    a.sw(24, 20, 0)
    a.addi(20, 20, 4)
    a.addi(21, 21, 1)
    a.j("buf_loop")
    a.label("buf_end")

    a.addi(5, 0, -1)            # crc = 0xFFFFFFFF
    a.li(6, BASE)
    a.addi(7, 0, NBYTES)
    a.li(8, 0xEDB88320)         # poly

    a.label("byte_loop")
    a.beq(7, 0, "byte_end")
    a.lbu(9, 6, 0)
    a.xor_(5, 5, 9)
    a.addi(10, 0, 8)
    a.label("bit_loop")
    a.beq(10, 0, "bit_end")
    a.andi(11, 5, 1)
    a.srli(5, 5, 1)
    a.beq(11, 0, "no_xor")
    a.xor_(5, 5, 8)
    a.label("no_xor")
    a.addi(10, 10, -1)
    a.j("bit_loop")
    a.label("bit_end")
    a.addi(6, 6, 1)
    a.addi(7, 7, -1)
    a.j("byte_loop")
    a.label("byte_end")
    append_epilogue(a)
    return a.assemble()


def bench_bsearch_64() -> List[int]:
    """Binary-search 6 keys against a sorted array of 64 ints @ 0x1000.

    Sorted A[i] = i*3 (so values 0,3,...,189). Keys: 0,9,30,99,189,200.
    Heavy on data-dependent branches the BHT cannot easily predict.
    """
    a = Asm()
    BASE = 0x1000
    N = 64
    KEYS = [0, 9, 30, 99, 189, 200]

    # init A[i] = i*3
    a.li(20, BASE)
    a.addi(21, 0, 0)
    a.addi(22, 0, N)
    a.addi(23, 0, 0)
    a.label("init")
    a.beq(21, 22, "init_end")
    a.sw(23, 20, 0)
    a.addi(20, 20, 4)
    a.addi(23, 23, 3)
    a.addi(21, 21, 1)
    a.j("init")
    a.label("init_end")

    # store keys at 0x2000
    a.li(20, 0x2000)
    for idx, k in enumerate(KEYS):
        a.li(21, k)
        a.sw(21, 20, idx * 4)

    a.addi(9, 0, 0)             # hit count
    a.li(15, 0x2000)
    a.addi(16, 0, 0)            # key idx
    a.addi(17, 0, len(KEYS))

    a.label("k_outer")
    a.beq(16, 17, "k_outer_end")
    a.slli(18, 16, 2)
    a.add(18, 15, 18)
    a.lw(19, 18, 0)             # key

    a.addi(5, 0, 0)             # lo
    a.addi(6, 0, N)             # hi
    a.label("bs")
    a.bge(5, 6, "bs_done")
    a.add(7, 5, 6)
    a.srli(7, 7, 1)             # mid
    a.slli(8, 7, 2)
    a.li(10, BASE)
    a.add(8, 10, 8)
    a.lw(11, 8, 0)
    a.beq(11, 19, "bs_hit")
    a.blt(11, 19, "bs_right")
    a.add(6, 7, 0)
    a.j("bs")
    a.label("bs_right")
    a.addi(5, 7, 1)
    a.j("bs")
    a.label("bs_hit")
    a.addi(9, 9, 1)
    a.label("bs_done")
    a.addi(16, 16, 1)
    a.j("k_outer")
    a.label("k_outer_end")
    append_epilogue(a)
    return a.assemble()


def bench_dotprod_32() -> List[int]:
    """sum_{i=0..31} A[i]*B[i] with software multiply."""
    a = Asm()
    A_BASE, B_BASE, N = 0x1000, 0x1100, 32

    a.li(20, A_BASE)
    a.li(24, B_BASE)
    a.addi(21, 0, 0)
    a.addi(22, 0, 1)            # A value
    a.addi(25, 0, N)            # B value
    a.addi(26, 0, N)
    a.label("init")
    a.beq(21, 26, "init_end")
    a.sw(22, 20, 0)
    a.sw(25, 24, 0)
    a.addi(20, 20, 4)
    a.addi(24, 24, 4)
    a.addi(22, 22, 1)
    a.addi(25, 25, -1)
    a.addi(21, 21, 1)
    a.j("init")
    a.label("init_end")

    a.addi(5, 0, 0)             # i
    a.addi(6, 0, N)
    a.addi(8, 0, 0)             # acc
    a.li(15, A_BASE)
    a.li(16, B_BASE)
    a.label("loop")
    a.beq(5, 6, "loop_end")
    a.slli(17, 5, 2)
    a.add(18, 15, 17)
    a.add(19, 16, 17)
    a.lw(10, 18, 0)
    a.lw(11, 19, 0)
    a.jal(1, "mul")
    a.add(8, 8, 10)
    a.addi(5, 5, 1)
    a.j("loop")
    a.label("loop_end")
    a.j("done")

    emit_mul_routine(a, "mul")
    a.label("done")
    append_epilogue(a)
    return a.assemble()


# ============ Standard-like benchmarks ============

def bench_dhrystone_lite(n_iter: int = 20) -> List[int]:
    """Simplified Dhrystone: string compare/copy, struct copy, function calls,
    enum-like branching, and integer ALU — the classic Dhrystone workload mix.
    """
    a = Asm()
    SP = 2

    a.li(SP, 0x3F00)

    # --- init string1 @ 0x1000: "Hello, World!\0\0\0" ---
    a.li(20, 0x1000)
    a.li(21, 0x6C6C6548); a.sw(21, 20, 0)    # "Hell"
    a.li(21, 0x57202C6F); a.sw(21, 20, 4)    # "o, W"
    a.li(21, 0x646C726F); a.sw(21, 20, 8)    # "orld"
    a.addi(21, 0, 0x21);  a.sw(21, 20, 12)   # "!\0\0\0"

    # --- init string2 @ 0x1010: identical ---
    a.li(20, 0x1010)
    a.li(21, 0x6C6C6548); a.sw(21, 20, 0)
    a.li(21, 0x57202C6F); a.sw(21, 20, 4)
    a.li(21, 0x646C726F); a.sw(21, 20, 8)
    a.addi(21, 0, 0x21);  a.sw(21, 20, 12)

    # --- init string3 @ 0x1020: "Hello, Vorld!" (V vs W at byte 7) ---
    a.li(20, 0x1020)
    a.li(21, 0x6C6C6548); a.sw(21, 20, 0)
    a.li(21, 0x56202C6F); a.sw(21, 20, 4)    # "o, V"
    a.li(21, 0x646C726F); a.sw(21, 20, 8)
    a.addi(21, 0, 0x21);  a.sw(21, 20, 12)

    # --- init record1 @ 0x1040: 8 words ---
    a.li(20, 0x1040)
    for i in range(8):
        a.li(21, ((i + 1) * 0x11111111) & 0xFFFFFFFF)
        a.sw(21, 20, i * 4)

    # --- main loop ---
    a.addi(3, 0, n_iter)
    a.addi(4, 0, 0)

    a.label("dh_main")
    a.beq(3, 0, "dh_done")

    # 1. strcmp(str1, str2, 16) → 0
    a.li(10, 0x1000); a.li(11, 0x1010); a.addi(12, 0, 16)
    a.addi(SP, SP, -4); a.sw(1, SP, 0)
    a.jal(1, "dh_strcmp")
    a.lw(1, SP, 0); a.addi(SP, SP, 4)
    a.add(4, 4, 10)

    # 2. strcmp(str1, str3, 16) → nonzero
    a.li(10, 0x1000); a.li(11, 0x1020); a.addi(12, 0, 16)
    a.addi(SP, SP, -4); a.sw(1, SP, 0)
    a.jal(1, "dh_strcmp")
    a.lw(1, SP, 0); a.addi(SP, SP, 4)
    a.add(4, 4, 10)

    # 3. memcpy record1→record2 (8 words)
    a.li(10, 0x1060); a.li(11, 0x1040); a.addi(12, 0, 8)
    a.addi(SP, SP, -4); a.sw(1, SP, 0)
    a.jal(1, "dh_mcpyw")
    a.lw(1, SP, 0); a.addi(SP, SP, 4)

    # 4. enum_proc
    a.add(10, 3, 0)
    a.addi(SP, SP, -4); a.sw(1, SP, 0)
    a.jal(1, "dh_enum")
    a.lw(1, SP, 0); a.addi(SP, SP, 4)
    a.add(4, 4, 10)

    # 5. int_compute
    a.add(10, 3, 4)
    a.addi(SP, SP, -4); a.sw(1, SP, 0)
    a.jal(1, "dh_intcalc")
    a.lw(1, SP, 0); a.addi(SP, SP, 4)
    a.add(4, 4, 10)

    a.addi(3, 3, -1)
    a.j("dh_main")
    a.label("dh_done")
    a.j("dh_epi")

    # === subroutines ===

    # strcmp: [x10] vs [x11] for x12 bytes → x10 = 0 (equal) or diff
    a.label("dh_strcmp")
    a.label("dh_scl")
    a.beq(12, 0, "dh_seq")
    a.lbu(13, 10, 0)
    a.lbu(14, 11, 0)
    a.bne(13, 14, "dh_sneq")
    a.addi(10, 10, 1)
    a.addi(11, 11, 1)
    a.addi(12, 12, -1)
    a.j("dh_scl")
    a.label("dh_seq")
    a.addi(10, 0, 0)
    a.ret()
    a.label("dh_sneq")
    a.sub(10, 13, 14)
    a.ret()

    # memcpy_w: copy x12 words from [x11] to [x10]
    a.label("dh_mcpyw")
    a.label("dh_mcl")
    a.beq(12, 0, "dh_mcd")
    a.lw(13, 11, 0)
    a.sw(13, 10, 0)
    a.addi(10, 10, 4)
    a.addi(11, 11, 4)
    a.addi(12, 12, -1)
    a.j("dh_mcl")
    a.label("dh_mcd")
    a.ret()

    # enum_proc: x10 mod 3 → switch
    a.label("dh_enum")
    a.addi(13, 0, 3)
    a.label("dh_eml")
    a.blt(10, 13, "dh_emd")
    a.sub(10, 10, 13)
    a.j("dh_eml")
    a.label("dh_emd")
    a.beq(10, 0, "dh_ec0")
    a.addi(14, 0, 1)
    a.beq(10, 14, "dh_ec1")
    a.addi(10, 0, 42)
    a.ret()
    a.label("dh_ec0")
    a.addi(10, 0, 7)
    a.ret()
    a.label("dh_ec1")
    a.addi(10, 0, 19)
    a.ret()

    # int_compute: ALU-heavy
    a.label("dh_intcalc")
    a.slli(13, 10, 3)
    a.add(13, 13, 10)
    a.xori(14, 13, 0x55)
    a.srai(15, 14, 2)
    a.add(10, 14, 15)
    a.andi(10, 10, 0xFF)
    a.ret()

    a.label("dh_epi")
    append_epilogue(a)
    return a.assemble()


def bench_coremark_lite() -> List[int]:
    """CoreMark-like: linked list build/traverse/search + state machine + CRC16."""
    a = Asm()
    NODE_BASE = 0x1000
    INPUT_BASE = 0x1100
    N_NODES = 16
    N_INPUT = 32

    # ---- Part 1: build linked list (16 nodes × 8 bytes: {next, value}) ----
    a.li(20, NODE_BASE)
    a.addi(5, 0, 0)
    a.addi(6, 0, N_NODES)
    a.addi(7, 0, N_NODES - 1)

    a.label("cm_bld")
    a.beq(5, 6, "cm_bld_done")
    a.slli(8, 5, 3)
    a.add(9, 20, 8)          # &node[i]
    a.addi(10, 5, 1)
    a.sw(10, 9, 4)            # value = i+1
    a.beq(5, 7, "cm_last")
    a.addi(11, 9, 8)
    a.sw(11, 9, 0)            # next = &node[i+1]
    a.j("cm_bld_next")
    a.label("cm_last")
    a.sw(0, 9, 0)             # next = NULL
    a.label("cm_bld_next")
    a.addi(5, 5, 1)
    a.j("cm_bld")
    a.label("cm_bld_done")

    # traverse: sum all values
    a.li(5, NODE_BASE)
    a.addi(6, 0, 0)
    a.label("cm_trav")
    a.beq(5, 0, "cm_trav_done")
    a.lw(7, 5, 4)
    a.add(6, 6, 7)
    a.lw(5, 5, 0)
    a.j("cm_trav")
    a.label("cm_trav_done")

    # search: find value == 10
    a.li(5, NODE_BASE)
    a.addi(8, 0, 10)
    a.addi(9, 0, 0)
    a.label("cm_srch")
    a.beq(5, 0, "cm_srch_done")
    a.lw(7, 5, 4)
    a.bne(7, 8, "cm_srch_next")
    a.addi(9, 0, 1)
    a.j("cm_srch_done")
    a.label("cm_srch_next")
    a.lw(5, 5, 0)
    a.j("cm_srch")
    a.label("cm_srch_done")
    a.add(6, 6, 9)

    # count nodes with value > 8
    a.li(5, NODE_BASE)
    a.addi(8, 0, 8)
    a.addi(9, 0, 0)
    a.label("cm_cnt")
    a.beq(5, 0, "cm_cnt_done")
    a.lw(7, 5, 4)
    a.bge(8, 7, "cm_cnt_skip")   # threshold >= value → skip
    a.addi(9, 9, 1)
    a.label("cm_cnt_skip")
    a.lw(5, 5, 0)
    a.j("cm_cnt")
    a.label("cm_cnt_done")
    a.add(6, 6, 9)

    # ---- Part 2: state machine (32 input bytes) ----
    a.li(20, INPUT_BASE)
    for i in range(8):
        val = 0
        for j in range(4):
            b = ((i * 4 + j) * 7 + 3) & 0xFF
            val |= b << (j * 8)
        a.li(21, val)
        a.sw(21, 20, i * 4)

    a.addi(5, 0, 0)           # state
    a.li(10, INPUT_BASE)
    a.addi(11, 0, N_INPUT)
    a.addi(15, 0, 0)          # transition count

    a.label("cm_fsm")
    a.beq(11, 0, "cm_fsm_done")
    a.lbu(12, 10, 0)
    a.andi(12, 12, 3)
    a.add(13, 5, 12)
    a.addi(13, 13, 1)
    a.andi(5, 13, 3)
    a.addi(15, 15, 1)
    a.addi(10, 10, 1)
    a.addi(11, 11, -1)
    a.j("cm_fsm")
    a.label("cm_fsm_done")
    a.add(6, 6, 5)
    a.add(6, 6, 15)

    # ---- Part 3: CRC16-CCITT over 32 bytes ----
    a.li(10, INPUT_BASE)
    a.addi(11, 0, N_INPUT)
    a.li(5, 0xFFFF)
    a.li(8, 0x1021)
    a.li(28, 0x8000)
    a.li(29, 0xFFFF)

    a.label("cm_crc_byte")
    a.beq(11, 0, "cm_crc_done")
    a.lbu(9, 10, 0)
    a.slli(9, 9, 8)
    a.xor_(5, 5, 9)
    a.addi(12, 0, 8)

    a.label("cm_crc_bit")
    a.beq(12, 0, "cm_crc_nb")
    a.and_(14, 5, 28)
    a.slli(5, 5, 1)
    a.beq(14, 0, "cm_crc_nx")
    a.xor_(5, 5, 8)
    a.label("cm_crc_nx")
    a.and_(5, 5, 29)
    a.addi(12, 12, -1)
    a.j("cm_crc_bit")
    a.label("cm_crc_nb")
    a.addi(10, 10, 1)
    a.addi(11, 11, -1)
    a.j("cm_crc_byte")
    a.label("cm_crc_done")
    a.add(6, 6, 5)

    append_epilogue(a)
    return a.assemble()


def bench_sieve_256() -> List[int]:
    """Sieve of Eratosthenes: find all primes up to 256."""
    a = Asm()
    BASE = 0x1000
    N = 256

    # init: all bytes = 1
    a.li(20, BASE)
    a.addi(5, 0, 0)
    a.li(6, N)
    a.addi(7, 0, 1)
    a.label("sv_init")
    a.beq(5, 6, "sv_init_done")
    a.sb(7, 20, 0)
    a.addi(20, 20, 1)
    a.addi(5, 5, 1)
    a.j("sv_init")
    a.label("sv_init_done")

    # mark 0, 1 as not prime
    a.li(20, BASE)
    a.sb(0, 20, 0)
    a.sb(0, 20, 1)

    # sieve
    a.li(30, BASE)
    a.addi(5, 0, 2)
    a.addi(6, 0, 16)          # sqrt(256)
    a.li(28, N)

    a.label("sv_outer")
    a.bge(5, 6, "sv_outer_done")
    a.add(20, 30, 5)
    a.lbu(21, 20, 0)
    a.beq(21, 0, "sv_skip")
    a.add(7, 5, 5)             # j = 2*i

    a.label("sv_inner")
    a.bge(7, 28, "sv_inner_done")
    a.add(20, 30, 7)
    a.sb(0, 20, 0)
    a.add(7, 7, 5)
    a.j("sv_inner")
    a.label("sv_inner_done")

    a.label("sv_skip")
    a.addi(5, 5, 1)
    a.j("sv_outer")
    a.label("sv_outer_done")

    # count primes
    a.addi(5, 0, 0)
    a.addi(8, 0, 2)
    a.label("sv_count")
    a.bge(8, 28, "sv_count_done")
    a.add(20, 30, 8)
    a.lbu(21, 20, 0)
    a.beq(21, 0, "sv_cnt_skip")
    a.addi(5, 5, 1)
    a.label("sv_cnt_skip")
    a.addi(8, 8, 1)
    a.j("sv_count")
    a.label("sv_count_done")

    append_epilogue(a)
    return a.assemble()


def bench_qsort_32() -> List[int]:
    """Iterative quicksort of 32 integers (Lomuto partition, explicit stack)."""
    a = Asm()
    ARR_BASE = 0x1000
    STK_BASE = 0x1200
    N = 32

    a.li(30, ARR_BASE)

    # init: reverse sorted [31, 30, ..., 0]
    a.addi(5, 0, 0)
    a.addi(6, 0, N)
    a.addi(7, 0, N - 1)
    a.label("qs_init")
    a.beq(5, 6, "qs_init_done")
    a.slli(8, 5, 2)
    a.add(8, 30, 8)
    a.sw(7, 8, 0)
    a.addi(5, 5, 1)
    a.addi(7, 7, -1)
    a.j("qs_init")
    a.label("qs_init_done")

    # push (0, N-1)
    a.li(2, STK_BASE)
    a.sw(0, 2, 0)
    a.addi(5, 0, N - 1)
    a.sw(5, 2, 4)
    a.addi(2, 2, 8)

    a.label("qs_loop")
    a.li(20, STK_BASE)
    a.beq(2, 20, "qs_done")

    a.addi(2, 2, -8)
    a.lw(3, 2, 0)             # lo
    a.lw(4, 2, 4)             # hi
    a.bge(3, 4, "qs_loop")

    # partition: pivot = arr[hi]
    a.slli(8, 4, 2)
    a.add(8, 30, 8)
    a.lw(5, 8, 0)             # pivot

    a.addi(6, 3, -1)          # i = lo - 1
    a.add(7, 3, 0)            # j = lo

    a.label("qs_part")
    a.bge(7, 4, "qs_part_done")
    a.slli(8, 7, 2)
    a.add(8, 30, 8)
    a.lw(9, 8, 0)             # arr[j]
    a.blt(5, 9, "qs_part_skip")   # pivot < arr[j] → skip

    # i++; swap arr[i], arr[j]
    a.addi(6, 6, 1)
    a.slli(10, 6, 2)
    a.add(10, 30, 10)
    a.lw(11, 10, 0)           # arr[i]
    a.sw(9, 10, 0)            # arr[i] = arr[j]
    a.sw(11, 8, 0)            # arr[j] = old arr[i]

    a.label("qs_part_skip")
    a.addi(7, 7, 1)
    a.j("qs_part")
    a.label("qs_part_done")

    # swap arr[i+1] and arr[hi]
    a.addi(12, 6, 1)          # pivot_pos
    a.slli(10, 12, 2)
    a.add(10, 30, 10)
    a.lw(11, 10, 0)
    a.slli(13, 4, 2)
    a.add(13, 30, 13)
    a.lw(14, 13, 0)
    a.sw(14, 10, 0)
    a.sw(11, 13, 0)

    # push right (pivot_pos+1, hi), then left (lo, pivot_pos-1)
    a.addi(15, 12, 1)
    a.sw(15, 2, 0)
    a.sw(4, 2, 4)
    a.addi(2, 2, 8)

    a.addi(16, 12, -1)
    a.sw(3, 2, 0)
    a.sw(16, 2, 4)
    a.addi(2, 2, 8)

    a.j("qs_loop")
    a.label("qs_done")

    append_epilogue(a)
    return a.assemble()


def bench_lfsr_256() -> List[int]:
    """Galois LFSR (16-bit) for 256 steps — heavy shifts & XOR."""
    a = Asm()

    a.li(5, 0xACE1)           # seed
    a.li(6, 0xB400)           # taps
    a.li(28, 0xFFFF)          # mask
    a.addi(7, 0, 0)           # accumulator
    a.addi(8, 0, 0)           # i
    a.li(9, 256)              # N

    a.label("lfsr_loop")
    a.beq(8, 9, "lfsr_done")

    a.andi(10, 5, 1)          # lsb
    a.sub(11, 0, 10)          # -lsb (0 or 0xFFFFFFFF)
    a.and_(11, 11, 6)         # feedback
    a.srli(5, 5, 1)
    a.xor_(5, 5, 11)
    a.and_(5, 5, 28)          # keep 16 bits

    a.xor_(7, 7, 5)

    a.addi(8, 8, 1)
    a.j("lfsr_loop")
    a.label("lfsr_done")

    append_epilogue(a)
    return a.assemble()


def bench_hello_uart() -> List[int]:
    """Hello World via MMIO UART — prints 'Hello, CPU!\\n' then PASS."""
    a = Asm()
    msg = "Hello, CPU!\n"

    # Store message string at 0x1000
    a.li(20, 0x1000)
    # Pack string into words (little-endian)
    msg_bytes = msg.encode("ascii") + b"\x00"
    # Pad to word boundary
    while len(msg_bytes) % 4 != 0:
        msg_bytes += b"\x00"
    for i in range(0, len(msg_bytes), 4):
        w = (msg_bytes[i]
             | (msg_bytes[i+1] << 8)
             | (msg_bytes[i+2] << 16)
             | (msg_bytes[i+3] << 24))
        a.li(21, w)
        a.sw(21, 20, i)

    # Print via puts helper
    a.li(10, 0x1000)
    a.puts(10)

    append_epilogue(a)
    return a.assemble()


BENCHMARKS: Dict[str, Callable[[], List[int]]] = {
    "fib_20":          lambda: bench_fib(20),
    "sum_1_to_100":    lambda: bench_sum_1_to_n(100),
    "memcpy_64w":      lambda: bench_memcpy_words(64),
    "popcount_64":     lambda: bench_popcount_loop(64),
    "matmul_4x4":      bench_matmul_4x4,
    "bsort_16":        bench_bsort_16,
    "crc32_64b":       bench_crc32_64b,
    "bsearch_64":      bench_bsearch_64,
    "dotprod_32":      bench_dotprod_32,
    "dhrystone_lite":  lambda: bench_dhrystone_lite(20),
    "coremark_lite":   bench_coremark_lite,
    "sieve_256":       bench_sieve_256,
    "qsort_32":        bench_qsort_32,
    "lfsr_256":        bench_lfsr_256,
    "hello_uart":      bench_hello_uart,
}


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out-dir", default="tb/programs/bench")
    ap.add_argument("--list", action="store_true", help="list available benchmarks")
    args = ap.parse_args()

    if args.list:
        for name in BENCHMARKS:
            print(name)
        return

    os.makedirs(args.out_dir, exist_ok=True)
    for name, builder in BENCHMARKS.items():
        words = builder()
        path = os.path.join(args.out_dir, f"{name}.hex")
        write_hex(path, words)
        print(f"  wrote {path}  ({len(words)} words)")


if __name__ == "__main__":
    main()
