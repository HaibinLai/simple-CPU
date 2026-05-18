# 从零开始造一颗 RISC-V CPU（三）：分支预测微架构 — 从 Bimodal 到 TAGE 引擎的硬核解析

> 系列博客第 3 篇 —— 深入探讨影响深级流水线性能的核心命题：分支预测（Branch Prediction）。本文将通过微架构层面的演进逻辑，讲解从基础的 Bimodal 到目前工业界最先进的 TAGE（TAgged GEometric History Length）预测器的算法本质，并结合微架构数据通路（Mermaid 框图）与核心 Verilog 源码，解析这套在不到 400 行代码内实现的高性能引擎。

---

## 1. 为什么我们需要复杂的预测器？IPC 崩塌的元凶

在我们的 8 级乱序双发流水线中，一条分支（Branch）或跳转（Jump）指令从 `IF`（取指）端进入，最快也要在 `EX1`（执行）端才能完成条件判断与目标地址解析。这意味着在这 **3~4 个周期** 内，如果没有预测机制，前端只能注入无效的 Bubble。

以 `bsort_16`（冒泡排序）为例，核心内层循环存在 325 次条件分支。如果采用最保守的 Stall-on-Branch（遇分支即停顿）策略，性能惩罚为：
$$\text{Penalty} = 325 \times 3 = 975 \text{ Cycles}$$
在百微秒级的基准测试中，这将直接绞杀掉架构所有的 IPC 优势。为了让流水线处于“无间断榨取（Speculative Pipelining）”状态，**CPU 必须在 IF 取指的第一拍，就“盲猜”出分支指令的方向（Direction）与目标地址（Target）。** 

分支预测从工程上拆分为两个独立的硬件实体：
- **BTB (Branch Target Buffer)**：预测“跳去哪里”（目标地址）。
- **BPU / BHT (Branch History Table)**：预测“跳还是不跳”（方向）。

---

## 2. BTB 结构：目标地址的相联缓存

我们在 IF 阶段部署了一个 **2路组相联（2-Way Set-Associative）** 的 BTB。它的物理实现极像上一篇讲的 L1 I-Cache。由于 PC 的跳转目标通常是静态固定的（除了 `jalr` 这种间接跳转），BTB 的核心职责就是建立起 `PC` 到 `Target PC` 的快速哈希映射。

我们的 BTB 参数极尽精简：32 Sets × 2 Ways = 共 64 项。采用 1-bit LRU 维持新鲜度。此外我们特别加入了一个 `uncond` (Unconditional) 标志位。
对于无条件跳转（如 `JAL`），只要 BTB 命中，直接拉起 `pred_taken = 1`，彻底旁路掉 BPU 方向预测器的读表操作，避免无效占用 BHT 宝贵的表项训练空间。

---

## 3. 方向预测器的架构演进

如果说 BTB 是查字典，那 BPU 就是真正的“算法玄学”。硬件需要根据历史行为特征去拟合未来的代码流控制。

### 3.1 第一代：Bimodal (双模态预测器)
在程序中，大部分循环底部的 `bne` 总是倾向于 Taken，直到最后一次退出。如果用 1-bit 记录，在退出和重新进入循环时会引发两次 Miss。
经典的解决方案是利用 **2-bit 饱和计数器（Saturating Counter）**。
- `00` (强不跳) <-> `01` (弱不跳) <-> `10` (弱跳) <-> `11` (强跳)

Bimodal 的问题在于它仅依赖 `PC` 寻址。对于那些高度依赖前后文（Context-Dependent）的交叉分支，不同代码路径带来的执行概率完全不同，这种现象被称为**干扰别名（Aliasing）**。

### 3.2 第二代：GShare (全局历史相关)
为了引入上下文，架构师们构建了 **GHR (Global History Register)**，即一个移位寄存器，每遇到一次分支就将其真实方向移入。然后将 `PC` 与 `GHR` 进行异或（XOR）哈希。这种设计有效剥离了别名，让同一条分支指令在不同历史踪迹下，被散列到 BHT 的不同槽位中去训练。

