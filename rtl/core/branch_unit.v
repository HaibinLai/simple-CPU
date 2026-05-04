// =============================================================
// branch_unit.v — 分支条件判断（EX 阶段）
// =============================================================
`include "defines.v"

module branch_unit (
    input  wire [2:0]        br_type,
    input  wire              is_jump,
    input  wire [`XLEN-1:0]  rs1,
    input  wire [`XLEN-1:0]  rs2,
    output reg               taken
);
    always @(*) begin
        case (br_type)
            `BR_BEQ : taken = (rs1 == rs2);
            `BR_BNE : taken = (rs1 != rs2);
            `BR_BLT : taken = ($signed(rs1) <  $signed(rs2));
            `BR_BGE : taken = ($signed(rs1) >= $signed(rs2));
            `BR_BLTU: taken = (rs1 <  rs2);
            `BR_BGEU: taken = (rs1 >= rs2);
            `BR_JAL : taken = is_jump;     // JAL/JALR 总跳
            default : taken = 1'b0;
        endcase
    end
endmodule
