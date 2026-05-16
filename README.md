# CPU Architecture 102

## 2-Wide Out-of-Order Superscalar RISC-V (RV32I) CPU

A fully functional dual-issue, out-of-order execution RISC-V CPU built in Verilog,
developed incrementally for teaching and learning purposes.
4,754 lines of synthesizable RTL across 18 modules.

## Architecture Summary

| Feature | Implementation |
|---------|---------------|
| ISA | RV32I (40 core instructions) |
| Pipeline | 8-stage: IF → ID1 → ID2 → EX1 → EX2 → AGU → MEM → WB |
| Issue Width | 2-wide superscalar (slot0 full + slot1 ALU/load/store/branch) |
| Execution Model | Out-of-order issue & execute, in-order commit |
| Reservation Station | 8-entry unified RS, age-based oldest-first selection |
| Reorder Buffer | 16-entry ROB, 2-wide alloc / 2-wide WB / 2-wide commit |
| Register File | 64-entry Physical Register File (PRF), 6 read / 4 write ports |
| Register Renaming | Full rename with free-list + busy vector |
| Common Data Bus | 2-lane CDB for result broadcast and RS wakeup |
| Branch Prediction | TAGE-2L direction predictor + 2-way BTB + RAS |
| I-Cache | 2-way set-associative, 64 sets × 4 words/line = 2 KB |
| D-Cache | 2-way set-associative, 64 sets × 4 words/line = 2 KB, dual-port |
| Forwarding | ptag-based, 5-stage deep (EX→MEM→EX2→AGU→WB) per slot |

### Pipeline Diagram
```
                   ┌─ slot0: EX1 → EX2 → AGU → MEM → WB  (full: ALU/load/store/branch/jump)
IF → ID1 → ID2 ──┤
                   └─ slot1: EX1b → WB                     (1-cycle: ALU/load/store/branch)
                   
                   ┌─ RS A-path → slot0 EX1  (乱序发射到主流水线)
         RS(8) ───┤
                   └─ RS B-path → slot1 EX1b (乱序发射到副流水线)
```

### Out-of-Order Execution Flow
```
Dispatch ──→ RS (wait for operands via CDB wakeup)
         ──→ ROB (allocate tag, track in-order commit)
         ──→ Rename (allocate physical register, set busy)

Issue    ──→ RS selects oldest-ready entry
         ──→ A-path: non-load ops → slot0 EX1 pipeline
         ──→ B-path: ALU/load/store/branch → slot1 EX1b (1-cycle)

Execute  ──→ slot0: 5-stage (EX1→EX2→AGU→MEM→WB)
         ──→ slot1: 1-stage (EX1b, immediate writeback)

Writeback ──→ CDB broadcast (ptag + value)
          ──→ RS wakeup dependent entries
          ──→ ROB mark done

Commit   ──→ ROB head retires in program order (up to 2/cycle)
         ──→ Rename free old ptag
```

## Performance Results (OoO dual-issue, current HEAD)

All numbers measured with zero-latency D-cache model. `CPI_c` = cycles / committed instructions
(the standard "instructions executed" metric). `dual%` = percentage of issue cycles with 2 instructions.

### Benchmark CPI and Event Breakdown

| Benchmark | Cycles | Committed | CPI_c | dual% | br_miss% | D$_miss% |
|-----------|-------:|----------:|------:|------:|---------:|---------:|
| fib_20 | 96 | 148 | 0.649 | 50.0 | 4.2 | 0.0 |
| sum_1_to_100 | 319 | 410 | 0.778 | 33.8 | 1.9 | 0.0 |
| bsearch_64 | 754 | 964 | 0.782 | 42.7 | 4.0 | 15.5 |
| popcount_64 | 979 | 1,159 | 0.845 | 66.4 | 0.3 | 0.0 |
| crc32_64b | 2,070 | 2,575 | 0.804 | 62.3 | 10.9 | 25.0 |
| bsort_16 | 1,401 | 1,677 | 0.835 | 40.6 | 1.0 | 0.6 |
| memcpy_64w | 401 | 397 | 1.010 | 72.9 | 2.9 | 24.6 |
| dotprod_32 | 8,627 | 7,762 | 1.111 | 45.4 | 19.3 | 16.0 |
| matmul_4x4 | 17,809 | 16,139 | 1.103 | 44.3 | 18.9 | 6.3 |

