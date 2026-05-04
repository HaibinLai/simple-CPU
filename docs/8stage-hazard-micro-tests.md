# 8-Stage Hazard Micro-Tests

This document lists focused micro-tests for 8-stage hazard windows.

## Purpose

These tests are intentionally small and targeted, designed to catch regressions in:

- load-use dependency handling
- branch dependency windows
- short dependency chains around branch decisions

## Test Generator

Script:

- `tools/gen_hazard_micro_tests.py`

Generate tests:

- `python3 tools/gen_hazard_micro_tests.py`

Output directory:

- `tb/programs/micro_hazard`

## Test Cases

1. `hz8_load_use_rs1.hex`
- Verifies immediate load-use with consumer on rs1.

2. `hz8_load_use_rs2.hex`
- Verifies immediate load-use with consumer on rs2.

3. `hz8_load_branch_taken.hex`
- Verifies load result consumed by branch compare (taken path).

4. `hz8_load_branch_not_taken.hex`
- Verifies load result consumed by branch compare (not-taken path).

5. `hz8_alu_branch_dep.hex`
- Verifies ALU->branch immediate dependency.

6. `hz8_branch_chain_dep.hex`
- Verifies short branch dependency chain with back-to-back branch checks.

## How To Run

Run all micro-tests with the existing regression runner:

- `python3 tools/run_generated_tests.py --dir tb/programs/micro_hazard --glob 'hz8_*.hex'`

Run a single case manually:

- `make run PROG=tb/programs/micro_hazard/hz8_load_use_rs1.hex TIMEOUT_NS=3000000`

## Expected Behavior

- All tests should end by writing `0xCAFEBABE` into x31 (PASS trigger in testbench).
- Any hazard regression usually manifests as timeout, wrong x31, or incorrect branch path.

## Current Snapshot (8-stage, latest optimization)

ISS semantic check:

- `6/6` programs reach PASS under the independent ISA simulator.

RTL execution check:

- `3/6` PASS, `3/6` FAIL on the current 8-stage configuration.
- Failing cases observed:
	- `hz8_alu_branch_dep.hex`
	- `hz8_branch_chain_dep.hex`
	- `hz8_load_use_rs2.hex`

Interpretation:

- The micro-tests are valid (ISS green), and current RTL failures likely indicate real dependency-window hazards.
- Keep these tests in regression to guard future forwarding/hazard fixes.
