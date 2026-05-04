// =============================================================
// ifq.v — Issue Fetch Queue (4-entry FIFO)
//
// Replaces the ID1/ID2 pipeline register stage. Decouples the dual-slot
// front-end fetch bandwidth from the back-end issue bandwidth.
//
// Push: 0/1/2 entries per cycle from IF/ID1 (slot0 + slot1)
// Pop:  1 entry per cycle for single-issue (Phase R1)
//       2 entries per cycle for dual-issue (Phase R2; future)
//
// Entry layout:
//   pc           : 32-bit instruction PC
//   instr        : 32-bit raw instruction word
//   pred_taken   : branch prediction at the slot's PC
//   pred_target  : predicted branch target (if taken)
//
// Backpressure:
//   full         : queue has no free slots; IF must stall completely
//   almost_full  : queue has only 1 free slot; can accept at most 1 push
//
// Flush:
//   On `flush` (e.g., ex_redirect / branch mispredict), drop all entries.
// =============================================================
`include "defines.v"

module ifq #(
    parameter DEPTH = 4,           // queue depth (must be power of 2)
    parameter AW    = 2            // log2(DEPTH)
) (
    input  wire clk,
    input  wire rst_n,
    input  wire flush,

    // Push side (from IF/ID1) — up to 2 entries per cycle
    input  wire        push_valid_0,
    input  wire [31:0] push_pc_0,
    input  wire [31:0] push_instr_0,
    input  wire        push_pred_taken_0,
    input  wire [31:0] push_pred_target_0,

    input  wire        push_valid_1,
    input  wire [31:0] push_pc_1,
    input  wire [31:0] push_instr_1,
    input  wire        push_pred_taken_1,
    input  wire [31:0] push_pred_target_1,

    output wire        full,
    output wire        almost_full,    // free <= 1, cannot accept 2 pushes

    // Pop side (to ID2 decode) — 1 entry per cycle (Phase R1)
    input  wire        pop,
    output wire        head_valid,
    output wire [31:0] head_pc,
    output wire [31:0] head_instr,
    output wire        head_pred_taken,
    output wire [31:0] head_pred_target,

    // Phase R2 (future): second-head visibility for dual-issue
    output wire        head2_valid,
    output wire [31:0] head2_pc,
    output wire [31:0] head2_instr,
    output wire        head2_pred_taken,
    output wire [31:0] head2_pred_target,
    input  wire        pop2,           // pop a second entry (Phase R2)

    // Diagnostics
    output wire [AW:0] count            // number of valid entries (0..DEPTH)
);

    // ---- Storage ----
    reg [31:0] pc_q          [0:DEPTH-1];
    reg [31:0] instr_q       [0:DEPTH-1];
    reg        pred_taken_q  [0:DEPTH-1];
    reg [31:0] pred_target_q [0:DEPTH-1];
    reg        valid_q       [0:DEPTH-1];

    // ---- Pointers ----
    reg [AW-1:0] head_ptr;
    reg [AW-1:0] tail_ptr;
    reg [AW:0]   cnt;          // 0..DEPTH

    assign count       = cnt;
    assign full        = (cnt == DEPTH);
    assign almost_full = (cnt >= DEPTH - 1);

    // ---- Pop view ----
    assign head_valid       = (cnt >= 1) && valid_q[head_ptr];
    assign head_pc          = pc_q[head_ptr];
    assign head_instr       = instr_q[head_ptr];
    assign head_pred_taken  = pred_taken_q[head_ptr];
    assign head_pred_target = pred_target_q[head_ptr];

    wire [AW-1:0] head2_idx = head_ptr + 1'b1;
    assign head2_valid       = (cnt >= 2) && valid_q[head2_idx];
    assign head2_pc          = pc_q[head2_idx];
    assign head2_instr       = instr_q[head2_idx];
    assign head2_pred_taken  = pred_taken_q[head2_idx];
    assign head2_pred_target = pred_target_q[head2_idx];

    // ---- How many pushes this cycle? ----
    wire actual_push_0 = push_valid_0 && (cnt + (pop ? -1 : 0) + (pop2 ? -1 : 0) < DEPTH);
    // Push 1 only if there's still room after push 0
    wire actual_push_1 = push_valid_1 && actual_push_0 &&
                         (cnt + (pop ? -1 : 0) + (pop2 ? -1 : 0) + 1 < DEPTH);

    // Note: When `flush` is high, we treat all pushes as dropped (queue cleared).
    wire do_push_0 = !flush && actual_push_0;
    wire do_push_1 = !flush && actual_push_1;
    wire do_pop_0  = !flush && pop  && head_valid;
    wire do_pop_1  = !flush && pop2 && head2_valid;

    // ---- Sequential update ----
    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            head_ptr <= {AW{1'b0}};
            tail_ptr <= {AW{1'b0}};
            cnt      <= {(AW+1){1'b0}};
            for (i = 0; i < DEPTH; i = i + 1) begin
                pc_q[i]          <= 32'b0;
                instr_q[i]       <= 32'h00000013;
                pred_taken_q[i]  <= 1'b0;
                pred_target_q[i] <= 32'b0;
                valid_q[i]       <= 1'b0;
            end
        end else if (flush) begin
            // Clear all entries
            head_ptr <= {AW{1'b0}};
            tail_ptr <= {AW{1'b0}};
            cnt      <= {(AW+1){1'b0}};
            for (i = 0; i < DEPTH; i = i + 1) begin
                valid_q[i] <= 1'b0;
            end
        end else begin
            // ---- Pops first (logical ordering) ----
            // Phase R1: only pop is used; pop2 ignored (input tied to 0)
            // (We model pop and pop2 generally for Phase R2 readiness.)
            if (do_pop_0) begin
                valid_q[head_ptr] <= 1'b0;
            end
            if (do_pop_1) begin
                valid_q[head2_idx] <= 1'b0;
            end

            // ---- Pushes ----
            if (do_push_0) begin
                pc_q[tail_ptr]          <= push_pc_0;
                instr_q[tail_ptr]       <= push_instr_0;
                pred_taken_q[tail_ptr]  <= push_pred_taken_0;
                pred_target_q[tail_ptr] <= push_pred_target_0;
                valid_q[tail_ptr]       <= 1'b1;
            end
            if (do_push_1) begin
                pc_q[tail_ptr + 1'b1]          <= push_pc_1;
                instr_q[tail_ptr + 1'b1]       <= push_instr_1;
                pred_taken_q[tail_ptr + 1'b1]  <= push_pred_taken_1;
                pred_target_q[tail_ptr + 1'b1] <= push_pred_target_1;
                valid_q[tail_ptr + 1'b1]       <= 1'b1;
            end

            // ---- Pointer / count updates ----
            head_ptr <= head_ptr + (do_pop_0 ? 1'b1 : 1'b0)
                                 + (do_pop_1 ? 1'b1 : 1'b0);
            tail_ptr <= tail_ptr + (do_push_0 ? 1'b1 : 1'b0)
                                 + (do_push_1 ? 1'b1 : 1'b0);

            cnt <= cnt
                   + (do_push_0 ? 1'b1 : 1'b0)
                   + (do_push_1 ? 1'b1 : 1'b0)
                   - (do_pop_0  ? 1'b1 : 1'b0)
                   - (do_pop_1  ? 1'b1 : 1'b0);
        end
    end

endmodule
