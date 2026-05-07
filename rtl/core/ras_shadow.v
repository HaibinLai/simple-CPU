// ras_shadow.v — Phase A2-step1: shadow Return Address Stack (observability)
//
// Quantifies what a RAS would buy us before adding it to the BPU path.
// Driven by EX-stage retired jumps; never affects PC.
//
// Classification (RISC-V calling conv, simple heuristic):
//   call : (JAL or JALR) with rd in {x1, x5}
//   ret  : JALR with rs1 in {x1, x5} AND rd not in {x1, x5}
//   other: rest
//
// On every retired jump:
//   - call : push(pc + 4)
//   - ret  : check actual_target == top; pop
//   - other: do nothing
//
// Counters:
//   jal_count                 : total JAL retired
//   jalr_count                : total JALR retired
//   call_count                : pushes (link writes)
//   ret_count                 : returns (link reads, not call)
//   ret_pred_correct          : RAS top == actual target on rets
//   ret_pred_wrong            : RAS top != actual target (or stack empty)
//   bpu_pred_correct_on_ret   : existing BPU prediction matched on rets
//   stack_underflow / overflow

`include "defines.v"

module ras_shadow #(
    parameter DEPTH = 16
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        flush,        // mispredict flush (do not pop on flushed insns)

    // EX-stage event: a uncond-jump (JAL/JALR) is retiring this cycle
    input  wire        jmp_valid,
    input  wire        jmp_is_jalr,  // 0=JAL, 1=JALR
    input  wire [4:0]  jmp_rd,
    input  wire [4:0]  jmp_rs1,      // only meaningful if JALR
    input  wire [31:0] jmp_pc,       // PC of the jump itself
    input  wire [31:0] jmp_actual_target,
    input  wire [31:0] jmp_pred_target, // what BPU said
    input  wire        jmp_pred_taken,

    output reg [31:0] jal_count,
    output reg [31:0] jalr_count,
    output reg [31:0] call_count,
    output reg [31:0] ret_count,
    output reg [31:0] ret_pred_correct,
    output reg [31:0] ret_pred_wrong,
    output reg [31:0] bpu_pred_correct_on_ret,
    output reg [31:0] stack_underflow,
    output reg [31:0] stack_overflow
);

    localparam AW = $clog2(DEPTH);

    reg [31:0] stack [0:DEPTH-1];
    reg [AW:0] sp;        // points to next free slot; 0 == empty
    integer    i;

    wire is_link_rd  = (jmp_rd  == 5'd1) || (jmp_rd  == 5'd5);
    wire is_link_rs1 = (jmp_rs1 == 5'd1) || (jmp_rs1 == 5'd5);

    wire is_call = jmp_valid && is_link_rd;
    wire is_ret  = jmp_valid && jmp_is_jalr && is_link_rs1 && !is_link_rd;

    // RAS prediction = top-of-stack (if non-empty)
    wire        ras_valid = (sp != 0);
    wire [31:0] ras_top   = ras_valid ? stack[sp - 1'b1] : 32'b0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sp <= {(AW+1){1'b0}};
            for (i = 0; i < DEPTH; i = i + 1) stack[i] <= 32'b0;
            jal_count               <= 32'b0;
            jalr_count              <= 32'b0;
            call_count              <= 32'b0;
            ret_count               <= 32'b0;
            ret_pred_correct        <= 32'b0;
            ret_pred_wrong          <= 32'b0;
            bpu_pred_correct_on_ret <= 32'b0;
            stack_underflow         <= 32'b0;
            stack_overflow          <= 32'b0;
        end else begin
            // counters
            if (jmp_valid && !jmp_is_jalr) jal_count  <= jal_count  + 32'd1;
            if (jmp_valid &&  jmp_is_jalr) jalr_count <= jalr_count + 32'd1;
            if (is_call)                   call_count <= call_count + 32'd1;
            if (is_ret) begin
                ret_count <= ret_count + 32'd1;
                if (ras_valid && ras_top == jmp_actual_target)
                    ret_pred_correct <= ret_pred_correct + 32'd1;
                else
                    ret_pred_wrong   <= ret_pred_wrong   + 32'd1;
                if (jmp_pred_taken && jmp_pred_target == jmp_actual_target)
                    bpu_pred_correct_on_ret <= bpu_pred_correct_on_ret + 32'd1;
            end

            // stack update — call wins if both somehow set (shouldn't on same insn)
            if (is_call) begin
                if (sp == DEPTH[AW:0]) begin
                    // overflow: drop oldest by shifting
                    stack_overflow <= stack_overflow + 32'd1;
                    for (i = 0; i < DEPTH-1; i = i + 1) stack[i] <= stack[i+1];
                    stack[DEPTH-1] <= jmp_pc + 32'd4;
                end else begin
                    stack[sp] <= jmp_pc + 32'd4;
                    sp <= sp + 1'b1;
                end
            end else if (is_ret) begin
                if (sp == 0)
                    stack_underflow <= stack_underflow + 32'd1;
                else
                    sp <= sp - 1'b1;
            end
        end
    end

endmodule
