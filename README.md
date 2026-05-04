# cpu20 — 5 级流水线 RISC-V (RV32I) CPU

一个用 Verilog 实现、分阶段迭代构建的经典 5 级流水线 CPU 教学/学习项目。

## 目标 ISA
RV32I 整数子集（47 条核心指令）。后续可扩展 Zicsr / 中断。

## 流水线
```
IF  →  ID  →  EX  →  MEM  →  WB
```

## 当前阶段
- [x] 阶段 0：项目骨架 + 仿真脚本
- [x] 阶段 2：最小可运行 5 级流水线骨架
- [x] 阶段 3：Forwarding + Load-use Stall
- [x] 阶段 4：分支预测（动态 BHT + BTB）
- [x] 阶段 5：最小 CSR + 异常（ecall / illegal）+ mret 跳转
- [x] 阶段 6：I-Cache + D-Cache（功能模型）
- [x] 阶段 7：综合测试与性能统计

## 目录结构
```
rtl/core/   流水线核心 RTL
rtl/mem/    指令/数据存储器（仿真用）
tb/         testbench 与测试程序
sim/        仿真产物（已 gitignore）
docs/       架构文档
```

## Cache 说明
- I-Cache 与 D-Cache 均为直接映射、1 字/行的教学实现。
- D-Cache 策略为 write-through + write-allocate。
- 当前实现保持 CPU 接口不变，miss 回填不引入额外流水线 stall（功能模型）。

## 仿真依赖
- Icarus Verilog (`iverilog`, `vvp`)
- GTKWave（查看波形）

macOS 安装：
```bash
brew install icarus-verilog gtkwave
```

## 运行测试
```bash
make run                                # 默认 test01
make run PROG=tb/programs/test02.hex    # 切换程序
make run PROG=tb/programs/test03.hex    # 循环分支预测测试
make run PROG=tb/programs/test04.hex    # ecall 异常测试
make wave                               # 查看波形
make clean
```

## 随机回归测试（100 个 RV32I case）

本仓库提供了两段 Python 脚本：
- `tools/gen_rv32_tests.py`：生成随机 RV32I `.hex` 测试程序，并在 Python 侧做指令级自校验。
- `tools/run_generated_tests.py`：批量调用 `make run PROG=...` 执行并统计通过率。

### 1) 生成 100 个测试
```bash
python3 tools/gen_rv32_tests.py \
	--count 100 \
	--out-dir tb/programs/generated \
	--seed 20260505
```

生成结果会放在 `tb/programs/generated/`，文件名类似 `rv32_rand_000.hex`。

### 2) 批量运行并统计
```bash
python3 tools/run_generated_tests.py --dir tb/programs/generated
```

脚本会逐条打印 PASS/FAIL，最后输出汇总：
- `Total`：总测试数
- `Passed`：通过数
- `Failed`：失败数
- `Aggregated Metrics`：聚合后的 CPI、分支错预测率、I$/D$ miss 率

判定规则：
- 仿真退出码为 0
- 输出包含 `[TB] PASS: x31 = 0xCAFEBABE detected`
- 输出不包含 `[TB] simulation finished by timeout`

### 3) 复测单个失败用例
```bash
make run PROG=tb/programs/generated/rv32_rand_042.hex
```

### 4) 常用参数
```bash
# 修改数量与随机种子
python3 tools/gen_rv32_tests.py --count 300 --seed 12345

# 控制随机程序长度（默认 20~40 条随机体 + 收尾）
python3 tools/gen_rv32_tests.py --min-body 10 --max-body 60
```

## 设计约定
- 时钟上升沿触发，同步低有效复位 `rst_n`。
- 所有流水线寄存器命名 `<src>_<dst>_*`，例如 `if_id_pc`。
- 复位 PC = `0x0000_0000`（可在 [defines.v](rtl/core/defines.v) 修改）。
