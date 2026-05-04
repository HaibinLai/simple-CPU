// =============================================================
// control.v — 主控译码（组合逻辑）
// 仅根据 opcode/funct3/funct7 产生控制信号；非法指令此处不报错。
// =============================================================
`include "defines.v"

module control (
    input  wire [31:0] instr,

    output reg  [2:0]  imm_type,
    output reg         a_src,        // ASRC_RS1 / ASRC_PC
    output reg         b_src,        // BSRC_RS2 / BSRC_IMM
    output reg  [3:0]  alu_op,
    output reg  [2:0]  br_type,
    output reg         is_jump,      // JAL / JALR
    output reg         mem_read,
    output reg         mem_write,
    output reg  [2:0]  mem_funct3,   // 直接用 funct3 决定宽度/符号扩展
    output reg         reg_write,
    output reg  [1:0]  wb_sel,
    output reg         is_ecall,
    output reg         is_mret,
    output reg         is_illegal
);
    wire [6:0] opcode = instr[6:0];
    wire [2:0] f3     = instr[14:12];
    wire [6:0] f7     = instr[31:25];

    always @(*) begin
        // 默认值
        imm_type   = `IMM_NONE;
        a_src      = `ASRC_RS1;
        b_src      = `BSRC_RS2;
        alu_op     = `ALU_ADD;
        br_type    = `BR_NONE;
        is_jump    = 1'b0;
        mem_read   = 1'b0;
        mem_write  = 1'b0;
        mem_funct3 = f3;
        reg_write  = 1'b0;
        wb_sel     = `WB_ALU;
        is_ecall   = 1'b0;
        is_mret    = 1'b0;
        is_illegal = 1'b0;

        case (opcode)
            `OP_LUI: begin
                imm_type  = `IMM_U;
                a_src     = `ASRC_RS1;     // rs1 取 x0 也可，这里用 BPASS
                b_src     = `BSRC_IMM;
                alu_op    = `ALU_BPASS;
                reg_write = 1'b1;
                wb_sel    = `WB_ALU;
            end
            `OP_AUIPC: begin
                imm_type  = `IMM_U;
                a_src     = `ASRC_PC;
                b_src     = `BSRC_IMM;
                alu_op    = `ALU_ADD;
                reg_write = 1'b1;
                wb_sel    = `WB_ALU;
            end
            `OP_JAL: begin
                imm_type  = `IMM_J;
                a_src     = `ASRC_PC;
                b_src     = `BSRC_IMM;
                alu_op    = `ALU_ADD;      // 计算目标地址
                br_type   = `BR_JAL;
                is_jump   = 1'b1;
                reg_write = 1'b1;
                wb_sel    = `WB_PC4;
            end
            `OP_JALR: begin
                imm_type  = `IMM_I;
                a_src     = `ASRC_RS1;
                b_src     = `BSRC_IMM;
                alu_op    = `ALU_ADD;
                br_type   = `BR_JAL;
                is_jump   = 1'b1;
                reg_write = 1'b1;
                wb_sel    = `WB_PC4;
            end
            `OP_BRANCH: begin
                imm_type  = `IMM_B;
                a_src     = `ASRC_RS1;
                b_src     = `BSRC_RS2;     // ALU 用于比较（这里直接走比较器）
                alu_op    = `ALU_SUB;      // 占位；EX 中由 br_type 决定真比较
                case (f3)
                    3'b000: br_type = `BR_BEQ;
                    3'b001: br_type = `BR_BNE;
                    3'b100: br_type = `BR_BLT;
                    3'b101: br_type = `BR_BGE;
                    3'b110: br_type = `BR_BLTU;
                    3'b111: br_type = `BR_BGEU;
                    default: br_type = `BR_NONE;
                endcase
                reg_write = 1'b0;
            end
            `OP_LOAD: begin
                imm_type  = `IMM_I;
                a_src     = `ASRC_RS1;
                b_src     = `BSRC_IMM;
                alu_op    = `ALU_ADD;
                mem_read  = 1'b1;
                reg_write = 1'b1;
                wb_sel    = `WB_MEM;
            end
            `OP_STORE: begin
                imm_type  = `IMM_S;
                a_src     = `ASRC_RS1;
                b_src     = `BSRC_IMM;
                alu_op    = `ALU_ADD;
                mem_write = 1'b1;
                reg_write = 1'b0;
            end
            `OP_IMM: begin
                imm_type  = `IMM_I;
                a_src     = `ASRC_RS1;
                b_src     = `BSRC_IMM;
                reg_write = 1'b1;
                case (f3)
                    3'b000: alu_op = `ALU_ADD;        // ADDI
                    3'b010: alu_op = `ALU_SLT;        // SLTI
                    3'b011: alu_op = `ALU_SLTU;       // SLTIU
                    3'b100: alu_op = `ALU_XOR;        // XORI
                    3'b110: alu_op = `ALU_OR;         // ORI
                    3'b111: alu_op = `ALU_AND;        // ANDI
                    3'b001: alu_op = `ALU_SLL;        // SLLI
                    3'b101: alu_op = (f7[5]) ? `ALU_SRA : `ALU_SRL; // SRAI/SRLI
                    default: alu_op = `ALU_ADD;
                endcase
            end
            `OP_REG: begin
                imm_type  = `IMM_NONE;
                a_src     = `ASRC_RS1;
                b_src     = `BSRC_RS2;
                reg_write = 1'b1;
                case (f3)
                    3'b000: alu_op = (f7[5]) ? `ALU_SUB : `ALU_ADD;
                    3'b001: alu_op = `ALU_SLL;
                    3'b010: alu_op = `ALU_SLT;
                    3'b011: alu_op = `ALU_SLTU;
                    3'b100: alu_op = `ALU_XOR;
                    3'b101: alu_op = (f7[5]) ? `ALU_SRA : `ALU_SRL;
                    3'b110: alu_op = `ALU_OR;
                    3'b111: alu_op = `ALU_AND;
                    default: alu_op = `ALU_ADD;
                endcase
            end
            `OP_SYSTEM: begin
                // 目前仅实现 ecall / mret
                if (instr == 32'h00000073) begin
                    is_ecall = 1'b1;
                end else if (instr == 32'h30200073) begin
                    is_mret  = 1'b1;
                end else begin
                    is_illegal = 1'b1;
                end
            end
            default: begin
                is_illegal = 1'b1;
            end
        endcase
    end
endmodule
