# 从零开始造一颗 RISC-V CPU（二）：双发射设计 — IFQ、配对规则与性能分析

> 系列博客第 2 篇 —— 深入双发射（dual-issue）的实现：指令取指队列 IFQ、slot0/slot1 配对条件、pair-block 原因分析，以及实测性能数据。

---

## 为什么要双发射？

单发射 CPU 的 IPC（Instructions Per Cycle）上限是 **1.0**——每个时钟周期最多完成一条指令。要突破这个天花板，最直接的方法是**每周期发射多条指令**。

双发射（2-wide issue）的理论 IPC 上限是 2.0，但实际受制于数据依赖、指令类型限制等因素，很难达到理论值。我们的目标是在**不引入过多复杂度**的前提下，尽可能提高实际 IPC。

核心思路是在 ID2（译码）阶段同时从 IFQ 弹出两条指令，分别送入两个执行通道：

```
                         ┌─ slot0: EX1 → EX2 → AGU → MEM → WB   (全功能，5 级)
 IF → ID1 → ID2(decode) ┤
                         └─ slot1: EX1b → WB                     (轻量，1 级)
```

- **Slot0**（主通道）：支持所有指令类型——ALU、load、store、branch、jump
- **Slot1**（辅助通道）：仅支持 ALU、load、store、branch

---

## IFQ：指令取指队列

双发射的前提是 ID2 阶段能**同时看到两条指令**。如果 IF 每周期只取一条指令，双发射率会被前端带宽限制。IFQ（Instruction Fetch Queue）解决这个问题——它在 IF 和 ID 之间插入一个 FIFO 缓冲区，允许 IF 预取的指令在队列中积累。

### 基本参数

| 参数 | 值 |
|------|---|
| 深度 | 8 entry（可配置，实际设为 8） |
| Push 带宽 | 每周期最多 2 条 |
| Pop 带宽 | 每周期最多 2 条（slot0 + slot1） |
| Entry 内容 | PC(32b) + 指令字(32b) + pred_taken(1b) + pred_target(32b) + pred_ghr(32b) |

### FIFO 实现

IFQ 本质上是一个**环形缓冲区**，用 head/tail 指针和计数器管理：

```verilog
reg [AW-1:0] head_ptr;    // 读指针（指向最老的指令）
reg [AW-1:0] tail_ptr;    // 写指针（指向下一个空位）
reg [AW:0]   cnt;         // 当前条目数，0..DEPTH
```

**Push 逻辑**（IF 阶段向 IFQ 写入）：

```verilog
// push_1 依赖 push_0 成功（串行准入）
wire actual_push_0 = push_valid_0 && (空间足够);
wire actual_push_1 = push_valid_1 && actual_push_0 && (还有第二个空位);
wire do_push_0 = !flush && actual_push_0;
wire do_push_1 = !flush && actual_push_1;
```

注意 push_1 **依赖 push_0 成功**——这保证了指令的程序序。如果 push_0 因为队列满而失败，push_1 也不会入队。

**Pop 逻辑**（ID2 阶段从 IFQ 读取）：

```verilog
wire do_pop_0 = !flush && pop && head_valid;      // slot0 弹出队首
wire do_pop_1 = !flush && pop2 && head2_valid;     // slot1 弹出队首+1
```

- `head_valid` = 队列非空且队首有效
- `head2_valid` = 队列至少 2 条且第二条有效

**指针更新**（单周期完成所有增减）：

```verilog
head_ptr <= head_ptr + do_pop_0 + do_pop_1;
tail_ptr <= tail_ptr + do_push_0 + do_push_1;
cnt      <= cnt + do_push_0 + do_push_1 - do_pop_0 - do_pop_1;
```

### 反压机制

当 IFQ 快满时，需要通知 IF 阶段减速或暂停：

| 信号 | 条件 | 效果 |
|------|------|------|
| `almost_full` | `cnt >= DEPTH - 1` | IF 最多只能 push 1 条 |
| `full` | `cnt == DEPTH` | IF 完全 stall，不发射任何指令 |

### Flush

分支 misprediction 或异常时，IFQ 需要立即清空所有 speculative 指令：

```verilog
if (flush) begin
    head_ptr <= 0;
    tail_ptr <= 0;
    cnt      <= 0;
    for (i = 0; i < DEPTH; i++)
        valid_q[i] <= 0;
end
```

一次性归零，下一周期 IF 从正确的 PC 重新开始填充。

---

## 配对规则：slot1 什么时候能发射？

双发射的核心难题是**判断两条相邻指令能否安全地同时执行**。在 ID2 阶段，agent 实现了 6 项检查，全部通过才允许 slot1 发射：

