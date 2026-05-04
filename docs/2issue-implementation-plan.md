# 2-Issue In-Order Implementation Plan (From Current 8-Stage Baseline)

## Scope
This document defines a practical upgrade path from the current single-issue 8-stage pipeline:

- IF -> ID1 -> ID2 -> EX1 -> EX2 -> AGU -> MEM -> WB

to a constrained dual-issue in-order machine.

Primary objective:

- Increase front-end and back-end throughput without switching to out-of-order execution.
- Preserve precise architectural state and keep verification manageable.
- Prefer a conservative first implementation over an aggressive superscalar design.

## Target Design

The recommended first dual-issue target is a restricted 2-issue pipeline with two issue slots:

- slot0: full-function pipe
- slot1: ALU-only auxiliary pipe

Key rules:

1. The machine remains in-order.
2. At most 2 instructions may be issued per cycle.
3. `slot0` may issue any currently supported legal instruction.
4. `slot1` may initially issue only `OP_IMM` and `OP_REG` integer ALU instructions.
5. `slot1` may not issue load/store, branch, jump, CSR/system, `ecall`, or `mret`.
6. If `slot1` depends on `slot0` in the same cycle, `slot1` is suppressed.
7. At most one memory operation may be issued per cycle.
8. At most one control-flow-changing instruction may be issued per cycle.

This target is intentionally asymmetric. It is much easier to stabilize than a fully symmetric 2-issue backend.

## Why 2-Issue and Not 3-Issue

2-issue is a reasonable extension of the current RTL organization.

3-issue is not impossible, but it adds disproportionate complexity in:

- same-cycle dependency checking
- forwarding matrix size
- register-file port count
- writeback arbitration
- branch recovery
- precise exception handling

For the current project stage, 2-issue is the highest-value next step.

## Architectural Delta

### Before
- Single fetch
- Single decode
- Single issue
- Single full backend path

### After
- Dual fetch bundle
- Dual decode bundle
- Restricted dual issue
- One full backend path plus one ALU-only auxiliary path

### Conceptual Structure

- IF: fetch instruction pair
- ID1: buffer instruction pair
- ID2: decode instruction pair and decide whether both may issue
- slot0: existing EX1 -> EX2 -> AGU -> MEM -> WB path
- slot1: lightweight EX path -> WB path

## Slot Pairing Policy

The first implementation should use conservative pairing rules.

Allow dual issue only when all of the following are true:

1. `slot0` contains a valid legal instruction.
2. `slot1` contains a valid legal ALU-only instruction.
3. `slot1` does not read `slot0.rd`.
4. `slot0` is not a branch or jump.
5. `slot0` is not a load or store when `slot1` would contend for a restricted backend resource.
6. Neither slot creates a same-cycle writeback conflict that the first implementation cannot retire safely.

If any condition fails, the machine falls back to single issue for that cycle.

## Required RTL Changes

### 1) Front-End Bundle Support
Files:

- `rtl/core/cpu_top.v`

Changes:

1. Fetch two instructions per cycle.
2. Replace single-lane IF/ID1 and ID1/ID2 registers with slot-based bundles.
3. Carry `pc0`, `pc1`, `instr0`, `instr1`, `valid0`, `valid1` through the front-end.
4. Keep flush and stall behavior simple: when `slot0` redirects, kill `slot1` in the same bundle.

Suggested naming:

- `if_id_pc0`, `if_id_instr0`, `if_id_valid0`
- `if_id_pc1`, `if_id_instr1`, `if_id_valid1`
- `id1_id2_*0`, `id1_id2_*1`

### 2) Dual Decode and Issue Classification
Files:

- `rtl/core/control.v`
- `rtl/core/cpu_top.v`

Changes:

1. Instantiate decode/control generation separately for slot0 and slot1.
2. Add classification outputs to mark whether an instruction is eligible for `slot1`.
3. Build a bundle issue decision in `ID2`.

Recommended new classification outputs:

- `is_alu_only`
- `uses_mem`
- `uses_redirect`
- `uses_system`

### 3) Register File Port Expansion
Files:

- `rtl/core/regfile.v`
- `rtl/core/cpu_top.v`

