# T2b-step3 Plan: Dispatch Fully Through RS

## Context

After T2b-step2b (unified arbitration, RS-IFQ deadlock resolved):
- Architecture is **2-wide in-order superscalar with a 4-entry slot0-ALU recovery RS**.
- Only slot0 ALU ops touch RS; slot1 ALU / load / store / branch all stay in-order.
- Measured `dual%` ≈ 11–12% on dotprod/matmul; `wait_cycles ≈ 3943` on matmul is the #1 remaining bottleneck.

## Goal

Migrate dispatch fully through the RS so that scheduling decisions become
data-flow driven instead of fetch-order driven. This is the prerequisite for
both **complete OoO** and **complete dual-issue** (the second ALU pipe is
meaningless without a real RS to feed it).

## Why This Before A Second ALU Pipe

| Dimension | T2b-step3 (this plan) | Add 2nd ALU pipe |
|-----------|------------------------|------------------|
| Scope | cpu_top + rs_shadow mostly | EX1b/EX2b + PRF read ports + CDB + ROB retire width |
| Risk | Medium (arbitration + bypass) | High (multi-file timing + verification gaps) |
| ROI | Directly attacks `wait_cycles` (top bottleneck) | Bounded by 1.x backend until RS exists |
| Prerequisites met | Yes (RS already in datapath) | Needs unified RS first |
| Test infra | Existing pair-split micros + bench + robust | Would need new dual-ALU stress tests |

## Sub-step Roadmap

### step3a-v0 — slot1 ALU enter RS via second alloc port  **[ATTEMPTED, REVERTED]**

**What was tried**: Added RS port B (second alloc port in `rs_shadow.v`) so
that when slot1 is an ALU op and pair-blocks (RAW/LU/xWAW vs slot0), slot1
pops, renames, and enters RS port B while slot0 continues in-order via EX1.
PRF gained ra6/ra7 read ports for slot1 operand capture; slot1 got a decode-
stage `imm_gen` instance.

**Why it failed (two coupled issues)**:

1. **RS drain bottleneck**. `rs_issue_allow` requires
   `slot0_is_alu && !slot0_pop_prearb`. A long stream of slot0 non-ALU
   instructions (load/store/branch) prevents RS from issuing → RS port B
   alloc traffic has nowhere to go → port B blocks → slot1 stalls → ROB
   eventually fills → full deadlock (benchmarks timeout at 199997 cycles
   with single-issue rate near 100%).

2. **Age-based RS arbitration breaks correctness**. Restoring age-based
   `rs_issue_age_allow` (so RS can preempt slot0 ALU when older entry
   ready) increases drain rate but breaks the robust test: a wrong-path
   store retires. Suspected mechanism: when RS preempts `id_ex` while
   slot0 simultaneously wants to advance, a non-ALU slot0 in-flight
   in the EX path gets clobbered by the RS write into `id_ex`.

**Conclusion**: The current single-RS-port → slot0-EX1 issue model cannot
sustain dual alloc rate (port A + port B). step3a needs a structural change
before it can succeed.

### step3a-v1 — Redesign options (next attempts)

Pick **one** of the following structural changes before retrying slot1
RS dispatch:

