# Milestone 2: Restricted Dual Issue - Implementation Plan

**Status**: 🔄 IN PROGRESS  
**Start Date**: 2026年5月5日

## Work Breakdown

### Phase 2A: Regfile 4R2W Upgrade (FIRST)
**Why first?** Many subsequent steps depend on having dual read + dual write capacity.

Tasks:
- [ ] Upgrade `regfile.v` from 2R1W to 4R2W
- [ ] Update `cpu_top.v` to instantiate with 4 read ports
- [ ] Add read address wiring for slot1 (id1_rs1_addr, id1_rs2_addr)
- [ ] Add dual write port support (wb_we0/wb_rd0/wb_data0 for slot0, wb_we1/wb_rd1/wb_data1 for slot1)
- [ ] Test with existing single-issue regressions (should be unchanged)

Exit criteria:
- ✅ Regfile instantiated with 4R2W signature
- ✅ Slot0 read/write paths unchanged
- ✅ Slot1 read paths wired but write signals not yet asserted
- ✅ All regressions still pass

---

### Phase 2B: Slot1 ID/EX Pipeline Registers (SECOND)
**Why second?** Needs regfile for operand reads.

Tasks:
- [ ] Create dual ID/EX registers (id1_ex_* for slot1)
- [ ] Wire regfile slot1 read outputs → id1_ex_rs1/rs2 during register update
- [ ] Add slot1 decode control signals to id1_ex pipeline
- [ ] Extend hazard detection for slot1 (stall if slot1 has load-use on deeper stages)
- [ ] Test that slot1 registers update correctly (waveform inspection)

Exit criteria:
- ✅ id1_ex_* registers latch slot1 instruction data
- ✅ Hazard stall still conservative (blocks both slots if any hazard)
- ✅ Regressions unchanged

---

### Phase 2C: Slot1 ALU Datapath (THIRD)
**Why third?** Needs id1_ex_* registers as inputs.

Tasks:
- [ ] Instantiate second ALU (`u_alu_slot1`) consuming slot1 operands
- [ ] Add slot1 forwarding logic (reuse forwarding.v with slot1 consumer addressing)
- [ ] Compute `slot1_alu_y` result
- [ ] Test: Waveform to verify ALU computes correct results

Exit criteria:
- ✅ Slot1 ALU produces results
- ✅ Forwarding correctly applies to slot1 operands

---

### Phase 2D: Slot1 Direct Write-Back Path (FOURTH)
**Why fourth?** Needs ALU result ready.

Tasks:
- [ ] Create lightweight slot1 write-back path (no AGU/MEM/WB stages)
- [ ] Direct slot1 ALU result → regfile write (same cycle as issue)
- [ ] Assert `wb_we1` when slot1 issues and rd != x0
- [ ] Test: Verify slot1 ALU result correctly written to regfile

Exit criteria:
- ✅ Slot1 ALU results written to regfile in same cycle
- ✅ Regfile contains correct slot1 writes
- ✅ Regressions unchanged

---

### Phase 2E: Dual Issue Control (FIFTH)
**Why fifth?** Depends on all above phases.

Tasks:
- [ ] Wire `id2_issue_slot1` signal (already generated in M1.5) to control slot1 issue
- [ ] Gate id1_ex pipeline update on `id2_issue_slot1`
- [ ] Ensure slot1 doesn't issue if:
  - [ ] `id2_issue_slot1 == 0` (pairing rules fail)
  - [ ] Same-cycle regfile write conflict (both slots write same rd)
  - [ ] Any hazard detected (conservative: block both)
- [ ] Create directed dual-issue test cases

Exit criteria:
- ✅ Slot1 only issues when all constraints met
- ✅ Directed dual-issue micro-tests pass
- ✅ Random regressions still pass

---

### Phase 2F: Integration Testing & Refinement (SIXTH)
**Why last?** After all components working.

Tasks:
- [ ] Run full regression suite
- [ ] Measure IPC improvement on ALU-heavy patterns
- [ ] Tune conservative stall masks if needed
- [ ] Document results

Exit criteria:
- ✅ All regressions pass
- ✅ IPC measurably improved on ALU patterns
- ✅ No correctness regressions

---

## Implementation Dependency Graph

```
Phase 2A (Regfile 4R2W)
  ↓
Phase 2B (Slot1 ID/EX)
  ↓ (+ Phase 2C in parallel)
Phase 2C (Slot1 ALU)
  ↓
Phase 2D (Slot1 Write-Back)
  ↓
Phase 2E (Dual Issue Control)
  ↓
Phase 2F (Integration Testing)
```

---

## Key Files to Modify

1. **rtl/core/regfile.v**: 2R1W → 4R2W
2. **rtl/core/cpu_top.v**: Add slot1 pipeline, ALU, write-back
3. **rtl/core/forwarding.v**: Extend for slot1 consumer (if needed)
4. **rtl/core/hazard.v**: Extend for slot1 (if needed)
5. **tools/gen_slot1_exec_tests.py**: NEW - Dual-issue execution micro-tests

---

## Risk Mitigation

- **Preserve single-issue baseline**: After each phase, verify existing regressions pass
- **Conservative hazard masking**: Initially block both slots on any dependency; relax later
- **Waveform inspection**: Use Icarus VVP waveform dumps to verify each phase
- **Micro-tests first**: Test each ALU+write-back case before full regression

---

## Success Criteria

✅ Dual ALU execution working  
✅ Slot1 write-back functional  
✅ All micro-tests pass (5 from M1.5 + 5 new dual-exec tests)  
✅ All regressions pass (100/100 random + directed)  
✅ IPC improved on ALU-heavy workloads  
✅ No correctness regressions  

