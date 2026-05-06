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
    // 综合冻结条件：load-use stall 或 IFQ 反压
    wire        if_freeze = stall || ifq_almost_full;

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
    wire        bpu_pred_taken;
    wire [31:0] bpu_pred_target;
    wire        bpu_upd_valid;
    wire [31:0] bpu_upd_pc, bpu_upd_target;
    wire        bpu_upd_taken;

    bpu u_bpu (
        .clk         (clk),
        .rst_n       (rst_n),
        .if_pc       (pc),
        .pred_taken  (bpu_pred_taken),
        .pred_target (bpu_pred_target),
        .upd_valid   (bpu_upd_valid),
        .upd_pc      (bpu_upd_pc),
        .upd_taken   (bpu_upd_taken),
        .upd_target  (bpu_upd_target)
    );

    // PC 选择：刷新 > stall/反压 > 预测 > PC+8（双发射前端）
    // BPU 仅在 slot0 处预测；若预测 taken，则 slot1 被丢弃，PC 跳转到目标
    wire [31:0] pc_next_seq = bpu_pred_taken ? bpu_pred_target : pc_plus8;

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
        end else begin
            if_id_pc0         <= pc;
            if_id_instr0      <= imem_rdata0;
            if_id_valid0      <= 1'b1;
            if_id_pc1         <= pc_plus4;
            if_id_instr1      <= imem_rdata1;
            // slot1 失效条件：BPU 在 slot0 预测 taken（slot1 在分支后，应被丢弃）
            if_id_valid1      <= ~bpu_pred_taken;
            if_id_pred_taken  <= bpu_pred_taken;
            if_id_pred_target <= bpu_pred_target;
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

    wire        id1_id2_valid1;
    wire [31:0] id1_id2_pc1;
    wire [31:0] id1_id2_instr1;
    // slot1 prediction signals are not used by ID2 (slot1 cannot be a branch in M1.5 rules)
    wire        id1_id2_pred_taken1_unused;
    wire [31:0] id1_id2_pred_target1_unused;

    // pop 控制：当 backend 接受 slot0 时（无 stall、无 redirect、有效），消费一条
    wire ifq_pop_slot0  = id1_id2_valid0 && !stall && !ex_redirect;
    // R2: 双发射 — 仅当 slot0 pop 且 slot1 满足配对条件时才 pop slot1
    wire id2_issue_slot1;
    wire ifq_pop_slot1  = ifq_pop_slot0 && id2_issue_slot1;

    wire [3:0]  ifq_count;

    ifq #(.DEPTH(8), .AW(3)) u_ifq (
        .clk    (clk),
        .rst_n  (rst_n),
        .flush  (ex_redirect),
        // Push side: 来自 IF/ID1
        .push_valid_0       (if_id_valid0 && !if_freeze),
        .push_pc_0          (if_id_pc0),
        .push_instr_0       (if_id_instr0),
        .push_pred_taken_0  (if_id_pred_taken),
        .push_pred_target_0 (if_id_pred_target),
        .push_valid_1       (if_id_valid1 && !if_freeze),
        .push_pc_1          (if_id_pc1),
        .push_instr_1       (if_id_instr1),
        .push_pred_taken_1  (1'b0),    // slot1 不携带预测（仅 slot0 可能是分支）
        .push_pred_target_1 (32'b0),
        .full               (ifq_full),
        .almost_full        (ifq_almost_full),
        // Pop side -> ID2 decode
        .pop                (ifq_pop_slot0),
        .head_valid         (id1_id2_valid0),
        .head_pc            (id1_id2_pc0),
        .head_instr         (id1_id2_instr0),
        .head_pred_taken    (id1_id2_pred_taken),
        .head_pred_target   (id1_id2_pred_target),
        // 第二头（R2 双发射用）
        .head2_valid        (id1_id2_valid1),
        .head2_pc           (id1_id2_pc1),
        .head2_instr        (id1_id2_instr1),
        .head2_pred_taken   (id1_id2_pred_taken1_unused),
        .head2_pred_target  (id1_id2_pred_target1_unused),
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
    // 1. Slot1 有效 && 是 ALU-only 指令
    // 2. 没有 same-cycle RAW：slot1 rs1/rs2 不与 slot0 rd 重叠（仅在 slot0 有写回时检查）
    wire slot1_rs1_used = (id1_opcode == `OP_REG) || (id1_opcode == `OP_IMM);
    wire slot1_rs2_used = (id1_opcode == `OP_REG);
    // LUI/AUIPC 不读寄存器，不参与 RAW/load-use 检查

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

    // R2 BUG#4 修复：slot0 必须是"无副作用 / 无重定向" 的指令，才允许 slot1 配对。
    // 否则 slot0 mispredict/exception 时 slot1 已经写回 regfile，无法撤销。
    // R3 放宽：允许 slot0 是 store（store 不修改控制流，不会触发 ex_redirect；
    //   store 没有 rd，因此不会与 slot1 形成 WAW；slot1 与 store 内存无序也无影响，
    //   因为 slot1 是 ALU-only 不访存）。
    wire id_slot0_safe_for_pair = (id_br_type == `BR_NONE) && !id_is_jump &&
                                   !id_is_ecall && !id_is_mret && !id_is_illegal;
                                   // 注：去掉 !id_mem_write，允许 store 配对

    // Slot1 issue 条件
    assign id2_issue_slot1 = id1_id2_valid1 && id1_is_alu_only &&
                             id_slot0_safe_for_pair &&
                             id1_no_raw_hazard && id1_no_waw_hazard &&
                             id1_no_load_use_hazard && id1_no_xcycle_waw;
    wire id2_issue_slot0 = id1_id2_valid0;

    // 寄存器堆（写口接到 WB）
    wire        wb_we;
    wire [4:0]  wb_rd;
    wire [31:0] wb_data;

    // Slot0 read outputs
    wire [31:0] id_rs1_data, id_rs2_data;
    
    // Slot1 read outputs (Milestone 2)
    wire [31:0] id1_rs1_data, id1_rs2_data;

    // M3.2: ROB alloc tag forward decl（实例化在文件末尾）
    wire [3:0]  rob_alloc_tag_0;
    wire [3:0]  rob_alloc_tag_1;
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
    wire [31:0] prf_r0, prf_r1, prf_r2, prf_r3;
    // M3.4c PRF read addresses (sourced from EX-stage rs ptag pipeline regs)
    wire [5:0]  prf_ra0, prf_ra1, prf_ra2, prf_ra3;
    
    regfile u_rf (
        .clk      (clk),
        .rst_n    (rst_n),
        // Slot0 read ports
        .rs1_addr (id_rs1),
        .rs2_addr (id_rs2),
        .rs1_data (id_rs1_data),
        .rs2_data (id_rs2_data),
        // Slot1 read ports (new)
        .rs3_addr (id1_rs1),
        .rs4_addr (id1_rs2),
        .rs3_data (id1_rs1_data),
        .rs4_data (id1_rs2_data),
        // Slot0 write port
        .we0      (wb_we),
        .rd0_addr (wb_rd),
        .rd0_data (wb_data),
        // Slot1 write port (new)
        .we1      (slot1_wb_we),
        .rd1_addr (slot1_wb_rd),
        .rd1_data (slot1_wb_data)
    );

    // M3.4b: 物理寄存器文件（当前仅写入，读口先做观测）
    prf #(.DEPTH(48), .AW(6)) u_prf (
        .clk      (clk),
        .rst_n    (rst_n),
        .we0      (prf_we0),
        .wa0      (prf_wa0),
        .wd0      (prf_wd0),
        .we1      (prf_we1),
        .wa1      (prf_wa1),
        .wd1      (prf_wd1),
        .ra0      (prf_ra0),
        .ra1      (prf_ra1),
        .ra2      (prf_ra2),
        .ra3      (prf_ra3),
        .rd0      (prf_r0),
        .rd1      (prf_r1),
        .rd2      (prf_r2),
        .rd3      (prf_r3)
    );

    // ===== Milestone 2: Slot1 ID/EX Pipeline Registers (Phase 2B) =====

    reg [31:0] id1_ex_pc;
    reg [31:0] id1_ex_instr;
    reg [31:0] id1_ex_rs1, id1_ex_rs2, id1_ex_imm;
    reg [4:0]  id1_ex_rs1_addr, id1_ex_rs2_addr;
    reg [4:0]  id1_ex_rd;
    reg [3:0]  id1_ex_alu_op;
    reg        id1_ex_a_src, id1_ex_b_src;
    reg        id1_ex_reg_write;
    reg [1:0]  id1_ex_wb_sel;
    reg        id1_ex_valid;
    reg [2:0]  id1_ex_imm_type;
    reg [3:0]  id1_ex_rob_tag;
    reg [5:0]  id1_ex_rd_ptag;
    reg [5:0]  id1_ex_rs1_ptag, id1_ex_rs2_ptag;

    // ID/EX 流水线寄存器
    reg [31:0] id_ex_pc;
    reg [31:0] id_ex_instr;
    reg [31:0] id_ex_rs1, id_ex_rs2, id_ex_imm;
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
    reg [3:0]  id_ex_rob_tag;
    reg [5:0]  id_ex_rd_ptag;
    reg [5:0]  id_ex_rs1_ptag, id_ex_rs2_ptag;

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

    // ===== Milestone 2: Slot1 ID/EX Pipeline Update (Phase 2B) =====
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            id1_ex_pc         <= 32'b0;
            id1_ex_instr      <= 32'h00000013;
            id1_ex_rs1        <= 32'b0;
            id1_ex_rs2        <= 32'b0;
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
            id1_ex_rd_ptag    <= 6'b0;
            id1_ex_rs1_ptag   <= 6'b0;
            id1_ex_rs2_ptag   <= 6'b0;
        end else if (ex_redirect || stall) begin
            // 刷新/气泡 slot1
            id1_ex_instr      <= 32'h00000013;
            id1_ex_rd         <= 5'b0;
            id1_ex_reg_write  <= 1'b0;
            id1_ex_valid      <= 1'b0;
        end else begin
            id1_ex_pc         <= id1_id2_pc1;
            id1_ex_instr      <= id1_instr;
            id1_ex_rs1        <= id1_rs1_data;        // slot1 读寄存器
            id1_ex_rs2        <= id1_rs2_data;        // slot1 读寄存器
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
            id1_ex_rob_tag    <= rob_alloc_tag_1;     // M3.2: 携带 ROB tag
            id1_ex_rd_ptag    <= rn_s1_rd_ptag_new;   // M3.4b: 携带 rename ptag
            id1_ex_rs1_ptag   <= rn_s1_rs1_ptag;       // M3.4c: 携带 rs ptag
            id1_ex_rs2_ptag   <= rn_s1_rs2_ptag;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            id_ex_pc         <= 32'b0;
            id_ex_instr      <= 32'h00000013;
            id_ex_rs1        <= 32'b0;
            id_ex_rs2        <= 32'b0;
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
            id_ex_rd_ptag    <= 6'b0;
            id_ex_rs1_ptag   <= 6'b0;
            id_ex_rs2_ptag   <= 6'b0;
        end else if (ex_redirect || stall) begin
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
        end else begin
            id_ex_pc          <= id1_id2_pc0;
            id_ex_instr       <= id_instr;
            id_ex_rs1         <= id_rs1_data;
            id_ex_rs2         <= id_rs2_data;
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
            id_ex_rob_tag     <= rob_alloc_tag_0;     // M3.2: 携带 ROB tag
            id_ex_rd_ptag     <= rn_s0_rd_ptag_new;   // M3.4b: 携带 rename ptag
            id_ex_rs1_ptag    <= rn_s0_rs1_ptag;       // M3.4c: 携带 rs ptag
            id_ex_rs2_ptag    <= rn_s0_rs2_ptag;
        end
    end

    // ---------------- EX1 ----------------
    // 前递选择
    wire [1:0] fwd_a, fwd_b;
    forwarding u_fwd (
        .id_ex_rs1        (id_ex_rs1_addr),
        .id_ex_rs2        (id_ex_rs2_addr),
        .ex_mem_reg_write (ex_mem_reg_write & ex_mem_valid & ~ex_mem_mem_read),
        .ex_mem_rd        (ex_mem_rd),
        .ex2_agu_reg_write(ex2_agu_reg_write & ex2_agu_valid & ~ex2_agu_mem_read),
        .ex2_agu_rd       (ex2_agu_rd),
        .agu_mem_reg_write(agu_mem_reg_write & agu_mem_valid),
        .agu_mem_rd       (agu_mem_rd),
        .mem_wb_reg_write (mem_wb_reg_write & mem_wb_valid),
        .mem_wb_rd        (mem_wb_rd),
        .fwd_a            (fwd_a),
        .fwd_b            (fwd_b)
    );

    // AGU/MEM 前递数据：普通 ALU 指令前递地址/ALU结果，load 前递扩展后的读数据
    wire [31:0] agu_mem_fwd_data = agu_mem_mem_read ? mem_load_data : agu_mem_alu_y;
    wire        fwd_a_from_agu = (agu_mem_reg_write & agu_mem_valid) &&
                                 (agu_mem_rd != 5'd0) &&
                                 (agu_mem_rd == id_ex_rs1_addr);
    wire        fwd_b_from_agu = (agu_mem_reg_write & agu_mem_valid) &&
                                 (agu_mem_rd != 5'd0) &&
                                 (agu_mem_rd == id_ex_rs2_addr);

    // 前递后的 rs1/rs2（这是“逐表达式中的真实寄存器值”）
    wire [31:0] ex_rs1_fwd =
        (fwd_a == 2'b01) ? ex_mem_alu_y :
        (fwd_a == 2'b10) ? ex2_agu_alu_y :
        (fwd_a == 2'b11) ? (fwd_a_from_agu ? agu_mem_fwd_data : wb_data) :
                           id_ex_rs1;
    wire [31:0] ex_rs2_fwd =
        (fwd_b == 2'b01) ? ex_mem_alu_y :
        (fwd_b == 2'b10) ? ex2_agu_alu_y :
        (fwd_b == 2'b11) ? (fwd_b_from_agu ? agu_mem_fwd_data : wb_data) :
                           id_ex_rs2;

    wire [31:0] ex_a = (id_ex_a_src == `ASRC_PC ) ? id_ex_pc  : ex_rs1_fwd;
    wire [31:0] ex_b = (id_ex_b_src == `BSRC_IMM) ? id_ex_imm : ex_rs2_fwd;

    wire [31:0] ex_alu_y;
    alu u_alu (
        .op (id_ex_alu_op),
        .a  (ex_a),
        .b  (ex_b),
        .y  (ex_alu_y)
    );

    // ===== Milestone 2: Slot1 ALU Datapath (Phase 2C) =====
    // Slot1 forwarding: 完整的 forwarding 网络，与 slot0 同等
    // 优先级（最近的 in-flight 优先）：id_ex (slot0 同 cycle EX) > ex_mem > ex2_agu > agu_mem > mem_wb
    // slot1 没有 load 数据来源，但 load 依赖已被配对规则禁止（id1_no_load_use_hazard）
    wire [31:0] slot1_rs1_fwd =
        (id1_ex_rs1_addr != 5'd0 && id1_ex_rs1_addr == id_ex_rd && id_ex_valid && id_ex_reg_write && !id_ex_mem_read) ? ex_alu_y :
        (id1_ex_rs1_addr != 5'd0 && id1_ex_rs1_addr == ex_mem_rd && ex_mem_valid && ex_mem_reg_write && !ex_mem_mem_read) ? ex_mem_alu_y :
        (id1_ex_rs1_addr != 5'd0 && id1_ex_rs1_addr == ex2_agu_rd && ex2_agu_valid && ex2_agu_reg_write && !ex2_agu_mem_read) ? ex2_agu_alu_y :
        (id1_ex_rs1_addr != 5'd0 && id1_ex_rs1_addr == agu_mem_rd && agu_mem_valid && agu_mem_reg_write) ? agu_mem_fwd_data :
        (id1_ex_rs1_addr != 5'd0 && id1_ex_rs1_addr == mem_wb_rd && mem_wb_valid && mem_wb_reg_write) ? wb_data :
                           id1_ex_rs1;
    wire [31:0] slot1_rs2_fwd =
        (id1_ex_rs2_addr != 5'd0 && id1_ex_rs2_addr == id_ex_rd && id_ex_valid && id_ex_reg_write && !id_ex_mem_read) ? ex_alu_y :
        (id1_ex_rs2_addr != 5'd0 && id1_ex_rs2_addr == ex_mem_rd && ex_mem_valid && ex_mem_reg_write && !ex_mem_mem_read) ? ex_mem_alu_y :
        (id1_ex_rs2_addr != 5'd0 && id1_ex_rs2_addr == ex2_agu_rd && ex2_agu_valid && ex2_agu_reg_write && !ex2_agu_mem_read) ? ex2_agu_alu_y :
        (id1_ex_rs2_addr != 5'd0 && id1_ex_rs2_addr == agu_mem_rd && agu_mem_valid && agu_mem_reg_write) ? agu_mem_fwd_data :
        (id1_ex_rs2_addr != 5'd0 && id1_ex_rs2_addr == mem_wb_rd && mem_wb_valid && mem_wb_reg_write) ? wb_data :
                           id1_ex_rs2;

    // Slot1 ALU input (ALU-only, so a_src is always RS1, b_src is IMM or RS2)
    // For ALU-only, imm_gen output can be reused or computed on-the-fly
    wire [31:0] slot1_imm;
    imm_gen u_imm_slot1 (
        .instr    (id1_ex_instr),
        .imm_type (id1_ex_imm_type),
        .imm      (slot1_imm)
    );

    wire [31:0] slot1_a = (id1_ex_a_src == `ASRC_PC) ? id1_ex_pc : slot1_rs1_fwd;
    wire [31:0] slot1_b = (id1_ex_b_src == `BSRC_IMM) ? slot1_imm : slot1_rs2_fwd;

    wire [31:0] slot1_alu_y;
    alu u_alu_slot1 (
        .op (id1_ex_alu_op),
        .a  (slot1_a),
        .b  (slot1_b),
        .y  (slot1_alu_y)
    );

    // Slot1 分支判断使用前递后的 rs1/rs2（仅用于验证，slot1 不会有分支）
    
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

    assign ex_redirect    = ex_is_exception || ex_is_mret_inst || ex_mispredict;
    assign ex_redirect_pc = ex_is_exception ? csr_mtvec :
                            ex_is_mret_inst ? csr_mepc :
                            (ex_br_taken ? ex_actual_target : (id_ex_pc + 32'd4));

    // BPU 训练反馈
    assign bpu_upd_valid  = ex_is_branch;
    assign bpu_upd_pc     = id_ex_pc;
    assign bpu_upd_taken  = ex_br_taken;
    assign bpu_upd_target = ex_actual_target;

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
    dmem u_dmem (
        .clk   (clk),
        .addr  (agu_mem_alu_y),
        .we    (agu_mem_mem_write & agu_mem_valid),
        .be    (mem_be),
        .wdata (mem_wdata_aligned),
        .rdata (dmem_rdata)
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
    assign slot1_wb_we   = id1_ex_valid && id1_ex_reg_write;
    assign slot1_wb_rd   = id1_ex_rd;
    assign slot1_wb_data = slot1_alu_y;

    // M3.4b: PRF 双写来源（保持旧 regfile 写回路径不变）
    assign prf_we0 = wb_we && (mem_wb_rd != 5'd0);
    assign prf_wa0 = mem_wb_rd_ptag;
    assign prf_wd0 = wb_data;
    assign prf_we1 = slot1_wb_we && (id1_ex_rd != 5'd0);
    assign prf_wa1 = id1_ex_rd_ptag;
    assign prf_wd1 = slot1_wb_data;
    // M3.4c: PRF 读地址由 EX 阶段的 rs ptag 驱动
    assign prf_ra0 = id_ex_rs1_ptag;
    assign prf_ra1 = id_ex_rs2_ptag;
    assign prf_ra2 = id1_ex_rs1_ptag;
    assign prf_ra3 = id1_ex_rs2_ptag;

    // ---------------- Debug ----------------
    assign dbg_pc       = pc;
    assign dbg_instr_wb = mem_wb_instr;
    assign dbg_wb_we    = wb_we;
    assign dbg_wb_rd    = wb_rd;
    assign dbg_wb_data  = wb_data;

    // ===== Milestone 3 Phase M3.4a: Register Rename (observability only) =====
    // rename 与 ROB 同步，但流水线不消费其输出（regfile/forwarding 仍走旧路径）。

    // Forward decls (实例化在文件末尾的 ROB 输出，rename 在此使用)
    wire        rob_commit_valid_0, rob_commit_valid_1;
    wire [4:0]  rob_commit_rd_0,    rob_commit_rd_1;
    wire        rob_commit_rw_0,    rob_commit_rw_1;
    // ROB ptag 接口（commit 时回收 old ptag 给 rename）
    wire [5:0] rob_commit_ptag_new_0, rob_commit_ptag_old_0;
    wire [5:0] rob_commit_ptag_new_1, rob_commit_ptag_old_1;

    wire [5:0]  rn_s0_rd_ptag_old;
    wire [5:0]  rn_s1_rd_ptag_old;
    wire        rn_stall;
    wire [4:0]  rn_free_count;
    wire [47:0] rn_busy_vec;

    wire        rn_s0_alloc = ifq_pop_slot0 && id_reg_write && (id_rd != 5'd0);
    wire        rn_s1_alloc = ifq_pop_slot1 && id1_reg_write && (id1_rd != 5'd0);

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
        .commit0_ptag_old   (rob_commit_ptag_old_0),
        .commit1_valid      (rob_commit_valid_1 && rob_commit_rw_1 && rob_commit_rd_1 != 5'd0),
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
    wire [31:0] rob_commit_res_0, rob_commit_res_1;
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
    wire        rob_alloc_br_1_w = 1'b0;        // slot1 不会是 branch

    // writeback：slot0 在 mem_wb 阶段；slot1 在 EX1 阶段
    wire        rob_wb_v0 = mem_wb_valid;
    wire [3:0]  rob_wb_t0 = mem_wb_rob_tag;
    wire [31:0] rob_wb_r0 = (mem_wb_wb_sel == `WB_MEM) ? mem_wb_load : mem_wb_alu_y;
    wire        rob_wb_v1 = id1_ex_valid;
    wire [3:0]  rob_wb_t1 = id1_ex_rob_tag;
    wire [31:0] rob_wb_r1 = slot1_alu_y;

    // commit pop：跟随 commit_valid（in-order 自然约束）
    wire [1:0]  rob_pop_cnt = (rob_commit_valid_0 ? 2'd1 : 2'd0)
                             + (rob_commit_valid_1 ? 2'd1 : 2'd0);

    rob #(.DEPTH(16), .AW(4)) u_rob (
        .clk                (clk),
        .rst_n              (rst_n),
        .flush              (ex_redirect),
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
        .count              (rob_count)
    );

endmodule
