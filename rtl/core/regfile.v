// =============================================================
// regfile.v — 32×32 通用寄存器堆
// 写在时钟上升沿；读为组合逻辑（同周期可读到旧值，写在 WB 阶段）
// 内置 "写优先" 旁路：当读地址 == 写地址 且 we=1 时直接给出新值，
// 这样即使没有 forwarding，相邻指令通过 regfile 也只需要一个气泡。
// =============================================================
`include "defines.v"

module regfile (
    input  wire              clk,
    input  wire              rst_n,

    input  wire [4:0]        rs1_addr,
    input  wire [4:0]        rs2_addr,
    output wire [`XLEN-1:0]  rs1_data,
    output wire [`XLEN-1:0]  rs2_data,

    input  wire              we,
    input  wire [4:0]        rd_addr,
    input  wire [`XLEN-1:0]  rd_data
);
    reg [`XLEN-1:0] regs [0:31];
    integer i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < 32; i = i + 1) regs[i] <= 32'b0;
        end else if (we && rd_addr != 5'd0) begin
            regs[rd_addr] <= rd_data;
        end
    end

    // x0 恒为 0；写优先旁路
    assign rs1_data = (rs1_addr == 5'd0) ? 32'b0 :
                      (we && (rd_addr == rs1_addr)) ? rd_data : regs[rs1_addr];
    assign rs2_data = (rs2_addr == 5'd0) ? 32'b0 :
                      (we && (rd_addr == rs2_addr)) ? rd_data : regs[rs2_addr];
endmodule
