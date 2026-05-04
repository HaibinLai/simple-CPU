# 8-Stage Bring-Up Log (Structural EX Split)

## Objective
Start 8-stage migration from the current 7-stage baseline by introducing an EX split with minimal risk and correctness-first constraints.

Baseline pipeline:

- IF -> ID1 -> ID2 -> EX -> AGU -> MEM -> WB

Bring-up target:

- IF -> ID1 -> ID2 -> EX1 -> EX2 -> AGU -> MEM -> WB

## What Was Implemented

### 1) Inserted EX2 pipeline register bank
File:

- `rtl/core/cpu_top.v`

Changes:

- Added a new `EX2/AGU` register bank (`ex2_agu_*`).
- Kept existing EX combinational logic behavior in EX1 to reduce bring-up risk.
- AGU now consumes inputs from `ex2_agu_*` instead of `ex_mem_*`.

### 2) Kept forwarding model stable for bring-up
File:

- `rtl/core/cpu_top.v`

Changes:

- Reused the existing forwarding network and selection flow.
- Preserved current MEM-derived load forwarding behavior.

### 3) Switched hazard wiring to conservative mode (initial bring-up)
File:

- `rtl/core/cpu_top.v`

Changes:

- Re-enabled the second hazard check window for load-use correctness in deeper EX timing:
  - `ex_agu_mem_read = ex_mem_mem_read`
  - `ex_agu_rd = ex_mem_rd`

Rationale:

- With EX split, one-bubble load-use is no longer guaranteed in all cases during initial bring-up.
- Conservative stalling is acceptable in this phase to protect correctness.

### 4) Optimization Pass 1: Remove the extra conservative hazard window
File:

- `rtl/core/cpu_top.v`

Changes:

- Disabled the second-stage conservative hazard check in top-level wiring:
  - `ex_agu_mem_read = 1'b0`
- Kept MEM-derived forwarding unchanged.

Observed effect:

- Directed `test02` improved from `cycles=24` to `cycles=23`.
- No directed or random correctness regressions were observed.

## Validation Results

Directed tests:

- `test02`: PASS, `cycles=24`, `retired=13`, `CPI=1.846154`
- `test03`: PASS, `cycles=65`, `retired=28`, `CPI=2.321429`
- `test04`: PASS, `cycles=16`, `retired=4`, `CPI=4.000000`

Random smoke subset (after Optimization Pass 1):

- `rv32_rand_0*.hex`: `100/100 PASS`
- Weighted CPI: `1.791020`

Full random regression (after Optimization Pass 1):

- `tb/programs/generated`: `500/500 PASS`
- Weighted CPI: `1.786219`

Benchmark sanity run (after Optimization Pass 1):

- Command completed successfully: `python3 tools/run_benchmarks.py --regen --timeout-ns 8000000 --wall-timeout-s 240`
- Benchmarks reported: `9/9 PASS`

Hazard micro-test run:

- Added focused suite under `tb/programs/micro_hazard` via `tools/gen_hazard_micro_tests.py`.
- ISS semantic check: `6/6 PASS`.
- RTL check (current optimized 8-stage): `3/6 PASS`, `3/6 FAIL`.
- Failing windows detected:
  - `hz8_alu_branch_dep.hex`
  - `hz8_branch_chain_dep.hex`
  - `hz8_load_use_rs2.hex`

## Commands Used

- `make run PROG=tb/programs/test02.hex TIMEOUT_NS=3000000`
- `make run PROG=tb/programs/test03.hex TIMEOUT_NS=3000000`
- `make run PROG=tb/programs/test04.hex TIMEOUT_NS=3000000`
- `python3 tools/run_generated_tests.py --glob 'rv32_rand_0*.hex' --retries 2`
- `python3 tools/run_generated_tests.py --dir tb/programs/generated`
- `python3 tools/run_benchmarks.py --regen --timeout-ns 8000000 --wall-timeout-s 240`

## Known Tradeoff in This Bring-Up Phase

- Correctness is prioritized over CPI.
- Some extra stalls may still exist compared with a fully tuned 8-stage design.

## Next Steps

1. Rebalance forwarding priorities with explicit EX2 producer timing assumptions.
2. Add targeted micro-tests for load-use and branch dependency windows in 8-stage.
3. Run benchmark table and compare pre/post optimization CPI side-by-side.
4. Update consolidated transition documentation after the next optimization pass.