Changes:

1. Expand the register file to support 4 read ports and 2 write ports.
2. Keep x0 behavior unchanged.
3. Define write collision behavior explicitly.

Recommended first rule:

- if both slots attempt to write the same destination register, suppress `slot1` issue for now.

### 4) Auxiliary ALU Path for Slot1
Files:

- `rtl/core/cpu_top.v`
- `rtl/core/alu.v` (reuse if possible)

Changes:

1. Reuse the existing full backend for `slot0`.
2. Add a lightweight ALU execution path for `slot1`.
3. Route `slot1` directly to writeback staging without AGU/MEM.
4. Do not allow `slot1` to generate redirect or memory traffic in milestone 1.

### 5) Forwarding Network Rewrite
Files:

- `rtl/core/forwarding.v`
- `rtl/core/cpu_top.v`

Changes:

1. Extend forwarding from one consumer lane to two consumer lanes.
2. Support forwarding from older `slot0` and `slot1` producers into current `slot0` and `slot1` consumers.
3. Keep same-cycle `slot0 -> slot1` bypass out of the first version by simply suppressing `slot1` on same-cycle RAW.

This is a major complexity control point. Do not try to implement a fully general bypass matrix in the first pass.

### 6) Hazard Logic Extension
Files:

- `rtl/core/hazard.v`
- `rtl/core/cpu_top.v`

Changes:

1. Check hazards for `slot0` against the older pipeline.
2. Check hazards for `slot1` against the older pipeline.
3. Check `slot1` against `slot0` in the same cycle.

Recommended first policy:

- if `slot1` has any RAW/WAW concern relative to `slot0`, suppress `slot1`

This keeps correctness simple and avoids premature complexity.

### 7) Branch and Redirect Policy
Files:

- `rtl/core/cpu_top.v`
- `rtl/core/branch_unit.v`

Changes:

1. Allow branch/jump only in `slot0`.
2. Kill `slot1` whenever `slot0` redirects.
3. Keep branch prediction and redirect generation centered on `slot0` in the first version.

This avoids bundle-level redirect corner cases in the early implementation.

### 8) Writeback and Retirement
Files:

- `rtl/core/cpu_top.v`
- `tb/tb_cpu.v`

Changes:

1. Add dual writeback support.
2. Preserve in-order retirement semantics.
3. Ensure `slot1` cannot retire architecturally before `slot0` if `slot0` triggers exception/redirect semantics.

## Milestones

### Milestone 1: Dual-Width Front-End, Single-Issue Back-End
**Status**: ✅ COMPLETE (2026年5月5日)

Goal:

- Introduce bundled IF/ID1/ID2 state without changing execution throughput yet.

Changes (Completed):

1. ✅ Dual-port IMEM: Added addr/rdata and addr1/rdata1 ports for simultaneous instruction fetch
2. ✅ Bundled pipeline registers: IF/ID1, ID1/ID2 now carry (pc0, instr0, valid0, pc1, instr1, valid1)
3. ✅ Dual-slot fetch: PC generation, BPU lookup, IMEM access all support simultaneous pair fetch
4. ✅ Reset-gated statistics: I$, D$ counters properly initialized to avoid simulation X contamination
5. ✅ Single-issue backend unchanged: EX1/EX2/AGU/MEM/WB consume only slot0

Exit criteria (Met):

- ✅ Existing single-issue regressions: 100/100 random tests PASS, all directed tests PASS
- ✅ No redirect/flush regressions: Branch/jump behavior unchanged
- ✅ Performance stable: CPI metrics unchanged from single-issue baseline

**Documentation**: See [milestone-1-frontend-refactor.md](milestone-1-frontend-refactor.md)

---

### Milestone 1.5: ID2 Slot1 Decode Pairing Logic  
**Status**: ✅ COMPLETE (2026年5月5日)

Goal:

- Add independent decode path for slot1 with conservative pairing constraint checks.
- Establish `id2_issue_slot1` signal for Milestone 2 backend consumption.

Changes (Completed):

