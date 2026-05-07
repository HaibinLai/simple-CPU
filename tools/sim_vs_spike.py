#!/usr/bin/env python3
"""Cross-check tools/gen_rv32_tests.py:RV32ISim against spike.

Pipeline per .hex program:
  1. Read raw 32-bit words from the .hex (one hex word per line).
  2. Patch any "LUI x10, 0x1" header (the gen_rv32_tests random data
     base = 0x1000) into "LUI x10, 0x80100" so the data area is above
     spike's reserved boot-ROM / CLINT region.
  3. Run the (patched) words on RV32ISim until x31 == 0xCAFEBABE or
     the step budget is exhausted; remember step count and final regs.
  4. Wrap the same words into a minimal RV32 ELF with entry=0x80000000.
  5. Drive spike in interactive debug mode: step exactly the same
     number of instructions, dump all 32 architectural registers,
     compare.

This treats spike (riscv-isa-sim, ratified RV32I reference) as the
golden model, so any discrepancy is a real RV32ISim bug.
"""
import argparse
import os
import re
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
from gen_rv32_tests import RV32ISim, MAGIC, LUI  # type: ignore


CODE_BASE = 0x80000000
DATA_BASE = 0x80100000   # patched mem_base for random tests


def load_hex(path: Path) -> list[int]:
    out = []
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("//") or line.startswith("@"):
            continue
        out.append(int(line, 16) & 0xFFFFFFFF)
    return out


def patch_data_base(words: list[int]) -> list[int]:
    """If word[0] is `LUI x10, 0x1` (gen_rv32_tests pattern), relocate to
    DATA_BASE so the program's data area doesn't collide with spike's
    boot ROM / CLINT below 0x80000000."""
    if not words:
        return words
    target = LUI(10, 0x1)  # LUI x10, 0x1  -> x10 = 0x00001000
    if words[0] == target:
        words = list(words)
        words[0] = LUI(10, DATA_BASE >> 12)
    return words


# ---------- minimal RV32 ELF wrapper ----------
def build_elf(words: list[int], mem_size: int = 0x200000) -> bytes:
    """Pack `words` (the .text) into a tiny RV32 ELF.

    Layout:
        ehdr (52) | phdr (32) | text bytes
    Single PT_LOAD covering [CODE_BASE, CODE_BASE + mem_size) so spike's
    loader allocates enough memory for both code and the program's data
    area at DATA_BASE.
    """
    EHDR_SIZE = 52
    PHDR_SIZE = 32
    SHDR_SIZE = 40
    text = b"".join(struct.pack("<I", w) for w in words)
    code_filesz = len(text)
    code_memsz = mem_size  # cover .text + far-away data area
    p_offset = EHDR_SIZE + PHDR_SIZE
    # Tiny string table containing just a single NUL byte; needed so
    # spike's load_elf accepts the shstrtab.
    strtab = b"\x00"
    strtab_offset = p_offset + code_filesz
    sh_offset = strtab_offset + len(strtab)

    e_ident = bytes([0x7F, ord('E'), ord('L'), ord('F'),
                     1,    # EI_CLASS = ELFCLASS32
                     1,    # EI_DATA  = ELFDATA2LSB
                     1,    # EI_VERSION
                     0,    # EI_OSABI
                     0]) + b"\x00" * 7

    ehdr = e_ident + struct.pack("<HHIIIIIHHHHHH",
        2,            # e_type = ET_EXEC
        0xF3,         # e_machine = EM_RISCV
        1,            # e_version
        CODE_BASE,    # e_entry
        EHDR_SIZE,    # e_phoff
        sh_offset,    # e_shoff
        0,            # e_flags
        EHDR_SIZE,    # e_ehsize
        PHDR_SIZE,    # e_phentsize
        1,            # e_phnum
        SHDR_SIZE,    # e_shentsize
        2,            # e_shnum (NULL + .shstrtab)
        1,            # e_shstrndx -> .shstrtab
    )

    phdr = struct.pack("<IIIIIIII",
        1,            # p_type = PT_LOAD
        p_offset,     # p_offset
        CODE_BASE,    # p_vaddr
        CODE_BASE,    # p_paddr
        code_filesz,  # p_filesz
        code_memsz,   # p_memsz
        7,            # p_flags = R|W|X
        0x1000,       # p_align
    )

    # Section 0: SHT_NULL (all zero)
    sh_null = b"\x00" * SHDR_SIZE
    # Section 1: SHT_STRTAB ("\0")
    sh_strtab = struct.pack("<IIIIIIIIII",
        0,                # sh_name
        3,                # sh_type = SHT_STRTAB
        0,                # sh_flags
        0,                # sh_addr
        strtab_offset,    # sh_offset
        len(strtab),      # sh_size
        0,                # sh_link
        0,                # sh_info
        1,                # sh_addralign
        0,                # sh_entsize
    )

    return ehdr + phdr + text + strtab + sh_null + sh_strtab


