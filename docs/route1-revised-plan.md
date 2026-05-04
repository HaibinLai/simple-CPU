# Route 1 Revised: Step Plan for PC+8 Dual-Issue

**Date**: 2026年5月5日

## Why Original Step 1/2/3 Cannot Be Separated

Original plan tried:
- Step 1: PC+8 fetch with single-issue backend
- Step 2: Add IFQ
- Step 3: Enable slot1 write-back

**Problem**: Step 1 alone is broken because:
- If PC advances +8 and backend only consumes slot0 (mem[PC]), then mem[PC+4] is dropped → half of instructions skipped → program correctness broken.

The three steps must be **combined into one atomic refactor** for correctness.

## Revised Plan: Single Atomic Refactor

### Phase R1: IFQ + Sequential Single-Issue Pull

Goal: Decouple IF and ID via IFQ; backend still single-issue but pulls from IFQ.

1. **IF stage**:
   - PC advances +8 (8-byte aligned)
   - IFQ receives a pair (mem[PC], mem[PC+4]) per cycle
   - Branch redirect to non-aligned target: send only the high half as the next slot0

2. **IFQ (Issue Fetch Queue)**:
   - 4-entry FIFO of (PC, instr, valid, pred_taken, pred_target)
   - Push: 0/1/2 instructions per cycle (depending on alignment + redirect)
   - Pop: 1 instruction per cycle (single-issue mode)
   - Flush on ex_redirect

3. **ID/Decode**:
   - Pull 1 instruction from IFQ head
   - Insert bubble if IFQ empty
   - Behavior identical to current single-issue from this point

**Verification**: All current regressions must pass (100/100 random, directed, micro-tests)

### Phase R2: Enable Dual-Issue Pull (with Slot1 Backend)

Goal: ID2 pulls 2 instructions from IFQ when pairing rules allow.

1. ID2 examines IFQ[0] and IFQ[1]
2. If pairing rules pass: pop 2 entries, issue both to slot0/slot1
3. Otherwise: pop 1 entry (slot0 only)
4. Slot1 backend (Phase 2A-2C infrastructure) now writes regfile
5. Slot1 forwarding handles cross-cycle dependencies

**Verification**: Slot1 micro-tests + regressions + IPC measurement

### Phase R3: Optimization

- Larger IFQ (8 entries)
- Relax pairing rules
- Add dual-issue counters

## Implementation Order

### Phase R1 Internals (~400 lines)

1. **Add IFQ module** (new file or in-line in cpu_top.v)
   - 4 entries × (32-bit pc, 32-bit instr, 1-bit valid, 1-bit pred_taken, 32-bit pred_target)
   - head/tail pointers
   - push (0/1/2 per cycle), pop (1 per cycle for R1)

2. **Modify PC logic**:
   - PC advances +8 normally
   - Branch redirect handles target alignment:
     - If `target[2]==0`: push both mem[target], mem[target+4]
     - If `target[2]==1`: push only mem[target] as slot0 (skip slot1 portion)

3. **Modify IF/ID1, ID1/ID2 stages**:
   - These become wrappers around IFQ
   - Or merge them into IFQ entries directly (cleaner)

4. **Decode pulls from IFQ**:
   - id_instr = ifq.head.instr
   - id_pc = ifq.head.pc
   - When IFQ is empty: id_valid = 0 (bubble)

### Phase R2 Internals (~200 lines)

1. ID2 dual examination of IFQ[0] and IFQ[1]
2. Slot1 control signals (already in M1.5)
3. Enable slot1_wb_we (already wired in 2D, just toggle)
4. Slot1 forwarding refinement (already in 2C)

## Critical Design Points

### Branch Misprediction Recovery
- ex_redirect → flush entire IFQ
- Insert N bubbles until pipeline refills

### Stall Handling
- IFQ full → IF stalls (PC hold)
- IFQ empty → ID stalls (insert bubble)
- Backend stall → IFQ pop frozen

### Instruction Memory Alignment
- Current IMEM is 4-byte aligned (each address is a word)
- For PC=0x80, fetch returns mem[0x80] and mem[0x84]
- For unaligned target PC=0x84, IF can still fetch 0x84 and 0x88,
  but only 0x84 should be enqueued (0x88 would belong to next cycle's first slot)

### Compaction (Phase R2)
When IFQ has [A, B, C, D] and we want to dual-issue:
- Try to pair (A, B). If yes, pop both.
- If B is incompatible, only issue A. Next cycle, try pair (B, C).
- This naturally handles non-pairable sequences without bubbles.

## Estimated Effort

- Phase R1 (IFQ + single-issue): 4-6 hours
- Phase R2 (dual issue enable): 2-3 hours
- Phase R3 (optimization): 1-2 hours
- Total: ~1-2 sessions

## Risk Mitigation

- Phase R1 is functionally identical to current single-issue → if regressions break, IFQ logic is wrong
- Phase R2 transitions to dual-issue → micro-tests catch most bugs
- Always keep slot1_wb_we tied to 0 until R1 fully verified

## Decision

Proceed with Phase R1 first. Verify single-issue regression. Only then proceed to R2.
