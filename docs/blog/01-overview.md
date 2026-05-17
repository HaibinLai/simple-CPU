# 从零开始造一颗 RISC-V CPU（一）：项目总览与流水线基础

> 系列博客第 1 篇 —— 介绍整个项目的动机、架构全貌、8 级流水线设计以及关键的 hazard 处理。

---

## 为什么要自己造 CPU？

每年的计算机组成原理课，都有一个调bug到想死的大作业：**用 Verilog 实现一颗 RISC-V CPU**。今天我决定试试一个不一样的方式——让 **AI agent来主导整个 CPU 的设计与实现**，我负责提出需求、审查代码、做关键决策。

从最基础的5级流水线开始，agent 逐步迭代出了 8 级双发射流水线、TAGE 分支预测、2-way set-associative Cache，以及完整的 Tomasulo+ROB 乱序执行引擎。所有 RTL 代码、测试脚本、benchmark 汇编程序，均由 agent 编写，我来指定方向和验收结果。

最终的成果是一颗 **4,754 行 RTL** 的 dual-issue superscalar CPU：

| 特性 | 实现 |
|------|------|
| ISA | RV32I（40 条指令） |
| 流水线 | 8 级：IF → ID1 → ID2 → EX1 → EX2 → AGU → MEM → WB |
| 发射宽度 | 2-wide（slot0 全功能 + slot1 ALU/load/store/branch） |
| 分支预测 | TAGE-2L + 2-way BTB |
| Cache | I$/D$ 各 2KB，2-way set-associative，4 words/line |
| MMIO | UART TX @ `0x10000000` |
| 验证 | 15 benchmarks + 2000 case 指令测试 + micro tests 全 PASS |

这个系列将记录整个设计过程中的关键决策和知识点。第一篇从全局视角出发，介绍项目的架构全貌和流水线基础。

### 人机协作模式

整个开发过程采用了一种**"人类架构师 + AI 工程师"**的协作模式：

| 角色 | 职责 |
|------|------|
| **我（人类）** | 提出功能需求、决定架构方向、审查关键设计、跑测试验收 |
| **Agent（GitHub Copilot）** | 编写全部 Verilog RTL、Python 工具链、测试用例、debug 修复 |

典型的工作流是这样的：我说"把 BPU 升级到 TAGE"，agent 就会分析现有代码、设计 TAGE 结构、写出 RTL、连线到 cpu_top、跑回归测试确认 PASS。如果测试失败，agent 自己分析波形和日志定位问题并修复，直到全部通过。

这种模式下，**agent 的代码产出速度非常快**（几分钟内可以完成一个完整 feature），但**架构决策的质量仍然取决于人类的判断**——比如选择 Tomasulo 而非 Scoreboard、RS 深度设为 8 而非 4、TAGE 用 2 级而非 3 级，这些 tradeoff 需要对体系结构有理解才能做好。

---

## 项目整体结构

```
cpu20/
├── rtl/
│   ├── core/         # CPU 核心逻辑
│   │   ├── cpu_top.v     # 顶层流水线（1,436 行）
│   │   ├── bpu.v         # 分支预测单元 TAGE-2L（394 行）
│   │   ├── control.v     # 译码与控制信号
│   │   ├── forwarding.v  # 前递网络
│   │   ├── hazard.v      # 冒险检测
│   │   ├── ifq.v         # 指令取指队列（186 行）
│   │   ├── alu.v         # 32-bit ALU
│   │   ├── imm_gen.v     # 立即数生成
│   │   └── ...
│   └── mem/
│       ├── imem.v        # I-Cache 2-way SA
│       └── dmem.v        # D-Cache 2-way SA, dual-port
├── tb/
│   ├── tb_cpu.v          # Testbench（统计 CPI/分支/Cache 等）
│   └── programs/         # 测试程序 .hex
├── tools/
│   ├── asm.py            # 汇编器（支持 label、putchar）
│   ├── gen_benchmarks.py # Benchmark 生成
│   └── run_benchmarks.py # 自动化运行与统计
└── docs/
```

整个项目使用 **Icarus Verilog** 仿真，**Python** 生成测试用例和收集性能数据，开发全程在 macOS 上完成。所有代码由 AI agent 在 VS Code 中通过 GitHub Copilot agent mode 编写和调试。

---

## 选择 RV32I

RISC-V 是一个开放的指令集架构。选择 RV32I base integer 子集，是因为它：

- **足够小**：只有 40 条指令，decode 逻辑简洁
- **足够完整**：支持 ALU、分支、load/store、跳转，能运行任意整数程序
- **正交设计**：opcode 字段对齐规整，非常适合硬件实现

RV32I 的指令格式一共 6 种（R/I/S/B/U/J），每条指令固定 32 位宽。这对流水线的 decode 阶段非常友好——不需要像 x86 那样处理变长指令。

```
R-type:  [funct7 | rs2 | rs1 | funct3 | rd | opcode]
I-type:  [    imm[11:0]  | rs1 | funct3 | rd | opcode]
S-type:  [imm[11:5]| rs2 | rs1 | funct3 | imm[4:0] | opcode]
B-type:  [imm bits | rs2 | rs1 | funct3 | imm bits | opcode]
U-type:  [        imm[31:12]          | rd | opcode]
J-type:  [        imm bits            | rd | opcode]
```