# ---------- python sim ----------
def run_python(words: list[int], step_budget: int):
    """Run RV32ISim with PC rebased at CODE_BASE so AUIPC / JAL link
    values match spike. Also seed the registers spike's boot ROM leaves
    behind before jumping to the entry:
        t0 (x5)  = entry  (boot ROM does `lw t0, ENTRY; jr t0`)
        a0 (x10) = mhartid = 0
        a1 (x11) = DTB pointer (0x1020 in spike's default boot ROM)
    Returns (final regs, steps_executed, hit_magic)."""
    sim = RV32ISim(words, mem_words=1 << 18, pc_base=CODE_BASE)
    sim.max_steps = step_budget
    sim.reg[5]  = CODE_BASE
    sim.reg[10] = 0
    sim.reg[11] = 0x1020
    steps = 0
    for _ in range(step_budget):
        if sim.reg[31] == MAGIC:
            break
        if not sim.step():
            break
        steps += 1
    return list(sim.reg), steps, sim.reg[31] == MAGIC


# Spike's "reg <core>" output uses ABI register names. Map back to
# architectural index 0..31.
ABI_TO_X = {
    "zero": 0, "ra": 1, "sp": 2, "gp": 3, "tp": 4,
    "t0": 5, "t1": 6, "t2": 7,
    "s0": 8, "fp": 8, "s1": 9,
    "a0": 10, "a1": 11, "a2": 12, "a3": 13,
    "a4": 14, "a5": 15, "a6": 16, "a7": 17,
    "s2": 18, "s3": 19, "s4": 20, "s5": 21,
    "s6": 22, "s7": 23, "s8": 24, "s9": 25,
    "s10": 26, "s11": 27,
    "t3": 28, "t4": 29, "t5": 30, "t6": 31,
}


# ---------- spike ----------
def run_spike(words: list[int], spike: str = "spike", timeout_s: int = 30):
    """Run the program on spike up to the JAL self-loop epilogue and
    return the final 32-register state."""
    elf_bytes = build_elf(words)
    halt_pc = CODE_BASE + (len(words) - 1) * 4   # PC of `JAL 0, 0`
    elf_f = tempfile.NamedTemporaryFile(suffix=".elf", delete=False)
    cmd_f = tempfile.NamedTemporaryFile(suffix=".cmd", delete=False, mode="w")
    try:
        elf_f.write(elf_bytes); elf_f.close()
        cmd_f.write(f"untiln pc 0 0x{halt_pc:x}\n")
        cmd_f.write("reg 0\n")
        cmd_f.write("quit\n")
        cmd_f.close()

        cmd = [spike, "-d", "--isa=rv32i", "-m0x80000000:0x200000",
               f"--debug-cmd={cmd_f.name}", elf_f.name]
        res = subprocess.run(cmd, capture_output=True, text=True,
                             timeout=timeout_s)
    finally:
        os.unlink(elf_f.name)
        os.unlink(cmd_f.name)

    out = res.stdout + "\n" + res.stderr
    # Extract every "<abiname>: 0xHEX" pair from the reg dump.
    regs = [None] * 32
    for m in re.finditer(r"\b([a-z][a-z0-9]*)\s*:\s*0x([0-9a-fA-F]+)", out):
        name = m.group(1)
        if name in ABI_TO_X:
            idx = ABI_TO_X[name]
            regs[idx] = int(m.group(2), 16) & 0xFFFFFFFF
    if any(r is None for r in regs):
        missing = [i for i, r in enumerate(regs) if r is None]
        raise RuntimeError(
            f"spike reg dump missing x{missing}\n"
            f"--- stdout tail ---\n{res.stdout[-1500:]}\n"
            f"--- stderr ---\n{res.stderr[-500:]}"
        )
    return regs


# ---------- driver ----------
def cross_check_one(hex_path: Path, max_steps: int, spike: str, spike_timeout_s: int):
    words = patch_data_base(load_hex(hex_path))
    py_regs, py_steps, py_pass = run_python(words, max_steps)
    sp_regs = run_spike(words, spike=spike, timeout_s=spike_timeout_s)

    diffs = [(i, py_regs[i], sp_regs[i])
             for i in range(32) if py_regs[i] != sp_regs[i]]
    return py_steps, py_pass, diffs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--hex-dir", default="tb/programs/generated")
    ap.add_argument("--count", type=int, default=20,
                    help="how many .hex files to cross-check")
    ap.add_argument("--max-steps", type=int, default=20000)
    ap.add_argument("--spike-timeout-s", type=int, default=30)
    ap.add_argument("--spike", default="spike")
    ap.add_argument("--only", nargs="*",
                    help="only run these stems (overrides --count)")
    args = ap.parse_args()

    files = sorted(Path(args.hex_dir).glob("*.hex"))
    if args.only:
        wanted = set(args.only)
        files = [f for f in files if f.stem in wanted]
    else:
        files = files[: args.count]

    fail = 0
    for hp in files:
        try:
            steps, pyp, diffs = cross_check_one(hp, args.max_steps, args.spike, args.spike_timeout_s)
        except Exception as e:
            print(f"[ERR ] {hp.stem}: {e}")
            fail += 1
            continue
        tag = "OK  " if not diffs else "FAIL"
        if diffs:
            fail += 1
        print(f"[{tag}] {hp.stem:24s}  steps={steps:5d}  py_pass={pyp}  diffs={len(diffs)}")
        for i, pv, sv in diffs:
            print(f"        x{i:02d}  py=0x{pv:08x}  spike=0x{sv:08x}")

    print(f"\nTotal: {len(files)} programs, {fail} failures")
    sys.exit(1 if fail else 0)


if __name__ == "__main__":
    main()
