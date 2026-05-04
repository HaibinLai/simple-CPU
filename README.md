# CPU Architecture 102

## From 5-Stage Pipelined RISC-V (RV32I) CPU to 10 stage

A classic 5-stage pipelined CPU built in Verilog, developed in incremental stages for teaching/learning purposes.

## Target ISA
RV32I integer subset (47 core instructions). Future extensions: Zicsr / interrupts.

## Pipeline
```
IF  →  ID  →  EX  →  MEM  →  WB
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

## Conventions
- Rising-edge clocking, synchronous active-low reset `rst_n`.
- Pipeline registers named `<src>_<dst>_*`, e.g. `if_id_pc`.
- Reset PC = `0x0000_0000` (configurable in [defines.v](rtl/core/defines.v)).
