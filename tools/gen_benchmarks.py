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
