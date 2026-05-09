// =============================================================
// forwarding.v — EX 阶段操作数前递（OoO Stage 3: ptag-based）
//
// OoO 改造：操作数比较从 5-bit arch reg id 改为 6-bit physical tag。
// 同一架构寄存器的多次 in-flight 写各自有不同 ptag，arch-id 比较会
// 把不该 forward 的旧值/新值取错；ptag 比较则按生产者-消费者一一对应。
//
// 选择信号编码：
//   2'b00 : 用 baseline (PRF[rs_ptag] 提供，调用方决定)
//   2'b01 : 来自 EX/MEM 的 ALU 结果
//   2'b10 : 来自 EX2/AGU 的 ALU 结果
//   2'b11 : 来自 AGU/MEM 或 MEM/WB 的数据（由顶层按 ptag 匹配细分）
//
// 优先级：EX/MEM > EX2/AGU > AGU/MEM > MEM/WB（更新者优先）
// =============================================================
module forwarding (
    input  wire [5:0] id_ex_rs1_ptag,
    input  wire [5:0] id_ex_rs2_ptag,

    input  wire       ex_mem_reg_write,
    input  wire [5:0] ex_mem_rd_ptag,

    input  wire       ex2_agu_reg_write,
    input  wire [5:0] ex2_agu_rd_ptag,

    input  wire       agu_mem_reg_write,
    input  wire [5:0] agu_mem_rd_ptag,

    input  wire       mem_wb_reg_write,
    input  wire [5:0] mem_wb_rd_ptag,

    output reg  [1:0] fwd_a,
    output reg  [1:0] fwd_b
);
    always @(*) begin
        // rs1
        if (ex_mem_reg_write && ex_mem_rd_ptag != 6'd0 && ex_mem_rd_ptag == id_ex_rs1_ptag)
            fwd_a = 2'b01;
        else if (ex2_agu_reg_write && ex2_agu_rd_ptag != 6'd0 && ex2_agu_rd_ptag == id_ex_rs1_ptag)
            fwd_a = 2'b10;
        else if ((agu_mem_reg_write && agu_mem_rd_ptag != 6'd0 && agu_mem_rd_ptag == id_ex_rs1_ptag) ||
                 (mem_wb_reg_write  && mem_wb_rd_ptag  != 6'd0 && mem_wb_rd_ptag  == id_ex_rs1_ptag))
            fwd_a = 2'b11;
        else
            fwd_a = 2'b00;

        // rs2
        if (ex_mem_reg_write && ex_mem_rd_ptag != 6'd0 && ex_mem_rd_ptag == id_ex_rs2_ptag)
            fwd_b = 2'b01;
        else if (ex2_agu_reg_write && ex2_agu_rd_ptag != 6'd0 && ex2_agu_rd_ptag == id_ex_rs2_ptag)
            fwd_b = 2'b10;
        else if ((agu_mem_reg_write && agu_mem_rd_ptag != 6'd0 && agu_mem_rd_ptag == id_ex_rs2_ptag) ||
                 (mem_wb_reg_write  && mem_wb_rd_ptag  != 6'd0 && mem_wb_rd_ptag  == id_ex_rs2_ptag))
            fwd_b = 2'b11;
        else
            fwd_b = 2'b00;
    end
endmodule