### 3.3 第三代：TAGE (多表标记几何历史预测器)
GShare 的问题是：GHR 究竟该多长？对于简单循环，极短的历史就能完美预测，长历史反而会稀释训练集导致冷启动（Cold-start）漫长；但对于超复杂的控制流，又需要动辄数十位的长历史才能捕捉隐秘关联。
2006 年 André Seznec 提出了 TAGE，它通过 **几何级数递增分配历史长度的多表组合（Multiple Tables with Geometric History Length）**，在极高命中率的同时抑制硬件开销，统治了此后多年的微架构界。

---

## 4. TAGE-2L 微架构数据通路全解

我们实现了一套标准的 TAGE-2L（包含 1 个 Base 表和 2 个 Tagged 表）。总体配置为：
- **T0 (Base)**: 256 项 Bimodal 表（无标签，退路底线）。
- **T1 表**: 128 项，挂载 8-bit GHR 历史。
- **T2 表**: 128 项，挂载 16-bit GHR 历史。（真正的 TAGE 会拉大至 6~8 个表，最高百位历史，本项目为平衡门效做压缩）。

```mermaid
graph TD
    PC[Fetch PC<br>32-bit] --> BaseIDX(Base Hash: PC[9:2])
    PC --> Hash1(T1 Hash: PC ^ Fold_8bit)
    PC --> Hash2(T2 Hash: PC ^ Fold_16bit)
    
    GHR[GHR 全局历史寄存器 32-bit] -->|8-bit 折叠函数| Hash1
    GHR -->|16-bit 折叠函数| Hash2

    BaseIDX --> Bank0[(T0 Base<br>256 组 2-bit BHT)]
    Hash1 --> Bank1[(T1 Tagged 表<br>Ctr+Usefulness+Tag)]
    Hash2 --> Bank2[(T2 Tagged 表<br>Ctr+Usefulness+Tag)]

    Bank2 -->|Tag Match?| Match2{Hit?}
    Bank1 -->|Tag Match?| Match1{Hit?}
    Bank0 -->|Always Hit| Match0{Hit!}

    Match2 -->|Yes| Sel2(T2 预测结果)
    Match1 -->|Yes| Sel1(T1 预测结果)
    
    Sel2 --> MUX((长历史优先 MUX))
    Sel1 --> MUX
    Match0 --> MUX
    
    MUX -->|最终 Provider| Final(预测跳转方向)
```

**预测选择逻辑 (Provider Selection)：**
TAGE 的奥义在于**优先相信长历史的判断**。电路通过并行的 Tag 比较，如果 T2 命中则强制采纳 T2；若未命中则降级求助 T1；若全不命中，靠底层的 T0 (Base) 保底。

```verilog
// bpu.v: 纯组合逻辑输出预测
wire if_tage_pred = if_t2_present ? if_t2_pred :    // T2 具有最高话语权
                    if_t1_present ? if_t1_pred :    // T1 次之
                                   if_base_pred;    // T0 保底

// 最终结合 BTB 的结果推向流水线
assign pred_taken = btb_hit && (if_hit_uncond || if_tage_pred);
```

---

## 5. TAGE 训练引擎的 Verilog 拆解

在 EX 阶段得出真实的 Taken / Not-Taken 后，硬件必须反向校准 BPU 表项。这比预测过程复杂得多。

### 5.1 Usefulness（效用位）与全局衰减
如何断定一条映射项是否有价值？每个 Tagged 表项携带了 2-bit 的 `Usefulness (u-bit)`。
- 如果 TAGE 采纳的预测正确，而次优表（Alternate 表）预测错误，证明当前选中的长历史表是非常不可替代的。**此时增加对应项的 u-bit**。
- 反之，如果长历史预测翻车，而次优表反而对了，说明当前的长历史关联是伪关联。**此时扣减 u-bit**。

当发现预测错误时，系统试图**在历史更长的表中开辟新领地（Allocation）**。但为了保护现有的极品条目，仅当目标位的 `u-bit == 0` 时才允许盖写。若找不到，则触发一次**全表微衰减 (Global Degradation)**。