```verilog
assign id2_issue_slot1 = id1_id2_valid1          // IFQ 有第二条指令
    && id1_is_pairable                            // 指令类型可配对
    && id_slot0_safe_for_pair                     // slot0 安全（恒 true）
    && id1_no_raw_hazard                          // 无 RAW 依赖
    && id1_no_waw_hazard                          // 无 WAW 冲突
    && id1_no_load_use_hazard                     // 无 load-use
    && id1_no_xcycle_waw                          // 无跨周期 WAW
    && id1_no_store_alias_hazard;                 // 无 store alias
```

### Check 1：指令类型（is_pairable）

```verilog
wire id1_is_pairable = (id1_opcode == `OP_REG)    // R-type ALU
                     || (id1_opcode == `OP_IMM)    // I-type ALU
                     || (id1_opcode == `OP_LUI)    // LUI
                     || (id1_opcode == `OP_AUIPC)  // AUIPC
                     || (id1_opcode == `OP_BRANCH)  // 条件分支
                     || (id1_opcode == `OP_LOAD)    // Load
                     || (id1_opcode == `OP_STORE);  // Store
```

**不可配对的指令**：JAL、JALR、ECALL、MRET——这些涉及控制流跳转或特权操作，只能走 slot0 主通道。

### Check 2：RAW 依赖

如果 slot0 的目标寄存器（rd）是 slot1 的源操作数（rs1 或 rs2），两条指令不能同时发射：

```verilog
wire id1_no_raw_hazard = ~(
    id_reg_write && (id_rd != 5'd0) && (
        (slot1_rs1_used && id1_rs1 == id_rd) ||
        (slot1_rs2_used && id1_rs2 == id_rd)
    )
);
```

例如：
```
ADD x1, x2, x3     # slot0: 写 x1
SUB x4, x1, x5     # slot1: 读 x1 ← 依赖 slot0，不能配对！
```

### Check 3：WAW 冲突

两条指令写同一个目标寄存器：

```
ADD x1, x2, x3     # slot0: 写 x1
OR  x1, x4, x5     # slot1: 也写 x1 ← WAW 冲突！
```

### Check 4：Load-Use（4 级深度）

slot1 的源操作数不能依赖任何 **正在流水线中飞行的 load 指令**——因为 load 的数据在 MEM 阶段才可用，无法前递到同周期的 slot1。

这个检查覆盖了 4 个流水线级：ID/EX、EX/EX2、EX2/AGU、AGU/MEM：

```verilog
assign id1_no_load_use_hazard = ~(
    (id_ex_mem_read  && ... && rd matches slot1 rs) ||
    (ex_mem_mem_read && ... && rd matches slot1 rs) ||
    (ex2_agu_mem_read && ... && rd matches slot1 rs) ||
    (agu_mem_mem_read && ... && rd matches slot1 rs)
);
```

### Check 5：Cross-Cycle WAW（5 级深度）

slot1 的 rd 不能与任何正在飞行的指令的 rd 相同——否则写回时会产生冲突。检查覆盖 5 级：

```verilog
assign id1_no_xcycle_waw = ~(
    id1_reg_write && (id1_rd != 5'd0) && (
        (id_ex_valid   && id_ex_reg_write   && id_ex_rd   == id1_rd) ||
        (ex_mem_valid  && ex_mem_reg_write  && ex_mem_rd  == id1_rd) ||
        (ex2_agu_valid && ex2_agu_reg_write && ex2_agu_rd == id1_rd) ||
        (agu_mem_valid && agu_mem_reg_write && agu_mem_rd == id1_rd) ||
        (mem_wb_valid  && mem_wb_reg_write  && mem_wb_rd  == id1_rd)
    )
);
```

### Check 6：Store Alias

防止 load 和 store 之间的地址冲突（store 还未计算出地址时，load 不能提前执行）。

---

## Slot1 执行路径：1-Cycle Shortcut

Slot0 走完整的 5 级流水线（EX1 → EX2 → AGU → MEM → WB），而 slot1 走一条**捷径**——只需 1 个周期就完成执行并写回：

```
Slot1: ID2 → EX1b → WB
```

EX1b 阶段有独立的 ALU 实例，执行 slot1 的 ALU 运算。写回时通过独立的 PRF 写端口完成，不与 slot0 争抢。

### Slot1 的前递网络

Slot1 也有完整的前递支持（ptag-based，5 级优先级），从 slot0 同周期结果到 MEM/WB 阶段都能前递：

```verilog
wire [31:0] slot1_rs1_fwd =
    match(id_ex_rd_ptag)   ? ex_alu_y :        // slot0 同周期
    match(ex_mem_rd_ptag)  ? ex_mem_alu_y :     // EX2
    match(ex2_agu_rd_ptag) ? ex2_agu_alu_y :    // AGU
    match(agu_mem_rd_ptag) ? agu_mem_fwd_data : // MEM
    match(mem_wb_rd_ptag)  ? wb_data :          // WB
                             slot1_rs1_base;    // PRF 原始值
