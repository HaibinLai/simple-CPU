# 从零开始造一颗 RISC-V CPU（四）：Cache 微架构演进与组相联设计深度解析

> 系列博客第 4 篇 —— 深入探讨存储器层级（Memory Hierarchy）的底层硬件机制。本文将从早期的“存储墙”问题出发，讲解从直接映射（Direct Mapped）到 2路组相联（2-Way Set-Associative）的架构演进，并结合完整的微架构数据通路（Mermaid 框图）与 Verilog 源码，极为细致地剖析这套 L1 Cache 的全相联比对、LRU 替换以及基于位掩码的写合并（Write Merge）逻辑。

---

## 1. 存储墙（Memory Wall）与工程动因

自 1980 年代以来，CPU 逻辑门频率的增长速度远超 DRAM 存储器的响应速度，形成了著名的 **“存储墙（Memory Wall）”**。在现代处理器中，如果不引入 Cache 隔离，一次 L1D Miss 动辄导致流水线 Stall 上百个周期，直接将极度优化的乱序超标量引擎压垮。

为了掩蔽这种极端的延迟周期，现代 CPU 基于时间局部性（Temporal Locality）和空间局部性（Spatial Locality）引入了 Cache 层次结构。本项目采用了经典的 **Harvard 架构**，实现了指令与数据分离的 L1 I-Cache 与 L1 D-Cache。

---

## 2. 直接映射（Direct Mapped）的死穴：冲突缺失（Conflict Miss）

在我们的第一版架构中，L1 I-Cache 被设计为极简的 **直接映射（Direct Mapped）**，每行 1 Word，容量 256 Bytes（由于是单字行，Index 占 6 比特，对应 64 行）。

直接映射的查找逻辑极快，因为一个内存地址唯一对应 Cache 中的某一行（仅需查一次表）。但在实际 Benchmark（特别是 `dotprod` 向量点乘）跑分时，我们遭遇了毁灭性的性能滑坡。

**为什么会发生组抖动（Cache Thrashing）？**
以 `dotprod` 为例，我们需要交替读取数组 A 和数组 B 的元素。假设：
- A 数组基址为 `0x1000` (二进制 `... 0001 0000 0000 0000`)
- B 数组基址为 `0x1100` (二进制 `... 0001 0001 0000 0000`)

在直接映射下，提取 Index 的位域是 `addr[7:2]`。
- A[0] 的 Index: `0x1000[7:2]` = `000000`
- B[0] 的 Index: `0x1100[7:2]` = `000000`

两者的 Index 发生**硬碰撞**。
```assembly
// 矩阵点乘：A[i] 与 B[i] 交替加载
LW   x10, 0(x15)    // 读 A[0]，占用 Index 0，引发 Miss 并写 Cache
LW   x11, 0(x16)    // 读 B[0]，也是 Index 0！被迫踢掉 A[0]，引发 Miss
// 下一次循环
LW   x10, 4(x15)    // 读 A[1]，又是 Index 1！被迫踢掉 B[0]...
```
这种两个频繁访问的地址被哈希到同一个 Cache 槽位的现象，导致了 100% 的**冲突缺失（Conflict Miss）**。为了化解这一微架构死穴，我们在后续分支中全面升级为 **2路组相联（2-Way Set-Associative）**。

---

## 3. L1 Cache 微架构全景：2-Way 组相联架构

为了平衡命中率与比较逻辑的时序裕量，我们采用了 **2路组相联 + 每行 4 Word (16 Bytes)** 的设计。地址解码规约为：
- **Tag (22-bit)**: 高位标签，用于验证地址身份。
- **Index (6-bit)**: 对应 64 个 Set。
- **Offset (2-bit)**: 在命中的 4 个 Word 中抉择目标字。
- **Byte (2-bit)**: 字节对齐（处理读写指令的 Byte 宽度）。

下图展示了读操作（Read Hit）在 Cache 内部最核心的关键时序路径：