1. ✅ Slot1 independent decode: Added `control u_ctrl_slot1` instance for slot1 instruction decoding
2. ✅ ALU-only constraint: `id1_is_alu_only = (opcode == OP_REG) || (opcode == OP_IMM)`
3. ✅ Same-cycle RAW hazard detection: Prevents slot1 from issuing when slot1's rs1/rs2 matches slot0's rd
4. ✅ Issue signal generation: `id2_issue_slot1 = id1_id2_valid1 && id1_is_alu_only && id1_no_raw_hazard`
5. ✅ 5 focused micro-tests: Verify pairing rules (two ALU, ALU+LOAD, RAW hazard, independent, ALU+BRANCH)

Exit criteria (Met):

- ✅ All 5 slot1 pairing micro-tests: 5/5 PASS
- ✅ Regression stable: 100/100 random smoke tests PASS
- ✅ Slot1 decode logic ready for Milestone 2 backend consumption

**Documentation**: See [milestone-1.5-slot1-decode.md](milestone-1.5-slot1-decode.md)

---

### Milestone 2: Restricted Dual Issue
**Status**: 🔄 PENDING

Goal:

- Enable `slot1` issue for ALU-only instructions under conservative pairing rules.

Changes (Required):

1. Dual ALU datapath: One ALU per slot
2. Regfile upgrade: 4R2W (4 read, 2 write ports per cycle)
3. Dual hazard/forwarding: Extended for slot1 consumer
4. Slot1 execution path: Lightweight ALU-only pipeline (no AGU/MEM/WB)
5. Dual write-back support: Concurrent regfile writes from slot0 and slot1

Exit criteria (Target):

- ✅ Slot1 ALU results correctly written to regfile
- ✅ Correctness regressions remain green
- ✅ Directed dual-issue functional tests pass
- ✅ IPC improves on ALU-heavy instruction patterns

## Verification Plan

### Existing Baseline Tests
Keep the current single-issue regression suite as a non-negotiable correctness gate:

- `make run PROG=tb/programs/test02.hex TIMEOUT_NS=3000000`
- `make run PROG=tb/programs/test03.hex TIMEOUT_NS=3000000`
- `make run PROG=tb/programs/test04.hex TIMEOUT_NS=3000000`
- `python3 tools/run_generated_tests.py --dir tb/programs/generated`
- `python3 tools/run_generated_tests.py --glob 'rv32_rand_0*.hex' --retries 2`

### New Dual-Issue Micro-Tests
Add dedicated tests for:

1. two independent ALU instructions issued in one cycle
2. `slot1` suppressed on same-cycle RAW with `slot0`
3. branch in `slot0` kills `slot1`
4. load/store in `slot0` prevents illegal `slot1` pairing
5. dual writeback correctness

### Performance Checks
Use benchmark kernels to measure whether issue width helps on pair-friendly code:

- `python3 tools/run_benchmarks.py --regen --timeout-ns 8000000 --wall-timeout-s 240`

Add new metrics if implemented:

- pair rate
- slot1 utilization
- slot1 suppression reason counts

## Risk Register

1. Register-file port expansion risk
- Risk: incorrect same-cycle write behavior corrupts architectural state.
- Mitigation: start with explicit suppression of unsupported same-cycle destination conflicts.

2. Forwarding matrix mistakes
- Risk: slot1 consumes stale data under mixed-lane dependencies.
- Mitigation: begin with conservative no-pair rules and expand only after micro-tests pass.

3. Redirect consistency risk
- Risk: slot1 commits work on a cycle that should have been killed by slot0 redirect.
- Mitigation: centralize control-flow authority in slot0 for the first design.

4. Verification explosion
- Risk: dual-issue correctness bugs are harder to observe in broad random tests.
- Mitigation: add focused bundle-aware micro-tests before broad regression.

## Definition of Done

1. The design can fetch, decode, and issue up to 2 instructions per cycle under documented constraints.
2. Existing single-issue directed and random regressions remain green.
3. New dual-issue micro-tests pass.
4. The implementation remains in-order and preserves precise architectural state.
5. Benchmark results show measurable throughput gain on ALU-friendly workloads.
6. Change log and tutorial documents are updated with final pairing rules and limitations.