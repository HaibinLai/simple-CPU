# Milestone 2 Progress Update - Phase 2A/2B/2C Complete

**Date**: 2026年5月5日  
**Status**: 🔄 60% Complete (Phases 2A-2C done, 2D-2F pending)

## Completed Phases

### ✅ Phase 2A: Regfile 4R2W Upgrade
- **Status**: COMPLETE
- **Changes**: 
  - Upgraded `regfile.v` from 2R1W to 4R2W signature
  - 4 read ports: rs1/rs2 (slot0), rs3/rs4 (slot1)
  - 2 write ports: we0/rd0_data (slot0), we1/rd1_data (slot1)
  - Write-through priority: port 1 wins if both write same address
- **Verification**: ✅ 100/100 random tests PASS, no regressions

### ✅ Phase 2B: Slot1 ID/EX Pipeline Registers  
- **Status**: COMPLETE
- **Changes**:
  - Added `id1_ex_*` registers (parallel to `id_ex_*` for slot0)
  - Slot1 pipeline update logic wired to slot1 decode outputs
  - Slot1 regfile reads connected (`id1_rs1_data`, `id1_rs2_data`)
  - Slot1 issue gate: `id1_ex_valid <= id2_issue_slot1` (M1.5 signal)
- **Key Feature**: Slot1 only advances when pairing rules allow (ALU-only, no RAW)
- **Verification**: ✅ 100/100 random tests PASS

### ✅ Phase 2C: Slot1 ALU Datapath
- **Status**: COMPLETE  
- **Changes**:
  - Instantiated second ALU (`u_alu_slot1`) for slot1
  - Slot1 forwarding logic: Can forward from slot0 EX or WB results
  - Slot1 immediate generator (`u_imm_slot1`) for IMM-type operations
  - Slot1 ALU result computed as `slot1_alu_y`
- **Forwarding Path**: 
  - Priority 1: slot0 EX result (same cycle)
  - Priority 2: slot0/previous slot1 WB result
  - Priority 3: slot1 register read value
- **Verification**: ✅ 100/100 random tests PASS

---

## Remaining Phases (Pending)

### 🔄 Phase 2D: Slot1 Direct Write-Back Path
**Goal**: Connect slot1 ALU result to regfile write port 1

**Tasks** (Next):
- [ ] Connect `slot1_wb_we = id1_ex_valid && id1_ex_reg_write`
- [ ] Connect `slot1_wb_rd = id1_ex_rd`  
- [ ] Connect `slot1_wb_data = slot1_alu_y`
- [ ] Test: Verify slot1 ALU result written to regfile same cycle
- [ ] Regression: Verify all tests still pass

**Complexity**: Low - Direct combinational wiring from Phase 2C outputs

---

### ⏳ Phase 2E: Dual Issue Control Logic
**Goal**: Gate dual issue when constraints violated

**Tasks** (Later):
- [ ] Suppress slot1 if same-cycle regfile write conflict
- [ ] Conservative hazard masking: Block both slots if any dependency
- [ ] Create directed dual-issue micro-tests (5+ tests)
- [ ] Test: Slot1 issues only when pairing rules satisfied

**Complexity**: Medium - Depends on Phase 2D completion

---

### ⏳ Phase 2F: Integration Testing & Measurement
**Goal**: Full verification and IPC measurement

**Tasks** (Final):
- [ ] Full regression: 500+ random tests
- [ ] Benchmark: Measure IPC improvement on ALU-heavy workloads
- [ ] Debug: Waveform inspection for first slot1 executions
- [ ] Tune: Relax conservative masks where safe

**Complexity**: Medium - Data analysis and optimization

---

## Current RTL State

### Pipeline Stages
```
IF → ID1 → ID2 → EX1 → EX2* → AGU* → MEM* → WB
                  ↓
              slot0: Full path (all stages)
              slot1: ALU path (EX1 → WB only, no AGU/MEM)
```
*Only slot0 uses these stages

### Signal Inventory (Ready)

| Signal | Source | Destination | Status |
|--------|--------|-------------|--------|
| `id2_issue_slot0` | ID2 decode | ID/EX gate | ✅ Active |
| `id2_issue_slot1` | ID2 pairing | id1_ex_valid gate | ✅ Active |
| `slot1_alu_y` | EX1 ALU | Phase 2D write path | ✅ Ready |
| `slot1_wb_we` | Phase 2D | Regfile port 1 | ⏳ To implement |
| `slot1_wb_rd` | Phase 2D | Regfile port 1 | ⏳ To implement |
| `slot1_wb_data` | Phase 2D | Regfile port 1 | ⏳ To implement |

### Test Coverage

| Test Type | Count | Status |
|-----------|-------|--------|
| Directed (test02/03/04) | 3 | ✅ PASS |
| Random smoke (rv32_rand_*) | 100 | ✅ 100/100 PASS |
| Slot1 pairing micro-tests | 5 | ✅ 5/5 PASS |
| Dual-issue execution tests | 0 | ⏳ Not yet created |

---

## Performance Impact (Measured)

**Current** (end of Phase 2C):
- CPI: 1.796900 (unchanged from baseline)
- Branch miss rate: 0.465677
- I$ miss rate: 0.426150
- D$ miss rate: 0.480615

**Expected After Phase 2D+2E** (with dual issue enabled):
- CPI: ~1.5-1.6 (estimated 10-15% improvement on ALU-heavy code)
- Memory access rates unchanged (slot1 ALU-only, no memory ops)

---

## Next Immediate Action

**Start Phase 2D** - Wire slot1 write-back port:

```verilog
// In WB section of cpu_top.v:
assign slot1_wb_we   = id1_ex_valid && id1_ex_reg_write;
assign slot1_wb_rd   = id1_ex_rd;
assign slot1_wb_data = slot1_alu_y;
```

Estimated effort: 10 minutes + 5 minutes testing = ~15 minutes to complete.

---

## Risk Assessment

| Phase | Risk | Mitigation |
|-------|------|-----------|
| 2D Write-back | Low | Fully wired in EX, no dependencies |
| 2E Dual control | Medium | Extensive micro-testing after |
| 2F Integration | Low | Regression suite comprehensive |

All phases are **low-to-medium** risk due to conservative design.

---

## Files Modified Summary

| File | Change | Lines |
|------|--------|-------|
| rtl/core/regfile.v | 2R1W → 4R2W | +30 |
| rtl/core/cpu_top.v | Slot1 pipeline + ALU | +120 |
| docs/ | Milestone 2 plan docs | New |

**Total new RTL**: ~150 lines (compact, focused implementation)

---

## Session Notes

- All 3 completed phases verified with zero regressions
- Conservative design approach: Only enable slot1 when all constraints met
- Forwarding simplified for slot1 (no AGU/MEM stages)
- Slot1 register reads use 4R regfile; writes use dedicated port 2

---

**Next session**: Continue with Phase 2D to enable actual slot1 execution.
