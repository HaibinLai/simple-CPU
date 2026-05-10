`include "defines.v"

module prf #(
    parameter DEPTH = 48,
    parameter AW    = 6
) (
    input  wire          clk,
    input  wire          rst_n,
    input  wire          we0,
    input  wire [AW-1:0] wa0,
    input  wire [31:0]   wd0,
    input  wire          we1,
    input  wire [AW-1:0] wa1,
    input  wire [31:0]   wd1,
    // M3.4d: commit-time writes to architectural slots (ptag 0..31)
    input  wire          we2,
    input  wire [AW-1:0] wa2,
    input  wire [31:0]   wd2,
    input  wire          we3,
    input  wire [AW-1:0] wa3,
    input  wire [31:0]   wd3,
    input  wire [AW-1:0] ra0,
    input  wire [AW-1:0] ra1,
    input  wire [AW-1:0] ra2,
    input  wire [AW-1:0] ra3,
    // T2b-step1: extra read ports for RS dispatch operand capture (ra4/ra5)
    input  wire [AW-1:0] ra4,
    input  wire [AW-1:0] ra5,
    output wire [31:0]   rd0,
    output wire [31:0]   rd1,
    output wire [31:0]   rd2,
    output wire [31:0]   rd3,
    output wire [31:0]   rd4,
    output wire [31:0]   rd5
);

    reg [31:0] regs [0:DEPTH-1];
    integer i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < DEPTH; i = i + 1)
                regs[i] <= 32'b0;
        end else begin
            if (we0) regs[wa0] <= wd0;
            if (we1) regs[wa1] <= wd1;
            // commit-port writes overlap with WB port ordering; later port wins on same addr
            if (we2) regs[wa2] <= wd2;
            if (we3) regs[wa3] <= wd3;
        end
    end

    // 写旁路（同周期写值在读口可见）。
    // 注意 we1 (slot1 EX1) 的 wd1 由 prf_r2/r3 间接计算（slot1 操作数）；任何
    // we1 → ra* 的旁路都可能经 slot1-forwarding-from-id_ex（slot1 用 slot0 同周期
    // EX 结果）形成组合环（prf_r0 → ex_alu_y → slot1_alu_y → wd1 → prf_r0）。
    // 因此 **we1 不参与任何旁路**；slot1 是 slot0 的 younger，不会被 slot0 同周期消费，
    // 而 slot1 自己的同周期写也不会被自己读。
    // we0 (slot0 WB) / we2/we3 (commit) 的 wd 均来自寄存器化的流水线结果，
    // 不依赖 PRF 读，旁路安全。
    // 优先级：we3 > we2 > we0。
    assign rd0 = (we3 && (wa3 == ra0)) ? wd3 :
                 (we2 && (wa2 == ra0)) ? wd2 :
                 (we0 && (wa0 == ra0)) ? wd0 : regs[ra0];
    assign rd1 = (we3 && (wa3 == ra1)) ? wd3 :
                 (we2 && (wa2 == ra1)) ? wd2 :
                 (we0 && (wa0 == ra1)) ? wd0 : regs[ra1];
    assign rd2 = (we3 && (wa3 == ra2)) ? wd3 :
                 (we2 && (wa2 == ra2)) ? wd2 :
                 (we0 && (wa0 == ra2)) ? wd0 : regs[ra2];
    assign rd3 = (we3 && (wa3 == ra3)) ? wd3 :
                 (we2 && (wa2 == ra3)) ? wd2 :
                 (we0 && (wa0 == ra3)) ? wd0 : regs[ra3];
    // T2b-step1: ra4/ra5 use the same write-bypass priority (we3 > we2 > we0).
    // we1 still excluded to avoid the slot1-EX combinational loop.
    assign rd4 = (we3 && (wa3 == ra4)) ? wd3 :
                 (we2 && (wa2 == ra4)) ? wd2 :
                 (we0 && (wa0 == ra4)) ? wd0 : regs[ra4];
    assign rd5 = (we3 && (wa3 == ra5)) ? wd3 :
                 (we2 && (wa2 == ra5)) ? wd2 :
                 (we0 && (wa0 == ra5)) ? wd0 : regs[ra5];

endmodule
