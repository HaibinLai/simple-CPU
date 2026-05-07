# OoO Implementation Plan

把当前 in-order 双发射核扩展为真正乱序发射 (out-of-order issue) 处理器。

## 当前架构 vs OoO 缺口

| 部件 | 现状 | OoO 需要 |
|---|---|---|
| Rename | ✅ 完整（48 PRF, map+freelist+busy） | ✅ 已可用 |
| ROB | ✅ 16 项, in-order commit, 双口 | ✅ 已可用 |
| PRF | ✅ 4R4W（slot0/1 wb + 2 commit 写口） | ✅ 4R4W 够 2-issue OoO |
| **Issue Queue (IQ)** | ❌ 没有 | **核心新增** |
| **Wakeup/Select 逻辑** | ❌ 没有 | **核心新增** |
| ALU/LSU 数量 | 2 ALU + 1 LSU(slot0) + 1 LSU(slot1 R-only) | 保留即可 |
| Forwarding | 按 arch reg id 比较 | 改为按 **dest ptag** |
| 分支恢复 | flush 整个 ROB + walk-back | 同上（先 walk-back，后 checkpoint） |
| Store buffer | ❌ 直接写 D$ | **必须**（speculative store 不能直入 cache） |
| Memory disambiguation | 保守阻塞 slot1 LOAD | 改为地址比较 |

## 顶层架构（目标）

```
IF → IFQ → ID/Rename(in-order) → IQ
                                  │
                                  ▼  乱序 select (≤2/cycle, oldest-ready-first)
                                  │
                              [PRF read]
                                  │
                                  ▼
                              EX / MEM
                                  │
                                  ▼
                                 WB → PRF + wakeup tag bus → ROB
                                                            │
                                                            ▼
                                                    in-order commit → arch state
```

## 阶段实施顺序（每阶段必须保持 1500 random + 9 benchmark PASS）

### Stage 1 — PRF 接进数据通路 ✅
**目标**：让 EX 阶段的 ALU 输入直接来自 `PRF[rs_ptag]`，而不是 ID2 寄存器堆读出后缓存到 `id_ex_rs*`。

**改动**：
- `prf.v`：加 4 写口 → 4 读口的写端口旁路（同 cycle 写值可见，与 `regfile.v` 对齐）。
- `cpu_top.v`：
  - slot0 EX1 ALU 操作数底（forwarding 失败时）从 `id_ex_rs1/2` 改为 `prf_r0/1`。
  - slot1 EX1 同样改 `prf_r2/3`。
  - 保留 `regfile`（仍是 ID2 读，仍写）做并行参考；不删除。
- 不动 forwarding 逻辑（仍按 arch reg id 比较），因为 forwarding 命中的源都是流水线寄存器值（PC-stage 索引），ptag 化等到 Stage 3。

**验证**：1500 random + 9 benchmark；TB 中 `c_prf_chk*` / `c_prf_mis*` 必须保持 0 mismatch。

---

### Stage 2 — 取消 regfile，唯一存储 = PRF ✅
**目标**：架构寄存器和重命名寄存器统一在 PRF 里（`ptag 0..31` = 架构槽，`32..47` = 重命名槽，commit 时 `we2/3` 把架构值写回 0..31，已实现）。

**改动**：
- `cpu_top.v`：
  - 删除 `regfile u_rf` 实例。
  - ID2 阶段不再读 regfile；`id_*_rs*_data` 改为 0（不再被消费）。
  - 把 PRF 增加 ID2 阶段的 4 读口（用于第一次读 ptag → value，避免 EX1 阶段才读引入额外的 forwarding 路径）。或者保留 EX1 读，删除 ID2 读相关 wire。**实际上 Stage 1 之后已经在 EX1 读 PRF；ID2 读可以直接删**。
- `tb_cpu.v`：`u_dut.u_rf.regs[i]` 比较改为 `u_dut.u_prf.regs[i]`（PRF arch 槽）。
- 终态校验：commit 完成后 `prf.regs[0..31]` 必须等于 ISS 架构状态。

**风险**：触及大量观测代码；要确保 commit-time PRF write 顺序与架构提交一致。

---

### Stage 3 — Forwarding 改 ptag-based
**目标**：每个 in-flight EX/MEM/WB 流水线寄存器都带 `dest_ptag`；forwarding 比较改为 `consumer_rs_ptag == producer_rd_ptag`。

**改动**：
- `forwarding.v`：输入从 `id_ex_rs1/rs2` (5-bit arch) 换成 `id_ex_rs1_ptag/rs2_ptag` (6-bit ptag)；各级 `*_rd` 换成 `*_rd_ptag`。
- `cpu_top.v`：所有 forwarding 比较替换。
- slot1 forwarding 网络同步替换。

**意义**：rename 后 arch reg 可能对应多个物理寄存器，arch-id 比较有歧义；ptag 比较是 OoO 的正确性基础。

**验证**：随机 + benchmark 全 PASS。

---

### Stage 4 — Issue Queue（in-order dispatch + ready-issue，**先不开 OoO**）
**目标**：在 rename 之后插入 IQ；instr 进 IQ 后只有 rs1/rs2 都 ready 才能出队进 EX。即使 IQ 是 FIFO 风格 in-order issue，引入它也意味着：
- RAW slot0→slot1 不再阻塞前端
- IQ 已经具备容纳 OoO 调度的容量

**模块**：`rtl/core/iq.v`，16 项，每项：
```
{ valid, op, alu_op, br_type, mem_rw, fu_type,
  rs1_ptag, rs1_ready,
  rs2_ptag, rs2_ready,
  rd_ptag, rob_tag,
  pc, imm, ... }
```