**Key observations:**
- 6 of 9 benchmarks achieve **CPI_c < 1.0** — meaning the CPU retires more than 1 instruction per cycle on average, demonstrating effective dual-issue + OoO scheduling.
- `fib_20` reaches CPI_c = **0.649** (1.54 IPC), the highest throughput.
- Compute-heavy kernels (`dotprod`, `matmul`) are limited by branch mispredictions (19%) from the software-multiply subroutine call pattern.

### Dual-Issue Pairing Analysis

When slot1 cannot pair, the reason breakdown:

| Benchmark | dual% | RAW% | nta% | xww% | lu% | nv1% |
|-----------|------:|-----:|-----:|-----:|----:|-----:|
| fib_20 | 50.0 | 4.5 | 4.5 | 88.6 | 0.0 | 2.3 |
| sum_1_to_100 | 33.8 | 1.5 | 50.0 | 48.0 | 0.0 | 0.5 |
| bsearch_64 | 42.7 | 49.3 | 18.7 | 19.0 | 11.3 | 1.7 |
| popcount_64 | 66.4 | 74.4 | 25.2 | 0.0 | 0.0 | 0.4 |
| crc32_64b | 62.3 | 25.2 | 31.3 | 18.6 | 0.0 | 24.9 |
| bsort_16 | 40.6 | 39.7 | 5.2 | 2.3 | 18.4 | 0.2 |
| memcpy_64w | 72.9 | 90.3 | 4.2 | 1.4 | 0.0 | 2.8 |
| dotprod_32 | 45.4 | 32.7 | 32.2 | 16.7 | 1.0 | 16.3 |
| matmul_4x4 | 44.3 | 34.2 | 33.1 | 17.4 | 0.0 | 15.3 |

- **RAW** — same-cycle data dependency (fundamental)
- **nta** — slot1 instruction type not pairable (jump/jalr)
- **xww** — cross-cycle WAW (slot1 rd conflicts with in-flight slot0)
- **lu** — load-use hazard blocking slot1
- **nv1** — no valid instruction in slot1 position (IFQ short)

### Test Suite Results

| Test Suite | Count | Pass Rate |
|------------|------:|----------:|
| Robustness (wrong-path store) | 1 | 100% |
| Benchmarks | 9 | 100% (9/9) |
| Micro hazard tests | 6 | 100% (6/6) |
| Micro pair/split tests | 4 | 100% (4/4) |
| Random generated (RV32I) | 500 | 100% (500/500) |

## Module Overview

| Module | Lines | Role |
|--------|------:|------|
| `cpu_top.v` | 1,967 | Top-level pipeline, arbitration, OoO control |
| `rs_shadow.v` | 477 | Reservation Station (8-entry, unified) |
| `bpu.v` | 394 | Branch Prediction Unit (TAGE + GHR + BTB) |
| `rob.v` | 333 | Reorder Buffer (16-entry, 2-wide) |
| `bpu_tage_eval.v` | 274 | TAGE shadow evaluator |
| `dmem.v` | 220 | D-Cache (2-way SA, dual-port) |
| `rename.v` | 189 | Register rename (free-list + busy vec) |
| `ifq.v` | 186 | Instruction Fetch Queue (dual-pop) |
| `control.v` | 165 | Decode / control signal generation |
| `ras_shadow.v` | 126 | Return Address Stack (IF-stage predictor) |
| `imem.v` | 98 | I-Cache (2-way SA) |
| `prf.v` | 83 | Physical Register File (64-entry, 6R/4W) |
| `defines.v` | 70 | Global constants and opcodes |
| `forwarding.v` | 58 | ptag-based forwarding logic |
| `hazard.v` | 36 | Load-use hazard detection |
| `alu.v` | 30 | ALU (shared by both slots) |
| `branch_unit.v` | 25 | Branch comparison unit |
| `imm_gen.v` | 23 | Immediate generator |
| **Total** | **4,754** | |

## Course Roadmap: From 5 Stages to 10 Stages

This repository can also serve as the implementation base for an architecture course sequence that starts from a classic 5-stage pipeline and gradually evolves toward a deeper 10-stage design.

