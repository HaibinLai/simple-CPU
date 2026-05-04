// =============================================================
// cpu_top.v — 5 级流水线 CPU 顶层（阶段 3：Forwarding + Load-use Stall）
//
// 结构：
//   IF  : PC + IMEM 取指
//   ID  : 译码 + 读寄存器 + 立即数生成 + 冲突检测
//   EX  : ALU 计算 + 前递 + 分支/跳转解析
//   MEM : 数据存储器访问
//   WB  : 写回寄存器堆
//
// 本阶段策略：
//   - EX/MEM、MEM/WB 结果前递到 EX 的 ALU 与分支比较器
//   - Load-use 冒险：在 ID 检测到后 stall 一个周期
//     · 冻结 PC、冻结 IF/ID、ID/EX 注入气泡
//   - 分支/跳转在 EX 解析，taken 时刷新 IF/ID 与 ID/EX
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
    // EX/MEM
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
    // MEM/WB
    reg [31:0] mem_wb_pc;
    reg [31:0] mem_wb_instr;
    reg [31:0] mem_wb_alu_y;
    reg [31:0] mem_wb_load;
    reg [4:0]  mem_wb_rd;
    reg        mem_wb_reg_write;
    reg [1:0]  mem_wb_wb_sel;
    reg        mem_wb_valid;

    // 最小 CSR 集合（阶段 5）
    reg [31:0] csr_mtvec;
    reg [31:0] csr_mepc;
    reg [31:0] csr_mcause;
    localparam [31:0] RESET_MTVEC = 32'h00000080;

    // ---------------- IF ----------------
    reg  [31:0] pc;
    wire [31:0] pc_plus4 = pc + 32'd4;

    // 来自 EX 的重定向
    wire        ex_redirect;
    wire [31:0] ex_redirect_pc;

    // 来自 ID 的 stall
    wire        stall;

    wire [31:0] imem_rdata;

    imem #(.HEX_FILE(`PROG_HEX)) u_imem (
        .clk   (clk),
        .addr  (pc),
        .rdata (imem_rdata)
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

    // PC 选择：刷新 > stall > 预测 > PC+4
    wire [31:0] pc_next_seq = bpu_pred_taken ? bpu_pred_target : pc_plus4;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)            pc <= `RESET_PC;
        else if (ex_redirect)  pc <= ex_redirect_pc;
        else if (stall)        pc <= pc;          // 冻结 PC
        else                   pc <= pc_next_seq;
    end

    // IF/ID 流水线寄存器
    reg [31:0] if_id_pc;
    reg [31:0] if_id_instr;
    reg        if_id_valid;
    reg        if_id_pred_taken;
    reg [31:0] if_id_pred_target;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            if_id_pc          <= 32'b0;
            if_id_instr       <= 32'h00000013; // NOP
            if_id_valid       <= 1'b0;
            if_id_pred_taken  <= 1'b0;
            if_id_pred_target <= 32'b0;
        end else if (ex_redirect) begin
            // 刷新 IF/ID（注入气泡）
            if_id_pc          <= 32'b0;
            if_id_instr       <= 32'h00000013;
            if_id_valid       <= 1'b0;
            if_id_pred_taken  <= 1'b0;
            if_id_pred_target <= 32'b0;
        end else if (stall) begin
            // 冻结 IF/ID：保持当前值
            if_id_pc          <= if_id_pc;
            if_id_instr       <= if_id_instr;
            if_id_valid       <= if_id_valid;
            if_id_pred_taken  <= if_id_pred_taken;
            if_id_pred_target <= if_id_pred_target;
        end else begin
            if_id_pc          <= pc;
            if_id_instr       <= imem_rdata;
            if_id_valid       <= 1'b1;
            if_id_pred_taken  <= bpu_pred_taken;
            if_id_pred_target <= bpu_pred_target;
        end
    end

    // ---------------- ID ----------------
    wire [31:0] id_instr = if_id_instr;
    wire [4:0]  id_rs1   = id_instr[19:15];
    wire [4:0]  id_rs2   = id_instr[24:20];
    wire [4:0]  id_rd    = id_instr[11:7];

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

    // 寄存器堆（写口接到 WB）
    wire        wb_we;
    wire [4:0]  wb_rd;
    wire [31:0] wb_data;

    wire [31:0] id_rs1_data, id_rs2_data;
    regfile u_rf (
        .clk      (clk),
        .rst_n    (rst_n),
        .rs1_addr (id_rs1),
        .rs2_addr (id_rs2),
        .rs1_data (id_rs1_data),
        .rs2_data (id_rs2_data),
        .we       (wb_we),
        .rd_addr  (wb_rd),
        .rd_data  (wb_data)
    );

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

    // 冒险检测（load-use）
    hazard u_hazard (
        .id_ex_mem_read (id_ex_mem_read),
        .id_ex_rd       (id_ex_rd),
        .id_rs1         (id_rs1),
        .id_rs2         (id_rs2),
        .stall          (stall)
    );

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
            id_ex_pc          <= if_id_pc;
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
            id_ex_valid       <= if_id_valid;
            id_ex_is_ecall    <= id_is_ecall;
            id_ex_is_mret     <= id_is_mret;
            id_ex_is_illegal  <= id_is_illegal;
            id_ex_pred_taken  <= if_id_pred_taken;
            id_ex_pred_target <= if_id_pred_target;
        end
    end

    // ---------------- EX ----------------
    // 前递选择
    wire [1:0] fwd_a, fwd_b;
    forwarding u_fwd (
        .id_ex_rs1        (id_ex_rs1_addr),
        .id_ex_rs2        (id_ex_rs2_addr),
        .ex_mem_reg_write (ex_mem_reg_write & ex_mem_valid),
        .ex_mem_rd        (ex_mem_rd),
        .mem_wb_reg_write (mem_wb_reg_write & mem_wb_valid),
        .mem_wb_rd        (mem_wb_rd),
        .fwd_a            (fwd_a),
        .fwd_b            (fwd_b)
    );

    // 前递后的 rs1/rs2（这是“逐表达式中的真实寄存器值”）
    wire [31:0] ex_rs1_fwd =
        (fwd_a == 2'b01) ? ex_mem_alu_y :
        (fwd_a == 2'b10) ? wb_data      :
                           id_ex_rs1;
    wire [31:0] ex_rs2_fwd =
        (fwd_b == 2'b01) ? ex_mem_alu_y :
        (fwd_b == 2'b10) ? wb_data      :
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

    // EX/MEM 流水线寄存器（声明在顶部）
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
        end
    end

    // ---------------- MEM ----------------
    // 字节使能 + 写数据按对齐放置
    reg  [3:0]  mem_be;
    reg  [31:0] mem_wdata_aligned;
    wire [1:0]  mem_byte_off = ex_mem_alu_y[1:0];

    always @(*) begin
        mem_be            = 4'b0000;
        mem_wdata_aligned = 32'b0;
        case (ex_mem_mem_funct3)
            3'b000: begin // SB
                case (mem_byte_off)
                    2'd0: begin mem_be = 4'b0001; mem_wdata_aligned = {24'b0, ex_mem_rs2[7:0]}; end
                    2'd1: begin mem_be = 4'b0010; mem_wdata_aligned = {16'b0, ex_mem_rs2[7:0], 8'b0}; end
                    2'd2: begin mem_be = 4'b0100; mem_wdata_aligned = {8'b0, ex_mem_rs2[7:0], 16'b0}; end
                    2'd3: begin mem_be = 4'b1000; mem_wdata_aligned = {ex_mem_rs2[7:0], 24'b0}; end
                endcase
            end
            3'b001: begin // SH
                if (mem_byte_off == 2'd0) begin
                    mem_be = 4'b0011; mem_wdata_aligned = {16'b0, ex_mem_rs2[15:0]};
                end else begin
                    mem_be = 4'b1100; mem_wdata_aligned = {ex_mem_rs2[15:0], 16'b0};
                end
            end
            3'b010: begin // SW
                mem_be = 4'b1111; mem_wdata_aligned = ex_mem_rs2;
            end
            default: ;
        endcase
    end

    wire [31:0] dmem_rdata;
    dmem u_dmem (
        .clk   (clk),
        .addr  (ex_mem_alu_y),
        .we    (ex_mem_mem_write & ex_mem_valid),
        .be    (mem_be),
        .wdata (mem_wdata_aligned),
        .rdata (dmem_rdata)
    );

    // load 数据按宽度/符号扩展
    reg [31:0] mem_load_data;
    always @(*) begin
        case (ex_mem_mem_funct3)
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
        end else begin
            mem_wb_pc        <= ex_mem_pc;
            mem_wb_instr     <= ex_mem_instr;
            mem_wb_alu_y     <= ex_mem_alu_y;
            mem_wb_load      <= mem_load_data;
            mem_wb_rd        <= ex_mem_rd;
            mem_wb_reg_write <= ex_mem_reg_write;
            mem_wb_wb_sel    <= ex_mem_wb_sel;
            mem_wb_valid     <= ex_mem_valid;
        end
    end

    // ---------------- WB ----------------
    assign wb_rd   = mem_wb_rd;
    assign wb_we   = mem_wb_reg_write & mem_wb_valid;
    assign wb_data = (mem_wb_wb_sel == `WB_MEM) ? mem_wb_load : mem_wb_alu_y;

    // ---------------- Debug ----------------
    assign dbg_pc       = pc;
    assign dbg_instr_wb = mem_wb_instr;
    assign dbg_wb_we    = wb_we;
    assign dbg_wb_rd    = wb_rd;
    assign dbg_wb_data  = wb_data;

endmodule
