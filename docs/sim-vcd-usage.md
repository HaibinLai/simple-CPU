# 仿真 VCD（波形）使用规范

## 背景

`tb/tb_cpu.v` 中通过 `$dumpvars(0, tb_cpu)` 会把整个 DUT 层级（包含 ROB、PRF、IFQ 等大数组）的所有信号每周期写入 VCD 文件。单个测试的 VCD 体积可达几十 MB ~ 几百 MB，批量回归时会产生**几十 GB 级别的磁盘 I/O**，导致：

- SSD / 文件系统缓存被打满
- 整机明显卡顿、风扇狂转
- 回归速度被磁盘 I/O 而非仿真本身拖慢

## 当前机制

VCD dump 改为编译期宏门控（默认关闭）：

- [tb/tb_cpu.v](../tb/tb_cpu.v)：`$dumpfile/$dumpvars` 包在 `` `ifdef ENABLE_VCD `` 中，文件名由 `` `VCD_FILE `` 宏决定。
- [Makefile](../Makefile)：新增 `VCD` 开关
  - `VCD=0`（默认）：不开 dump，回归用。
  - `VCD=1`：编译期定义 `ENABLE_VCD`，并把 `VCD_FILE` 设为 `$(SIM_DIR)/cpu.vcd`。
- `make wave` 自动以 `VCD=1` 重编、运行、并用 gtkwave 打开。

## ⚠️ 强制规则：测试波形时最多 5 个

**当开启 VCD（`VCD=1` 或 `make wave`）时，单次运行的测试数量 ≤ 5。**

理由：

1. VCD 单文件可达数百 MB，5 个已经接近 1~2 GB；超过会占满磁盘并卡机。
2. 调试波形本就是定位问题用，没必要批量跑。如需批量回归，使用默认 `VCD=0`。
3. 多 worker 并发开 VCD 会同时写多个大文件，I/O 雪崩，**禁止 `-j > 1` + VCD 同时开**。

### 允许的用法

```bash
# 单个测试 + 波形
make wave PROG=tb/programs/generated/rv32_rand_021.hex

# 少量（≤5）特定测试 + 波形：手动逐个跑
make wave PROG=tb/programs/micro_hazard/raw_01.hex
make wave PROG=tb/programs/micro_hazard/raw_02.hex
# ...最多 5 个
```

如果用回归脚本 `tools/run_generated_tests.py` 调试波形，必须：

- `-j 1` 串行
- 通过 `--glob` 或单独传 `--dir` 把范围限制在 ≤5 个 hex
- 显式指定 `--sim-dir` 隔离

### 禁止的用法

```bash
# ❌ 禁止：开 VCD 跑全量回归
make wave PROG=...                          # 然后改脚本批量调用
python3 tools/run_generated_tests.py -j 8   # 配合 VCD=1 环境变量

# ❌ 禁止：并发 + VCD
```

## 回归默认流程（无波形，快速）

```bash
# 默认 VCD=0，跑得快、不卡机
python3 tools/run_generated_tests.py -j 1 > /tmp/reg.log
# 或并发
python3 tools/run_generated_tests.py -j 8 > /tmp/reg.log
```

## 调试到具体测试后再开波形

回归发现某个 hex 失败 → 单独对该 hex 开 VCD 调试：

```bash
make wave PROG=tb/programs/generated/rv32_rand_021.hex
```

这是推荐工作流：**回归不开波形，定位失败用例后单点开波形**。