The main teaching goal is not simply to increase the number of stages, but to help students understand the tradeoff between shorter critical paths and higher control complexity.

### Course Objectives
- Understand why deeper pipelines can support higher clock frequency.
- Understand why deeper pipelines also increase data hazard distance and branch recovery cost.
- Learn how forwarding, hazard detection, branch prediction, and cache timing must evolve as the pipeline becomes deeper.
- Compare performance and complexity across 5-stage, 6-stage, 8-stage, and 10-stage implementations.

### Recommended Teaching Path

#### Lesson 1: Classic 5-Stage Pipeline
Pipeline:
```text
IF -> ID -> EX -> MEM -> WB
```

Topics:
- Basic datapath and control.
- Register forwarding and load-use stall.
- Branch handling and branch prediction.
- Basic cache integration.

#### Lesson 1.1: From 5 Stages to 6 Stages
Recommended pipeline:
```text
IF -> ID -> EX -> AGU -> MEM -> WB
```

Why this split:
- It is the smallest structural extension from the current design.
- It cleanly separates address generation from memory access.
- It prepares the design for more realistic data-cache timing.

Topics:
- Longer load-use dependency distance.
- Store-data forwarding beyond the classic 5-stage model.
- Revised hazard detection and forwarding rules.

#### Lesson 1.2: From 6 Stages to 7 Stages
Recommended pipeline:
```text
IF -> ID1 -> ID2 -> EX -> AGU -> MEM -> WB
```

Topics:
- Split decode from register read.
- Move field extraction and control generation earlier.
- Revisit when operand values become available.

#### Lesson 1.3: From 7 Stages to 8 Stages
Recommended pipeline:
```text
IF -> ID1 -> ID2 -> EX1 -> EX2 -> AGU -> MEM -> WB
```

Topics:
- Split execute into early operand processing and late result generation.
- Analyze how deeper execute stages increase forwarding complexity.
- Reevaluate branch resolution timing and penalty.

#### Lesson 1.4: From 8 Stages to 9 Stages
Recommended pipeline:
```text
IF1 -> IF2 -> ID1 -> ID2 -> EX1 -> EX2 -> AGU -> MEM -> WB
```

Topics:
- Separate front-end PC generation and I-cache access.
- Replace idealized fetch timing with a staged instruction fetch path.
- Study how front-end timing affects branch prediction behavior.

#### Lesson 1.5: From 9 Stages to 10 Stages
Recommended pipeline:
```text
IF1 -> IF2 -> ID1 -> ID2 -> EX1 -> EX2 -> AGU -> MEM1 -> MEM2 -> WB
```

Topics:
- Split data-cache access and data return.
- Introduce more realistic miss handling and pipeline freeze behavior.
- Study how memory-system timing changes overall CPI.

### Final 10-Stage Reference Structure
```text
IF1  : PC generation / branch prediction lookup
IF2  : I-cache access / instruction return
ID1  : predecode / field extraction
ID2  : register read / control generation
EX1  : operand select / early execute
EX2  : ALU result / branch resolution
AGU  : address generation for load/store
MEM1 : D-cache lookup
MEM2 : data return / memory response staging
WB   : register write-back
```

### What Students Should Learn
- A deeper pipeline is not automatically faster.
- Frequency potential may improve, but CPI often gets worse.
- Branch misprediction penalty grows as the resolution stage moves later.
- Forwarding networks and hazard detection scale in complexity faster than the datapath itself.
- Real cache timing matters if the goal is to study meaningful pipeline scaling.

### Suggested Implementation Milestones
1. Build a correct 6-stage version before discussing anything deeper.
2. Extend forwarding and hazard detection after every new pipeline split.
3. Keep branch handling stable first, then move branch resolution later only when the earlier version is correct.
4. Replace functional caches with timing-aware caches before claiming a realistic 9-stage or 10-stage design.
5. Track CPI, branch miss rate, I-cache miss rate, D-cache miss rate, and stall cycles at every stage count.

### Suggested Evaluation Metrics
- Weighted CPI across a benchmark set.
- Branch misprediction rate and recovery penalty.
- I-cache and D-cache miss rates.
- Number of stall cycles caused by load-use hazards.
- Number of stall cycles caused by cache misses.
- Control complexity: forwarding paths, hazard rules, and flush logic.

