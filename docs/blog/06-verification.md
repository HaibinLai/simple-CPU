# 从零开始造一颗 RISC-V CPU（六）：微架构验证体系与 IPC 性能评估报告

> 系列博客第 6 篇（最终篇） —— 在现代 CPU 设计中，验证（Verification）往往占据了流片前 70% 的工作量。本文将全面解析我们如何通过 Python 构建指令集模拟器（ISS）、约束随机验证（CRV）以及端到端的状态机快照比对，验证这套复杂的双发乱序引擎，并给出最终的微架构 IPC 性能跑分。

---

## 1. 硅片上的混沌：为什么 CPU 验证如此绝望？

当你手搓了一套支持双发射、5级深度、乃至拥有乱序执行和 TAGE 分支预测的 CPU 时，真正的噩梦才刚刚开始。
指令的组合空间是爆炸的：一条看似无害的 `ADD` 指令，当它处于 `IF` 段时，可能前面的 `LW` 刚刚在 `MEM` 段发生 Cache Miss，而旁边的 `Slot1` 正卡在 `xWAW` 跨拍冲突判断上，与此同时分支预测器正好给出了错误的跳转打断（Flush）……

任何一个旁路（Bypass）选择器的 Off-by-one 偏差，都会导致最终写入寄存器的值完全崩坏。为了捕获潜伏在几十万种状态流形中的时序炸弹，我们建立了一套**四梯次立体验证体系**：

| 层级 | 测试类型 | 用例数 | 工程目的 |
|------|---------|-------:|---------|
| L1   | **微观制导测试 (Micro-Tests)** | 15 | 纯汇编手撕，精准向危险的冒险通路投毒（如 Load-Use 边界、连续双发 RAW 阻断）。 |
| L2   | **约束随机指令流 (CRV)** | 200 | 覆盖人力无法想象的极端指令纠缠，是榨出深水区 Bug 的重火力。 |
| L3   | **真实负载 (Benchmarks)** | 15 | 高压算法全量跑分，验证 Cache 淘汰、BPU 训练等长周期状态机制，兼作性能基准。 |
| L4   | **终态对比网络 (ISS Co-Sim)** | ALL | 最高判决法庭，逐个比对 RTL 和黄金模型的通用寄存器堆。 |

总计 **230 个高压测试集**，在我们的流水线上达成了 100% PASS 的闭环。

---

## 2. 验证体系全景：Python ISS 与寄存器全息快照

我们的核心验证手段采用了工业界标配的 **黄金模型协同仿真（Golden Model Co-Simulation）**。我们在 Python 中硬写了一个纯净的 RISC-V 指令集模拟器（ISS）作为绝对正确的“上帝”。

```mermaid
graph TD
    Generator[指令流生成器<br>gen_rv32_tests.py] -->|生成 HEX 流| DUT[RTL (Verilog)]
    Generator -->|生成 HEX 流| ISS[Python 参考模型]
    
    subgraph Verilator 闭环仿真栈
        DUT --> |执行中| DMon((微架构状态监听器))
        DUT --> |遇到 x31 = CAFEBABE| DTrace[Dump Arch State<br>32x32 寄存器墙]
    end
    
    subgraph Python 解释器
        ISS --> |瞬间跑完| ITrace[Dump ISS State<br>32个正确的寄存器值]
    end
    
    DTrace --> Comparator{Python 比对脚本}
    ITrace --> Comparator
    
    Comparator -->|Mismatch| FAIL[报告触发 Bug 的指令上下文]
    Comparator -->|Match| PASS[回归测试通过]
```

### 2.1 硬件探针：终态投递与停机协议
为了让自动化脚本能知道 Verilog 什么时候跑完代码，我们在汇编器的编译流末尾强行注入了一段“停机封印”（Epilogue）：

```python
# 工具链 asm.py 中的尾流生成
def append_epilogue(a: Asm):
    a.li(1, 0xCAFEBABE)     # 将黄金魔数推入 x1
    a.add(31, 1, 0)         # 将魔数倾倒进 x31
    a.label("__halt")
    a.j("__halt")           # 永死循环挂起流水线
```

在 Testbench 中，只要硬件嗅探到 `x31` 写入了 `0xCAFEBABE`，立刻停机并转储物理寄存器状态：

```verilog
always @(posedge clk) begin
    // 监听写回段，侦测停机魔数
    if (rst_n && dbg_wb_we && dbg_wb_rd == 5'd31 && dbg_wb_data == 32'hCAFEBABE) begin
        $display("[TB] PASS: x31 = 0xCAFEBABE detected");
        dump_arch_registers(); // 全息状态转储
        $finish;
    end
end
```

### 2.2 约束随机生成器 (CRV) 的混沌攻击
人脑写不出所有引发瘫痪的代码。我们在 `gen_rv32_tests.py` 中写了一套具有内存边界约束的随机代码生成引擎，疯狂生产包含了 `JALR`, `BEQ`, 重型算术以及位移操作的乱码程序堆。
这些长短不一的代码会生成千奇百怪的 Bubble 和 Hazard，如果 RTL 处理错了一根前递线（Forwarding），最后 Dump 出来的 `x1 ~ x30` 必定与 ISS 有出入！

---

## 3. 微架构全息监测仪：Profile Counters

为了回答“为什么 IPC 上不去”这个灵魂拷问，我们的 Testbench 被打满了非侵入式的“侧信道探针（Snoop Hooks）”，它们默默趴在主流水线上，对每个周期的动作进行物理归因（Attribution Profiling）：