```verilog
// 分配逻辑：如果 T1_u 已经被耗尽为 0，则可以被新历史霸占写入
if (!upd_t1_u_zero) begin
    t1_valid[upd_t1_idx] <= 1;
    t1_tag[upd_t1_idx]   <= upd_t1_tag;
    t1_ctr[upd_t1_idx]   <= upd_taken ? 3'b100 : 3'b011; // 初始化弱倾向
    t1_u[upd_t1_idx]     <= 0; // 新条目 usefulness 极低，待培养
end else begin
    // 定期全局衰减，把那些历史久远不再生效的老爷条目排空
    for (j = 0; j < T1_SIZE; j++)
        if (t1_u[j] != 0) t1_u[j] <= t1_u[j] - 1;
end
```

这是一套由数字硬件实现的、极为精微的**无监督强化学习模型**。

---

## 6. 微架构上的致命陷阱：GHR Snapshot 退窗

在工程实现中，我们曾经在接入 TAGE 后发现预测率还不如极简的 Bimodal，经过极限波形追踪才排查出了深水区大坑——在更新表项时，使用了 EX 阶段实时的 GHR。

**理论死角**：当分支到达 EX 段准备更新历史时（周期 N+3），IF 段很可能已经又预抓取并吐出了两三个推测分支，悄悄篡改了当前的 GHR。如果我们用此时已经被污染的 GHR 去重建索引（Fold hash），就会像刻舟求剑一样把数据写到错位的槽位里，严重毒化整个 TAGE 网络。

**正确解法：GHR 快照伴随式穿透（Snapshot Pipeline）**。
```verilog
// 1. IF 阶段：在打出预测的瞬间，将此刻的 GHR "快照"封存
assign pred_ghr_o = ghr;

// 2. 随指令流历经 IFQ → ID1 → Renaming → EX... (增加沿途流水寄存器的开销)

// 3. EX 阶段：提取当年的纯净快照，逆推计算出它当年访问的 BPU 槽位
wire [BHT_IDX_W-1:0] upd_bht_idx = upd_pc_idx ^ fold_bht(upd_pred_ghr);
```
为了这一正确的训练机制，IFQ 指令队列每一个 Entry 都必须多花 32-bit 的珍贵 SRAM 以寄存 `pred_ghr`。这是为了获取极致 IPC 必须付出的硬件代价。

---

## 7. 实测数据与形态学洞见

我们提取了基准库中最具代表性的代码分布形态的 Miss Rate 回溯：

| 代码形态特征 | Benchmark | Mispred 次数 | Miss Rate | 深层解析 |
|-------------|-----------|--------:|----------:|---------|
| 纯线性内存复制 | memcpy_64w | 3 | **4.3%** | 循环极度规律，TAGE 快速学习锁死，几乎零误判。 |
| 高计算密度嵌套 | bsort_16 | 38 | **11.7%** | 存在内外层逻辑纠缠，嵌套长度超过 GHR，但 TAGE T1 表仍能锚定中长度关联。 |
| 疯狂函数调用场 | matmul_4x4 | 2,349 | **36.7%** | 大量 JALR 子程序回调，超出了 BTB 64项容量导致地址靶向性击穿，这是深层压制的根源。 |
| 短路高频微循环 | fib_20 | 23 | **53.5%** | 循环体仅 5 条指令，TAGE 刚建立数学拟合便遇上退出沿（必然引爆 1 次 Miss），样本稀释导致。 |

可以看到，在纯正的数学运算和算法级迭代上（如 `11.7%` Miss 惩罚），TAGE 展现出了无与伦比的压制力。将几年前论文中的顶级魔法在不到 400 行 Verilog 芯片逻辑上运行且实现高达预期（大幅收窄了原先 Bimodal 在同规格下的伪命题预测），是我们这套乱序架构最性感的证明。

下一篇，我们将回眸整体，用 Python 编写一套微架构指令集测试集（Instruction Generator），从上层发起最为地狱的交叉组合覆盖。

---
*项目地址：[github.com/HaibinLai/simple-CPU](https://github.com/HaibinLai/simple-CPU)*
