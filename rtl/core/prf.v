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
    output wire [31:0]   rd0,
    output wire [31:0]   rd1,
    output wire [31:0]   rd2,
    output wire [31:0]   rd3
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

    assign rd0 = regs[ra0];
    assign rd1 = regs[ra1];
    assign rd2 = regs[ra2];
    assign rd3 = regs[ra3];

endmodule