```verilog
// Testbench 中的窥探计数器，不污染硬件本身的布线
reg [31:0] cnt_stall_load_use;
reg [31:0] cnt_flush_branch;

always @(posedge clk) begin
    if (dut.id2_stall_load_use) cnt_stall_load_use <= cnt_stall_load_use + 1;
    if (dut.flush_pred_miss)    cnt_flush_branch   <= cnt_flush_branch + 1;
end
```

在每次测试跑完时，不仅给出 PASS/FAIL，还会生成一份类似硅片 B超图的诊断报告：
```text
[TB] Retired=9929 Cycles=18767
[TB] stalls: load_use=1204 flush_br=230 flush_jump=50
[TB] I$ miss_rate=0.0012 D$ miss_rate=0.108
[TB] pair_blk: novalid1=10 unsafe0=0 notalu=120 raw=4500 waw=0 xcycwaw=309
```
这份精确到周期的脉搏图，成为了引导我们实施 2-Way 组相联 Cache、引入 TAGE 预测器、开发双发旁路网络的最核心物理证据。

---

## 4. 微架构 IPC 决战：In-Order 双发 vs 乱序引擎 (OoO)

历经重重改版，我们最终挂载了涵盖经典算法、内存推流和矩阵乘法在内的 15 个重灾区 Benchmark 测试。以下是主分支（In-Order）与乱序特装分支（Out-of-Order）的绝对算力交锋：

### 微架构跑分墙 (基于 Verilator 纳秒级闭环)

| Benchmark 测试集 | 指令特征形态 | Main 分支 (顺序双发) CPI | Feature/OoO (乱序引擎) CPI_c | 乱序架构 IPC 峰值 |
|------------------|-------------|----------------------:|--------------------------:|-----------------:|
| `fib_20` | **强状态复用依赖** | 1.81 | **0.65** | **🔥 1.54** |
| `crc32_64b` | **密集计算+短逻辑** | 1.86 | **0.80** | **1.24** |
| `bsort_16` | **控制流与访存扭结** | 1.80 | **0.84** | **1.20** |
| `memcpy_64w` | **线性内存推流** | 1.53 | 1.01 | 0.99 |
| `matmul_4x4` | **暴力算力与寻址** | 1.89 | 1.10 | 0.91 |

**(注：理想标量管线 IPC = 1.0，双发管线理论极致 IPC = 2.0，CPI = 1/IPC)**

### 数据研判与工程洞见
1. **强行突破 1.0 壁垒**：在乱序引擎开启时，`fib_20`、`crc32` 等高达 60% 的程序的 IPC 直接撕开了 1.0 的铁壁（1 周期执行完 1 条以上的汇编）。在顺序流水线中，因为寄存器锁死造成的 Pipeline Stall 被 OoO 的**寄存器重命名（Renaming）和保留站（RS）**化解为了物理层的齐头并进。
2. **OoO 并非神药**：对于 `memcpy_64w` 这样纯粹的大规模流式读写，因为毫无寄存器复用的卡顿隐患，顺序双发就能通过纯计算掩蔽跑得飞起。乱序架构庞大的 ROB 在面对纯线性读写时，能够剥削出的边际算力几乎为零。

---

## 5. 硅片上的血泪：微架构 Bug 现世录

验证过程中挖掘出了大量极具隐蔽性的深水区大坑（往往在几百到几千周期才发生一次决堤），这些 Bug 对系统架构工程师而言是极佳的血泪教训：

1. **跨周期优先级的致命截胡**：
   在早期的前递（Bypass）网络中，如果 `ex_mem_rd` 和 `mem_wb_rd` 刚好都在给 `x5` 写值，组合逻辑会随机拉错优先级（理应优先拦截离时空最近的、刚刚在 EX 算完的最新值）。修复手段是引入瀑布流式的 `ptag` 三态条件树。
2. **分支快照（Snapshot）退窗污染**：
   引入 TAGE 后出现负优化。通过仿真回放波形抓取到，由于更新操作是在 EX 段发起的，此时 GHR 早就被 IF 端推测吞吐的后续指令篡改了。**只有在 IF 阶段做快照封存并穿透传送给 EX**，才能避免训练状态翻车。
3. **乱序下的 Store 洗脑**：
   在 OoO 架构研发期偶尔会导致 Data Cache 里的值异常乱码。罪魁祸首是 Store 在进入执行通道算完地址和数据后，立刻把数据插进了 D$！**一旦产生异常冲刷任务，原本投机的 Store 数据已经在存储器中不可撤销。** 解决办法是引入 In-Order Write 协议，死死卡住所有的 Store 发送，必须等待其自身位于 ROB 队首（Head 位被允许 Commit）时，才准对外击发真实的 WE（写使能）信号。

---

## 6. 完结篇小结

从零开始手撕一颗能在 FPGA/Verilator 极速奔跑的双发乱序流水线 RISC-V 处理器，是一场对数字逻辑、体系结构和微操作定序的极限拷问。

通过高达 **230 个高压自动化对抗测试（CRV）** 的轮番洗礼，我们用数据定性地摸清楚了：
- **BTB+TAGE** 对超前调度的绝对镇压（拦截了高达 90% 的指令空爆）。
- **2路组相联 Cache** 对 Memory Wall 命中率底线的拯救。
- **动态仲裁与 OoO 并发模型** 榨出了 1.54 IPC 的工业级性能指标。

这不仅是一颗可以在板级稳定发声 `"Hello, CPU!"` (UART MMIO 测试项) 的硬核芯片，更是一套充满着硬件极致暴力艺术的作品。希望这个系列能够为你推开微架构世界的神秘大门！

---
*项目地址：[github.com/HaibinLai/simple-CPU](https://github.com/HaibinLai/simple-CPU)*
