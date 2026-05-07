# OoO / Superscalar 概念与本项目代码对照

下面把现代 CPU 中常见的几个核心概念，对应到本项目（`rtl/core/`）里的具体代码位置与关键信号。

---

## 多发射（Superscalar）

Superscalar（超标量）是指 CPU 在一个时钟周期里，不再只发射（issue）一条指令，而是同时发射多条彼此独立的指令到不同执行单元。例如一个现代 CPU 可能同时执行整数加法、浮点乘法、load/store 等不同操作。核心目标是提升 IPC（Instructions Per Cycle）。为了做到这一点，CPU 需要能够分析指令之间是否存在依赖关系，并动态寻找可以并行执行的指令。比如 Intel、AMD 的现代 CPU 通常都是 4-wide、6-wide 甚至更宽的 superscalar 架构。

**本项目实现：2-wide（双发射）前端**，slot0/slot1 同时取两条相邻指令，经 IFQ 缓冲后按配对规则发射到后端。

- 双 PC 取指（`pc` / `pc+4`）与双指令读 IMEM：[rtl/core/cpu_top.v](rtl/core/cpu_top.v#L129-L156)
- IFQ（双 push / 双 pop）：[rtl/core/ifq.v](rtl/core/ifq.v)，例化点 [cpu_top.v#L213-L276](rtl/core/cpu_top.v#L213-L276)
- Slot1 配对门控（`id2_issue_slot1`，要求 ALU-only、无依赖等）：[cpu_top.v#L397-L404](rtl/core/cpu_top.v#L397-L404)
- 关键信号：`pc_plus4` / `pc_plus8` / `if_id_valid0/1` / `push_valid_0/1` / `id1_is_alu_only`

---

## 乱序执行（Out-of-Order Execution, OoO）

乱序执行是现代 CPU 提高利用率的核心技术之一。它允许 CPU 不按照程序原本的顺序执行指令，而是优先执行"已经准备好"的指令。比如某条 load 指令正在等待内存返回数据（可能要几百 cycles），CPU 不会傻等，而是继续执行后面那些不依赖它的指令。这样可以隐藏长延迟，提高流水线利用率。需要注意的是，虽然内部执行顺序乱了，但 CPU 最终仍然必须保证程序对外的结果与原始顺序一致（precise state）。

**本项目状态：in-order 后端 + OoO 基础设施**。Rename + ROB 已经就位，但还没有独立的乱序 issue 阶段；后端仍按 PC 顺序发射，由 ROB 保证最终对外顺序一致。

- ROB 提供顺序提交、乱序写回的容器：[rtl/core/rob.v](rtl/core/rob.v)
- Rename 提供 ptag 化解假依赖：[rtl/core/rename.v](rtl/core/rename.v)
- 路径规划文档：[docs/2issue-implementation-plan.md](docs/2issue-implementation-plan.md)

---

## Speculative Execution（推测执行）

推测执行是 CPU 在"不确定未来是否正确"的情况下提前执行指令。最典型的场景是 branch prediction（分支预测）：CPU 猜测 if/else 会走哪条路径，然后提前执行对应路径上的指令。如果猜对了，就节省了大量等待时间；如果猜错了，则回滚错误执行的结果并重新执行正确路径。现代深流水 CPU 非常依赖 speculative execution，否则 branch stall 会让流水线大量空闲。著名的 Spectre 漏洞，本质上就是 speculative execution 带来的侧信道问题。

**本项目实现：BTB + GShare BHT + GHR 的分支预测器，配合 EX 阶段误预测 flush。**

- BPU 模块（2-way BTB + GShare BHT + GHR）：[rtl/core/bpu.v](rtl/core/bpu.v)
  - BTB / BHT 存储：[bpu.v#L32-L52](rtl/core/bpu.v#L32-L52)
  - IF 阶段产出 `pred_taken` / `pred_target`：[bpu.v#L57-L75](rtl/core/bpu.v#L57-L75)
  - EX 阶段反馈训练（更新 BHT/BTB/GHR）：[bpu.v#L77-L95](rtl/core/bpu.v#L77-L95)
- 误预测回滚（`ex_redirect` → 注入 NOP + 重定向 PC）：[cpu_top.v#L873-L874](rtl/core/cpu_top.v#L873-L874)
- 关键信号：`pred_taken`、`pred_target`、`ghr`、`btb0_valid` / `btb1_valid`、`bht[]`、`upd_valid`、`upd_taken`

---

## Register Renaming（寄存器重命名）

寄存器重命名用于消除"假依赖（false dependency）"。程序里虽然只有有限个架构寄存器（如 x86 的 rax/rbx），但 CPU 内部实际上有更多"物理寄存器（physical registers）"。CPU 会把逻辑寄存器动态映射到新的物理寄存器上。例如：

```asm
mov r1, ...
add r1, ...
```

表面上两条指令都写 r1，但 CPU 可以把它们映射到不同物理寄存器，从而避免无意义的写后写（WAW）或写后读（WAR）冲突。这样可以让更多指令并行执行。register renaming 是 OoO CPU 的基础技术之一。

**本项目实现：48 个物理寄存器（ptag 0–47，6-bit）**。ptag 0–31 与架构寄存器一一固定映射，ptag 32–47 由 free list 动态分配给推测写。

- Rename 模块（双槽 s0/s1 同时分配）：[rtl/core/rename.v](rtl/core/rename.v)
  - 存储：`map[32]`（speculative RAT，ARF→ptag）、`arch_map[32]`（RRAT，已提交映射，用于 flush 恢复）、`busy[48]`、free list `fl_mem[16]`：[rename.v#L52-L72](rtl/core/rename.v#L52-L72)
  - 双槽组合查 + bundle 内前递：[rename.v#L80-L106](rtl/core/rename.v#L80-L106)
  - Free list 头尾指针 / 分配 vs commit 释放：[rename.v#L108-L200](rtl/core/rename.v#L108-L200)
- 关键信号：`map[]` / `arch_map[]` / `fl_head` / `fl_tail` / `fl_cnt` / `s0_rd_ptag_new` / `s0_rd_ptag_old` / `s1_rd_ptag_new` / `s1_rd_ptag_old` / `stall`

---

## Tomasulo Algorithm（Tomasulo 算法）

Tomasulo 是 IBM 在 1960s 提出的经典动态调度算法，是现代 OoO CPU 的理论基础之一。它的核心思想是：通过 reservation stations（保留站）和寄存器重命名，让指令在操作数准备好后自动执行，而不必严格按照程序顺序等待。它能动态跟踪数据依赖，并通过广播结果（Common Data Bus）唤醒后续指令。相比早期 scoreboard 方法，Tomasulo 能更好地解决 WAR/WAW hazard。现代 CPU 虽然实现已经复杂很多，但本质思想仍然来自 Tomasulo。

**本项目状态：未实现 Tomasulo**（没有 reservation station，没有 CDB wakeup）。当前走的是更简单的 **显式 forwarding + load-use stall** 路线：

- 操作数前递（4 优先级 MUX，从最近的生产者取值）：[rtl/core/forwarding.v](rtl/core/forwarding.v)
- 冒险检测（load-use 等）：[rtl/core/hazard.v](rtl/core/hazard.v)

未来要做真正的 OoO 后端时，Tomasulo 风格的 RS + wakeup 是要补的核心结构。

---

## ROB（Reorder Buffer，重排序缓冲区）

ROB 是现代 OoO CPU 用来"恢复程序顺序"的关键结构。虽然 CPU 内部会乱序执行，但最终必须按程序顺序提交（commit）结果，否则异常、中断、错误恢复会完全混乱。ROB 会记录每条指令的执行状态、目标寄存器、结果等信息。指令可以乱序执行，但只有当它之前的所有指令都完成后，它才能按顺序 commit。ROB 保证了 precise exception（精确异常）和程序可见状态的一致性。可以理解为：

> OoO 是"乱着干活"，ROB 是"按顺序交卷"。

**本项目实现：16 条目环形 ROB（tag 0–15，4-bit），支持双分配 / 双写回 / 双提交，以及全 flush 与 partial flush。**

- ROB 模块：[rtl/core/rob.v](rtl/core/rob.v)
  - 条目存储（`valid_q[] / done_q[] / pc_q[] / rd_q[] / result_q[] / is_store_q[] / ptag_new_q[] / ptag_old_q[]`）：[rob.v#L47-L97](rtl/core/rob.v#L47-L97)
  - 分配（`alloc_tag_0/1`，移动 `tail_ptr`）：[rob.v#L112-L145](rtl/core/rob.v#L112-L145)
  - 顺序提交头视图（`commit_valid_X = valid_q[head_X] && done_q[head_X]`）：[rob.v#L147-L185](rtl/core/rob.v#L147-L185)
  - 写回置 `done`、commit 弹出、flush / flush_partial：[rob.v#L230-L280](rtl/core/rob.v#L230-L280)
- 关键信号：`valid_q[]` / `done_q[]` / `head_ptr` / `tail_ptr` / `cnt` / `alloc_tag_0/1` / `commit_valid_0/1` / `commit_result_0/1` / `flush` / `flush_partial`
- 配合 Rename：每条进 ROB 时同时记 `ptag_new`（新分配的目标 ptag）和 `ptag_old`（被该 rd 覆盖的旧 ptag）；commit 时把 `arch_map[rd] ← ptag_new` 并把 `ptag_old` 还回 free list，从而做到 precise state。

---

## 一句话对照表

| 概念 | 项目里对应 | 状态 |
|---|---|---|
| Superscalar | [cpu_top.v](rtl/core/cpu_top.v) 双取指 + [ifq.v](rtl/core/ifq.v) | ✅ 2-wide 前端 |
| OoO | [rob.v](rtl/core/rob.v) + [rename.v](rtl/core/rename.v) 已就位 | ⚠️ 后端仍 in-order |
| Speculative | [bpu.v](rtl/core/bpu.v) BTB+GShare + flush | ✅ |
| Renaming | [rename.v](rtl/core/rename.v)（`map` / `arch_map` / free list） | ✅ |
| Tomasulo (RS+CDB) | 用 [forwarding.v](rtl/core/forwarding.v) + [hazard.v](rtl/core/hazard.v) 替代 | ❌ 未实现 |
| ROB | [rob.v](rtl/core/rob.v) 16-entry，双口 | ✅ |