## Directory Layout
```
rtl/core/   Pipeline core RTL
rtl/mem/    Instruction/data memory (for simulation)
tb/         Testbench and test programs
sim/        Simulation artifacts (gitignored)
docs/       Architecture docs
tools/      Python helpers (test generator, batch runner)
```

## Dependencies
- Icarus Verilog (`iverilog`, `vvp`)
- GTKWave (waveform viewer)
- Python 3 (for the random test flow)

macOS install:
```bash
brew install icarus-verilog gtkwave
```

## Running a Single Test
```bash
make run                                # default: test01
make run PROG=tb/programs/test02.hex    # switch program
make run PROG=tb/programs/test03.hex    # branch prediction test
make run PROG=tb/programs/test04.hex    # ecall exception test
make wave                               # open waveform
make clean
```

## Random Regression (100 RV32I cases)

Two Python scripts are provided:
- `tools/gen_rv32_tests.py` — generate random RV32I `.hex` programs and self-check them with a built-in ISA simulator.
- `tools/run_generated_tests.py` — batch invoke `make run PROG=...` and report a pass/fail summary.

### 1) Generate 100 tests
```bash
python3 tools/gen_rv32_tests.py \
    --count 100 \
    --out-dir tb/programs/generated \
    --seed 20260505
```

Output goes to `tb/programs/generated/`, e.g. `rv32_rand_000.hex`.

### 2) Run all and summarize
```bash
python3 tools/run_generated_tests.py --dir tb/programs/generated
```

The script prints PASS/FAIL per test and a final summary:
- `Total`  — number of tests
- `Passed` — number of passes
- `Failed` — number of failures

Pass criteria:
- Simulation exit code is 0
- Output contains `[TB] PASS: x31 = 0xCAFEBABE detected`
- Output does NOT contain `[TB] simulation finished by timeout`

### 3) Re-run a single failing case
```bash
make run PROG=tb/programs/generated/rv32_rand_042.hex
```

### 4) Useful options
```bash
# Change count / seed
python3 tools/gen_rv32_tests.py --count 300 --seed 12345

# Control random body length (default 20~40 instructions + epilogue)
python3 tools/gen_rv32_tests.py --min-body 10 --max-body 60
```

## Performance Benchmarks (CPI / branch / cache)

For longer kernels — Fibonacci, sum, memcpy, popcount, matrix multiply,
bubble sort, CRC32, binary search, dot product — use:
- `tools/asm.py`            — tiny label-based RV32I assembler.
- `tools/gen_benchmarks.py` — emit hand-written `.hex` kernels.
- `tools/run_benchmarks.py` — run each, parse the testbench summary,
  print a CPI / branch / cache table.

The simulation timeout is configurable via `TIMEOUT_NS` (Makefile variable),
because heavier kernels exceed the default 2000 ns.

### 1) Generate + run all benchmarks
```bash
python3 tools/run_benchmarks.py --regen --timeout-ns 8000000
```

Example output (current OoO dual-issue):
```
benchmark             status      cycles   committed     CPI_c   dual%   br_miss   D$_miss
-------------------------------------------------------------------------------------------
bsearch_64              PASS         754         964     0.782   42.7     0.040     0.155
bsort_16                PASS        1401        1677     0.835   40.6     0.010     0.006
crc32_64b               PASS        2070        2575     0.804   62.3     0.109     0.250
dotprod_32              PASS        8627        7762     1.111   45.4     0.193     0.160
fib_20                  PASS          96         148     0.649   50.0     0.042     0.000
matmul_4x4              PASS       17809       16139     1.103   44.3     0.189     0.063
memcpy_64w              PASS         401         397     1.010   72.9     0.029     0.246
popcount_64             PASS         979        1159     0.845   66.4     0.003     0.000
sum_1_to_100            PASS         319         410     0.778   33.8     0.019     0.000
```

### 2) Reading the table

Two CPI numbers are reported because they answer different questions:

- `CPI` (legacy): `cycles / retired`, where `retired` only counts
  instructions that performed a register write to a non-x0 destination.
  Stores, branches, `JAL x0,...`, etc. are excluded, which makes this
  metric **systematically pessimistic** for memory- and control-heavy code.