```mermaid
graph TD
    ADDR[CPU 访存地址 32-bit] -->|拆解| Decoder[Tag = bit 31:10<br/>Index = bit 9:4<br/>Offset = bit 3:2]
    
    Decoder -->|Index 路由| Bank0[(Way 0 SRAM Bank)<br/>Tag & Data & Valid]
    Decoder -->|Index 路由| Bank1[(Way 1 SRAM Bank)<br/>Tag & Data & Valid]
    
    Bank0 -->|Way0 Tag | CMP0{CMP ==}
    Decoder -.->|Address Tag| CMP0
    Bank0 -->|Way0 Valid| AND0(&)
    CMP0 --> AND0
    
    Bank1 -->|Way1 Tag | CMP1{CMP ==}
    Decoder -.->|Address Tag| CMP1
    Bank1 -->|Way1 Valid| AND1(&)
    CMP1 --> AND1
    
    AND0 -->|Hit 0| OR(OR Gate)
    AND1 -->|Hit 1| OR
    OR -->|最终 Hit | HitSignal((Hit Result))
    
    Bank0 -->|Way0 Data Line 4-Words| MUX_WAY((Way MUX))
    Bank1 -->|Way1 Data Line 4-Words| MUX_WAY
    AND0 -.->|Sel = 0| MUX_WAY
    AND1 -.->|Sel = 1| MUX_WAY
    
    MUX_WAY -->|选出的 Cache Line| MUX_OFF((Offset MUX))
    Decoder -.->|Offset 二进制位| MUX_OFF
    MUX_OFF -->|最终 32-bit Word| RData(CPU 读数据)
```

### 3.1 关键时序路径分析 (Critical Timing Path)
请仔细观察上面的网络，**SRAM 读取 -> Tag 比较器 (XOR 树) -> Valid 位与门 -> 多路选择器 (MUX) 最终选通 32-bit 数据**，这段纯组合逻辑链条是现代 CPU 的超级性能瓶颈。
如果 CPU 频率跑向 3GHz+（约 0.33ns 单周期），信号根本跑不完这条物理链路。这就是为什么高速处理器（如 Cortex-A78 或 Zen 架构）的 L1 命中往往需要 3~4 个独立流水周期，或者必须引入复杂的“路预测（Way Prediction）”技术。

### 3.2 命中判定逻辑的并行展开

```verilog
// 2-Way 命中判定逻辑的并行展开
wire a_hit0 = c_valid[0][a_idx] && (c_tag[0][a_idx] == a_tg);
wire a_hit1 = c_valid[1][a_idx] && (c_tag[1][a_idx] == a_tg);
wire a_hit  = a_hit0 || a_hit1;

// 依靠 a_hit0 和 a_hit1 驱动后端的多路选通 (Multiplexing)
wire [31:0] cache_word = a_hit0
    ? c_data[0][a_idx][a_off*32 +: 32]    // 若 Way 0 命中，拦截对应偏移量的数据
    : c_data[1][a_idx][a_off*32 +: 32];   // 否则取 Way 1 
```

---

## 4. LRU (Least Recently Used) 机制的降维打击

当一个 Set 中的 2 个 Way 都被占满时，新来的数据该踢走谁？我们需要淘汰“最近最少使用”的缓存行。

对于 4-Way 或 8-Way，精确的 LRU 记录需要巨大的硬件开销（通常退化为 Tree-PLRU 伪算法）。但是**对于 2-Way，只需要 1 根 Flip-Flop (寄存器) 就可以完美表达！** 一个布尔状态刚好记录 2 个元素的相对冷热：

```verilog
reg c_lru [0:CACHE_SETS-1]; // 每个 Set 只需 1-bit，空间开销微乎其微

always @(posedge clk) begin
    // 状态反转：若这次摸了 Way 0，那 Way 1 就变成了最冷的“备胎”(记为 1)
    if (a_hit0) c_lru[a_idx] <= 1'b1;   
    if (a_hit1) c_lru[a_idx] <= 1'b0;   
end

// Victim 选择网络：如果某条路还是空的，优先填空路；都满则依照 LRU 踢人
wire a_have_empty = !c_valid[0][a_idx] || !c_valid[1][a_idx];
wire a_empty_way  = !c_valid[0][a_idx] ? 1'b0 : 1'b1;
wire a_victim_way = a_have_empty ? a_empty_way : c_lru[a_idx];
```
仅仅通过这三行简单的组合门逻辑，我们就在 1 纳秒的时间内无损解决了 Cache 的生态代谢。

---

## 5. 写策略：Write-Through 与 字内掩码融合 (Write Merge)

我们的 D-Cache 采用了极简但绝对安全的 **Write-Through（直写） + Write-Allocate（写分配）** 架构。

**直写策略（Write-Through）**意味着，无论 Cache 是否命中，对 CPU 而言，数据的写入也会同步穿透到背后的主存中。优点是：**主存永远持有最新数据，抛弃了复杂的 Dirty 标记和淘汰脏数据的回写（Write-Back）耗时。**

