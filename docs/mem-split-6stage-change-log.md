# 6/7-Stage Transition Change Log (MEM First, then ID Split)

## Summary
This change sequence migrates the core pipeline in two incremental steps:

1. 5-stage -> 6-stage by splitting MEM
2. 6-stage -> 7-stage by splitting ID

Stage-6 split:

- EX -> AGU -> MEM

Stage-7 split:

- ID -> ID1 -> ID2

The goal is to evolve the microarchitecture incrementally while preserving interfaces and keeping the verification flow stable.

## Pipeline Structure

### Before
- IF -> ID -> EX -> MEM -> WB

### After Stage-6
- IF -> ID -> EX -> AGU -> MEM -> WB

### After Stage-7
- IF -> ID1 -> ID2 -> EX -> AGU -> MEM -> WB

## What Was Changed

### 1) Top-Level Pipeline Restructure
File: `rtl/core/cpu_top.v`

- Added an AGU/MEM pipeline register bank.
- Kept EX-stage branch/exception redirect behavior unchanged.
- Moved MEM-stage consumption from EX/MEM signals to AGU/MEM signals.
- Preserved WB-stage interface and debug outputs.

### 2) Hazard Detection Update for 6 Stages
File: `rtl/core/hazard.v`

- The previous load-use detector only looked at ID/EX.
- The new detector checks both:
  - ID/EX load dependency
  - EX/AGU load dependency
- This enables safe stalling in the deeper pipeline, including cases that require up to two bubbles.

### 3) Forwarding Network Expansion
File: `rtl/core/forwarding.v`

Forwarding sources were extended from 2 to 3 priority levels:

1. EX/AGU result
2. AGU/MEM result
3. MEM/WB writeback data

In `cpu_top.v`, forwarding select muxes were updated accordingly.

## Correctness Notes

### Load-Use Behavior
After splitting MEM, load data becomes available later relative to decode/execute. To preserve correctness quickly, stall logic is conservative and may introduce more stalls than the 5-stage version.

### Stage-7 Optimization: One-Bubble Load-Use (Common Case)

A follow-up optimization was added for the 7-stage pipeline:

- Enabled MEM->EX forwarding for load data (from `mem_load_data`).
- Masked the extra conservative EX/AGU load-use stall in top-level hazard wiring.

Practical effect:

- Common immediate load-use chains now require one bubble instead of two.
- Directed `test02` improved from CPI `1.769` to `1.692` while preserving correctness.

### Stage-7 Optimization: Source-Aware Hazard Check

Another low-risk optimization was added in decode/hazard coupling:

- Hazard detection now checks dependencies only for source registers that an instruction actually reads.
- For example, instructions such as `LUI`, `AUIPC`, and `JAL` no longer trigger false `rs2`-related load-use stalls.

Practical effect:

- Removes unnecessary stalls in decode for non-`rs2` consumers.
- Preserves all existing directed and random regression results.

### Branch/Exception Path
Branch prediction training and redirect logic remain in EX. Exception and `mret` control flow are still resolved in EX, consistent with prior behavior.

## Regression Snapshot

The following directed tests pass after this change:

- `tb/programs/test02.hex`
- `tb/programs/test03.hex`
- `tb/programs/test04.hex`

Additional Stage-7 smoke results:

- Directed tests (`test02`, `test03`, `test04`): PASS
- Random smoke (`rv32_rand_0*.hex`, 100 cases): `100/100 PASS`
- Full random regression (`tb/programs/generated`, 500 cases): `500/500 PASS`

## Validation Commands (Reproducible)

Use explicit program paths (for example `tb/programs/test02.hex`) when running `make run`.

Directed tests:

- `make run PROG=tb/programs/test02.hex TIMEOUT_NS=3000000`
- `make run PROG=tb/programs/test03.hex TIMEOUT_NS=3000000`
- `make run PROG=tb/programs/test04.hex TIMEOUT_NS=3000000`

Random regression:

- `python3 tools/run_generated_tests.py --dir tb/programs/generated`
- `python3 tools/run_generated_tests.py --glob 'rv32_rand_0*.hex' --retries 2`

Benchmarks:

- `python3 tools/run_benchmarks.py --regen --timeout-ns 8000000 --wall-timeout-s 240`

Representative measured results from this step:

- `test02`: `cycles=22`, `retired=13`, `CPI=1.692308`
- `test03`: `cycles=60`, `retired=26`, `CPI=2.307692`
- `test04`: `cycles=15`, `retired=4`, `CPI=3.750000`
- Random smoke subset (`rv32_rand_0*.hex`): `100/100 PASS`, weighted CPI `1.747145`

## Stability Issue and Resolution

During early 6-stage runs, random generated regression sometimes failed with simulator-level errors such as:

- `syntax error` in `sim/cpu.vvp`
- `Unable to resolve label ...`
- `unresolved functor reference`
- `Program not runnable`

Root cause was infrastructure contention, not architectural correctness:

- Different runs/processes were sharing and overwriting the same simulation artifact path.

Resolution:

1. `Makefile` now supports configurable `SIM_DIR`.
2. `tools/run_generated_tests.py` now uses an isolated `SIM_DIR` per process.
3. The runner also retries probable simulator flakes.

After this fix, the full 500-case random regression completed with:

- `Passed: 500`
- `Failed: 0`

## Recommended Next Steps

1. Add targeted 6-stage stress tests for two-cycle load-use dependency windows.
2. Add explicit stall counters (load-use-1, load-use-2) to quantify added bubbles.
3. Optimize conservative stalling with additional valid forwarding cases.
4. Add dedicated 6-stage hazard micro-tests to prevent regressions in future stage-splits.

## Files Involved in This Step

- `rtl/core/cpu_top.v`
- `rtl/core/forwarding.v`
- `rtl/core/hazard.v`
- `README.md`

## Next Step Documents (8-Stage)

- Implementation plan: `docs/8stage-implementation-plan.md`
- Hands-on tutorial: `docs/8stage-tutorial.md`
- Bring-up log (first 8-stage RTL pass): `docs/8stage-bringup-log.md`
