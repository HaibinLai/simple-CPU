"""Tiny label-based assembler for RV32I benchmarks.

Lets benchmark builders write
    a.label("loop")
    a.beq(x_i, x_n, "end")
    ...
    a.j("loop")
    a.label("end")

and resolves PC-relative offsets at assemble() time. Avoids manual offset math
that scales poorly as kernels grow.
"""
from __future__ import annotations

from typing import Callable, Dict, List, Tuple, Union

from gen_rv32_tests import (
    ADD, ADDI, AND, ANDI, BEQ, BGE, BGEU, BLT, BLTU, BNE, JAL, JALR, LB, LBU,
    LH, LHU, LUI, LW, OR, ORI, SB, SH, SLL, SLLI, SLT, SLTI, SLTIU, SLTU, SRA,
    SRAI, SRL, SRLI, SUB, SW, XOR, XORI,
)


_BR_FN = {
    "beq":  BEQ, "bne":  BNE,
    "blt":  BLT, "bge":  BGE,
    "bltu": BLTU, "bgeu": BGEU,
}


class Asm:
    def __init__(self) -> None:
        # Each entry: (kind, payload).
        # kind=='raw'  -> payload = int instruction word
        # kind=='br'   -> payload = (op, rs1, rs2, label_name)
        # kind=='jal'  -> payload = (rd, label_name)
        self._items: List[Tuple[str, object]] = []
        self._labels: Dict[str, int] = {}

    # ---- meta ----
    def label(self, name: str) -> None:
        if name in self._labels:
            raise ValueError(f"label {name!r} already defined")
        self._labels[name] = len(self._items)

    def __len__(self) -> int:
        return len(self._items)

    # ---- raw instruction emit ----
    def emit(self, word: int) -> None:
        self._items.append(("raw", word & 0xFFFFFFFF))

    # ---- pseudo helpers (still raw) ----
    def li(self, rd: int, value: int) -> None:
        """Load a 32-bit constant via LUI/ADDI (matches `li` semantics)."""
        v = value & 0xFFFFFFFF
        # split into upper20 + signed-lower12 such that (upper20<<12) + sign_ext(lower12) == v
        lower = v & 0xFFF
        upper = (v >> 12) & 0xFFFFF
        if lower & 0x800:           # lower will sign-extend negative; bump upper
            upper = (upper + 1) & 0xFFFFF
        if upper == 0:
            self.emit(ADDI(rd, 0, sign12(lower)))
        else:
            self.emit(LUI(rd, upper))
            if lower != 0:
                self.emit(ADDI(rd, rd, sign12(lower)))

    # ---- ALU R-type ----
    def add(self, rd, rs1, rs2):  self.emit(ADD(rd, rs1, rs2))
    def sub(self, rd, rs1, rs2):  self.emit(SUB(rd, rs1, rs2))
    def sll(self, rd, rs1, rs2):  self.emit(SLL(rd, rs1, rs2))
    def srl(self, rd, rs1, rs2):  self.emit(SRL(rd, rs1, rs2))
    def sra(self, rd, rs1, rs2):  self.emit(SRA(rd, rs1, rs2))
    def slt(self, rd, rs1, rs2):  self.emit(SLT(rd, rs1, rs2))
    def sltu(self, rd, rs1, rs2): self.emit(SLTU(rd, rs1, rs2))
    def xor_(self, rd, rs1, rs2): self.emit(XOR(rd, rs1, rs2))
    def or_(self, rd, rs1, rs2):  self.emit(OR(rd, rs1, rs2))
    def and_(self, rd, rs1, rs2): self.emit(AND(rd, rs1, rs2))

    # ---- ALU I-type ----
    def addi(self, rd, rs1, imm):  self.emit(ADDI(rd, rs1, imm))
    def slti(self, rd, rs1, imm):  self.emit(SLTI(rd, rs1, imm))
    def sltiu(self, rd, rs1, imm): self.emit(SLTIU(rd, rs1, imm))
    def xori(self, rd, rs1, imm):  self.emit(XORI(rd, rs1, imm))
    def ori(self, rd, rs1, imm):   self.emit(ORI(rd, rs1, imm))
    def andi(self, rd, rs1, imm):  self.emit(ANDI(rd, rs1, imm))
    def slli(self, rd, rs1, sh):   self.emit(SLLI(rd, rs1, sh))
    def srli(self, rd, rs1, sh):   self.emit(SRLI(rd, rs1, sh))
    def srai(self, rd, rs1, sh):   self.emit(SRAI(rd, rs1, sh))

    # ---- mem ----
    def lw(self, rd, rs1, imm):   self.emit(LW(rd, rs1, imm))
    def lh(self, rd, rs1, imm):   self.emit(LH(rd, rs1, imm))
    def lhu(self, rd, rs1, imm):  self.emit(LHU(rd, rs1, imm))
    def lb(self, rd, rs1, imm):   self.emit(LB(rd, rs1, imm))
    def lbu(self, rd, rs1, imm):  self.emit(LBU(rd, rs1, imm))
    def sw(self, rs2, rs1, imm):  self.emit(SW(rs2, rs1, imm))
    def sh(self, rs2, rs1, imm):  self.emit(SH(rs2, rs1, imm))
    def sb(self, rs2, rs1, imm):  self.emit(SB(rs2, rs1, imm))

    # ---- control ----
    def j(self, label: str) -> None:
        self._items.append(("jal", (0, label)))

    def jal(self, rd: int, label: str) -> None:
        self._items.append(("jal", (rd, label)))

    def jalr(self, rd: int, rs1: int, imm: int = 0) -> None:
        self.emit(JALR(rd, rs1, imm))

    def ret(self) -> None:
        # JALR x0, x1, 0
        self.emit(JALR(0, 1, 0))

    def br(self, op: str, rs1: int, rs2: int, label: str) -> None:
        if op not in _BR_FN:
            raise ValueError(f"unknown branch op {op!r}")
        self._items.append(("br", (op, rs1, rs2, label)))

    def beq(self, rs1, rs2, lab):  self.br("beq",  rs1, rs2, lab)
    def bne(self, rs1, rs2, lab):  self.br("bne",  rs1, rs2, lab)
    def blt(self, rs1, rs2, lab):  self.br("blt",  rs1, rs2, lab)
    def bge(self, rs1, rs2, lab):  self.br("bge",  rs1, rs2, lab)
    def bltu(self, rs1, rs2, lab): self.br("bltu", rs1, rs2, lab)
    def bgeu(self, rs1, rs2, lab): self.br("bgeu", rs1, rs2, lab)

    # ---- assemble ----
    def assemble(self) -> List[int]:
        words: List[int] = []
        for idx, (kind, payload) in enumerate(self._items):
            if kind == "raw":
                words.append(payload)  # type: ignore[arg-type]
            elif kind == "br":
                op, rs1, rs2, lab = payload  # type: ignore[misc]
                if lab not in self._labels:
                    raise ValueError(f"undefined label {lab!r}")
                offset = (self._labels[lab] - idx) * 4
                words.append(_BR_FN[op](rs1, rs2, offset))
            elif kind == "jal":
                rd, lab = payload  # type: ignore[misc]
                if lab not in self._labels:
                    raise ValueError(f"undefined label {lab!r}")
                offset = (self._labels[lab] - idx) * 4
                words.append(JAL(rd, offset))
            else:  # pragma: no cover
                raise AssertionError(kind)
        return words


def sign12(value: int) -> int:
    """Convert an unsigned 12-bit value to its signed equivalent for ADDI."""
    value &= 0xFFF
    if value & 0x800:
        return value - 0x1000
    return value
