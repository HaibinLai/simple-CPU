# Phase 2D Analysis: Why Direct Write-Back Failed

**Date**: 2026年5月5日  
**Status**: 🛑 DEFERRED - Architectural redesign needed  

## Symptom

When Phase 2D was applied (connecting `slot1_wb_we = id1_ex_valid && id1_ex_reg_write`), regression failures appeared:
- 4+ random tests showed register mismatches (x05, x07, x13, x15, x16, x18, x19)
- Mismatches indicated values being computed but written to wrong registers or incorrect values

## Root Cause: PC Advancement Mismatch

### Current PC Advancement Logic
- `pc <= pc + 4` every cycle (single-issue model)
- IF fetches `imem[pc]` (slot0) and `imem[pc+4]` (slot1) in parallel

### Cycle Trace Showing the Bug

```
Cycle 0: PC=A    | IF: fetch mem[A], mem[A+4]      | IF/ID1<=(A, A+4)
Cycle 1: PC=A+4  | IF: fetch mem[A+4], mem[A+8]    | IF/ID1<=(A+4, A+8)
                                                    | ID1/ID2<=(A, A+4)
Cycle 2: PC=A+8  | IF: fetch mem[A+8], mem[A+12]   | IF/ID1<=(A+8, A+12)
                 | ID2 processes (A, A+4)          | ID1/ID2<=(A+4, A+8)
                 | ↑ DUAL-ISSUE: A and A+4 both executed
                 | ↑ slot1 writes regfile via slot1_wb_we
Cycle 3: PC=A+12 | ID2 processes (A+4, A+8)        | ← BUG!
                 | A+4 was ALREADY EXECUTED as slot1 in cycle 2
                 | Now A+4 executes AGAIN as slot0 → duplicate writes!
```

## Why It's an Architectural Issue

The pipeline stages are:
- **IF**: Fetches pair (PC, PC+4)
- **ID1, ID2**: Carry pair forward
- **EX1**: Slot1 writes regfile (Phase 2D); slot0 continues to EX2/AGU/MEM/WB
- **PC advance**: +4 each cycle

The fundamental conflict:
- IF advances by **+4** (single-issue rate)
- ID2 dual-issues processes **2 instructions per cycle**
- → Pairs OVERLAP: (A, A+4), (A+4, A+8), (A+8, A+12) all share one PC

When slot1 issues, the "+4 instruction" is executed twice:
1. Once as slot1 of pair N
2. Once as slot0 of pair N+1

## Possible Solutions (For Future Implementation)

### Option A: PC +8 with Issue Queue (Best for IPC, Complex)
- IF advances PC by +8
- Pairs are non-overlapping: (A, A+4), (A+8, A+12), (A+16, A+20)
- Issue queue retains non-eligible slot1 to retry as next slot0
- **Pros**: Proper IPC gain (up to 2x for ALU code)
- **Cons**: Major RTL refactor (front-end queue, complex stall logic)

### Option B: Slot Rotation (Medium Complexity)
- PC always advances +4
- ID2 alternates: cycle N executes slot0+slot1, cycle N+1 executes slot1 only (because slot0 is duplicate)
- **Pros**: Less front-end change
- **Cons**: Requires `slot_skip_phase` state propagating across cycles
- **Net IPC**: Limited (might not improve, may degrade)

### Option C: Redirect on Dual-Issue (Simple, Zero Gain)
- When slot1 issues, redirect PC to id1_id2_pc1 + 4 = pc0 + 8
- Inserts 2-cycle bubble per dual-issue
- **Pros**: Minimal changes, conservative
- **Cons**: Net IPC = 1.0 (no improvement); not worth the complexity

### Option D: Constrained Dual-Issue (What we've done) 
Current state: dual front-end, dual decode, dual ALU, but **slot1 write disabled**.
- Allows slot1 forwarding to slot0 (architectural improvement at no IPC cost)
- Provides infrastructure for future dual-issue implementation
- **Status**: ✅ Working baseline

## Decision: Option A is the Correct Long-Term Path

To genuinely benefit from 2-issue, **Option A (PC +8 with Issue Queue)** is required.

This requires:
1. Front-end: PC advances +8, but always tries to issue both
2. Issue Queue: Buffer between IF and ID2 that holds 2-4 instructions
3. ID2: Compaction logic — if slot1 not eligible, retains it for next cycle's slot0
4. Hazard: Cross-cycle slot1→slot0 forwarding paths
5. Branch prediction: Pair-aligned BPU (slot0 branch invalidates slot1 anyway)

**Estimated effort**: Major refactor (~500-800 lines)

## Current Stable State (Option D / Phase 2A-2C)

What's preserved:
- ✅ Regfile 4R2W (ready for dual write)
- ✅ Slot1 ID/EX pipeline registers (functional)
- ✅ Slot1 ALU datapath (computes results, just doesn't commit)
- ✅ Slot1 forwarding (can forward from slot0 EX/WB)
- ✅ All ID2 pairing logic (id2_issue_slot1 signal active)
- ✅ Single-issue regression: 100/100 PASS

What's disabled:
- ❌ slot1_wb_we (kept tied to 0 to prevent duplicate execution)

## Recommendation

**Treat current state as "Milestone 2 Phase 1 Complete"** and document it as a preparation phase. **Phase 2 Redesign** would target:
- PC advancement +8 with dynamic recovery
- Issue queue front-end
- True dual-issue execution

This split allows the current changes to remain valuable infrastructure without requiring the full architectural redesign in this session.

## Verification of Current Stable State

- ✅ test02/test03/test04: PASS
- ✅ rv32_rand_0*: 100/100 PASS  
- ✅ Slot1 pairing micro-tests: 5/5 PASS (front-end verification)
- ✅ CPI: 1.797 (unchanged from baseline)

The baseline is rock-solid; we have a working dual-decode, dual-ALU front-end ready for the proper dual-issue back-end when implemented.

