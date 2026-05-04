// =============================================================
// forwarding.v — EX 阶段操作数前递
//
// 选择信号编码：
//   2'b00 : 用 ID/EX 的寄存器值（无前递）
//   2'b01 : 来自 EX/MEM 的 ALU 结果
//   2'b10 : 来自 EX2/AGU 的 ALU 结果
//   2'b11 : 来自 AGU/MEM 或 MEM/WB 的数据（由顶层按 rd 匹配细分）
//
// 优先级：EX/MEM > EX2/AGU > AGU/MEM > MEM/WB（更新者优先）
// =============================================================
module forwarding (
    input  wire [4:0] id_ex_rs1,
    input  wire [4:0] id_ex_rs2,

    input  wire       ex_mem_reg_write,
    input  wire [4:0] ex_mem_rd,

    input  wire       ex2_agu_reg_write,
    input  wire [4:0] ex2_agu_rd,

    input  wire       agu_mem_reg_write,
    input  wire [4:0] agu_mem_rd,

    input  wire       mem_wb_reg_write,
    input  wire [4:0] mem_wb_rd,

    output reg  [1:0] fwd_a,
    output reg  [1:0] fwd_b
);
    always @(*) begin
        // rs1
        if (ex_mem_reg_write && ex_mem_rd != 5'd0 && ex_mem_rd == id_ex_rs1)
            fwd_a = 2'b01;
        else if (ex2_agu_reg_write && ex2_agu_rd != 5'd0 && ex2_agu_rd == id_ex_rs1)
            fwd_a = 2'b10;
        else if ((agu_mem_reg_write && agu_mem_rd != 5'd0 && agu_mem_rd == id_ex_rs1) ||
                 (mem_wb_reg_write && mem_wb_rd != 5'd0 && mem_wb_rd == id_ex_rs1))
            fwd_a = 2'b11;
        else
            fwd_a = 2'b00;

        // rs2
        if (ex_mem_reg_write && ex_mem_rd != 5'd0 && ex_mem_rd == id_ex_rs2)
            fwd_b = 2'b01;
        else if (ex2_agu_reg_write && ex2_agu_rd != 5'd0 && ex2_agu_rd == id_ex_rs2)
            fwd_b = 2'b10;
        else if ((agu_mem_reg_write && agu_mem_rd != 5'd0 && agu_mem_rd == id_ex_rs2) ||
                 (mem_wb_reg_write && mem_wb_rd != 5'd0 && mem_wb_rd == id_ex_rs2))
            fwd_b = 2'b11;
        else
            fwd_b = 2'b00;
    end
endmodule
