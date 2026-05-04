// =============================================================
// forwarding.v — EX 阶段操作数前递
//
// 选择信号编码：
//   2'b00 : 用 ID/EX 的寄存器值（无前递）
//   2'b01 : 来自 EX/MEM 的 ALU 结果
//   2'b10 : 来自 MEM/WB 的写回数据（mem load 或 alu）
//
// 优先级：EX/MEM > MEM/WB（更新者优先）
// =============================================================
module forwarding (
    input  wire [4:0] id_ex_rs1,
    input  wire [4:0] id_ex_rs2,

    input  wire       ex_mem_reg_write,
    input  wire [4:0] ex_mem_rd,

    input  wire       mem_wb_reg_write,
    input  wire [4:0] mem_wb_rd,

    output reg  [1:0] fwd_a,
    output reg  [1:0] fwd_b
);
    always @(*) begin
        // rs1
        if (ex_mem_reg_write && ex_mem_rd != 5'd0 && ex_mem_rd == id_ex_rs1)
            fwd_a = 2'b01;
        else if (mem_wb_reg_write && mem_wb_rd != 5'd0 && mem_wb_rd == id_ex_rs1)
            fwd_a = 2'b10;
        else
            fwd_a = 2'b00;

        // rs2
        if (ex_mem_reg_write && ex_mem_rd != 5'd0 && ex_mem_rd == id_ex_rs2)
            fwd_b = 2'b01;
        else if (mem_wb_reg_write && mem_wb_rd != 5'd0 && mem_wb_rd == id_ex_rs2)
            fwd_b = 2'b10;
        else
            fwd_b = 2'b00;
    end
endmodule