- `CPI_c` (commit-based): `cycles / committed`, where `committed` counts
  every instruction that reaches WB with `mem_wb_valid` (matches the
  commonly understood "instructions executed"). Use this number when
  comparing the design against the ideal in-order issue rate of `1.0`.

The new stall-breakdown columns are absolute event counts:

- `lu`     — number of cycles the front-end was frozen by load-use stalls.
- `f_br`   — conditional-branch mispredict flushes.
- `f_jmp`  — flushes caused by unconditional jumps (`JAL` / `JALR`)
  resolved late.
- `f_exc`  — flushes caused by exceptions / `mret`.

Together these explain where each kernel's CPI overhead comes from.

### 3) Observations from the current measurements

- **6 of 9 benchmarks achieve CPI_c < 1.0** — the out-of-order dual-issue
  engine retires more than 1 instruction per cycle on average, proving
  effective ILP extraction.
- `fib_20` at CPI_c = **0.649** (1.54 IPC) demonstrates the best-case
  throughput gain from dual-issue + OoO.
- `dotprod_32` / `matmul_4x4`: CPI_c ≈ 1.1, limited by branch mispredictions
  (19%) from the software-multiply subroutine call pattern.
- `crc32_64b`: CPI_c = 0.804 with 62% dual-issue rate; the main bottleneck
  is now branch misprediction (10.9%) in the bit-level inner loop.
- `memcpy_64w`: CPI_c ≈ 1.01 at 73% dual-issue — almost perfectly pipelined
  LW/SW pairs.
- `bsort_16`: CPI_c = 0.835 despite data-dependent branch chains, showing
  effective OoO scheduling of adjacent load/store/compare sequences.

### 4) Available kernels

| name             | what it does                                        | what it stresses                                      |
| ---------------- | --------------------------------------------------- | ----------------------------------------------------- |
| `fib_20`         | iterative Fibonacci(20)                             | short RAW chain, EX→EX forwarding                     |
| `sum_1_to_100`   | sum 1..100                                          | medium loop with predictable backward branch          |
| `memcpy_64w`     | copy 64 words 0x1000 → 0x2000                       | LW/SW pairs, D-Cache traffic                          |
| `popcount_64`    | Brian Kernighan popcount over 1..64                 | nested loop, data-dependent inner termination         |
| `matmul_4x4`     | int 4×4 matmul with software multiply               | triple loop + strided LW/SW + long mul shift+add chain|
| `bsort_16`       | bubble-sort 16 ints                                 | adjacent LW/SW + many short data-dependent branches   |
| `crc32_64b`      | CRC32 (poly 0xEDB88320) over 64 bytes               | bit-level inner loop, hard-to-predict branches        |
| `bsearch_64`     | binary search 6 keys against sorted array of 64     | data-dependent branches that defeat the BHT           |
| `dotprod_32`     | dot product of length-32 vectors via software mul   | long inner loop with function call (JAL/JALR)         |

List them:
```bash
python3 tools/gen_benchmarks.py --list
```

### 5) Run a single kernel
```bash
make run PROG=tb/programs/bench/matmul_4x4.hex TIMEOUT_NS=8000000
```

### 6) Useful options
```bash
# Filter by name (glob on stem)
python3 tools/run_benchmarks.py --filter "matmul_*"
python3 tools/run_benchmarks.py --filter "*sort*"

# Just regenerate the .hex files
python3 tools/gen_benchmarks.py --out-dir tb/programs/bench
```

### 7) Adding a new benchmark
Edit `tools/gen_benchmarks.py`:
1. Build the kernel using the `Asm` helper from `tools/asm.py`. Use
   `a.label("foo")` and `a.beq(rs1, rs2, "foo")` / `a.j("foo")` so you don't
   have to compute branch offsets by hand.
2. End with `append_epilogue(a)` so the testbench's PASS detector triggers.
3. Add the builder to the `BENCHMARKS` dict.
4. Re-run `python3 tools/run_benchmarks.py --regen`.

## Conventions
- Rising-edge clocking, synchronous active-low reset `rst_n`.
- Pipeline registers named `<src>_<dst>_*`, e.g. `if_id_pc`.
- Reset PC = `0x0000_0000` (configurable in [defines.v](rtl/core/defines.v)).
