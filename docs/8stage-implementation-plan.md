# 8-Stage Pipeline Implementation Plan (From Current 7-Stage)

## Scope
This document defines a low-risk path to migrate the current pipeline from:

- IF -> ID1 -> ID2 -> EX -> AGU -> MEM -> WB

to:

- IF -> ID1 -> ID2 -> EX1 -> EX2 -> AGU -> MEM -> WB

Primary objective:

- Keep architectural correctness first.
- Minimize interface breakage in memory/cache/CSR/testbench.
- Add performance refinements only after the baseline is stable.

Related tutorial:

- See `docs/8stage-tutorial.md` for step-by-step implementation details.

## Design Intent
Split the current EX stage into two stages:

- EX1: operand preparation / branch compare input selection / simple precompute signals.
- EX2: ALU final result, branch/jump target finalization, redirect/flush decision, exception/mret resolve.

Why this split:

- It preserves the existing AGU/MEM/WB backend behavior.
- It allows a gradual forwarding/hazard extension.
- It reduces risk versus splitting IF or MEM first.

## Architecture Delta

### Before
- IF, ID1, ID2, EX, AGU, MEM, WB

### After
- IF, ID1, ID2, EX1, EX2, AGU, MEM, WB

### New Pipeline Register Bank
Add one register bank in `rtl/core/cpu_top.v`:

- EX1/EX2 register set

Suggested naming convention:

- `ex1_ex2_*` signals, consistent with existing `id_ex_*`, `ex_mem_*`, `agu_mem_*` style.

## Milestones

### Milestone 1: Structural Split, Functional Equivalence
Goal:

- Insert EX1/EX2 register bank.
- Keep behavior equivalent to 7-stage as much as possible.

Changes:

1. `rtl/core/cpu_top.v`
- Move current EX combinational inputs into EX1 outputs where appropriate.
- Move branch/jump resolve and redirect to EX2.
- Keep CSR exception/mret handling in EX2.
- Keep AGU input source from EX2 outputs.

2. `rtl/core/forwarding.v`
- Extend source priority for EX-stage consumers to include EX2 path cleanly.
- Keep current load forwarding policy unchanged in this milestone.

3. `rtl/core/hazard.v`
- Start conservative: maintain correctness with possibly extra stalls.
- Keep source-aware checks (`id_use_rs1`, `id_use_rs2`).

Exit criteria:

- Directed tests pass.
- Random smoke passes.

### Milestone 2: Forwarding Rebalance for 8-Stage
Goal:

- Restore/optimize data availability timing after EX split.

Changes:

1. Prioritize nearest producer stage for ALU dependencies.
2. Keep MEM->EX load forwarding where valid.
3. Prevent forwarding from invalid/non-writing bubbles.

Exit criteria:

- No correctness regressions.
- CPI is not worse than a conservative expected bound.

### Milestone 3: Hazard Tightening
Goal:

- Remove avoidable stalls introduced by conservative split.

Changes:

1. Distinguish dependency windows by producer stage.
2. Gate checks by actual source usage.
3. Add optional counters (if desired) for stall attribution.

Exit criteria:

- Directed tests pass.
- Random full regression stable.
- Stall metrics show expected reduction.

## Verification Plan

### Directed Regression
Run:

- `make run PROG=tb/programs/test02.hex TIMEOUT_NS=3000000`
- `make run PROG=tb/programs/test03.hex TIMEOUT_NS=3000000`
- `make run PROG=tb/programs/test04.hex TIMEOUT_NS=3000000`

### Random Regression
Run:

- `python3 tools/run_generated_tests.py --dir tb/programs/generated`
- `python3 tools/run_generated_tests.py --glob 'rv32_rand_0*.hex' --retries 2`

### Benchmarks
Run:

- `python3 tools/run_benchmarks.py --regen --timeout-ns 8000000 --wall-timeout-s 240`

## Risk Register

1. Branch/redirect timing shift
- Risk: flush boundary moves and causes ghost commits.
- Mitigation: keep redirect/flush generation fully in EX2 and verify kill paths.

2. Load-use timing drift
- Risk: stale operand in EX1/EX2 path.
- Mitigation: conservative hazard first, then tighten after green regressions.

3. Forwarding priority mistakes
- Risk: choosing older producer over newer one.
- Mitigation: explicit nearest-first ordering and directed micro-cases.

4. Simulator artifact flakiness
- Risk: false failures due to shared simulation output.
- Mitigation: keep isolated `SIM_DIR` flow in batch scripts.

## Definition of Done

1. 8-stage pipeline compiles and runs in default flow.
2. Directed tests (`test02`, `test03`, `test04`) pass.
3. Random smoke (`rv32_rand_0*.hex`) passes 100/100.
4. Full generated random regression passes 500/500.
5. Benchmark table can be generated successfully.
6. Change log is updated with architecture and measured impact.