```

### Slot1 分支处理

Slot1 支持条件分支指令，但采用**隐式 predict not-taken** 策略（不查 BPU）。如果 slot1 的分支实际 taken，就触发 misprediction flush。

Redirect 优先级：**slot0 > slot1**。如果 slot0 本身也在 redirect，slot1 的结果会被 gate 掉。

---

## Pair-Block 分析：为什么不能双发射？

双发射率不是 100%，原因就是各种配对检查未通过。Testbench 对每个单发射周期进行归因，按**互斥优先级**分类：

```verilog
if (dut_pop0 && !dut_pop1) begin          // slot0 发射了，slot1 没有
    if      (!dut_id1_valid1)   → novalid1  // IFQ 没第二条指令
    else if (!dut_slot0_safe)   → unsafe0   // slot0 不安全（已废弃）
    else if (!dut_id1_alu_only) → notalu    // 指令类型不可配对
    else if (!dut_id1_no_raw)   → raw       // RAW 依赖
    else if (!dut_id1_no_waw)   → waw       // WAW 冲突
    else if (!dut_id1_no_lu)    → loaduse   // load-use
    else if (!dut_id1_no_xwaw)  → xcycwaw   // 跨周期 WAW
end
```

### 实测数据解读

以 main 分支的 benchmark 数据为例：

| Benchmark | dual% | 主要阻挡因素 | 分析 |
|-----------|------:|-------------|------|
| **memcpy_64w** | 73% | RAW 90% | LW/SW 交替，天然配对良好；RAW 主要是 SW 依赖前一条 LW 的寄存器 |
| **popcount_64** | 69% | RAW 74% | 内层循环有紧密的数据依赖链 |
| **fib_20** | 50% | xWAW 89% | `a=b; b=a+b` 模式导致大量跨周期 WAW |
| **bsort_16** | 41% | RAW 42%, nta 42% | 比较-交换模式中 LW 后紧跟 BLT 造成 RAW |
| **sum_1_to_100** | 34% | nta 50%, xWAW 48% | 循环体短，branch 占比高 |

几个关键观察：

1. **RAW 依赖是最大的阻挡因素**——这是程序本身的数据流决定的，硬件优化空间有限
2. **Cross-cycle WAW (xWAW)** 在某些模式下很突出（如 fib 的寄存器复用模式）
3. **novalid1（IFQ 没有第二条）** 在正常运行中占比很低，说明 IFQ 深度 8 足够
4. **unsafe0 恒为 0**——slot0 的安全检查已完全放宽

### 不可配对指令类型（nta）细分

当 slot1 因为指令类型被阻挡时，进一步细分：

| 类别 | 说明 | 典型场景 |
|------|------|----------|
| store | Store 指令 | 连续 SW 无法都走 slot1 |
| branch | 条件分支 | 但已支持 slot1 branch |
| jump | JAL/JALR | 函数调用/返回，**不可配对** |
| other | ecall/mret | 特权指令 |

> 注：早期版本 slot1 只支持纯 ALU 指令。后续 agent 逐步扩展了 slot1 对 load、store、branch 的支持，显著提升了双发射率。

---

## 双发射的收益

双发射对性能有多大提升？对比理论单发射 CPI（假设无 dual-issue）和实际 CPI：

在 feature/ooo 分支（乱序执行）上，**6/9 benchmarks 达到 CPI < 1.0**，即 IPC > 1.0——这只有双发射才能做到。最高的 `fib_20` 达到 **1.54 IPC**，意味着平均每周期退休 1.54 条指令。

即使在 main 分支（顺序执行），双发射也将大部分 benchmark 的 CPI 从 2.x 降到了 1.5-1.9 的范围。

---

## 小结

本篇介绍了双发射设计的核心要素：

| 组件 | 要点 |
|------|------|
| **IFQ** | 8-entry 环形队列，每周期 push/pop 各最多 2 条 |
| **配对规则** | 6 项检查：指令类型 + RAW + WAW + load-use + xWAW + store alias |
| **Slot1 通道** | 1-cycle shortcut，独立 ALU + 前递网络 |
| **Pair-block** | 最大瓶颈是 RAW 依赖（程序固有），其次是 xWAW |
| **实测收益** | 峰值 73% 双发射率，IPC 最高 1.54 |

下一篇将探讨**分支预测**——从 Bimodal 到 TAGE，如何将 30-50% 的 misprediction rate 压下来。

---

*项目地址：[github.com/HaibinLai/simple-CPU](https://github.com/HaibinLai/simple-CPU)*