**接口**：
- `dispatch_v0/v1`、`dispatch_*`：rename 阶段 2-wide insert
- wakeup bus：`wakeup_v_n / wakeup_ptag_n`（多端口，对应所有 in-flight WB 端口）
- `issue_v0/v1`、`issue_*`：每周期最多 2 条出队
- `flush`：分支错预测 / 异常时清空（先粗暴地全清）

**dispatch 时初始 ready 判断**：`ready = !busy_vec[ptag]`（rename 模块已暴露 busy_vec）。

**验证**：先做 in-order issue（IQ 头部判 ready），跑通 1500 random。

---

### Stage 5 — 打开 OoO Select
**目标**：select 改为 oldest-ready-first（不限制 head）。每周期扫描 IQ，挑出最老的 ≤2 条 ready 项发射。

**改动**：
- `iq.v`：select 逻辑用优先编码器或 age matrix。简单做法：每项有一个 age counter（dispatch 时记当前 dispatch 序号），select 选最小 age 的 2 个 ready 项。
- 注意 FU 约束：当前只有 1 个 LSU（slot0 数据通路），所以 select 出的 2 条不能都是 mem-op；`branch / jump` 也只能走 slot0 数据通路。后续可加专用 FU 队列。

**预期收益**：随机 RAW% 20% → 大幅下降，CPI 1.34 → ~1.10–1.15。

---

### Stage 6 — Store Buffer + commit-time D$ write
**目标**：speculative store 不进 D$，commit 时才 retire 到 D$。

**模块**：`rtl/core/sb.v`，8~16 项 FIFO。每项 `{addr, data, be, valid, ready_to_retire}`。

**改动**：
- store 在 EX/AGU 完成地址 + 数据计算后写入 SB（标记非 speculative-pending）。
- ROB commit 触发 SB 头部 retire（写 D$ port A）。
- LOAD 必须先查 SB（store-to-load forwarding，全部 entry 地址比较，命中则直接旁路 SB.data）。
- D$ port A 现有路径改为：commit 端驱动 / EX 端只 LOAD；slot1 LOAD 仍走 port B。

**意义**：当前 R4 的 "slot1 LOAD 与在飞 store 阻塞" 已不需要保守阻塞——SB-bypass 是正确性保证。

---

### Stage 7 — 分支恢复（walk-back）
**目标**：分支错预测时，把 ROB 中 mispredict tag 之后的项倒回 rename map，恢复 free list。

**改动**：
- `rob.v`：暴露 `walk_back_*` 端口，逐个 pop 错误路径项，把 `ptag_old` 还回 map / `ptag_new` 还回 free list。
- 错预测时多花若干 cycle 做 walk（最坏 16 cycle），但比 checkpoint 简单。
- IQ 整个 flush（错路径项已无意义；正确路径项也需 squash 因为 dispatch 顺序与 ROB 不同？——其实 IQ 项也有 rob_tag，可以按 rob_tag 部分 flush。先简单全 flush）。

---

### Stage 8 — Load-Store Disambiguation
**目标**：去掉 SB 全比较的延迟，引入轻量 disambiguation predictor 或允许 load 推测穿越未知 older store，commit 时检查别名。

（Stage 8+ 是性能优化，先做正确性 1–7。）

---

### Stage 9 — Map Checkpoint（性能向）
**目标**：每条分支 dispatch 时 snapshot rename map + free list 头部；mispredict 直接恢复，省掉 walk-back 的 N 个 cycle。

支持的分支数 = checkpoint 个数（4 个就够大多数情况）。

---

### Stage 10 — 高级 BPU + RAS（可选）
- GShare / TAGE-lite 替换当前 BPU
- JALR 用 Return-Address Stack
- 当前随机 branch_miss=34%，目标 <15%

## 性能预估

| 阶段 | 随机 CPI | 备注 |
|---|---|---|
| 当前 | 1.339 | in-order 双发射 |
| Stage 1–3 完成 | 1.339 | 无性能变化（基础设施迁移） |
| Stage 4 (in-order IQ) | ~1.30 | RAW 阻塞略缓解 |
| Stage 5 (OoO select) | ~1.10–1.15 | 真正受益 |
| Stage 6 (SB) | ~1.08 | slot1 LOAD 解锁 store-heavy 情形 |
| Stage 7 (walk-back) | 同上 | 正确性 |
| Stage 9–10 | ~1.00–1.05 | 优化分支 + 减少 walk-back |

## 工作分支

- `feature/ooo`：所有 OoO 改造
- 每 Stage 一个 PR / 子提交，分别跑回归
- main 维持当前 in-order 状态作为基线

## Stage 1 详细任务清单

- [x] 创建 `feature/ooo` 分支
- [x] `prf.v` 加写端口旁路（同 cycle 写值在读口可见）— we0/we2/we3 旁路；we1 不旁路（避免 slot1 EX1→forwarding→PRF 组合环）
- [x] `cpu_top.v` slot0 EX1 ALU 操作数底从 `id_ex_rs1/rs2` 切到 `prf_r0/prf_r1`
- [x] slot1 EX1 ALU 操作数底从 `id1_ex_rs1/rs2` 切到 `prf_r2/prf_r3`
- [x] 保留 regfile 不动（用于并行参考 + tb 终态比较）
- [x] 跑 `make` + 500 random + 9 benchmark — 全 PASS
- [x] commit

**关键决策**：Stage 1 让 PRF[0..31] 镜像 regfile：
- `prf_we0/we1` 写到 arch idx (`{1'b0, rd}`)，不写 spec ptag
- `prf_we2/we3` (commit) 暂停（与 we0/we1 重复）
- `prf_ra*` 用 arch rs idx 直读
- map[]/spec ptag/rename 输出仍保持观测，不进数据通路
- 这避免了 spec ptag + commit 时序竞争，也是后续 Stage 2/3 的安全起点