在 `defines.v` 中，所有 opcode 都被定义为宏常量：

```verilog
`define OP_LUI     7'b0110111
`define OP_AUIPC   7'b0010111
`define OP_JAL     7'b1101111
`define OP_JALR    7'b1100111
`define OP_BRANCH  7'b1100011
`define OP_LOAD    7'b0000011
`define OP_STORE   7'b0100011
`define OP_IMM     7'b0010011
`define OP_REG     7'b0110011
`define OP_SYSTEM  7'b1110011
```

---

## 8 级流水线

经典教科书上的 RISC 流水线是 5 级（IF → ID → EX → MEM → WB）。

### 从 5 级到 8 级的演进

| 阶段 | 5 级 | 8 级 | 拆分原因 |
|------|------|------|----------|
| IF | ✅ | ✅ | 取指 |
| ID | 1 级 | **ID1 + ID2** | ID1 做指令缓冲和对齐（IFQ），ID2 做译码+读寄存器 |
| EX | 1 级 | **EX1 + EX2** | 拆分 ALU 与地址生成，降低关键路径延迟 |
| MEM | 1 级 | **AGU + MEM** | 地址生成单独一级，MEM 纯做存储器访问 |
| WB | ✅ | ✅ | 写回 |

拆分的核心考虑是：

1. **降低关键路径**：5 级流水线的 EX 阶段同时做 ALU 计算和分支判断，路径太长。拆成 EX1（ALU + 分支）和 EX2（结果缓冲）后，单级延迟更短，有利于提高时钟频率。

2. **为双发射铺路**：ID1 引入 IFQ（指令取指队列），可以缓冲多条指令，为 ID2 阶段的双发射配对提供基础。IFQ 深度为 4，每周期最多 push 2 条、pop 2 条。

3. **AGU 独立**：地址生成（rs1 + offset）与数据存储器读写分离，使 store 数据的前递和 load 的符号扩展逻辑更清晰。

### 8 级流水线全景

```
                         ┌─ slot0: EX1 → EX2 → AGU → MEM → WB
 IF → ID1 → ID2(decode) ┤
                         └─ slot1: EX1b → WB (1-cycle shortcut)
```

- **IF**：PC 生成 + I-Cache 读取 + 分支预测查询
- **ID1**：指令推入 IFQ，BPU 结果跟随指令一起入队
- **ID2**：从 IFQ 弹出 1~2 条指令，译码、读寄存器、冒险检测、配对判定
- **EX1**：ALU 计算、分支/跳转解析、分支预测验证
- **EX2**：EX 结果缓冲，为 AGU 提供稳定的输入
- **AGU**：访存地址生成（load/store 的 base + offset）
- **MEM**：D-Cache 读写，load 数据符号/零扩展
- **WB**：结果写回寄存器堆

---

## 流水线的核心挑战：Hazard 处理

流水线的性能优势来自指令重叠执行，但这也引入了三类冒险（hazard）：

### 1. 数据冒险（Data Hazard）

最常见的是 **RAW（Read After Write）** 冒险：后面的指令需要读取前面指令尚未写回的结果。

```
ADD  x1, x2, x3    # 写 x1
SUB  x4, x1, x5    # 读 x1 —— 此时 ADD 还在 EX 阶段，x1 尚未更新
```

#### 前递（Forwarding）

解决方案是**前递网络**（`forwarding.v`）：直接把 EX/AGU/MEM 阶段计算好的结果旁路回 ID 阶段使用的操作数，无需等到 WB 写回。

我们的前递网络有 **4 级优先级**，对 rs1 和 rs2 分别独立选择：

| 优先级 | 来源 | 信号前缀 |
|--------|------|----------|
| 最高 | EX1→EX2 级间 | `ex_mem_*` |
| 次高 | EX2→AGU 级间 | `ex2_agu_*` |
| 再次 | AGU→MEM 级间 | `agu_mem_*` |
| 最低 | MEM→WB 级间 | `mem_wb_*` |

```verilog
// forwarding.v 中的优先级逻辑（rs1 为例）
if (ex_mem_reg_write && ex_mem_rd == id_rs1)
    fwd_a = 2'b01;      // 从 EX 前递
else if (ex2_agu_reg_write && ex2_agu_rd == id_rs1)
    fwd_a = 2'b10;      // 从 AGU 前递
else if (agu_mem_reg_write && agu_mem_rd == id_rs1)
    fwd_a = 2'b11;      // 从 MEM 前递
else
    fwd_a = 2'b00;      // 无前递，使用寄存器值
```

#### Load-Use Stall

有一种情况前递也解决不了：**load-use 冒险**。Load 指令的数据要到 MEM 阶段才能从 D-Cache 读出，但紧随其后的指令在 EX 阶段就需要用到这个值——差了一个周期，无法前递。

```
LW   x1, 0(x2)     # MEM 阶段才拿到 x1 的值
ADD  x3, x1, x4    # EX 阶段就需要 x1 —— 必须 stall 1 拍
```

