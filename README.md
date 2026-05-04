# 5-Stage Pipelined RISC-V (RV32I) CPU

A classic 5-stage pipelined CPU built in Verilog, developed in incremental stages for teaching/learning purposes.

## Target ISA
RV32I integer subset (47 core instructions). Future extensions: Zicsr / interrupts.

## Pipeline
```
IF  →  ID  →  EX  →  MEM  →  WB
```

## Current Status
- [x] Stage 0: Project skeleton + simulation scripts
- [x] Stage 2: Minimal runnable 5-stage pipeline skeleton
- [x] Stage 3: Forwarding + load-use stall
- [x] Stage 4: Branch prediction (dynamic BHT + BTB)
- [x] Stage 5: Minimal CSR + exceptions (ecall / illegal) + `mret`
- [ ] Stage 6: I-Cache + D-Cache
- [ ] Stage 7: Regression and performance statistics

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
