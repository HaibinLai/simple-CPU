// =============================================================
// defines.v — 全局参数与编码
// =============================================================
`ifndef CPU20_DEFINES_V
`define CPU20_DEFINES_V

`define XLEN          32
`define RESET_PC      32'h0000_0000

// ---------- Opcodes (RV32I) ----------
`define OP_LUI        7'b0110111
`define OP_AUIPC      7'b0010111
`define OP_JAL        7'b1101111
`define OP_JALR       7'b1100111
`define OP_BRANCH     7'b1100011
`define OP_LOAD       7'b0000011
`define OP_STORE      7'b0100011
`define OP_IMM        7'b0010011
`define OP_REG        7'b0110011
`define OP_SYSTEM     7'b1110011

// ---------- ALU ops (内部编码) ----------
`define ALU_ADD       4'd0
`define ALU_SUB       4'd1
`define ALU_AND       4'd2
`define ALU_OR        4'd3
`define ALU_XOR       4'd4
`define ALU_SLL       4'd5
`define ALU_SRL       4'd6
`define ALU_SRA       4'd7
`define ALU_SLT       4'd8
`define ALU_SLTU      4'd9
`define ALU_BPASS     4'd10  // 直接传递 B 操作数（用于 LUI）

// ---------- 立即数类型 ----------
`define IMM_I         3'd0
`define IMM_S         3'd1
`define IMM_B         3'd2
`define IMM_U         3'd3
`define IMM_J         3'd4
`define IMM_NONE      3'd7

// ---------- 分支类型 ----------
`define BR_NONE       3'd0
`define BR_BEQ        3'd1
`define BR_BNE        3'd2
`define BR_BLT        3'd3
`define BR_BGE        3'd4
`define BR_BLTU       3'd5
`define BR_BGEU       3'd6
`define BR_JAL        3'd7   // 无条件 (JAL/JALR 用 jump 标志另行区分)

// ---------- 访存宽度（funct3 直传也可，这里独立编码避免歧义） ----------
`define MEM_B         3'd0  // funct3 = 000 / 100
`define MEM_H         3'd1  // funct3 = 001 / 101
`define MEM_W         3'd2  // funct3 = 010

// ---------- ALU 源选择 ----------
`define ASRC_RS1      1'b0
`define ASRC_PC       1'b1

`define BSRC_RS2      1'b0
`define BSRC_IMM      1'b1

// ---------- 写回数据来源 ----------
`define WB_ALU        2'd0
`define WB_MEM        2'd1
`define WB_PC4        2'd2  // JAL/JALR 写 PC+4

`endif