`hazard.v` 检测这种情况并插入一个 bubble：

```verilog
// 两级 load-use 检测
wire hazard_id_ex  = id_ex_mem_read
                   && ((id_use_rs1 && id_ex_rd == id_rs1)
                    || (id_use_rs2 && id_ex_rd == id_rs2));

wire hazard_ex_agu = ex_agu_mem_read
                   && ((id_use_rs1 && ex_agu_rd == id_rs1)
                    || (id_use_rs2 && ex_agu_rd == id_rs2));

assign stall = hazard_id_ex || hazard_ex_agu;
```

注意 `id_use_rs1` / `id_use_rs2` 信号用于精确过滤——像 `LUI` 这种不使用源寄存器的指令不会触发虚假 stall。

### 2. 控制冒险（Control Hazard）

分支/跳转指令需要到 **EX1 阶段** 才能解析目标地址和方向。如果预测错误，已经进入流水线的后续指令都是无效的，需要 flush。

在 8 级流水线中，一次分支 misprediction 会浪费 **3~4 个周期**（从 IF 到 EX1 的流水线深度）。这就是为什么分支预测对性能至关重要——后续博客会详细讨论 TAGE 预测器。

### 3. 结构冒险（Structural Hazard）

当两条指令需要同时使用同一个硬件资源时产生。在我们的设计中：

- **寄存器堆**：有足够多的读写端口，不会冲突
- **D-Cache**：提供双端口（Port A 读写 + Port B 只读），slot0 和 slot1 可以同时访存
- **ALU**：slot0 和 slot1 各有独立的 ALU 实例

因此结构冒险在本设计中基本不存在。

---

## 双发射（Dual-Issue）简介

单发射 CPU 的 IPC 上限是 1.0。要突破这个限制，需要每周期发射多条指令。我们的 CPU 在 ID2 阶段同时从 IFQ 弹出两条指令：

- **Slot0**（主通道）：支持所有指令类型
- **Slot1**（辅助通道）：支持 ALU、load、store、branch

配对条件由 ID2 阶段检查：
1. Slot1 指令类型必须是 ALU/load/store/branch（不能是 JAL/JALR/ECALL）
2. 两条指令之间无 RAW 依赖（slot0 的 rd ≠ slot1 的 rs1/rs2）
3. 两条指令之间无 WAW 冲突（rd 不同）
4. 没有 load-use 冒险阻塞

实测数据中，`memcpy_64w`（连续 LW/SW 对）的双发射率最高达 **73%**，而分支密集的 `sum_1_to_100` 只有 34%。详细的双发射设计和 pair-block 分析将在第 2 篇中展开。

---

## Benchmark 一览

为了验证 CPU 的正确性和衡量性能，我们构建了一套完整的 benchmark 套件：

| Benchmark | 特点 | Cycles | CPI |
|-----------|------|-------:|----:|
| `fib_20` | 纯寄存器循环 | 157 | 1.81 |
| `memcpy_64w` | 连续 LW/SW | 401 | 1.53 |
| `bsort_16` | 嵌套循环 + 条件交换 | 1,515 | 1.80 |
| `crc32_64b` | 位操作密集 | 4,348 | 1.86 |
| `dhrystone_lite` | 字符串/函数调用/分支 | 7,546 | 1.84 |
| `coremark_lite` | 链表 + 状态机 + CRC16 | 2,984 | 1.62 |
| `qsort_32` | 快排 + 显式栈 | 7,515 | 1.93 |
| `sieve_256` | Eratosthenes 筛法 | 4,996 | 2.43 |
| `hello_uart` | MMIO 输出字符串 | 105 | 2.76 |

> 注：以上数据来自 main 分支（in-order dual-issue）。feature/ooo 分支（out-of-order）的 CPI 显著更低，6/9 benchmarks 达到 CPI < 1.0。

所有 benchmark 的 hex 文件由 Python 汇编器 (`asm.py`) 生成，支持 label 解析、`li` 伪指令、`putchar`/`puts` MMIO 输出等功能。

---

## 小结

这一篇介绍了项目的全貌：

- **8 级流水线**：IF → ID1 → ID2 → EX1 → EX2 → AGU → MEM → WB
- **三类冒险处理**：前递网络（4 级优先级）、load-use stall、分支 flush
- **双发射基础**：slot0 全功能 + slot1 辅助通道
- **验证体系**：15 benchmarks + 200 随机回归

后续文章将深入每个子系统：

| 篇目 | 主题 |
|------|------|
| 第 2 篇 | 双发射设计 — IFQ、配对规则、pair-block 分析 |
| 第 3 篇 | 分支预测 — 从 Bimodal 到 TAGE |
| 第 4 篇 | Cache 层次 — 2-way SA I$/D$ |
| 第 5 篇 | 乱序执行 — Tomasulo + ROB |
| 第 6 篇 | 验证与性能 — Benchmark 结果分析 |

---

*项目地址：[github.com/HaibinLai/simple-CPU](https://github.com/HaibinLai/simple-CPU)*
