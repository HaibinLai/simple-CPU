# 8-Stage Pipeline Tutorial (Hands-On)

This tutorial explains how to upgrade the current CPU from 7 stages to 8 stages with a correctness-first workflow.

Current baseline:

- IF -> ID1 -> ID2 -> EX -> AGU -> MEM -> WB

Target:

- IF -> ID1 -> ID2 -> EX1 -> EX2 -> AGU -> MEM -> WB

If you want the high-level roadmap first, read:

- `docs/8stage-implementation-plan.md`

If you want focused hazard validation cases, read:

- `docs/8stage-hazard-micro-tests.md`

## 0) Pre-Flight Checklist

Before code changes:

1. Confirm baseline is green.
2. Use explicit `.hex` paths in `make run` commands.
3. Keep a short validation loop (directed + smoke).

Recommended baseline commands:

- `make run PROG=tb/programs/test02.hex TIMEOUT_NS=3000000`
- `make run PROG=tb/programs/test03.hex TIMEOUT_NS=3000000`
- `make run PROG=tb/programs/test04.hex TIMEOUT_NS=3000000`
- `python3 tools/run_generated_tests.py --glob 'rv32_rand_0*.hex' --retries 2`

## 1) Add EX1/EX2 Pipeline Register Bank

File:

- `rtl/core/cpu_top.v`

Action:

1. Add `ex1_ex2_*` registers near other pipeline register declarations.
2. Move the existing EX-stage logic into two parts:
- EX1 builds/stages operand/control context.
- EX2 performs final ALU/branch/redirect/exception resolution.
3. Keep AGU input from EX2 outputs so backend stages stay stable.

Tips:

- Keep naming consistent with existing style (`id_ex_*`, `ex_mem_*`).
- Ensure reset values for all new control bits are safe (no accidental write/mem op).

## 2) Rewire Redirect and Flush Boundaries

File:

- `rtl/core/cpu_top.v`

Action:

1. Compute `ex_redirect` and `ex_redirect_pc` in EX2.
2. Ensure flush reaches IF/ID1, ID1/ID2, and ID/EX where needed.
3. Keep exception (`ecall`, illegal) and `mret` semantics unchanged.

Why:

- Splitting EX changes where branch truth is known.
- Redirect must be aligned with the stage that has final decision data.

## 3) Update Forwarding Network

Files:

- `rtl/core/forwarding.v`
- `rtl/core/cpu_top.v`

Action:

1. Re-define nearest-first producer priority for EX consumers.
2. Include EX2 as the nearest ALU producer source where applicable.
3. Keep load forwarding behavior explicit (MEM-derived value path).

Validation micro-cases:

1. ALU->ALU back-to-back RAW.
2. load->use immediate dependency.
3. branch compare using recently produced register values.

## 4) Keep Hazard Conservative First

Files:

- `rtl/core/hazard.v`
- `rtl/core/cpu_top.v`

Action:

1. Keep source-aware checks (`id_use_rs1`, `id_use_rs2`).
2. Expand stage-window checks conservatively for the split.
3. Accept temporary extra stalls if needed.

Why:

- Correctness-first reduces debug complexity during structural change.
- Performance tuning is safer after green regressions.

## 5) Fast Validation Loop

Run after each major edit batch:

- `make run PROG=tb/programs/test02.hex TIMEOUT_NS=3000000`
- `make run PROG=tb/programs/test03.hex TIMEOUT_NS=3000000`
- `make run PROG=tb/programs/test04.hex TIMEOUT_NS=3000000`

Then smoke:

- `python3 tools/run_generated_tests.py --glob 'rv32_rand_0*.hex' --retries 2`

If green, run full:

- `python3 tools/run_generated_tests.py --dir tb/programs/generated`
- `python3 tools/run_benchmarks.py --regen --timeout-ns 8000000 --wall-timeout-s 240`

## 6) Typical Failure Patterns and Fix Hints

1. Timeout with retired=0
- Usually wrong program path or bad redirect/flush loop.
- Check `PROG` path and redirect conditions.

2. Wrong branch behavior
- Compare predicted vs actual target at EX2.
- Verify flush timing for upstream stages.

3. Random-only failures
- Re-check forwarding priority and bubble gating.
- Confirm no invalid stage writes register/memory.

4. Performance drop after green correctness
- Expected in conservative hazard mode.
- Tighten hazard windows after baseline stability.

## 7) Optional Performance Tightening After Stable 8-Stage

1. Narrow hazard checks by actual source usage and producer distance.
2. Add stall counters by category:
- `stall_load_use_ex1`
- `stall_load_use_ex2`
- `stall_redirect_recovery`
3. Re-run benchmark table and compare CPI deltas.

## 8) Documentation Update Checklist

After implementation, update:

1. Architecture section in `README.md`.
2. Transition/change-log document in `docs`.
3. Validation command snippets and measured results.

Recommended commit sequence:

1. `8-stage structural split (EX1/EX2)`
2. `8-stage forwarding/hazard stabilization`
3. `8-stage documentation and benchmark update`