**硬核技术解析：Byte-Enable (字节掩码) 的时序融合**
RISC-V 支持部分字长存储（比如 `SB` 存单字节, `SH` 存半字）。假设原内存数据为 `0x11223344`，指令 `SB x10, 0(x15)` 企图将 `0x99` 写入该地址的最低字节。我们需要产生最终词 `0x11223399`。如果只有寄存器级别操作，需要进行精细的位操纵：

```verilog
// 1. 根据 sb/sh/sw 指令译码下发的 Byte Enable 构建 32 位的宽掩码
// 比如 SB 最低字节，be = 0001, be_mask 展开后就是 0x000000FF
wire [31:0] be_mask = {{8{be[3]}}, {8{be[2]}}, {8{be[1]}}, {8{be[0]}}};

// 2. 将 CPU 试图写入的字节片段，强行镶嵌回被读出的 src_word 背景板上
// src_word & ~be_mask: 保留无关的高 24 位 (得 0x11223300)
// wdata & be_mask:    取新写的低 8 位 (得 0x00000099)
// 两者 OR 操作，达成字内写入融合 (得 0x11223399)
wire [31:0] merged_word = (src_word & ~be_mask) | (wdata & be_mask);
```

**写分配（Write-Allocate）**是指如果发生 Write Miss，硬件会将它所属的整个 Cache Line (4 Words) 从主存拉上来，然后再对命中的那 1 个 Word 应用上文的 `merged_word`，最后写向目标 Way。

---

## 6. 特殊端口：MMIO 映射与 Dual-Port D-Cache

D-Cache 不可缓存 I/O（MMIO）地址，否则会错过 UART 外设引脚上状态寄存器的变化：
```verilog
// cpu_top.v: I/O 地址穿透屏蔽
wire mmio_hit = (agu_mem_alu_y >= `MMIO_BASE) && (agu_mem_alu_y < `MMIO_END);
wire dmem_we  = dmem_write_req & ~mmio_hit;  // 直接斩断向 D-Cache 的写使能
wire [31:0] mem_rdata_mux = mmio_hit ? mmio_rdata : dmem_rdata;
```

此外为了迎合我们的**乱序双发射（Dual-Issue）**流水线设计，D-Cache 底层扩展了**端口双开（Dual-Port）读特性**（在 FPGA 上相当于使用真正的真双端口 BRAM 宏）。Slot0 与 Slot1 在同一流水拍内，可以从同一组 Cache 宏内部并发提取两个完全互相独立的 32-bit 数据，支撑起超标量核极具侵略性的发射率。

---

## 7. 微架构性能剖析：命中率监测

基于 Verilator，我们在 main 分支上挂载了标准测试子集，截取真实的 L1 I$ 与 D$ Miss 占比监测点：

| Benchmark (RISC-V 32I) | I$ Miss 率 | D$ Miss 率 | 形态学深度点评 |
|------------------------|----------:|----------:|-------------|
| fib_20                 | 3.8%      | 14.4%     | 指令段极短，I$ Miss 大多源于首轮 Compulsory Miss (强制缺失) |
| bsort_16               | 0.7%      | 1.3%      | 数据集完全嵌入单向 L1 Set 内容纳极限，趋近 100% Hit |
| coremark_lite          | 0.7%      | **20.9%** | **重灾区：指针追逐 (Pointer Chasing)**，由于链表指向在堆内存中呈现高度的空间离散分布，预取机制失效，导致命中率垮塌。 |
| matmul_4x4             | 0.1%      | **10.8%** | 通过从直接映射跃升到 2-Way 组相联，极大削减了 `A[i]` 与 `B[i]` 的 Index 冲突缺失。 |

**数据推论总结：**
1. **指令局部性天然碾压数据局部性**：所有程序在核心循环体的 I-Cache 命中率极速跃入 99%+（指令流天生是连续分布的）。这就是为什么现代的高端芯片更愿意维持小尺寸但高速的 L1I-Cache，而腾出硅片面积给大容量的 L1D 以及极为庞杂的分支预测器（BPU）。
2. **块级预取（Block Prefetch）的立杆见影**：Line Size 从 1 word 升维到 4 words 后，诸如 `memcpy` 这样简单的线性数组遍历，只要触发 1 次 Miss，就会将后续的 3 个数据顺带“绑架”进缓存（预取效应），实现 75% 的地板命中率。

这套高速 2路组相联 L1 存储器系统的竣工，为随后的 OoO 乱序引擎提供了一个延迟稳定、带宽充足的弹药库。在下一篇，我们将直击乱序芯片上的混沌艺术边界。

---
*项目地址：[github.com/HaibinLai/simple-CPU](https://github.com/HaibinLai/simple-CPU)*
