# CPU Architecture 102

## From 5-Stage Pipelined RISC-V (RV32I) CPU to 10 stage

A staged pipelined CPU built in Verilog, developed incrementally for teaching/learning purposes.

## Target ISA
RV32I integer subset (47 core instructions). Future extensions: Zicsr / interrupts.

## Current Implemented Pipeline
```
IF  →  ID1  →  ID2  →  EX1  →  EX2  →  AGU  →  MEM  →  WB
```

## Current Status

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

Example output:
```
benchmark             status      cycles     retired       CPI   committed     CPI_c      lu    f_br   f_jmp   f_exc   branches   mispred   br_miss   I$_miss   D$_miss
-----------------------------------------------------------------------------------------------------------------------------------------------------------------------
bsearch_64              PASS         939         498     1.886         846     1.110      36      13       5       0        278        18     0.065     0.061     0.377
bsort_16                PASS        1729         841     2.056        1540     1.123     120      18       4       0        443        22     0.050     0.021     0.323
crc32_64b               PASS        5161        2337     2.208        4116     1.254      64     322       4       0       1763       326     0.185     0.009     0.055
dotprod_32              PASS        8649        4705     1.838        8037     1.076       0     134      69       0       3300       203     0.062     0.006     0.372
fib_20                  PASS         141          87     1.621         129     1.093       0       1       2       0         42         3     0.071     0.125     0.215
matmul_4x4              PASS       17340        9929     1.746       16506     1.051       0     252      25       0       6593       277     0.042     0.005     0.363
memcpy_64w              PASS         532         262     2.031         456     1.167      64       1       2       0        130         3     0.023     0.034     0.596
popcount_64             PASS        1500         713     2.104        1293     1.160       0      65       3       0        580        68     0.117     0.013     0.051
sum_1_to_100            PASS         420         206     2.039         408     1.029       0       1       2       0        202         3     0.015     0.035     0.541
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

- `matmul_4x4`, `dotprod_32`, `sum_1_to_100`: legacy `CPI` ~1.7–2.0 looks
  high, but **commit-based `CPI_c` is 1.03–1.08** — already very close to
  the single-issue ideal. The gap is almost entirely an artifact of
  stores not being counted in `retired`.
- `crc32_64b`: this is the kernel that is **actually CPI-bound** —
  `CPI_c = 1.254` driven by 322 conditional-branch mispredicts in the
  bit-level inner loop. The BHT cannot learn the pattern.
- `memcpy_64w`, `bsort_16`: dominated by load-use stalls (`lu = 64` /
  `120`) — adjacent `LW`/`SW` chains keep producing 1-cycle bubbles.
- `bsearch_64`: a balanced mix — `lu = 36` (data-dependent address
  computations) plus `f_br = 13` (the inherently unpredictable comparison
  branch in binary search).

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
