// =============================================================
// regfile.v — 32×32 通用寄存器堆（4R2W 版本）
// 
// 读取：组合逻辑，同周期可读到旧值（WB 阶段才写入）
// 写入：时钟上升沿
//   - we0 + rd0_addr + rd0_data：slot0 写端口（通常来自 MEM/WB）
//   - we1 + rd1_addr + rd1_data：slot1 写端口（直接来自 EX，ALU-only）
//   - 如果两个端口写同一个地址，rd1 端口优先（较新的操作）
// 
// 写优先旁路：读地址 == 写地址 && we=1 时，直接给出新值
// x0 恒为 0
// =============================================================
`include "defines.v"

module regfile (
    input  wire              clk,
    input  wire              rst_n,

    // 4 read ports
    input  wire [4:0]        rs1_addr,
    input  wire [4:0]        rs2_addr,
    input  wire [4:0]        rs3_addr,  // Slot1 rs1
    input  wire [4:0]        rs4_addr,  // Slot1 rs2
    output wire [`XLEN-1:0]  rs1_data,
    output wire [`XLEN-1:0]  rs2_data,
    output wire [`XLEN-1:0]  rs3_data,
    output wire [`XLEN-1:0]  rs4_data,

    // 2 write ports
    input  wire              we0,        // Slot0 write enable (MEM/WB)
    input  wire [4:0]        rd0_addr,
    input  wire [`XLEN-1:0]  rd0_data,

    input  wire              we1,        // Slot1 write enable (direct from EX)
    input  wire [4:0]        rd1_addr,
    input  wire [`XLEN-1:0]  rd1_data
);
    reg [`XLEN-1:0] regs [0:31];
    integer i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < 32; i = i + 1) regs[i] <= 32'b0;
        end else begin
            // Write port 0 (slot0 from WB)
            if (we0 && rd0_addr != 5'd0) begin
                regs[rd0_addr] <= rd0_data;
            end
            
            // Write port 1 (slot1 direct from EX)
            // If both ports write same address, port 1 wins
            if (we1 && rd1_addr != 5'd0) begin
                regs[rd1_addr] <= rd1_data;
            end
        end
    end

    // Read port 1 (slot0 rs1)
    assign rs1_data = (rs1_addr == 5'd0) ? 32'b0 :
                      (we1 && (rd1_addr == rs1_addr)) ? rd1_data :
                      (we0 && (rd0_addr == rs1_addr)) ? rd0_data : regs[rs1_addr];
    
    // Read port 2 (slot0 rs2)
    assign rs2_data = (rs2_addr == 5'd0) ? 32'b0 :
                      (we1 && (rd1_addr == rs2_addr)) ? rd1_data :
                      (we0 && (rd0_addr == rs2_addr)) ? rd0_data : regs[rs2_addr];
    
    // Read port 3 (slot1 rs1)
    assign rs3_data = (rs3_addr == 5'd0) ? 32'b0 :
                      (we1 && (rd1_addr == rs3_addr)) ? rd1_data :
                      (we0 && (rd0_addr == rs3_addr)) ? rd0_data : regs[rs3_addr];
    
    // Read port 4 (slot1 rs2)
    assign rs4_data = (rs4_addr == 5'd0) ? 32'b0 :
                      (we1 && (rd1_addr == rs4_addr)) ? rd1_data :
                      (we0 && (rd0_addr == rs4_addr)) ? rd0_data : regs[rs4_addr];
endmodule