**Option A: dedicated EX1b ALU pipe for RS issue**
- Today: RS issues into `id_ex` (slot0's EX1 pipeline).
- Proposal: RS issues into a NEW pipeline register set `id_ex_rs_*` with
  its own ALU instance. `id_ex` remains slot0 in-order only.
- Pros: RS drain decoupled from slot0 occupancy.
- Cons: more pipeline regs, additional CDB lane needed (3 lanes), PRF
  read port budget grows.

**Option B: RS issues into slot1's EX1b pipe when slot1 idle**
- Today: `u_alu_slot1` only fires for paired slot1 ALU.
- Proposal: when `id1_ex_valid=0` (no paired slot1), let RS issue use
  `id1_ex_*` registers and `u_alu_slot1`. Add MUX at front of id1_ex.
- Pros: reuses existing slot1 ALU/PRF/CDB infrastructure.
- Cons: RS issue priority arbitration becomes 2-way (slot0 vs slot1 pipe).
  Need careful design to avoid CDB lane collisions when both pipes fire.

**Option C: dispatch slot0 ALU through RS (truly remove in-order slot0
ALU path)**
- Today: slot0 ALU has BOTH RS observability alloc AND in-order EX1.
- Proposal: slot0 ALU goes only through RS (RS issues to EX1 always).
  Non-ALU slot0 keeps the existing in-order path.
- Pros: unifies the model; RS always feeds EX1; `slot0_is_alu` constraint
  on `rs_issue_allow` is naturally consistent (issue and slot0 alloc are
  the same instruction stream).
- Cons: every slot0 ALU eats RS depth; need slot0-direct fast path when
  RS would be a 1-cycle pass-through; need slot1 RS dispatch via a 2nd
  alloc port (back to step3a-v0 problem unless paired with option A or B).

**Recommended path forward**: Option B is the smallest structural delta
and reuses `u_alu_slot1`. Try it as step3a-v1. If CDB collision logic
becomes too complex, fall back to Option A.

### step3a-v1 — Option B result  **[DONE]**

Implemented Option B in `cpu_top.v`: RS-ready entry can issue through slot1
EX1b path when A-path is unavailable and slot1 pop is idle.

Final correctness fixes after initial 462/500 random-regression failures:

1. **RS stale-entry self-invalidation (`rs_shadow.v`)**
   - Root cause: each slot0 ALU instruction exists in both in-order path and
     RS. If in-order copy already completed, stale RS entry could still issue
     later and broadcast with a possibly re-used ROB tag.
   - Fix: drop RS entry when CDB ptag matches entry `rd` ptag; also skip
     same-cycle issue candidate if it is being invalidated by CDB.

2. **Suppress from-RS arch-idx PRF write (`cpu_top.v`)**
   - Root cause: Option B OoO issue writing `prf_we1` into arch index
     (`PRF[0..31]`) can clobber identity-ptag readers of older in-flight ops.
   - Fix: gate `prf_we1` with `!id1_ex_from_rs` while keeping `prf_we3`
     (ptag write) active for RS-issued entries.

Validation after fixes:
- `make`: PASS
- `make robust`: PASS
- `python3 tools/run_benchmarks.py`: 9/9 PASS
- `python3 tools/run_generated_tests.py --dir tb/programs/micro_pair_split --glob '*.hex' -j 1`: 4/4 PASS
- `python3 tools/run_generated_tests.py -j 1`: 500/500 PASS

### step3b — non-ALU dispatch flows through RS

#### step3b-v1 (LOAD-only)  **[DONE]**

First non-ALU slice landed with a conservative scope: **slot0 LOAD** is now
RS-eligible, while store/branch/jump/system remain in-order.

Design choices:
- Extend RS payload with `mem_read` + `mem_funct3` fields.
- Keep A-path (`RS -> id_ex/slot0 EX1`) ALU-only.
- Allow LOAD to issue via B-path (`RS -> id1_ex/slot1 EX1b`) using slot1 load
  datapath already present.
- For LOAD alloc, force RS operand-2 as ready/x0 so address-gen only waits on
  `rs1` (base register), matching real dependency semantics.

Safety constraints preserved:
- No store/branch/jump/system enters RS in this slice.
- Existing step3a-v1 stale-entry invalidation remains active.

Validation:
- `make`: PASS
- `make robust`: PASS
- `python3 tools/run_benchmarks.py`: 9/9 PASS
- `python3 tools/run_generated_tests.py --dir tb/programs/micro_hazard --glob '*.hex' -j 1`: 6/6 PASS
- `python3 tools/run_generated_tests.py --dir tb/programs/micro_pair_split --glob '*.hex' -j 1`: 4/4 PASS
- `python3 tools/run_generated_tests.py -j 1`: 500/500 PASS

#### step3b-v2 (STORE-through-RS)  **[DONE]**

Extended RS eligibility to include **slot0 STORE** with conservative execution
rules to preserve correctness:

- RS payload now carries `reg_write` + `mem_write` control bits.
- STORE and other non-reg-write entries are kept off B-path; B-path remains
  register-write-focused (ALU/LOAD) to avoid slot1 side effects.
- Added ROB-tag based RS self-invalidation (`wb_rob_tag`) so entries that do
  not produce CDB writes (for example STORE) are still retired from RS when
  their in-order twin has completed WB/commit window, preventing stale reissue
  after ROB tag reuse.

Validation (same gate as v1):
- `make`: PASS
- `make robust`: PASS
- `python3 tools/run_benchmarks.py`: 9/9 PASS
- `python3 tools/run_generated_tests.py --dir tb/programs/micro_hazard --glob '*.hex' -j 1`: 6/6 PASS
- `python3 tools/run_generated_tests.py --dir tb/programs/micro_pair_split --glob '*.hex' -j 1`: 4/4 PASS
- `python3 tools/run_generated_tests.py -j 1`: 500/500 PASS

### step3c — RS depth 4 → 8 *(blocked on step3a-v1)*
*(unchanged from original plan)*

### step3d (optional) — Load early wakeup *(blocked on step3c)*
*(unchanged from original plan)*

## Acceptance Criteria (overall)

- [x] All existing tests still pass: `make`, `make robust`, 9/9 bench, 4/4 pair-split micro, generated regression (`-j 1`).
- [ ] `dual%` ≥ baseline (no regression).
- [ ] `wait_cycles` reduction visible in the rs_shadow counters.
- [ ] No new timing/structural assertions in TB (e.g. ROB tag wrap, free-list underflow).

## Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| Two-source alloc (slot0+slot1) creates race in RS state | Start with single alloc port + slot0 priority; only widen after step3a stable |
| Age comparison for RS issue against IFQ slot1 | Re-use existing `rob_head_tag` 4-bit subtraction; verify slot1's tag also covered |
| Rename free-list mismatch when slot1 ALU now goes via RS instead of in-order EX1 | Ensure rename `alloc/free` still tied to final pop_allow; CDB `free_ptag` covers RS-completed entries |
| RS ALU result vs. in-order ALU result race on CDB | Existing CDB arbitration in cpu_top already chooses RS over in-order when both fire; verify still holds |

## Validation Commands

```bash
# Build + correctness
make
make robust

# Standard bench (CPI / dual% / wait_cycles)
python3 tools/run_benchmarks.py

# Pair-split micros (regression for step2b territory)
python3 tools/run_generated_tests.py --dir tb/programs/micro_pair_split --glob '*.hex' -j 1

# Random hazard regression (200 cases, j=1 per repo policy)
python3 tools/run_generated_tests.py -j 1
```

## Rollback Plan

Each sub-step lands in its own commit on `feature/ooo`. If a regression appears
after step3X, `git revert <sha>` restores the previous known-good state. No
sub-step modifies file structure (only logic in cpu_top + rs_shadow), so revert
is mechanical.
