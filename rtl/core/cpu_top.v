// =============================================================
// cpu_top.v — 8 级流水线 CPU 顶层（在 7 级基础上拆 EX）
//
// 结构：
//   IF  : PC + IMEM 取指
//   ID1 : 指令缓冲/对齐（IF 后一级）
//   ID2 : 译码 + 读寄存器 + 立即数生成 + 冲突检测
//   EX1 : ALU 计算 + 前递 + 分支/跳转解析
//   EX2 : EX 结果缓冲（与 AGU 解耦）
//   AGU : 地址生成/访存参数整理
//   MEM : 数据存储器访问
//   WB  : 写回寄存器堆
//
// 本阶段策略：
//   - 结构改为 IF/ID1/ID2/EX1/EX2/AGU/MEM/WB
//   - 前递源：EX/AGU、AGU/MEM（仅 ALU 结果）与 MEM/WB
//   - Load-use 冒险：ID/EX1 基础检测 + MEM->EX 前递下的轻量化 stall
//   - 分支/跳转仍在 EX 解析，taken/mret/exception 时刷新 IF/ID1 与 ID1/ID2
// =============================================================
`include "defines.v"

module cpu_top (
    input  wire clk,
    input  wire rst_n,

    // 调试观察口（可选）
    output wire [31:0] dbg_pc,
    output wire [31:0] dbg_instr_wb,
    output wire        dbg_wb_we,
    output wire [4:0]  dbg_wb_rd,
    output wire [31:0] dbg_wb_data
);

    // ===== \u6240\u6709\u6d41\u6c34\u7ebf\u5bc4\u5b58\u5668\u524d\u7f6e\u58f0\u660e\uff08Icarus \u4e0d\u5141\u8bb8\u524d\u5411\u5f15\u7528 reg\uff09=====
    // EX1/EX2
    reg [31:0] ex_mem_pc;
    reg [31:0] ex_mem_instr;
    reg [31:0] ex_mem_alu_y;
    reg [31:0] ex_mem_rs2;
    reg [4:0]  ex_mem_rd;
    reg        ex_mem_mem_read, ex_mem_mem_write;
    reg [2:0]  ex_mem_mem_funct3;
    reg        ex_mem_reg_write;
    reg [1:0]  ex_mem_wb_sel;
    reg        ex_mem_valid;
    reg [3:0]  ex_mem_rob_tag;
    reg [5:0]  ex_mem_rd_ptag;

    // EX2/AGU
    reg [31:0] ex2_agu_pc;
    reg [31:0] ex2_agu_instr;
    reg [31:0] ex2_agu_alu_y;
    reg [31:0] ex2_agu_rs2;
    reg [4:0]  ex2_agu_rd;
    reg        ex2_agu_mem_read, ex2_agu_mem_write;
    reg [2:0]  ex2_agu_mem_funct3;
    reg        ex2_agu_reg_write;
    reg [1:0]  ex2_agu_wb_sel;
    reg        ex2_agu_valid;
    reg [3:0]  ex2_agu_rob_tag;
    reg [5:0]  ex2_agu_rd_ptag;

    // AGU/MEM
    reg [31:0] agu_mem_pc;
    reg [31:0] agu_mem_instr;
    reg [31:0] agu_mem_alu_y;
    reg [31:0] agu_mem_rs2;
    reg [4:0]  agu_mem_rd;
    reg        agu_mem_mem_read, agu_mem_mem_write;
    reg [2:0]  agu_mem_mem_funct3;
    reg        agu_mem_reg_write;
    reg [1:0]  agu_mem_wb_sel;
    reg        agu_mem_valid;
    reg [3:0]  agu_mem_rob_tag;
    reg [5:0]  agu_mem_rd_ptag;
    // MEM/WB
    reg [31:0] mem_wb_pc;
    reg [31:0] mem_wb_instr;
    reg [31:0] mem_wb_alu_y;
    reg [31:0] mem_wb_load;
    reg [4:0]  mem_wb_rd;
    reg        mem_wb_reg_write;
    reg [1:0]  mem_wb_wb_sel;
    reg        mem_wb_valid;
    reg [3:0]  mem_wb_rob_tag;
    reg [5:0]  mem_wb_rd_ptag;

    // MEM 阶段 load 扩展结果（用于 WB，也可用于 EX 前递）
    reg [31:0] mem_load_data;

    // 最小 CSR 集合（阶段 5）
    reg [31:0] csr_mtvec;
    reg [31:0] csr_mepc;
    reg [31:0] csr_mcause;
    localparam [31:0] RESET_MTVEC = 32'h00000080;

    // ---------------- IF ----------------
    reg  [31:0] pc;
    wire [31:0] pc_plus4 = pc + 32'd4;
    wire [31:0] pc_plus8 = pc + 32'd8;

    // 来自 EX 的重定向
    wire        ex_redirect;
    wire [31:0] ex_redirect_pc;

    // 来自 ID 的 stall（load-use）
    wire        stall;
    // IFQ backpressure stall（IFQ 即将满，无法接收 2 条新指令）
    wire        ifq_almost_full;
    wire        ifq_full;
    // OoO Stage1-bis: rename free-list stall (分 slot)
    // 跳过全部阻塑：仅 free=0 且 slot0 需分配时 stall slot0。
    //               free<2 且两者都需分配时 stall slot1 (slot0 仍 pop)。
    wire        rn_block_slot0;     // 在后面 forward decl
    wire        rn_block_slot1;
    // PC 冻结只需在 slot0 被阻时生效 (slot1 单独阻不影响 IFQ 消费 1 条)
    wire if_freeze = stall || ifq_almost_full || rn_block_slot0;

    wire [31:0] imem_rdata0, imem_rdata1;

    imem #(.HEX_FILE(`PROG_HEX)) u_imem (
        .clk   (clk),
        .rst_n (rst_n),
        .addr  (pc),
        .rdata (imem_rdata0),
        .addr1 (pc_plus4),
        .rdata1(imem_rdata1)
    );

    // 分支预测器
    localparam BPU_GHR_W = 32;
    wire        bpu_pred_taken;
    wire [31:0] bpu_pred_target;
    wire [BPU_GHR_W-1:0] bpu_pred_ghr;     // IF 时 GHR 快照
    wire        bpu_upd_valid;
    wire [31:0] bpu_upd_pc, bpu_upd_target;
    wire        bpu_upd_taken;
    wire        bpu_upd_is_uncond;
    wire [BPU_GHR_W-1:0] bpu_upd_pred_ghr;  // 训练时还原预测索引用的 GHR

    bpu u_bpu (
        .clk         (clk),
        .rst_n       (rst_n),
        .if_pc       (pc),
        .pred_taken  (bpu_pred_taken),
        .pred_target (bpu_pred_target),
        .pred_ghr_o  (bpu_pred_ghr),
        .upd_valid   (bpu_upd_valid),
        .upd_pc      (bpu_upd_pc),
        .upd_taken   (bpu_upd_taken),
        .upd_target  (bpu_upd_target),
        .upd_is_uncond(bpu_upd_is_uncond),
        .upd_pred_ghr(bpu_upd_pred_ghr)
    );

    // TAGE-2L 影子评估器（不参与 PC 选择，仅采集 mispred 对比统计）
    wire [31:0] tage_total, tage_t1_hit, tage_t2_hit, tage_t1_use, tage_t2_use;
    wire [31:0] tage_correct, gshare_correct;
    wire [31:0] tage_t1_alloc, tage_t2_alloc, tage_alloc_fail;
    bpu_tage_eval #(.GHR_W(BPU_GHR_W)) u_bpu_tage_eval (
        .clk            (clk),
        .rst_n          (rst_n),
        .upd_valid      (bpu_upd_valid),
        .upd_pc         (bpu_upd_pc),
        .upd_pred_ghr   (bpu_upd_pred_ghr),
        .upd_taken      (bpu_upd_taken),
        .upd_is_uncond  (bpu_upd_is_uncond),
        .tage_total     (tage_total),
        .tage_t1_hit    (tage_t1_hit),
        .tage_t2_hit    (tage_t2_hit),
        .tage_t1_use    (tage_t1_use),
        .tage_t2_use    (tage_t2_use),
        .tage_correct   (tage_correct),
        .gshare_correct (gshare_correct),
        .tage_t1_alloc  (tage_t1_alloc),
        .tage_t2_alloc  (tage_t2_alloc),
        .tage_alloc_fail(tage_alloc_fail)
    );

    // PC 选择：刷新 > stall/反压 > 预测 > slot1-JAL 静态跳转 > PC+8
    //
    // A2-step2 (v2 — proper fix): slot1 是 JAL 时，在 IF 阶段直接静态计算
    // 目标并 redirect PC，避免一律走 PC+8 取错路径再到 EX flush。
    // 同时把 (taken=1, target=jal_target) 注入 IFQ 的 slot1 push 端，
    // 这条 JAL 后续以 slot0 形式被消费时 EX 不会再判 mispredict。
    //   * 仅在 BPU 没在 slot0 预测 taken 时触发（否则 slot1 会被 if_id_valid1=0 丢掉）
    //   * 不需要任何预测器状态
    //   * 必须 PC redirect + IFQ 预测两件事一起做，缺一不可（否则就是被 revert
    //     的旧 A2-step2：wrong-path store 会进入并提交，由 tools/run_a2step2_robustness.py 拦住）
    wire        if_slot1_is_jal      = (imem_rdata1[6:0] == 7'b1101111);
    wire [31:0] if_slot1_jal_imm     = {{12{imem_rdata1[31]}},
                                        imem_rdata1[19:12],
                                        imem_rdata1[20],
                                        imem_rdata1[30:21], 1'b0};
    wire [31:0] if_slot1_jal_target  = pc_plus4 + if_slot1_jal_imm;

    // P1.6: slot0/slot1 是 JALR-ret 时用 RAS 顶预测目标，在 IF 直接 redirect。
    //   ret 识别同 ras_shadow.v 里的定义：JALR && rs1∈{x1,x5} && rd∉{x1,x5}
    //   ras_shadow 的栈在 EX 阶段 push/pop，同一个 top 会被 IF 读、后被
    //   EX 弹出；预测错了依靠 EX redirect 兼完成讯号的 flush。
    //   实际 bench (dotprod/matmul) 中 ret 几乎都出现在 slot1，所以两个 slot 都要接。
    wire [31:0] ras_top_for_pred;
    wire        ras_top_valid_for_pred;

    wire        if_slot0_is_jalr     = (imem_rdata0[6:0] == 7'b1100111);
    wire [4:0]  if_slot0_rs1         = imem_rdata0[19:15];
    wire [4:0]  if_slot0_rd          = imem_rdata0[11:7];
    wire        if_slot0_link_rs1    = (if_slot0_rs1 == 5'd1) || (if_slot0_rs1 == 5'd5);
    wire        if_slot0_link_rd     = (if_slot0_rd  == 5'd1) || (if_slot0_rd  == 5'd5);
    wire        if_slot0_is_ret      = if_slot0_is_jalr && if_slot0_link_rs1 && !if_slot0_link_rd;
    wire        if_take_slot0_ret    = if_slot0_is_ret && ras_top_valid_for_pred && !bpu_pred_taken;

    wire        if_slot1_is_jalr     = (imem_rdata1[6:0] == 7'b1100111);
    wire [4:0]  if_slot1_rs1         = imem_rdata1[19:15];
    wire [4:0]  if_slot1_rd          = imem_rdata1[11:7];
    wire        if_slot1_link_rs1    = (if_slot1_rs1 == 5'd1) || (if_slot1_rs1 == 5'd5);
    wire        if_slot1_link_rd     = (if_slot1_rd  == 5'd1) || (if_slot1_rd  == 5'd5);
    wire        if_slot1_is_ret      = if_slot1_is_jalr && if_slot1_link_rs1 && !if_slot1_link_rd;
    // 仅在 slot0 不跳、也不是 slot0-ret、也不是 slot1-JAL 时才手点 slot1-ret
    wire        if_take_slot1_ret    = if_slot1_is_ret && !bpu_pred_taken && !if_take_slot0_ret
                                       && ras_top_valid_for_pred;

    // BPU-taken 优先 > slot0-ret > slot1-ret > slot1-JAL
    wire        if_pred_taken_eff   = bpu_pred_taken | if_take_slot0_ret;
    wire [31:0] if_pred_target_eff  = bpu_pred_taken    ? bpu_pred_target
                                                        : ras_top_for_pred;

    wire        if_take_slot1_jal    = if_slot1_is_jal && !bpu_pred_taken
                                       && !if_take_slot0_ret && !if_take_slot1_ret;

    // P1.6 \u8c03\u8bd5\u8ba1\u6570\uff1aIF \u9636\u6bb5\u89e6\u53d1\u7684 ret-redirect \u6b21\u6570
    reg [31:0] dbg_ret_pred_fire;
    reg [31:0] dbg_slot0_is_ret_seen;
    reg [31:0] dbg_ras_top_valid_seen;
    reg [31:0] dbg_bpu_pred_taken_on_ret;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dbg_ret_pred_fire        <= 32'b0;
            dbg_slot0_is_ret_seen    <= 32'b0;
            dbg_ras_top_valid_seen   <= 32'b0;
            dbg_bpu_pred_taken_on_ret<= 32'b0;
        end else begin
            if (if_take_slot0_ret) dbg_ret_pred_fire     <= dbg_ret_pred_fire     + 32'd1;
            if (if_slot0_is_ret)   dbg_slot0_is_ret_seen <= dbg_slot0_is_ret_seen + 32'd1;
            if (if_slot0_is_ret && ras_top_valid_for_pred)
                dbg_ras_top_valid_seen <= dbg_ras_top_valid_seen + 32'd1;
            if (if_slot0_is_ret && bpu_pred_taken)
                dbg_bpu_pred_taken_on_ret <= dbg_bpu_pred_taken_on_ret + 32'd1;
        end
    end

    // BPU 仅在 slot0 处预测；若预测 taken，则 slot1 被丢弃，PC 跳转到目标
    wire [31:0] pc_next_seq = if_pred_taken_eff ? if_pred_target_eff :
                              if_take_slot1_ret ? ras_top_for_pred  :
                              if_take_slot1_jal ? if_slot1_jal_target :
                                                  pc_plus8;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)            pc <= `RESET_PC;
        else if (ex_redirect)  pc <= ex_redirect_pc;
        else if (if_freeze)    pc <= pc;          // 冻结 PC
        else                   pc <= pc_next_seq;
    end

    // IF/ID1 流水线寄存器（Milestone 1: dual-slot front-end bundle）
    reg [31:0] if_id_pc0;
    reg [31:0] if_id_instr0;
    reg        if_id_valid0;
    reg [31:0] if_id_pc1;
    reg [31:0] if_id_instr1;
    reg        if_id_valid1;
    reg        if_id_pred_taken;
    reg [31:0] if_id_pred_target;
    reg [BPU_GHR_W-1:0] if_id_pred_ghr;
    // A2-step2 (v2): slot1 静态 JAL 预测随 if_id 流水线走
    reg        if_id_pred_taken1;
    reg [31:0] if_id_pred_target1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            if_id_pc0         <= 32'b0;
            if_id_instr0      <= 32'h00000013; // NOP
            if_id_valid0      <= 1'b0;
            if_id_pc1         <= 32'b0;
            if_id_instr1      <= 32'h00000013;
            if_id_valid1      <= 1'b0;
            if_id_pred_taken  <= 1'b0;
            if_id_pred_target <= 32'b0;
            if_id_pred_ghr    <= {BPU_GHR_W{1'b0}};
            if_id_pred_taken1 <= 1'b0;
            if_id_pred_target1<= 32'b0;
        end else if (ex_redirect) begin
            // 刷新 IF/ID1（注入气泡）
            if_id_pc0         <= 32'b0;
            if_id_instr0      <= 32'h00000013;
            if_id_valid0      <= 1'b0;
            if_id_pc1         <= 32'b0;
            if_id_instr1      <= 32'h00000013;
            if_id_valid1      <= 1'b0;
            if_id_pred_taken  <= 1'b0;
            if_id_pred_target <= 32'b0;
            if_id_pred_ghr    <= {BPU_GHR_W{1'b0}};
            if_id_pred_taken1 <= 1'b0;
            if_id_pred_target1<= 32'b0;
        end else if (if_freeze) begin
            // 冻结 IF/ID1：保持当前值（load-use stall 或 IFQ 反压）
            if_id_pc0         <= if_id_pc0;
            if_id_instr0      <= if_id_instr0;
            if_id_valid0      <= if_id_valid0;
            if_id_pc1         <= if_id_pc1;
            if_id_instr1      <= if_id_instr1;
            if_id_valid1      <= if_id_valid1;
            if_id_pred_taken  <= if_id_pred_taken;
            if_id_pred_target <= if_id_pred_target;
            if_id_pred_ghr    <= if_id_pred_ghr;
            if_id_pred_taken1 <= if_id_pred_taken1;
            if_id_pred_target1<= if_id_pred_target1;
        end else begin
            if_id_pc0         <= pc;
            if_id_instr0      <= imem_rdata0;
            if_id_valid0      <= 1'b1;
            if_id_pc1         <= pc_plus4;
            if_id_instr1      <= imem_rdata1;
            // slot1 失效条件：BPU 在 slot0 预测 taken，或 slot0 是 ret 被 IF redirect
            if_id_valid1      <= ~if_pred_taken_eff;
            if_id_pred_taken  <= if_pred_taken_eff;
            if_id_pred_target <= if_pred_target_eff;
            if_id_pred_ghr    <= bpu_pred_ghr;
            // 静态 slot1-JAL / slot1-ret 预测（与上面 pc_next_seq 同步）
            if_id_pred_taken1 <= if_take_slot1_jal | if_take_slot1_ret;
            if_id_pred_target1<= if_take_slot1_ret ? ras_top_for_pred
                                                   : if_slot1_jal_target;
        end
    end

    // ---------------- IFQ (Issue Fetch Queue) ----------------
    // 替代原 ID1/ID2 流水线寄存器；解耦取指带宽与发射带宽
    // R1: 单发射 pop（pop=1，pop2=0）
    // R2 (future): 双发射 pop（启用 pop2）
    wire        id1_id2_valid0;
    wire [31:0] id1_id2_pc0;
    wire [31:0] id1_id2_instr0;
    wire        id1_id2_pred_taken;
    wire [31:0] id1_id2_pred_target;
    wire [BPU_GHR_W-1:0] id1_id2_pred_ghr;

    wire        id1_id2_valid1;
    wire [31:0] id1_id2_pc1;
    wire [31:0] id1_id2_instr1;
    // slot1 prediction signals are not used by ID2 (slot1 cannot be a branch in M1.5 rules)
    wire        id1_id2_pred_taken1_unused;
    wire [31:0] id1_id2_pred_target1_unused;
    wire [BPU_GHR_W-1:0] id1_id2_pred_ghr1_unused;

    // pop 控制：当 backend 接受 slot0 时（无 stall、无 redirect、有效），消费一条
    // OoO Stage1-bis step3: 加入 rn_block_slot0/slot1 闸门。注意 rn_block_*
    // 由 cpu_top 在 "would-be alloc" + rn_free_count 上计算，所以 ifq_pop_*
    // 不会反馈进 rename，避免组合环。
    wire slot0_can_consider = id1_id2_valid0 && !stall && !ex_redirect;
    wire slot0_is_alu;
    wire slot0_pop_would;
    wire slot1_pop_would;
    wire slot0_pop_allow;
    wire slot1_pop_allow;
    // R2: 双发射 — 仅当 slot0 pop 且 slot1 满足配对条件时才 pop slot1
    wire id2_issue_slot1;
    wire rs_sh_issue_peek_v;
    wire rs_issue_allow;       // T2b-step3a-v1: A-path (RS->id_ex / slot0 EX1)
    wire rs_issue_via_b;       // T2b-step3a-v1: B-path (RS->id1_ex / slot1 EX1b)
    wire rs_issue_grant = rs_issue_allow || rs_issue_via_b;
    wire ifq_pop_slot0 = slot0_pop_allow;
    wire ifq_pop_slot1 = slot1_pop_allow;

    wire [3:0]  ifq_count;

    ifq #(.DEPTH(8), .AW(3), .PRED_GHR_W(BPU_GHR_W)) u_ifq (
        .clk    (clk),
        .rst_n  (rst_n),
        .flush  (ex_redirect),
        // Push side: 来自 IF/ID1
        .push_valid_0       (if_id_valid0 && !if_freeze),
        .push_pc_0          (if_id_pc0),
        .push_instr_0       (if_id_instr0),
        .push_pred_taken_0  (if_id_pred_taken),
        .push_pred_target_0 (if_id_pred_target),
        .push_pred_ghr_0    (if_id_pred_ghr),
        .push_valid_1       (if_id_valid1 && !if_freeze),
        .push_pc_1          (if_id_pc1),
        .push_instr_1       (if_id_instr1),
        // A2-step2 (v2): 静态 slot1 JAL 预测（来自 IF 阶段的解码 + PC redirect）
        .push_pred_taken_1  (if_id_pred_taken1),
        .push_pred_target_1 (if_id_pred_target1),
        .push_pred_ghr_1    ({BPU_GHR_W{1'b0}}),
        .full               (ifq_full),
        .almost_full        (ifq_almost_full),
        // Pop side -> ID2 decode
        .pop                (ifq_pop_slot0),
        .head_valid         (id1_id2_valid0),
        .head_pc            (id1_id2_pc0),
        .head_instr         (id1_id2_instr0),
        .head_pred_taken    (id1_id2_pred_taken),
        .head_pred_target   (id1_id2_pred_target),
        .head_pred_ghr      (id1_id2_pred_ghr),
        // 第二头（R2 双发射用）
        .head2_valid        (id1_id2_valid1),
        .head2_pc           (id1_id2_pc1),
        .head2_instr        (id1_id2_instr1),
        .head2_pred_taken   (id1_id2_pred_taken1_unused),
        .head2_pred_target  (id1_id2_pred_target1_unused),
        .head2_pred_ghr     (id1_id2_pred_ghr1_unused),
        .pop2               (ifq_pop_slot1),
        .count              (ifq_count)
    );

    // ---------------- ID2 ----------------
    // Milestone 1 keeps the backend single-issue; slot0 remains the only consumer.
    wire [31:0] id_instr = id1_id2_instr0;
    wire [6:0]  id_opcode= id_instr[6:0];
    wire [4:0]  id_rs1   = id_instr[19:15];
    wire [4:0]  id_rs2   = id_instr[24:20];
    wire [4:0]  id_rd    = id_instr[11:7];

    // 仅在指令真实读取源寄存器时参与 load-use 相关判断，减少无效 stall。
    wire id_use_rs1 = (id_opcode == `OP_REG)    ||
                      (id_opcode == `OP_IMM)    ||
                      (id_opcode == `OP_LOAD)   ||
                      (id_opcode == `OP_STORE)  ||
                      (id_opcode == `OP_BRANCH) ||
                      (id_opcode == `OP_JALR);
    wire id_use_rs2 = (id_opcode == `OP_REG)    ||
                      (id_opcode == `OP_STORE)  ||
                      (id_opcode == `OP_BRANCH);

    // 控制信号
    wire [2:0] id_imm_type;
    wire       id_a_src, id_b_src;
    wire [3:0] id_alu_op;
    wire [2:0] id_br_type;
    wire       id_is_jump;
    wire       id_mem_read, id_mem_write;
    wire [2:0] id_mem_funct3;
    wire       id_reg_write;
    wire [1:0] id_wb_sel;
    wire       id_is_ecall, id_is_mret, id_is_illegal;

    control u_ctrl (
        .instr      (id_instr),
        .imm_type   (id_imm_type),
        .a_src      (id_a_src),
        .b_src      (id_b_src),
        .alu_op     (id_alu_op),
        .br_type    (id_br_type),
        .is_jump    (id_is_jump),
        .mem_read   (id_mem_read),
        .mem_write  (id_mem_write),
        .mem_funct3 (id_mem_funct3),
        .reg_write  (id_reg_write),
        .wb_sel     (id_wb_sel),
        .is_ecall   (id_is_ecall),
        .is_mret    (id_is_mret),
        .is_illegal (id_is_illegal)
    );

    wire [31:0] id_imm;
    imm_gen u_imm (
        .instr    (id_instr),
        .imm_type (id_imm_type),
        .imm      (id_imm)
    );

    // ===== Milestone 1.5: ID2 Slot1 Decode Pairing Logic =====
    // Slot1 decode：独立检查slot1指令的可行性
    wire [31:0] id1_instr = id1_id2_instr1;
    wire [6:0]  id1_opcode= id1_instr[6:0];
    wire [4:0]  id1_rs1   = id1_instr[19:15];
    wire [4:0]  id1_rs2   = id1_instr[24:20];
    wire [4:0]  id1_rd    = id1_instr[11:7];

    // Slot1 ALU-only 约束：允许 OP_REG / OP_IMM / OP_LUI / OP_AUIPC
    // （LUI/AUIPC 是单加法 / bypass，不访存，不重定向）
    wire id1_is_alu_only = (id1_opcode == `OP_REG)  || (id1_opcode == `OP_IMM) ||
                           (id1_opcode == `OP_LUI)  || (id1_opcode == `OP_AUIPC);
    // R3 扩展：条件分支（在 EX1 解析，隐式预测 not-taken）也可进入 slot1。
    wire id1_is_branch_op = (id1_opcode == `OP_BRANCH);
    // R4 扩展：load 也可进入 slot1（D$ 加只读端口 B；slot1 LOAD 1 周期完成）。
    wire id1_is_load_op   = (id1_opcode == `OP_LOAD);
    wire id1_is_pairable  = id1_is_alu_only || id1_is_branch_op || id1_is_load_op;

    // Slot1 control 解码（仅供约束检查；暂不用于执行）
    wire [2:0] id1_imm_type;
    wire       id1_a_src, id1_b_src;
    wire [3:0] id1_alu_op;
    wire [2:0] id1_br_type;
    wire       id1_is_jump;
    wire       id1_mem_read, id1_mem_write;
    wire [2:0] id1_mem_funct3;
    wire       id1_reg_write;
    wire [1:0] id1_wb_sel;
    wire       id1_is_ecall, id1_is_mret, id1_is_illegal;

    control u_ctrl_slot1 (
        .instr      (id1_instr),
        .imm_type   (id1_imm_type),
        .a_src      (id1_a_src),
        .b_src      (id1_b_src),
        .alu_op     (id1_alu_op),
        .br_type    (id1_br_type),
        .is_jump    (id1_is_jump),
        .mem_read   (id1_mem_read),
        .mem_write  (id1_mem_write),
        .mem_funct3 (id1_mem_funct3),
        .reg_write  (id1_reg_write),
        .wb_sel     (id1_wb_sel),
        .is_ecall   (id1_is_ecall),
        .is_mret    (id1_is_mret),
        .is_illegal (id1_is_illegal)
    );

    // Slot1 配对约束（仅依赖 ID 阶段信号；in-flight load 检查在 id_ex 声明后做）：
    // 1. Slot1 有效 && 是 可配对 指令 (ALU-only 或 条件分支)
    // 2. 没有 same-cycle RAW：slot1 rs1/rs2 不与 slot0 rd 重叠（仅在 slot0 有写回时检查）
    wire slot1_rs1_used = (id1_opcode == `OP_REG) || (id1_opcode == `OP_IMM) ||
                          (id1_opcode == `OP_BRANCH) || (id1_opcode == `OP_LOAD);
    wire slot1_rs2_used = (id1_opcode == `OP_REG) || (id1_opcode == `OP_BRANCH);
    // LUI/AUIPC 不读寄存器，不参与 RAW/load-use 检查
    // OP_LOAD 仅读 rs1（基址），不读 rs2

    wire id1_no_raw_hazard = ~(
        (id_reg_write && (id_rd != 5'd0)) && (
            (slot1_rs1_used && (id1_rs1 == id_rd) && (id1_rs1 != 5'd0)) ||
            (slot1_rs2_used && (id1_rs2 == id_rd) && (id1_rs2 != 5'd0))
        )
    );

    // R2 BUG#1 修复：避免 output dependency（WAW）。
    // 若 slot0.rd == slot1.rd，slot0 在 5 周期后 WB 会覆盖 slot1 早写回的正确值。
    wire id1_no_waw_hazard = ~(
        (id_reg_write && id1_reg_write) &&
        (id_rd == id1_rd) && (id_rd != 5'd0)
    );

    // R2 BUG#2: in-flight load → slot1 RAW（在 id_ex 声明之后定义）
    wire id1_no_load_use_hazard;
    // R2 BUG#5: cross-cycle WAW（在 id_ex/ex_mem/... 声明之后定义）
    wire id1_no_xcycle_waw;
    // R4: slot1 LOAD 与在飞 slot0 STORE 的潜在地址别名（保守阻塞）
    wire id1_no_store_alias_hazard;

    // R3 放宽：允许 slot0 为 branch / JAL / JALR / ecall / mret / illegal。
    // 详细推导：
    //   * BPU 预测 taken 时，if_id_valid1 = ~bpu_pred_taken 会丢掉 slot1，
    //     所以 slot1 只可能与「预测不跳」的 slot0 配对；
    //   * 若 slot0 预测错误 / JAL/JALR BTB miss / 异常 / mret → ex_redirect，
    //     此时同 cycle gate slot1_wb_we / prf_we1 / rob_wb_v1 以丢掉错误路径 slot1。
    //   * Same-cycle WAW 仍由 id1_no_waw_hazard 拦截（e.g. JAL.rd == slot1.rd）。
    //   * Cross-cycle WAW 仍由 id1_no_xcycle_waw 拦截。
    //   * Store 依然允许（原本已放宽）。
    wire id_slot0_safe_for_pair = 1'b1;

    // Slot1 issue 条件
    assign id2_issue_slot1 = id1_id2_valid1 && id1_is_pairable &&
                             id_slot0_safe_for_pair &&
                             id1_no_raw_hazard && id1_no_waw_hazard &&
                             id1_no_load_use_hazard && id1_no_xcycle_waw &&
                             id1_no_store_alias_hazard;
    wire id2_issue_slot0 = id1_id2_valid0;

    // 寄存器堆写回信号（PRF 是唯一存储；Stage 2 已删除架构 regfile）
    wire        wb_we;
    wire [4:0]  wb_rd;
    wire [31:0] wb_data;

    // M3.2: ROB alloc tag forward decl（实例化在文件末尾）
    wire [3:0]  rob_alloc_tag_0;
    wire [3:0]  rob_alloc_tag_1;
    wire [3:0]  rob_head_tag;
    // M3.4a/b: rename ptag forward decl（实例化在文件末尾）
    wire [5:0]  rn_s0_rs1_ptag, rn_s0_rs2_ptag;
    wire [5:0]  rn_s1_rs1_ptag, rn_s1_rs2_ptag;
    wire [5:0]  rn_s0_rd_ptag_new;
    wire [5:0]  rn_s1_rd_ptag_new;
    // M3.4c: rs ptag pipeline regs forward-decl
    // (实际声明在流水线寄存器部分，这里提前使 PRF 能引用)
    // 注意：Icarus 在同一 module 内允许 "declare-after-use"仅限 net；reg 需要提前声明。
    
    // Slot1 write ports (Milestone 2, not yet enabled)
    wire        slot1_wb_we;
    wire [4:0]  slot1_wb_rd;
    wire [31:0] slot1_wb_data;
    // M3.4b PRF dual-write source
    wire        prf_we0, prf_we1;
    wire [5:0]  prf_wa0, prf_wa1;
    wire [31:0] prf_wd0, prf_wd1;
    // M3.4d: commit-time arch writes
    wire        prf_we2, prf_we3;
    wire [5:0]  prf_wa2, prf_wa3;
    wire [31:0] prf_wd2, prf_wd3;
    // M3.4d forward-decl: ROB commit results consumed by PRF[arch] writes
    // (真正实例化在文件末尾 u_rob)
    wire [31:0] rob_commit_res_0, rob_commit_res_1;
    wire        rob_commit_valid_0, rob_commit_valid_1;
    wire [4:0]  rob_commit_rd_0,    rob_commit_rd_1;
    wire        rob_commit_rw_0,    rob_commit_rw_1;
    wire [5:0]  rob_commit_ptag_new_0, rob_commit_ptag_old_0;
    wire [5:0]  rob_commit_ptag_new_1, rob_commit_ptag_old_1;
    wire [31:0] prf_r0, prf_r1, prf_r2, prf_r3;
    // M3.4c PRF read addresses (sourced from EX-stage rs ptag pipeline regs)
    wire [5:0]  prf_ra0, prf_ra1, prf_ra2, prf_ra3;
    // T2b-step1: extra PRF read ports for shadow-RS dispatch operand capture
    wire [5:0]  prf_ra4, prf_ra5;
    wire [31:0] prf_r4,  prf_r5;
    
    // OoO Stage 2: 删除架构 regfile —— PRF 成为唯一寄存器存储。
    // ID2 阶段不再读寄存器；EX1 通过 prf_r0..3 (arch idx 索引) 拿到操作数。
    // 旧的 id_*_data wire 与 id_ex_rs* (32-bit data) 流水线寄存器已一并删除。

    // 物理寄存器文件（48 项，前 32 槽 = 架构寄存器；we0/we1 写 arch idx）
    prf #(.DEPTH(64), .AW(6)) u_prf (
        .clk      (clk),
        .rst_n    (rst_n),
        .we0      (prf_we0),
        .wa0      (prf_wa0),
        .wd0      (prf_wd0),
        .we1      (prf_we1),
        .wa1      (prf_wa1),
        .wd1      (prf_wd1),
        .we2      (prf_we2),
        .wa2      (prf_wa2),
        .wd2      (prf_wd2),
        .we3      (prf_we3),
        .wa3      (prf_wa3),
        .wd3      (prf_wd3),
        .ra0      (prf_ra0),
        .ra1      (prf_ra1),
        .ra2      (prf_ra2),
        .ra3      (prf_ra3),
        .ra4      (prf_ra4),
        .ra5      (prf_ra5),
        .rd0      (prf_r0),
        .rd1      (prf_r1),
        .rd2      (prf_r2),
        .rd3      (prf_r3),
        .rd4      (prf_r4),
        .rd5      (prf_r5)
    );

    // ===== Milestone 2: Slot1 ID/EX Pipeline Registers (Phase 2B) =====

    reg [31:0] id1_ex_pc;
    reg [31:0] id1_ex_instr;
    reg [31:0] id1_ex_imm;
    reg [4:0]  id1_ex_rs1_addr, id1_ex_rs2_addr;
    reg [4:0]  id1_ex_rd;
    reg [3:0]  id1_ex_alu_op;
    reg        id1_ex_a_src, id1_ex_b_src;
    reg        id1_ex_reg_write;
    reg [1:0]  id1_ex_wb_sel;
    reg        id1_ex_valid;
    reg [2:0]  id1_ex_imm_type;
    reg [2:0]  id1_ex_br_type;       // R3: 支持 slot1 = 条件分支
    reg        id1_ex_mem_read;      // R4: slot1 LOAD
    reg [2:0]  id1_ex_mem_funct3;    // R4: LB/LH/LW/LBU/LHU
    reg [3:0]  id1_ex_rob_tag;
    reg [5:0]  id1_ex_rd_ptag;
    reg [5:0]  id1_ex_rs1_ptag, id1_ex_rs2_ptag;
    // T2b-step3a-v1 (Option B): id1_ex can be filled by RS issue when slot1
    // EX1b pipe is otherwise idle. id1_ex_from_rs marks the entry; rs*_val
    // hold the captured/woken-up operand values.
    reg        id1_ex_from_rs;
    reg [31:0] id1_ex_rs1_val, id1_ex_rs2_val;

    // ID/EX 流水线寄存器
    reg [31:0] id_ex_pc;
    reg [31:0] id_ex_instr;
    reg [31:0] id_ex_imm;
    reg [4:0]  id_ex_rs1_addr, id_ex_rs2_addr;
    reg [4:0]  id_ex_rd;
    reg [3:0]  id_ex_alu_op;
    reg        id_ex_a_src, id_ex_b_src;
    reg [2:0]  id_ex_br_type;
    reg        id_ex_is_jump;
    reg        id_ex_mem_read, id_ex_mem_write;
    reg [2:0]  id_ex_mem_funct3;
    reg        id_ex_reg_write;
    reg [1:0]  id_ex_wb_sel;
    reg        id_ex_valid;
    reg        id_ex_is_ecall, id_ex_is_mret, id_ex_is_illegal;
    reg        id_ex_pred_taken;
    reg [31:0] id_ex_pred_target;
    reg [BPU_GHR_W-1:0] id_ex_pred_ghr;
    reg [3:0]  id_ex_rob_tag;
    reg [5:0]  id_ex_rd_ptag;
    reg [5:0]  id_ex_rs1_ptag, id_ex_rs2_ptag;
    reg        id_ex_from_rs;
    reg [31:0] id_ex_rs1_val, id_ex_rs2_val;

    // T2b-step2: rs_shadow issue/peek wires need to be in scope before the
    // ID/EX and EX1 logic that consumes them.
    wire        rs_sh_issue_v;
    wire [31:0] rs_sh_issue_rs1_val, rs_sh_issue_rs2_val;
    wire [3:0]  rs_sh_issue_alu_op;
    wire [5:0]  rs_sh_issue_rd_ptag;
    wire [3:0]  rs_sh_issue_rob_tag;
    wire [31:0] rs_sh_issue_pc;
    wire [31:0] rs_sh_issue_peek_rs1_val, rs_sh_issue_peek_rs2_val;
    wire [3:0]  rs_sh_issue_peek_alu_op;
    wire [31:0] rs_sh_issue_peek_imm;
    wire        rs_sh_issue_peek_a_src, rs_sh_issue_peek_b_src;
    wire [1:0]  rs_sh_issue_peek_wb_sel;
    wire        rs_sh_issue_peek_mem_read;
    wire [2:0]  rs_sh_issue_peek_mem_funct3;
    wire [4:0]  rs_sh_issue_peek_rd_arch;
    wire [31:0] rs_sh_issue_peek_instr;
    wire [5:0]  rs_sh_issue_peek_rd_ptag;
    wire [3:0]  rs_sh_issue_peek_rob_tag;
    wire [31:0] rs_sh_issue_peek_pc;

    // 冒险检测（load-use）
    hazard u_hazard (
        .id_ex_mem_read (id_ex_mem_read),
        .id_ex_rd       (id_ex_rd),
        // 8 级恢复保守窗口：避免 load 在更深级时被过早消费
        .ex_agu_mem_read(ex_mem_mem_read),
        .ex_agu_rd      (ex_mem_rd),
        .id_rs1         (id_rs1),
        .id_rs2         (id_rs2),
        .id_use_rs1     (id_use_rs1),
        .id_use_rs2     (id_use_rs2),
        .stall          (stall)
    );

    // R2 BUG#2 修复：slot1 不能依赖 in-flight load（slot1 没有 load forwarding 路径）。
    // 检查 slot1.rs1/rs2 vs 任意 in-flight load 的 rd
    assign id1_no_load_use_hazard = ~(
        (id_ex_mem_read && id_ex_valid && (id_ex_rd != 5'd0) && (
            (slot1_rs1_used && (id1_rs1 == id_ex_rd)) ||
            (slot1_rs2_used && (id1_rs2 == id_ex_rd))
        )) ||
        (ex_mem_mem_read && ex_mem_valid && (ex_mem_rd != 5'd0) && (
            (slot1_rs1_used && (id1_rs1 == ex_mem_rd)) ||
            (slot1_rs2_used && (id1_rs2 == ex_mem_rd))
        )) ||
        (ex2_agu_mem_read && ex2_agu_valid && (ex2_agu_rd != 5'd0) && (
            (slot1_rs1_used && (id1_rs1 == ex2_agu_rd)) ||
            (slot1_rs2_used && (id1_rs2 == ex2_agu_rd))
        )) ||
        (agu_mem_mem_read && agu_mem_valid && (agu_mem_rd != 5'd0) && (
            (slot1_rs1_used && (id1_rs1 == agu_mem_rd)) ||
            (slot1_rs2_used && (id1_rs2 == agu_mem_rd))
        ))
    );

    // R2 BUG#5 修复：cross-cycle WAW。slot1 在 EX1 立即写回，但 in-flight slot0
    // 之前发射的指令仍在 5 级流水线中，将在 N 周期后 WB。若 slot1.rd 与
    // 任意 in-flight slot0 的 rd 相同，slot0 的晚到 WB 会覆盖 slot1 的正确值。
    assign id1_no_xcycle_waw = ~(
        id1_reg_write && (id1_rd != 5'd0) && (
            (id_ex_valid    && id_ex_reg_write    && (id_ex_rd    == id1_rd)) ||
            (ex_mem_valid   && ex_mem_reg_write   && (ex_mem_rd   == id1_rd)) ||
            (ex2_agu_valid  && ex2_agu_reg_write  && (ex2_agu_rd  == id1_rd)) ||
            (agu_mem_valid  && agu_mem_reg_write  && (agu_mem_rd  == id1_rd)) ||
            (mem_wb_valid   && mem_wb_reg_write   && (mem_wb_rd   == id1_rd))
        )
    );

    // R4: slot1 LOAD 在 EX1 组合读 D-Cache port B；slot0 store 要 4 周期后才落
    // dmem，因此任何在飞的 slot0 store 都可能与 slot1 LOAD 形成地址别名 RAW。
    // 当前没做地址比较 / store-buffer，保守做法：在飞 slot0 store 期间不发 slot1 LOAD。
    // 包括 ID2 同 cycle slot0=STORE 的情形（因 slot0 4 周期后才写）。
    assign id1_no_store_alias_hazard = ~(
        id1_is_load_op && (
            (id_mem_write) ||                                         // slot0 同 cycle = STORE
            (id_ex_valid    && id_ex_mem_write   ) ||
            (ex_mem_valid   && ex_mem_mem_write  ) ||
            (ex2_agu_valid  && ex2_agu_mem_write ) ||
            (agu_mem_valid  && agu_mem_mem_write )
        )
    );

    // ===== Milestone 2: Slot1 ID/EX Pipeline Update (Phase 2B) =====
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            id1_ex_pc         <= 32'b0;
            id1_ex_instr      <= 32'h00000013;
            id1_ex_imm        <= 32'b0;
            id1_ex_rs1_addr   <= 5'b0;
            id1_ex_rs2_addr   <= 5'b0;
            id1_ex_rd         <= 5'b0;
            id1_ex_alu_op     <= `ALU_ADD;
            id1_ex_a_src      <= 1'b0;
            id1_ex_b_src      <= 1'b0;
            id1_ex_reg_write  <= 1'b0;
            id1_ex_wb_sel     <= `WB_ALU;
            id1_ex_valid      <= 1'b0;
            id1_ex_imm_type   <= `IMM_NONE;
            id1_ex_br_type    <= `BR_NONE;
            id1_ex_mem_read   <= 1'b0;
            id1_ex_mem_funct3 <= 3'b0;
            id1_ex_rd_ptag    <= 6'b0;
            id1_ex_rs1_ptag   <= 6'b0;
            id1_ex_rs2_ptag   <= 6'b0;
            id1_ex_from_rs    <= 1'b0;
            id1_ex_rs1_val    <= 32'b0;
            id1_ex_rs2_val    <= 32'b0;
        end else if (ex_redirect || stall || rn_block_slot0 || rn_block_slot1 || rs_issue_allow) begin
            // 刷新/气泡 slot1（A 路径 RS issue 也 bubble，因为 slot0 让位给 RS，slot1 此 cycle 不能跟随 slot0 进流水线）
            id1_ex_instr      <= 32'h00000013;
            id1_ex_rd         <= 5'b0;
            id1_ex_reg_write  <= 1'b0;
            id1_ex_valid      <= 1'b0;
            id1_ex_br_type    <= `BR_NONE;
            id1_ex_mem_read   <= 1'b0;
            id1_ex_from_rs    <= 1'b0;
        end else if (rs_issue_via_b) begin
            // T2b-step3a-v1 (Option B): RS issues into slot1 EX1b pipe.
            // Reuses u_alu_slot1, slot1_wb_we, prf_we1, cdb1.
            id1_ex_pc         <= rs_sh_issue_peek_pc;
            id1_ex_instr      <= rs_sh_issue_peek_instr;
            id1_ex_imm        <= rs_sh_issue_peek_imm;
            id1_ex_rs1_addr   <= 5'b0;
            id1_ex_rs2_addr   <= 5'b0;
            id1_ex_rd         <= rs_sh_issue_peek_rd_arch;
            id1_ex_alu_op     <= rs_sh_issue_peek_alu_op;
            id1_ex_a_src      <= rs_sh_issue_peek_a_src;
            id1_ex_b_src      <= rs_sh_issue_peek_b_src;
            id1_ex_reg_write  <= 1'b1;
            id1_ex_wb_sel     <= rs_sh_issue_peek_wb_sel;
            id1_ex_valid      <= 1'b1;
            id1_ex_imm_type   <= `IMM_NONE;
            id1_ex_br_type    <= `BR_NONE;
            id1_ex_mem_read   <= rs_sh_issue_peek_mem_read;
            id1_ex_mem_funct3 <= rs_sh_issue_peek_mem_funct3;
            id1_ex_rob_tag    <= rs_sh_issue_peek_rob_tag;
            id1_ex_rd_ptag    <= rs_sh_issue_peek_rd_ptag;
            id1_ex_rs1_ptag   <= 6'b0;
            id1_ex_rs2_ptag   <= 6'b0;
            id1_ex_from_rs    <= 1'b1;
            id1_ex_rs1_val    <= rs_sh_issue_peek_rs1_val;
            id1_ex_rs2_val    <= rs_sh_issue_peek_rs2_val;
        end else begin
            id1_ex_pc         <= id1_id2_pc1;
            id1_ex_instr      <= id1_instr;
            id1_ex_imm        <= id_imm;              // slot0 产生的立即数，对 slot1 不适用；仅 PHase 2C 使用
            id1_ex_rs1_addr   <= id1_rs1;
            id1_ex_rs2_addr   <= id1_rs2;
            id1_ex_rd         <= id1_rd;
            id1_ex_alu_op     <= id1_alu_op;
            id1_ex_a_src      <= id1_a_src;
            id1_ex_b_src      <= id1_b_src;
            id1_ex_reg_write  <= id1_reg_write;
            id1_ex_wb_sel     <= id1_wb_sel;
            id1_ex_valid      <= id2_issue_slot1;     // 仅当 slot1 满足配对条件时，流水线才推进
            id1_ex_imm_type   <= id1_imm_type;
            id1_ex_br_type    <= id1_br_type;
            id1_ex_mem_read   <= id1_mem_read;     // R4: slot1 LOAD
            id1_ex_mem_funct3 <= id1_mem_funct3;
            id1_ex_rob_tag    <= rob_alloc_tag_1;     // M3.2: 携带 ROB tag
            id1_ex_rd_ptag    <= rn_s1_rd_ptag_new;   // M3.4b: 携带 rename ptag
            id1_ex_rs1_ptag   <= rn_s1_rs1_ptag;       // M3.4c: 携带 rs ptag
            id1_ex_rs2_ptag   <= rn_s1_rs2_ptag;
            id1_ex_from_rs    <= 1'b0;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            id_ex_pc         <= 32'b0;
            id_ex_instr      <= 32'h00000013;
            id_ex_imm        <= 32'b0;
            id_ex_rs1_addr   <= 5'b0;
            id_ex_rs2_addr   <= 5'b0;
            id_ex_rd         <= 5'b0;
            id_ex_alu_op     <= `ALU_ADD;
            id_ex_a_src      <= 1'b0;
            id_ex_b_src      <= 1'b0;
            id_ex_br_type    <= `BR_NONE;
            id_ex_is_jump    <= 1'b0;
            id_ex_mem_read   <= 1'b0;
            id_ex_mem_write  <= 1'b0;
            id_ex_mem_funct3 <= 3'b0;
            id_ex_reg_write  <= 1'b0;
            id_ex_wb_sel     <= `WB_ALU;
            id_ex_valid      <= 1'b0;
            id_ex_is_ecall   <= 1'b0;
            id_ex_is_mret    <= 1'b0;
            id_ex_is_illegal <= 1'b0;
            id_ex_pred_taken <= 1'b0;
            id_ex_pred_target<= 32'b0;
            id_ex_pred_ghr   <= {BPU_GHR_W{1'b0}};
            id_ex_rd_ptag    <= 6'b0;
            id_ex_rs1_ptag   <= 6'b0;
            id_ex_rs2_ptag   <= 6'b0;
            id_ex_from_rs    <= 1'b0;
            id_ex_rs1_val    <= 32'b0;
            id_ex_rs2_val    <= 32'b0;
        end else if (ex_redirect || stall || rn_block_slot0) begin
            // 刷新/气泡 ID/EX：清控制信号
            id_ex_instr       <= 32'h00000013;
            id_ex_rd          <= 5'b0;
            id_ex_br_type     <= `BR_NONE;
            id_ex_is_jump     <= 1'b0;
            id_ex_mem_read    <= 1'b0;
            id_ex_mem_write   <= 1'b0;
            id_ex_reg_write   <= 1'b0;
            id_ex_valid       <= 1'b0;
            id_ex_is_ecall    <= 1'b0;
            id_ex_is_mret     <= 1'b0;
            id_ex_is_illegal  <= 1'b0;
            id_ex_pred_taken  <= 1'b0;
            id_ex_pred_target <= 32'b0;
            id_ex_pred_ghr    <= {BPU_GHR_W{1'b0}};
            id_ex_from_rs     <= 1'b0;
        end else if (rs_issue_allow) begin
            id_ex_pc          <= rs_sh_issue_peek_pc;
            id_ex_instr       <= rs_sh_issue_peek_instr;
            id_ex_imm         <= rs_sh_issue_peek_imm;
            id_ex_rs1_addr    <= 5'b0;
            id_ex_rs2_addr    <= 5'b0;
            id_ex_rd          <= rs_sh_issue_peek_rd_arch;
            id_ex_alu_op      <= rs_sh_issue_peek_alu_op;
            id_ex_a_src       <= rs_sh_issue_peek_a_src;
            id_ex_b_src       <= rs_sh_issue_peek_b_src;
            id_ex_br_type     <= `BR_NONE;
            id_ex_is_jump     <= 1'b0;
            id_ex_mem_read    <= 1'b0;
            id_ex_mem_write   <= 1'b0;
            id_ex_mem_funct3  <= 3'b0;
            id_ex_reg_write   <= 1'b1;
            id_ex_wb_sel      <= rs_sh_issue_peek_wb_sel;
            id_ex_valid       <= 1'b1;
            id_ex_is_ecall    <= 1'b0;
            id_ex_is_mret     <= 1'b0;
            id_ex_is_illegal  <= 1'b0;
            id_ex_pred_taken  <= 1'b0;
            id_ex_pred_target <= 32'b0;
            id_ex_pred_ghr    <= {BPU_GHR_W{1'b0}};
            id_ex_rob_tag     <= rs_sh_issue_peek_rob_tag;
            id_ex_rd_ptag     <= rs_sh_issue_peek_rd_ptag;
            id_ex_rs1_ptag    <= 6'b0;
            id_ex_rs2_ptag    <= 6'b0;
            id_ex_from_rs     <= 1'b1;
            id_ex_rs1_val     <= rs_sh_issue_peek_rs1_val;
            id_ex_rs2_val     <= rs_sh_issue_peek_rs2_val;
        end else begin
            id_ex_pc          <= id1_id2_pc0;
            id_ex_instr       <= id_instr;
            id_ex_imm         <= id_imm;
            id_ex_rs1_addr    <= id_rs1;
            id_ex_rs2_addr    <= id_rs2;
            id_ex_rd          <= id_rd;
            id_ex_alu_op      <= id_alu_op;
            id_ex_a_src       <= id_a_src;
            id_ex_b_src       <= id_b_src;
            id_ex_br_type     <= id_br_type;
            id_ex_is_jump     <= id_is_jump;
            id_ex_mem_read    <= id_mem_read;
            id_ex_mem_write   <= id_mem_write;
            id_ex_mem_funct3  <= id_mem_funct3;
            id_ex_reg_write   <= id_reg_write;
            id_ex_wb_sel      <= id_wb_sel;
            id_ex_valid       <= id1_id2_valid0;
            id_ex_is_ecall    <= id_is_ecall;
            id_ex_is_mret     <= id_is_mret;
            id_ex_is_illegal  <= id_is_illegal;
            id_ex_pred_taken  <= id1_id2_pred_taken;
            id_ex_pred_target <= id1_id2_pred_target;
            id_ex_pred_ghr    <= id1_id2_pred_ghr;
            id_ex_rob_tag     <= rob_alloc_tag_0;     // M3.2: 携带 ROB tag
            id_ex_rd_ptag     <= rn_s0_rd_ptag_new;   // M3.4b: 携带 rename ptag
            id_ex_rs1_ptag    <= rn_s0_rs1_ptag;       // M3.4c: 携带 rs ptag
            id_ex_rs2_ptag    <= rn_s0_rs2_ptag;
            id_ex_from_rs     <= 1'b0;
            id_ex_rs1_val     <= 32'b0;
            id_ex_rs2_val     <= 32'b0;
        end
    end

    // ---------------- EX1 ----------------
    // 前递选择 (OoO Stage 3: ptag-based)
    wire [1:0] fwd_a, fwd_b;
    forwarding u_fwd (
        .id_ex_rs1_ptag    (id_ex_rs1_ptag),
        .id_ex_rs2_ptag    (id_ex_rs2_ptag),
        .ex_mem_reg_write  (ex_mem_reg_write & ex_mem_valid & ~ex_mem_mem_read),
        .ex_mem_rd_ptag    (ex_mem_rd_ptag),
        .ex2_agu_reg_write (ex2_agu_reg_write & ex2_agu_valid & ~ex2_agu_mem_read),
        .ex2_agu_rd_ptag   (ex2_agu_rd_ptag),
        .agu_mem_reg_write (agu_mem_reg_write & agu_mem_valid),
        .agu_mem_rd_ptag   (agu_mem_rd_ptag),
        .mem_wb_reg_write  (mem_wb_reg_write & mem_wb_valid),
        .mem_wb_rd_ptag    (mem_wb_rd_ptag),
        .fwd_a             (fwd_a),
        .fwd_b             (fwd_b)
    );

    // AGU/MEM 前递数据：普通 ALU 指令前递地址/ALU结果，load 前递扩展后的读数据
    wire [31:0] agu_mem_fwd_data = agu_mem_mem_read ? mem_load_data : agu_mem_alu_y;
    wire        fwd_a_from_agu = (agu_mem_reg_write & agu_mem_valid) &&
                                 (agu_mem_rd_ptag != 6'd0) &&
                                 (agu_mem_rd_ptag == id_ex_rs1_ptag);
    wire        fwd_b_from_agu = (agu_mem_reg_write & agu_mem_valid) &&
                                 (agu_mem_rd_ptag != 6'd0) &&
                                 (agu_mem_rd_ptag == id_ex_rs2_ptag);

    // 前递后的 rs1/rs2（这是“逐表达式中的真实寄存器值”）
    // OoO Stage 1: baseline operand source 由 regfile-cached `id_ex_rs*` 切到
    // PRF[id_ex_rs*_ptag]（prf_r0/prf_r1）。forwarding 命中时仍由相应流水线寄存器
    // 提供 in-flight 值，PRF 仅作为 baseline（producer 已经 WB 或仍是架构值）。
    wire [31:0] ex_rs1_base = prf_r0;
    wire [31:0] ex_rs2_base = prf_r1;
    wire [31:0] ex_rs1_fwd =
        (fwd_a == 2'b01) ? ex_mem_alu_y :
        (fwd_a == 2'b10) ? ex2_agu_alu_y :
        (fwd_a == 2'b11) ? (fwd_a_from_agu ? agu_mem_fwd_data : wb_data) :
                           ex_rs1_base;
    wire [31:0] ex_rs2_fwd =
        (fwd_b == 2'b01) ? ex_mem_alu_y :
        (fwd_b == 2'b10) ? ex2_agu_alu_y :
        (fwd_b == 2'b11) ? (fwd_b_from_agu ? agu_mem_fwd_data : wb_data) :
                           ex_rs2_base;

    wire [31:0] ex_a = (id_ex_a_src == `ASRC_PC ) ? id_ex_pc  : (id_ex_from_rs ? id_ex_rs1_val : ex_rs1_fwd);
    wire [31:0] ex_b = (id_ex_b_src == `BSRC_IMM) ? id_ex_imm : (id_ex_from_rs ? id_ex_rs2_val : ex_rs2_fwd);

    wire [31:0] ex_alu_y;
    alu u_alu (
        .op (id_ex_alu_op),
        .a  (ex_a),
        .b  (ex_b),
        .y  (ex_alu_y)
    );

    // ===== Milestone 2: Slot1 ALU Datapath (Phase 2C) =====
    // Slot1 forwarding (OoO Stage 3: ptag-based)
    // 优先级（最近的 in-flight 优先）：id_ex (slot0 同 cycle EX) > ex_mem > ex2_agu > agu_mem > mem_wb
    // slot1 没有 load 数据来源，但 load 依赖已被配对规则禁止（id1_no_load_use_hazard）
    // baseline operand source = PRF[id1_ex_rs*_ptag] = prf_r2/prf_r3
    wire [31:0] slot1_rs1_base = prf_r2;
    wire [31:0] slot1_rs2_base = prf_r3;
    wire [31:0] slot1_rs1_fwd =
        (id1_ex_rs1_ptag != 6'd0 && id1_ex_rs1_ptag == id_ex_rd_ptag  && id_ex_valid  && id_ex_reg_write  && !id_ex_mem_read)  ? ex_alu_y :
        (id1_ex_rs1_ptag != 6'd0 && id1_ex_rs1_ptag == ex_mem_rd_ptag && ex_mem_valid && ex_mem_reg_write && !ex_mem_mem_read) ? ex_mem_alu_y :
        (id1_ex_rs1_ptag != 6'd0 && id1_ex_rs1_ptag == ex2_agu_rd_ptag && ex2_agu_valid && ex2_agu_reg_write && !ex2_agu_mem_read) ? ex2_agu_alu_y :
        (id1_ex_rs1_ptag != 6'd0 && id1_ex_rs1_ptag == agu_mem_rd_ptag && agu_mem_valid && agu_mem_reg_write) ? agu_mem_fwd_data :
        (id1_ex_rs1_ptag != 6'd0 && id1_ex_rs1_ptag == mem_wb_rd_ptag  && mem_wb_valid  && mem_wb_reg_write)  ? wb_data :
                           slot1_rs1_base;
    wire [31:0] slot1_rs2_fwd =
        (id1_ex_rs2_ptag != 6'd0 && id1_ex_rs2_ptag == id_ex_rd_ptag  && id_ex_valid  && id_ex_reg_write  && !id_ex_mem_read)  ? ex_alu_y :
        (id1_ex_rs2_ptag != 6'd0 && id1_ex_rs2_ptag == ex_mem_rd_ptag && ex_mem_valid && ex_mem_reg_write && !ex_mem_mem_read) ? ex_mem_alu_y :
        (id1_ex_rs2_ptag != 6'd0 && id1_ex_rs2_ptag == ex2_agu_rd_ptag && ex2_agu_valid && ex2_agu_reg_write && !ex2_agu_mem_read) ? ex2_agu_alu_y :
        (id1_ex_rs2_ptag != 6'd0 && id1_ex_rs2_ptag == agu_mem_rd_ptag && agu_mem_valid && agu_mem_reg_write) ? agu_mem_fwd_data :
        (id1_ex_rs2_ptag != 6'd0 && id1_ex_rs2_ptag == mem_wb_rd_ptag  && mem_wb_valid  && mem_wb_reg_write)  ? wb_data :
                           slot1_rs2_base;

    // Slot1 ALU input (ALU-only, so a_src is always RS1, b_src is IMM or RS2)
    // For ALU-only, imm_gen output can be reused or computed on-the-fly
    wire [31:0] slot1_imm;
    imm_gen u_imm_slot1 (
        .instr    (id1_ex_instr),
        .imm_type (id1_ex_imm_type),
        .imm      (slot1_imm)
    );

    wire [31:0] slot1_a = (id1_ex_a_src == `ASRC_PC) ? id1_ex_pc :
                          (id1_ex_from_rs ? id1_ex_rs1_val : slot1_rs1_fwd);
    // T2b-step3a-v1: RS-issued entries store imm directly in id1_ex_imm
    // (imm_type isn't recoverable post-decode, so bypass imm_gen recompute).
    wire [31:0] slot1_b_imm = id1_ex_from_rs ? id1_ex_imm : slot1_imm;
    wire [31:0] slot1_b = (id1_ex_b_src == `BSRC_IMM) ? slot1_b_imm :
                          (id1_ex_from_rs ? id1_ex_rs2_val : slot1_rs2_fwd);

    wire [31:0] slot1_alu_y;
    alu u_alu_slot1 (
        .op (id1_ex_alu_op),
        .a  (slot1_a),
        .b  (slot1_b),
        .y  (slot1_alu_y)
    );

    // Slot1 分支判断使用前递后的 rs1/rs2
    wire slot1_br_taken;
    branch_unit u_bu_slot1 (
        .br_type (id1_ex_br_type),
        .is_jump (1'b0),                 // slot1 不接受 JAL/JALR（需 redirect+rd 写）
        .rs1     (slot1_rs1_fwd),
        .rs2     (slot1_rs2_fwd),
        .taken   (slot1_br_taken)
    );

    wire slot1_is_branch_ex = id1_ex_valid && (id1_ex_br_type != `BR_NONE);
    wire [31:0] slot1_br_target = id1_ex_pc + slot1_imm;
    // slot1 分支隐式预测 not-taken（IF 阶段 BPU 仅给 slot0；若 BPU 预测 taken，
    // slot1 已在 IF 时被 if_id_valid1 = ~bpu_pred_taken 丢弃）。
    // 因此：slot1 实际 taken == 错预测；实际 not-taken == 命中。
    wire slot1_mispredict = slot1_is_branch_ex && slot1_br_taken;
    
    // 分支判断使用前递后的 rs1/rs2
    wire ex_br_taken;
    branch_unit u_bu (
        .br_type (id_ex_br_type),
        .is_jump (id_ex_is_jump),
        .rs1     (ex_rs1_fwd),
        .rs2     (ex_rs2_fwd),
        .taken   (ex_br_taken)
    );

    // 分支/跳转目标地址：
    //   JAL / Bxx : pc + imm
    //   JALR      : (rs1 + imm) & ~1
    wire [31:0] ex_target_normal = id_ex_pc  + id_ex_imm;
    wire [31:0] ex_target_jalr   = (ex_rs1_fwd + id_ex_imm) & ~32'b1;
    wire        ex_is_jalr       = id_ex_is_jump && (id_ex_a_src == `ASRC_RS1);
    wire [31:0] ex_actual_target = ex_is_jalr ? ex_target_jalr : ex_target_normal;
    wire        ex_is_branch     = id_ex_valid && (id_ex_br_type != `BR_NONE);
    wire        ex_is_exception  = id_ex_valid && (id_ex_is_ecall || id_ex_is_illegal);
    wire [31:0] ex_exception_cause = id_ex_is_ecall ? 32'd11 : 32'd2; // ecall M-mode / illegal
    wire        ex_is_mret_inst  = id_ex_valid && id_ex_is_mret;

    // 错预测条件：
    //   1) 应该 taken 但 IF 没预测 taken（或预测目标不对）
    //   2) 不应该 taken 但 IF 预测了 taken
    wire ex_mispredict = ex_is_branch && (
            (ex_br_taken  && (!id_ex_pred_taken || (id_ex_pred_target != ex_actual_target))) ||
            (!ex_br_taken &&  id_ex_pred_taken)
        );

    // R3: slot0 优先级高于 slot1（slot0 是 program order 中较早的指令）。
    //   * slot0 redirect → ex_redirect_pc 使用 slot0 路径；slot1 在同 cycle 已被 gate 杀掉。
    //   * slot0 不 redirect 但 slot1 mispredict → 使用 slot1 redirect 至 slot1 分支目标。
    wire ex_redirect_slot0 = ex_is_exception || ex_is_mret_inst || ex_mispredict;
    wire ex_redirect_slot1 = !ex_redirect_slot0 && slot1_mispredict;

    assign ex_redirect    = ex_redirect_slot0 || ex_redirect_slot1;
    assign ex_redirect_pc = ex_is_exception ? csr_mtvec :
                            ex_is_mret_inst ? csr_mepc :
                            ex_mispredict   ? (ex_br_taken ? ex_actual_target : (id_ex_pc + 32'd4)) :
                            /* slot1 mispredict */ slot1_br_target;

    // BPU 训练反馈
    //   * slot0 是分支 → 用 slot0 训练（同 cycle 若 slot1 也是分支，丢弃 slot1 训练；
    //     发生概率低，可接受）。
    //   * 否则若 slot1 是分支 → 用 slot1 训练。
    assign bpu_upd_valid  = ex_is_branch || slot1_is_branch_ex;
    assign bpu_upd_pc     = ex_is_branch ? id_ex_pc          : id1_ex_pc;
    assign bpu_upd_taken  = ex_is_branch ? ex_br_taken       : slot1_br_taken;
    assign bpu_upd_target = ex_is_branch ? ex_actual_target  : slot1_br_target;
    // 训练索引还原：slot0 使用流水线透传的快照；slot1 不携带快照，
    // 退化为 0（slot1 仅限条件分支，占比低）。
    assign bpu_upd_pred_ghr  = ex_is_branch ? id_ex_pred_ghr : {BPU_GHR_W{1'b0}};
    // slot1 不受理 JAL/JALR，所以 is_uncond 只需看 slot0。
    assign bpu_upd_is_uncond = ex_is_branch && id_ex_is_jump;

    // CSR 写入：异常入口记录 mepc/mcause；mret 只做跳转
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            csr_mtvec  <= RESET_MTVEC;
            csr_mepc   <= 32'b0;
            csr_mcause <= 32'b0;
        end else if (ex_is_exception) begin
            csr_mepc   <= id_ex_pc;
            csr_mcause <= ex_exception_cause;
        end
    end

    // EX1/EX2 流水线寄存器（声明在顶部）
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ex_mem_pc         <= 32'b0;
            ex_mem_instr      <= 32'h00000013;
            ex_mem_alu_y      <= 32'b0;
            ex_mem_rs2        <= 32'b0;
            ex_mem_rd         <= 5'b0;
            ex_mem_mem_read   <= 1'b0;
            ex_mem_mem_write  <= 1'b0;
            ex_mem_mem_funct3 <= 3'b0;
            ex_mem_reg_write  <= 1'b0;
            ex_mem_wb_sel     <= `WB_ALU;
            ex_mem_valid      <= 1'b0;
            ex_mem_rd_ptag    <= 6'b0;
        end else begin
            ex_mem_pc         <= id_ex_pc;
            ex_mem_instr      <= id_ex_instr;
            // 对 JAL/JALR：写回 PC+4
            ex_mem_alu_y      <= (id_ex_wb_sel == `WB_PC4) ? (id_ex_pc + 32'd4) : ex_alu_y;
            ex_mem_rs2        <= ex_rs2_fwd;
            ex_mem_rd         <= id_ex_rd;
            ex_mem_mem_read   <= id_ex_mem_read;
            ex_mem_mem_write  <= id_ex_mem_write;
            ex_mem_mem_funct3 <= id_ex_mem_funct3;
            ex_mem_reg_write  <= id_ex_reg_write;
            ex_mem_wb_sel     <= id_ex_wb_sel;
            ex_mem_valid      <= id_ex_valid;
            ex_mem_rob_tag    <= id_ex_rob_tag;
            ex_mem_rd_ptag    <= id_ex_rd_ptag;
        end
    end

    // EX2/AGU 流水线寄存器（声明在顶部）
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ex2_agu_pc         <= 32'b0;
            ex2_agu_instr      <= 32'h00000013;
            ex2_agu_alu_y      <= 32'b0;
            ex2_agu_rs2        <= 32'b0;
            ex2_agu_rd         <= 5'b0;
            ex2_agu_mem_read   <= 1'b0;
            ex2_agu_mem_write  <= 1'b0;
            ex2_agu_mem_funct3 <= 3'b0;
            ex2_agu_reg_write  <= 1'b0;
            ex2_agu_wb_sel     <= `WB_ALU;
            ex2_agu_valid      <= 1'b0;
            ex2_agu_rd_ptag    <= 6'b0;
        end else begin
            ex2_agu_pc         <= ex_mem_pc;
            ex2_agu_instr      <= ex_mem_instr;
            ex2_agu_alu_y      <= ex_mem_alu_y;
            ex2_agu_rs2        <= ex_mem_rs2;
            ex2_agu_rd         <= ex_mem_rd;
            ex2_agu_mem_read   <= ex_mem_mem_read;
            ex2_agu_mem_write  <= ex_mem_mem_write;
            ex2_agu_mem_funct3 <= ex_mem_mem_funct3;
            ex2_agu_reg_write  <= ex_mem_reg_write;
            ex2_agu_wb_sel     <= ex_mem_wb_sel;
            ex2_agu_valid      <= ex_mem_valid;
            ex2_agu_rob_tag    <= ex_mem_rob_tag;
            ex2_agu_rd_ptag    <= ex_mem_rd_ptag;
        end
    end

    // ---------------- AGU ----------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            agu_mem_pc         <= 32'b0;
            agu_mem_instr      <= 32'h00000013;
            agu_mem_alu_y      <= 32'b0;
            agu_mem_rs2        <= 32'b0;
            agu_mem_rd         <= 5'b0;
            agu_mem_mem_read   <= 1'b0;
            agu_mem_mem_write  <= 1'b0;
            agu_mem_mem_funct3 <= 3'b0;
            agu_mem_reg_write  <= 1'b0;
            agu_mem_wb_sel     <= `WB_ALU;
            agu_mem_valid      <= 1'b0;
            agu_mem_rd_ptag    <= 6'b0;
        end else begin
            agu_mem_pc         <= ex2_agu_pc;
            agu_mem_instr      <= ex2_agu_instr;
            agu_mem_alu_y      <= ex2_agu_alu_y;
            agu_mem_rs2        <= ex2_agu_rs2;
            agu_mem_rd         <= ex2_agu_rd;
            agu_mem_mem_read   <= ex2_agu_mem_read;
            agu_mem_mem_write  <= ex2_agu_mem_write;
            agu_mem_mem_funct3 <= ex2_agu_mem_funct3;
            agu_mem_reg_write  <= ex2_agu_reg_write;
            agu_mem_wb_sel     <= ex2_agu_wb_sel;
            agu_mem_valid      <= ex2_agu_valid;
            agu_mem_rob_tag    <= ex2_agu_rob_tag;
            agu_mem_rd_ptag    <= ex2_agu_rd_ptag;
        end
    end

    // ---------------- MEM ----------------
    // 字节使能 + 写数据按对齐放置
    reg  [3:0]  mem_be;
    reg  [31:0] mem_wdata_aligned;
    wire [1:0]  mem_byte_off = agu_mem_alu_y[1:0];

    always @(*) begin
        mem_be            = 4'b0000;
        mem_wdata_aligned = 32'b0;
        case (agu_mem_mem_funct3)
            3'b000: begin // SB
                case (mem_byte_off)
                    2'd0: begin mem_be = 4'b0001; mem_wdata_aligned = {24'b0, agu_mem_rs2[7:0]}; end
                    2'd1: begin mem_be = 4'b0010; mem_wdata_aligned = {16'b0, agu_mem_rs2[7:0], 8'b0}; end
                    2'd2: begin mem_be = 4'b0100; mem_wdata_aligned = {8'b0, agu_mem_rs2[7:0], 16'b0}; end
                    2'd3: begin mem_be = 4'b1000; mem_wdata_aligned = {agu_mem_rs2[7:0], 24'b0}; end
                endcase
            end
            3'b001: begin // SH
                if (mem_byte_off == 2'd0) begin
                    mem_be = 4'b0011; mem_wdata_aligned = {16'b0, agu_mem_rs2[15:0]};
                end else begin
                    mem_be = 4'b1100; mem_wdata_aligned = {agu_mem_rs2[15:0], 16'b0};
                end
            end
            3'b010: begin // SW
                mem_be = 4'b1111; mem_wdata_aligned = agu_mem_rs2;
            end
            default: ;
        endcase
    end

    wire [31:0] dmem_rdata;
    wire [31:0] dmem_rdata_b;     // R4: slot1 LOAD 读端口 B
    // R4: slot1 LOAD 地址 = slot1 ALU 结果（rs1+imm，OP_LOAD 已置 a_src=RS1, b_src=IMM）
    wire [31:0] slot1_mem_addr   = slot1_alu_y;
    wire        slot1_mem_re     = id1_ex_valid && id1_ex_mem_read && !ex_redirect;
    dmem u_dmem (
        .clk    (clk),
        .addr   (agu_mem_alu_y),
        .we     (agu_mem_mem_write & agu_mem_valid),
        .be     (mem_be),
        .wdata  (mem_wdata_aligned),
        .rdata  (dmem_rdata),
        // R4: 第二只读端口
        .addr_b (slot1_mem_addr),
        .re_b   (slot1_mem_re),
        .rdata_b(dmem_rdata_b)
    );

    // load 数据按宽度/符号扩展
    always @(*) begin
        case (agu_mem_mem_funct3)
            3'b000: begin // LB
                case (mem_byte_off)
                    2'd0: mem_load_data = {{24{dmem_rdata[7]}},  dmem_rdata[7:0]};
                    2'd1: mem_load_data = {{24{dmem_rdata[15]}}, dmem_rdata[15:8]};
                    2'd2: mem_load_data = {{24{dmem_rdata[23]}}, dmem_rdata[23:16]};
                    2'd3: mem_load_data = {{24{dmem_rdata[31]}}, dmem_rdata[31:24]};
                endcase
            end
            3'b001: begin // LH
                if (mem_byte_off == 2'd0)
                    mem_load_data = {{16{dmem_rdata[15]}}, dmem_rdata[15:0]};
                else
                    mem_load_data = {{16{dmem_rdata[31]}}, dmem_rdata[31:16]};
            end
            3'b010: mem_load_data = dmem_rdata; // LW
            3'b100: begin // LBU
                case (mem_byte_off)
                    2'd0: mem_load_data = {24'b0, dmem_rdata[7:0]};
                    2'd1: mem_load_data = {24'b0, dmem_rdata[15:8]};
                    2'd2: mem_load_data = {24'b0, dmem_rdata[23:16]};
                    2'd3: mem_load_data = {24'b0, dmem_rdata[31:24]};
                endcase
            end
            3'b101: begin // LHU
                if (mem_byte_off == 2'd0)
                    mem_load_data = {16'b0, dmem_rdata[15:0]};
                else
                    mem_load_data = {16'b0, dmem_rdata[31:16]};
            end
            default: mem_load_data = dmem_rdata;
        endcase
    end

    // MEM/WB 流水线寄存器（声明在顶部）
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mem_wb_pc        <= 32'b0;
            mem_wb_instr     <= 32'h00000013;
            mem_wb_alu_y     <= 32'b0;
            mem_wb_load      <= 32'b0;
            mem_wb_rd        <= 5'b0;
            mem_wb_reg_write <= 1'b0;
            mem_wb_wb_sel    <= `WB_ALU;
            mem_wb_valid     <= 1'b0;
            mem_wb_rd_ptag   <= 6'b0;
        end else begin
            mem_wb_pc        <= agu_mem_pc;
            mem_wb_instr     <= agu_mem_instr;
            mem_wb_alu_y     <= agu_mem_alu_y;
            mem_wb_load      <= mem_load_data;
            mem_wb_rd        <= agu_mem_rd;
            mem_wb_reg_write <= agu_mem_reg_write;
            mem_wb_wb_sel    <= agu_mem_wb_sel;
            mem_wb_valid     <= agu_mem_valid;
            mem_wb_rob_tag   <= agu_mem_rob_tag;
            mem_wb_rd_ptag   <= agu_mem_rd_ptag;
        end
    end

    // ---------------- WB ----------------
    assign wb_rd   = mem_wb_rd;
    assign wb_we   = mem_wb_reg_write & mem_wb_valid;
    assign wb_data = (mem_wb_wb_sel == `WB_MEM) ? mem_wb_load : mem_wb_alu_y;

    // ===== Milestone 2 Phase R2: Slot1 Direct Write-Back (ENABLED) =====
    // PC 已升级为 +8 推进 + IFQ 双 pop，避免重复执行问题。
    // Slot1 在 EX1 阶段直接写回 regfile（ALU-only，无需 EX2/AGU/MEM）
    // R3: 当同 cycle slot0 (paired) 触发 ex_redirect（mispredict/exc/mret）时
    //     slot1 是错误路径，必须 kill WB / PRF write / ROB writeback。
    // R4: slot1 也可以是 LOAD（1 周期完成：组合读 D-Cache port B + 符号扩展）。
    //     slot1_load_data 在 EX1 同 cycle 组合产生。

    wire [1:0] slot1_byte_off = slot1_mem_addr[1:0];
    reg [31:0] slot1_load_data;
    always @(*) begin
        case (id1_ex_mem_funct3)
            3'b000: begin // LB
                case (slot1_byte_off)
                    2'd0: slot1_load_data = {{24{dmem_rdata_b[7]}},  dmem_rdata_b[7:0]};
                    2'd1: slot1_load_data = {{24{dmem_rdata_b[15]}}, dmem_rdata_b[15:8]};
                    2'd2: slot1_load_data = {{24{dmem_rdata_b[23]}}, dmem_rdata_b[23:16]};
                    2'd3: slot1_load_data = {{24{dmem_rdata_b[31]}}, dmem_rdata_b[31:24]};
                endcase
            end
            3'b001: begin // LH
                if (slot1_byte_off == 2'd0)
                    slot1_load_data = {{16{dmem_rdata_b[15]}}, dmem_rdata_b[15:0]};
                else
                    slot1_load_data = {{16{dmem_rdata_b[31]}}, dmem_rdata_b[31:16]};
            end
            3'b010: slot1_load_data = dmem_rdata_b; // LW
            3'b100: begin // LBU
                case (slot1_byte_off)
                    2'd0: slot1_load_data = {24'b0, dmem_rdata_b[7:0]};
                    2'd1: slot1_load_data = {24'b0, dmem_rdata_b[15:8]};
                    2'd2: slot1_load_data = {24'b0, dmem_rdata_b[23:16]};
                    2'd3: slot1_load_data = {24'b0, dmem_rdata_b[31:24]};
                endcase
            end
            3'b101: begin // LHU
                if (slot1_byte_off == 2'd0)
                    slot1_load_data = {16'b0, dmem_rdata_b[15:0]};
                else
                    slot1_load_data = {16'b0, dmem_rdata_b[31:16]};
            end
            default: slot1_load_data = dmem_rdata_b;
        endcase
    end

    assign slot1_wb_we   = id1_ex_valid && id1_ex_reg_write && !ex_redirect;
    assign slot1_wb_rd   = id1_ex_rd;
    assign slot1_wb_data = id1_ex_mem_read ? slot1_load_data : slot1_alu_y;

    // OoO Stage 1-bis (step1): PRF dual-write — wb 同时写 arch_idx 和 spec ptag。
    //   we0/we1 写 arch idx (= Stage 2 行为，保证 PRF[0..31] 始终镜像架构态，
    //                       即便 ROB flush 也不丢 wb-done 的值)。
    //   we2/we3 写 spec ptag (新增)，让 PRF[ptag] 也持有 wb 后的值，为 step2
    //                       切换读端口到 spec ptag 做准备。
    //   spec_ptag == arch_idx 时（identity 映射，未 rename），跳过 we2/we3 避免重写。
    //   读端口本步保持 arch idx（行为零变化），下一 commit 切到 spec ptag。
    assign prf_we0 = wb_we && (mem_wb_rd != 5'd0);
    assign prf_wa0 = {1'b0, mem_wb_rd};
    assign prf_wd0 = wb_data;
    // T2b-step3a-v1 fix: when slot1 EX1b is firing an RS-issued (out-of-order)
    // op, suppress the arch-idx PRF write (we1). The arch-idx slot
    // (PRF[0..31]) is also the "identity OLD ptag" for any reg that hasn't
    // been renamed yet; an OoO write can clobber an older in-flight reader
    // still using the identity ptag. We KEEP the ptag-side write (we3 →
    // PRF[NEW ptag]) and the CDB1 broadcast (ROB done + RS wake up) so
    // forward progress is unaffected. The matching in-order copy of the
    // same instr will eventually reach mem_wb and update arch-idx via
    // prf_we0 in program order.
    assign prf_we1 = slot1_wb_we && (id1_ex_rd != 5'd0) && !id1_ex_from_rs;
    assign prf_wa1 = {1'b0, id1_ex_rd};
    assign prf_wd1 = slot1_wb_data;
    // 读地址：使用 spec ptag（OoO 准备）。Forwarding 仍按 arch id 命中较新值，
    // 不命中时由 PRF[ptag] 提供 in-flight 推测值（we2/we3 已 mirror）。
    assign prf_ra0 = id_ex_rs1_ptag;
    assign prf_ra1 = id_ex_rs2_ptag;
    assign prf_ra2 = id1_ex_rs1_ptag;
    assign prf_ra3 = id1_ex_rs2_ptag;

    // we2/we3: 镜像写到 spec ptag。
    assign prf_we2 = prf_we0 && (mem_wb_rd_ptag != {1'b0, mem_wb_rd});
    assign prf_wa2 = mem_wb_rd_ptag;
    assign prf_wd2 = wb_data;
    // T2b-step3a-v1 fix: prf_we3 must remain active even when prf_we1 is
    // suppressed for from_rs (so PRF[NEW ptag] still receives the OoO value
    // for downstream readers). Recompute the gate from slot1_wb_we directly.
    assign prf_we3 = slot1_wb_we && (id1_ex_rd != 5'd0) &&
                     (id1_ex_rd_ptag != {1'b0, id1_ex_rd});
    assign prf_wa3 = id1_ex_rd_ptag;
    assign prf_wd3 = slot1_wb_data;


    // ============================================================
    // Tomasulo Phase T1 — Common Data Bus (CDB) abstraction
    // Pure aliasing of existing WB→PRF wires. Zero functional change.
    // Future T2 reservation stations will snoop these signals to wake
    // up waiting entries (set rs1/rs2 ready, capture value).
    // ============================================================
    wire        cdb0_valid;
    wire [5:0]  cdb0_ptag;
    wire [31:0] cdb0_value;
    wire [3:0]  cdb0_rob_tag;
    wire        cdb1_valid;
    wire [5:0]  cdb1_ptag;
    wire [31:0] cdb1_value;
    wire [3:0]  cdb1_rob_tag;
    assign cdb0_valid   = prf_we0;
    assign cdb0_ptag    = mem_wb_rd_ptag;
    assign cdb0_value   = wb_data;
    assign cdb0_rob_tag = mem_wb_rob_tag;
    assign cdb1_valid   = prf_we1;
    assign cdb1_ptag    = id1_ex_rd_ptag;
    assign cdb1_value   = slot1_wb_data;
    assign cdb1_rob_tag = id1_ex_rob_tag;

    // T1 stats: also keep CDB wires alive through iverilog DCE so TB peeks bind.
    reg [31:0] cdb0_event_cnt;
    reg [31:0] cdb1_event_cnt;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cdb0_event_cnt <= 32'b0;
            cdb1_event_cnt <= 32'b0;
        end else begin
            if (cdb0_valid) cdb0_event_cnt <= cdb0_event_cnt + 32'd1;
            if (cdb1_valid) cdb1_event_cnt <= cdb1_event_cnt + 32'd1;
        end
    end

    // ============================================================
    // Tomasulo Phase T2a — shadow Reservation Station (observability)
    //
    // Runs in parallel with the in-order pipeline. Driven by the same
    // dispatch/CDB events. Does NOT affect issue. Counters answer:
    //   - how often would RS be full (back-pressure dispatch)?
    //   - how many cycles do entries wait for operands?
    //   - what % of allocs are ready immediately?
    // ============================================================
    // Forward-declare rename outputs the shadow RS reads (real declarations
    // + instance live further below; Verilog wires can be forward-referenced
    // but indexed bit-select wants the decl already in scope).
    wire [63:0] rn_busy_vec;

    // RS-eligible slot0 classes:
    //   - ALU (existing step3a behavior)
    //   - LOAD (step3b first slice)
    // Excludes store/branch/jump/system for now.
    assign slot0_is_alu = !id_mem_read && !id_mem_write
                          && (id_br_type == `BR_NONE) && !id_is_jump
                          && !id_is_ecall && !id_is_mret && !id_is_illegal;
    wire slot0_is_load = id_mem_read && !id_mem_write
                         && (id_br_type == `BR_NONE) && !id_is_jump
                         && !id_is_ecall && !id_is_mret && !id_is_illegal;
    wire slot0_is_rs_eligible = slot0_is_alu || slot0_is_load;
    wire rs_sh_alloc_op = ifq_pop_slot0 && slot0_is_rs_eligible;

    // ready-at-alloc test: rename's busy_vec is the post-update busy after
    // commit/wb in the previous cycle, so it reflects "is producer still
    // in-flight?". ptag==0 (x0) is always ready.
    wire rs_sh_alloc_rs1_rdy = (rn_s0_rs1_ptag == 6'd0) || !rn_busy_vec[rn_s0_rs1_ptag];
    // LOAD address generation only depends on rs1. For step3b-load, force rs2
    // as ready/x0 to avoid unnecessary waiting on an unused operand.
    wire rs_sh_alloc_rs2_rdy = slot0_is_load ? 1'b1 :
                               ((rn_s0_rs2_ptag == 6'd0) || !rn_busy_vec[rn_s0_rs2_ptag]);
    // 环形年龄比较（以 ROB head 为基准）：更小 delta 代表更老。
    // 仅在 slot0 为 ALU 且可被后端考虑时，允许 shadow-RS 抢占 EX1。
    assign slot0_pop_would = slot0_can_consider;
    assign slot1_pop_would = slot0_can_consider && id2_issue_slot1;

    wire slot0_pop_prearb = slot0_pop_would && !rn_block_slot0;
    wire slot1_pop_prearb = slot1_pop_would && !rn_block_slot0 && !rn_block_slot1;
    wire [3:0] rs_issue_age_delta = rs_sh_issue_peek_rob_tag - rob_head_tag;
    wire [3:0] slot0_alloc_age_delta = rob_alloc_tag_0 - rob_head_tag;
    wire rs_issue_older_than_slot0 = (rs_issue_age_delta < slot0_alloc_age_delta);
    wire rs_issue_age_allow = !slot0_pop_prearb || rs_issue_older_than_slot0;
    assign rs_issue_allow = rs_sh_issue_peek_v
                            && !rs_sh_issue_peek_mem_read
                            && slot0_can_consider
                            && slot0_is_alu
                            && !slot0_pop_prearb
                            && rs_issue_age_allow;

    // T2b-step3a-v1 (Option B): RS B-path. When the A-path is unavailable
    // (e.g. slot0 is non-ALU, or slot0 wants to pop and is older), route the
    // RS-ready entry into the slot1 EX1b pipe instead. Conditions:
    //   - RS has a ready entry
    //   - A-path is not firing
    //   - slot1 EX1b pipe is idle this cycle (no slot1 IFQ pop)
    //   - no global stall / redirect
    //   - rename block on slot1 must not gate it (we don't allocate; we just
    //     issue an already-renamed entry from RS)
    assign rs_issue_via_b = rs_sh_issue_peek_v
                            && !rs_issue_allow
                            && !ifq_pop_slot1
                            && !ex_redirect
                            && !stall;

    assign slot0_pop_allow = slot0_pop_prearb && !rs_issue_allow;
    assign slot1_pop_allow = slot1_pop_prearb;

    wire [31:0] rs_sh_alloc_count, rs_sh_issue_count, rs_sh_full_stall_count;
    wire [31:0] rs_sh_wait_cycles_total, rs_sh_ready_at_alloc_count;
    wire [31:0] rs_sh_max_occupancy;

    // T2b-step1: extra PRF read ports for capturing operand values at the
    // shadow-RS dispatch instant. ra4/ra5 read by rename's slot0 ptags so
    // that prf_r4/r5 are valid the same cycle alloc_valid asserts.
    assign prf_ra4 = rn_s0_rs1_ptag;
    assign prf_ra5 = rn_s0_rs2_ptag;

    rs_shadow #(.DEPTH(4), .PTAG_W(6), .ROB_W(4)) u_rs_shadow (
        .clk                  (clk),
        .rst_n                (rst_n),
        .flush                (ex_redirect),
        .issue_grant          (rs_issue_grant),
        .alloc_valid          (rs_sh_alloc_op),
        .alloc_rs1_ptag       (rn_s0_rs1_ptag),
        .alloc_rs2_ptag       (slot0_is_load ? 6'd0 : rn_s0_rs2_ptag),
        .alloc_rs1_ready      (rs_sh_alloc_rs1_rdy),
        .alloc_rs2_ready      (rs_sh_alloc_rs2_rdy),
        .alloc_rd_ptag        (rn_s0_rd_ptag_new),
        .alloc_rob_tag        (rob_alloc_tag_0),
        .alloc_rs1_val        (prf_r4),
        .alloc_rs2_val        (slot0_is_load ? 32'b0 : prf_r5),
        .alloc_alu_op         (id_alu_op),
        .alloc_imm            (id_imm),
        .alloc_a_src          (id_a_src),
        .alloc_b_src          (id_b_src),
        .alloc_wb_sel         (id_wb_sel),
        .alloc_mem_read       (id_mem_read),
        .alloc_mem_funct3     (id_mem_funct3),
        .alloc_rd_arch        (id_rd),
        .alloc_instr          (id_instr),
        .alloc_pc             (id1_id2_pc0),
        .cdb0_valid           (cdb0_valid),
        .cdb0_ptag            (cdb0_ptag),
        .cdb0_value           (cdb0_value),
        .cdb1_valid           (cdb1_valid),
        .cdb1_ptag            (cdb1_ptag),
        .cdb1_value           (cdb1_value),
        .issue_v_o            (rs_sh_issue_v),
        .issue_rs1_val_o      (rs_sh_issue_rs1_val),
        .issue_rs2_val_o      (rs_sh_issue_rs2_val),
        .issue_alu_op_o       (rs_sh_issue_alu_op),
        .issue_rd_ptag_o      (rs_sh_issue_rd_ptag),
        .issue_rob_tag_o      (rs_sh_issue_rob_tag),
        .issue_pc_o           (rs_sh_issue_pc),
        .issue_peek_v_o       (rs_sh_issue_peek_v),
        .issue_peek_rs1_val_o (rs_sh_issue_peek_rs1_val),
        .issue_peek_rs2_val_o (rs_sh_issue_peek_rs2_val),
        .issue_peek_alu_op_o  (rs_sh_issue_peek_alu_op),
        .issue_peek_imm_o     (rs_sh_issue_peek_imm),
        .issue_peek_a_src_o   (rs_sh_issue_peek_a_src),
        .issue_peek_b_src_o   (rs_sh_issue_peek_b_src),
        .issue_peek_wb_sel_o  (rs_sh_issue_peek_wb_sel),
        .issue_peek_mem_read_o   (rs_sh_issue_peek_mem_read),
        .issue_peek_mem_funct3_o (rs_sh_issue_peek_mem_funct3),
        .issue_peek_rd_arch_o (rs_sh_issue_peek_rd_arch),
        .issue_peek_instr_o   (rs_sh_issue_peek_instr),
        .issue_peek_rd_ptag_o (rs_sh_issue_peek_rd_ptag),
        .issue_peek_rob_tag_o (rs_sh_issue_peek_rob_tag),
        .issue_peek_pc_o      (rs_sh_issue_peek_pc),
        .alloc_count          (rs_sh_alloc_count),
        .issue_count          (rs_sh_issue_count),
        .full_stall_count     (rs_sh_full_stall_count),
        .wait_cycles_total    (rs_sh_wait_cycles_total),
        .ready_at_alloc_count (rs_sh_ready_at_alloc_count),
        .max_occupancy        (rs_sh_max_occupancy)
    );

    // T2b-step1: shadow ALU driven by registered RS issue port. Pure
    // observability for now; result feeds nothing in the real pipeline.
    // Visible in waveforms as rs_sh_alu_y_w.
    wire [31:0] rs_sh_alu_y_w;
    alu u_rs_sh_alu (
        .op (rs_sh_issue_alu_op),
        .a  (rs_sh_issue_rs1_val),
        .b  (rs_sh_issue_rs2_val),
        .y  (rs_sh_alu_y_w)
    );

    // ============================================================
    // Phase A2-step1 — shadow Return Address Stack (observability)
    //
    // Quantifies what a 16-deep RAS would buy us before adding it
    // to the BPU PC-select path. Driven by EX-stage retired jumps.
    // ============================================================
    wire        ras_sh_jmp_valid = ex_is_branch && id_ex_is_jump;
    wire [31:0] ras_sh_jal_count, ras_sh_jalr_count;
    wire [31:0] ras_sh_call_count, ras_sh_ret_count;
    wire [31:0] ras_sh_ret_pred_correct, ras_sh_ret_pred_wrong;
    wire [31:0] ras_sh_bpu_pred_correct_on_ret;
    wire [31:0] ras_sh_underflow, ras_sh_overflow;

    ras_shadow #(.DEPTH(16)) u_ras_shadow (
        .clk                     (clk),
        .rst_n                   (rst_n),
        .flush                   (ex_redirect),
        .jmp_valid               (ras_sh_jmp_valid),
        .jmp_is_jalr             (ex_is_jalr),
        .jmp_rd                  (id_ex_rd),
        .jmp_rs1                 (id_ex_rs1_addr),
        .jmp_pc                  (id_ex_pc),
        .jmp_actual_target       (ex_actual_target),
        .jmp_pred_target         (id_ex_pred_target),
        .jmp_pred_taken          (id_ex_pred_taken),
        .jal_count               (ras_sh_jal_count),
        .jalr_count              (ras_sh_jalr_count),
        .call_count              (ras_sh_call_count),
        .ret_count               (ras_sh_ret_count),
        .ret_pred_correct        (ras_sh_ret_pred_correct),
        .ret_pred_wrong          (ras_sh_ret_pred_wrong),
        .bpu_pred_correct_on_ret (ras_sh_bpu_pred_correct_on_ret),
        .stack_underflow         (ras_sh_underflow),
        .stack_overflow          (ras_sh_overflow),
        .ras_top_valid           (ras_top_valid_for_pred),
        .ras_top_o               (ras_top_for_pred)
    );

    // ---------------- Debug ----------------
    assign dbg_pc       = pc;
    assign dbg_instr_wb = mem_wb_instr;
    assign dbg_wb_we    = wb_we;
    assign dbg_wb_rd    = wb_rd;
    assign dbg_wb_data  = wb_data;

    // ===== Milestone 3 Phase M3.4a: Register Rename (observability only) =====
    // rename 与 ROB 同步，但流水线不消费其输出（regfile/forwarding 仍走旧路径）。

    // Forward decls (实例化在文件末尾的 ROB 输出，rename 在此使用)
    // (M3.4d 已把 rob_commit_valid/rd/rw/ptag_new/ptag_old 上提到 PRF 段)
    // (T2a 已把 rn_busy_vec 上提到 shadow RS 段供 bit-select 使用)
    wire [5:0]  rn_s0_rd_ptag_old;
    wire [5:0]  rn_s1_rd_ptag_old;
    // rn_block_slot0/1 在文件顶部 forward-declared
    wire [5:0]  rn_free_count;

    wire        rn_s0_alloc_req = slot0_pop_would && id_reg_write && (id_rd != 5'd0);
    wire        rn_s1_alloc_req = slot1_pop_would && id1_reg_write && (id1_rd != 5'd0);

    // OoO Stage1-bis step3: per-slot rename free-list block
    //   slot0 阻塞条件：slot0 需分配但 free_count == 0
    //   slot1 阻塞条件：slot1 需分配但 free_count < (slot0_alloc ? 2 : 1)
    //   注意计算用 *_alloc_req (would-be, 未带 rn_block_*)，避免组合环。
    assign rn_block_slot0 = rn_s0_alloc_req && (rn_free_count == 6'd0);
    assign rn_block_slot1 = rn_s1_alloc_req && (rn_free_count < (rn_s0_alloc_req ? 6'd2 : 6'd1));

    // 实际传给 rename 的 alloc 信号必须与最终 pop allow 一致，
    // 避免出现“IFQ 未出队但 rename 已分配”的状态失配。
    wire        rn_s0_alloc = slot0_pop_allow && id_reg_write && (id_rd != 5'd0);
    wire        rn_s1_alloc = slot1_pop_allow && id1_reg_write && (id1_rd != 5'd0);

    rename u_rename (
        .clk                (clk),
        .rst_n              (rst_n),
        .flush              (ex_redirect),
        .s0_rs1             (id_rs1),
        .s0_rs2             (id_rs2),
        .s0_rd              (id_rd),
        .s0_alloc           (rn_s0_alloc),
        .s1_rs1             (id1_rs1),
        .s1_rs2             (id1_rs2),
        .s1_rd              (id1_rd),
        .s1_alloc           (rn_s1_alloc),
        .s0_rs1_ptag        (rn_s0_rs1_ptag),
        .s0_rs2_ptag        (rn_s0_rs2_ptag),
        .s0_rd_ptag_new     (rn_s0_rd_ptag_new),
        .s0_rd_ptag_old     (rn_s0_rd_ptag_old),
        .s1_rs1_ptag        (rn_s1_rs1_ptag),
        .s1_rs2_ptag        (rn_s1_rs2_ptag),
        .s1_rd_ptag_new     (rn_s1_rd_ptag_new),
        .s1_rd_ptag_old     (rn_s1_rd_ptag_old),
        .stall              (rn_stall),
        // M3.4b: 用真实写回事件清 busy
        .wb0_valid          (prf_we0),
        .wb0_ptag           (mem_wb_rd_ptag),
        .wb1_valid          (prf_we1),
        .wb1_ptag           (id1_ex_rd_ptag),
        .commit0_valid      (rob_commit_valid_0 && rob_commit_rw_0 && rob_commit_rd_0 != 5'd0),
        .commit0_rd         (rob_commit_rd_0),
        .commit0_ptag_new   (rob_commit_ptag_new_0),
        .commit0_ptag_old   (rob_commit_ptag_old_0),
        .commit1_valid      (rob_commit_valid_1 && rob_commit_rw_1 && rob_commit_rd_1 != 5'd0),
        .commit1_rd         (rob_commit_rd_1),
        .commit1_ptag_new   (rob_commit_ptag_new_1),
        .commit1_ptag_old   (rob_commit_ptag_old_1),
        .free_count         (rn_free_count),
        .busy_vec           (rn_busy_vec)
    );

    // ===== Milestone 3 Phase M3.2: ROB shadow tracking (alloc + wb + commit观测) =====
    // ROB 仍然不驱动 regfile（旧路径仍生效）；ROB 跟踪 in-flight 状态。
    wire [4:0]  rob_count;
    wire        rob_full, rob_almost_full;

    // commit 视图（M3.2 中仅观测；rob_commit_valid/rd/rw 已在 rename 段 forward-decl）
    wire [3:0]  rob_commit_tag_0, rob_commit_tag_1;
    wire [31:0] rob_commit_pc_0, rob_commit_pc_1;
    wire        rob_commit_st_0, rob_commit_st_1;
    wire [31:0] rob_commit_sa_0, rob_commit_sa_1;
    wire [31:0] rob_commit_sd_0, rob_commit_sd_1;
    wire [3:0]  rob_commit_sb_0, rob_commit_sb_1;
    wire        rob_commit_exc_0, rob_commit_exc_1;
    wire [31:0] rob_commit_cause_0, rob_commit_cause_1;

    // alloc 来自 IFQ 的 pop（issue 时刻分配 tag）
    // 注意：使用同 cycle 的 alloc 输出 tag，写入 ID/EX 流水线寄存器。
    wire        rob_alloc_v0 = ifq_pop_slot0;
    wire        rob_alloc_v1 = ifq_pop_slot1;
    wire [31:0] rob_alloc_pc_0_w = id1_id2_pc0;
    wire [31:0] rob_alloc_pc_1_w = id1_id2_pc1;
    wire [4:0]  rob_alloc_rd_0_w = id_rd;
    wire [4:0]  rob_alloc_rd_1_w = id1_rd;
    wire        rob_alloc_rw_0_w = id_reg_write;
    wire        rob_alloc_rw_1_w = id1_reg_write;
    wire        rob_alloc_st_0_w = id_mem_write;
    wire        rob_alloc_st_1_w = 1'b0;        // slot1 不会是 store
    wire        rob_alloc_br_0_w = (id_br_type != `BR_NONE) || id_is_jump;
    // R3: slot1 可以是条件分支
    wire        rob_alloc_br_1_w = id1_is_branch_op;

    // writeback：slot0 在 mem_wb 阶段；slot1 在 EX1 阶段
    wire        rob_wb_v0 = mem_wb_valid;
    wire [3:0]  rob_wb_t0 = mem_wb_rob_tag;
    wire [31:0] rob_wb_r0 = (mem_wb_wb_sel == `WB_MEM) ? mem_wb_load : mem_wb_alu_y;
    wire        rob_wb_v1 = id1_ex_valid && !ex_redirect;
    wire [3:0]  rob_wb_t1 = id1_ex_rob_tag;
    wire [31:0] rob_wb_r1 = slot1_wb_data;     // R4: LOAD 时为 sign-ext 后的 load data

    // commit pop：跟随 commit_valid（in-order 自然约束）
    wire [1:0]  rob_pop_cnt = (rob_commit_valid_0 ? 2'd1 : 2'd0)
                             + (rob_commit_valid_1 ? 2'd1 : 2'd0);

    rob #(.DEPTH(16), .AW(4)) u_rob (
        .clk                (clk),
        .rst_n              (rst_n),
        .flush              (ex_redirect),
        .flush_partial      (1'b0),
        .flush_keep_tag     (4'b0),
        .flush_keep_valid   (1'b0),
        .alloc_valid_0      (rob_alloc_v0),
        .alloc_pc_0         (rob_alloc_pc_0_w),
        .alloc_rd_0         (rob_alloc_rd_0_w),
        .alloc_reg_write_0  (rob_alloc_rw_0_w),
        .alloc_is_store_0   (rob_alloc_st_0_w),
        .alloc_is_branch_0  (rob_alloc_br_0_w),
        .alloc_ptag_new_0   (rn_s0_rd_ptag_new),
        .alloc_ptag_old_0   (rn_s0_rd_ptag_old),
        .alloc_tag_0        (rob_alloc_tag_0),
        .alloc_valid_1      (rob_alloc_v1),
        .alloc_pc_1         (rob_alloc_pc_1_w),
        .alloc_rd_1         (rob_alloc_rd_1_w),
        .alloc_reg_write_1  (rob_alloc_rw_1_w),
        .alloc_is_store_1   (rob_alloc_st_1_w),
        .alloc_is_branch_1  (rob_alloc_br_1_w),
        .alloc_ptag_new_1   (rn_s1_rd_ptag_new),
        .alloc_ptag_old_1   (rn_s1_rd_ptag_old),
        .alloc_tag_1        (rob_alloc_tag_1),
        .full               (rob_full),
        .almost_full        (rob_almost_full),
        .wb_valid_0         (rob_wb_v0),
        .wb_tag_0           (rob_wb_t0),
        .wb_result_0        (rob_wb_r0),
        .wb_exception_0     (1'b0),
        .wb_exc_cause_0     (32'b0),
        .wb_store_addr_0    (32'b0),
        .wb_store_data_0    (32'b0),
        .wb_store_be_0      (4'b0),
        .wb_valid_1         (rob_wb_v1),
        .wb_tag_1           (rob_wb_t1),
        .wb_result_1        (rob_wb_r1),
        .wb_exception_1     (1'b0),
        .wb_exc_cause_1     (32'b0),
        .wb_store_addr_1    (32'b0),
        .wb_store_data_1    (32'b0),
        .wb_store_be_1      (4'b0),
        .commit_valid_0     (rob_commit_valid_0),
        .commit_tag_0       (rob_commit_tag_0),
        .commit_pc_0        (rob_commit_pc_0),
        .commit_rd_0        (rob_commit_rd_0),
        .commit_reg_write_0 (rob_commit_rw_0),
        .commit_result_0    (rob_commit_res_0),
        .commit_ptag_new_0  (rob_commit_ptag_new_0),
        .commit_ptag_old_0  (rob_commit_ptag_old_0),
        .commit_is_store_0  (rob_commit_st_0),
        .commit_store_addr_0(rob_commit_sa_0),
        .commit_store_data_0(rob_commit_sd_0),
        .commit_store_be_0  (rob_commit_sb_0),
        .commit_exception_0 (rob_commit_exc_0),
        .commit_exc_cause_0 (rob_commit_cause_0),
        .commit_valid_1     (rob_commit_valid_1),
        .commit_tag_1       (rob_commit_tag_1),
        .commit_pc_1        (rob_commit_pc_1),
        .commit_rd_1        (rob_commit_rd_1),
        .commit_reg_write_1 (rob_commit_rw_1),
        .commit_result_1    (rob_commit_res_1),
        .commit_ptag_new_1  (rob_commit_ptag_new_1),
        .commit_ptag_old_1  (rob_commit_ptag_old_1),
        .commit_is_store_1  (rob_commit_st_1),
        .commit_store_addr_1(rob_commit_sa_1),
        .commit_store_data_1(rob_commit_sd_1),
        .commit_store_be_1  (rob_commit_sb_1),
        .commit_exception_1 (rob_commit_exc_1),
        .commit_exc_cause_1 (rob_commit_cause_1),
        .commit_pop_count   (rob_pop_cnt),
        .count              (rob_count),
        .head_tag           (rob_head_tag)
    );

endmodule
