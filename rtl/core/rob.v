// =============================================================
// rob.v — Reorder Buffer (16 entries, 2 alloc / 2 wb / 2 commit per cycle)
//
// Stage M3.1: skeleton only. Instantiated by cpu_top but not wired into
//             the pipeline yet. Behaviour of the CPU must remain identical.
//
// Roles in later stages:
//   M3.2: allocate a tag for each issued instruction (slot0 / slot1)
//   M3.3: collect writeback results from EX / MEM (slot0) and EX1 (slot1),
//         then commit in-order to architectural state
//   M3.4: tag-based forwarding (rename + map table)
//   M3.5: speculative writeback (recover via flush on mispredict / exception)
//
// Entry layout:
//   valid       : entry occupied
//   done        : result is ready (writeback completed)
//   pc          : instruction PC (for exceptions / debug)
//   rd          : architectural destination register (5'd0 if no writeback)
//   reg_write   : true if this instruction writes a register
//   result      : 32-bit writeback value (ALU result or load data)
//   is_store    : memory store (commits at retire time)
//   store_addr  : store address (latched at EX/AGU)
//   store_data  : store data    (latched at EX/AGU)
//   store_be    : store byte enable
//   exception   : raised an exception
//   exc_cause   : RISC-V mcause value
//   is_branch   : conditional branch (for diagnostics)
//   br_taken    : actual taken (for BPU update at commit, currently unused
//                 because BPU update happens at EX in the existing design)
// =============================================================
`include "defines.v"

module rob #(
    parameter DEPTH = 16,
    parameter AW    = 4,
    parameter PTAG_W = 6
) (
    input  wire                 clk,
    input  wire                 rst_n,

    // Flush all in-flight entries (e.g. mispredict / exception redirect)
    input  wire                 flush,
    // M3.5-step2: partial flush — 仅清除 tag > flush_keep_tag 的条目
    // （在环形 head..tail 顺序上）。flush_partial=1 时优先于 flush。
    // flush_keep_valid 表示 flush_keep_tag 是否本身也被保留（为 0 时连同 keep_tag 也清除，
    // 用于异常场景）。平常 mispredict 使用 flush_keep_valid=1。
    input  wire                 flush_partial,
    input  wire [AW-1:0]        flush_keep_tag,
    input  wire                 flush_keep_valid,

    // ---- Allocate (dispatch) — up to 2 per cycle ----
    // alloc_valid_X must be 0 if no instruction is being dispatched.
    // Allocation order: alloc_0 first, alloc_1 second (slot0 must precede slot1).
    input  wire                 alloc_valid_0,
    input  wire [31:0]          alloc_pc_0,
    input  wire [4:0]           alloc_rd_0,
    input  wire                 alloc_reg_write_0,
    input  wire                 alloc_is_store_0,
    input  wire                 alloc_is_branch_0,
    input  wire [PTAG_W-1:0]    alloc_ptag_new_0,
    input  wire [PTAG_W-1:0]    alloc_ptag_old_0,
    output wire [AW-1:0]        alloc_tag_0,

    input  wire                 alloc_valid_1,
    input  wire [31:0]          alloc_pc_1,
    input  wire [4:0]           alloc_rd_1,
    input  wire                 alloc_reg_write_1,
    input  wire                 alloc_is_store_1,
    input  wire                 alloc_is_branch_1,
    input  wire [PTAG_W-1:0]    alloc_ptag_new_1,
    input  wire [PTAG_W-1:0]    alloc_ptag_old_1,
    output wire [AW-1:0]        alloc_tag_1,

    output wire                 full,
    output wire                 almost_full,    // free <= 1, cannot accept 2 allocs

    // ---- Writeback (mark done + result) — up to 2 per cycle ----
    input  wire                 wb_valid_0,
    input  wire [AW-1:0]        wb_tag_0,
    input  wire [31:0]          wb_result_0,
    input  wire                 wb_exception_0,
    input  wire [31:0]          wb_exc_cause_0,
    // Store payload (only valid if entry was alloc_is_store)
    input  wire [31:0]          wb_store_addr_0,
    input  wire [31:0]          wb_store_data_0,
    input  wire [3:0]           wb_store_be_0,

    input  wire                 wb_valid_1,
    input  wire [AW-1:0]        wb_tag_1,
    input  wire [31:0]          wb_result_1,
    input  wire                 wb_exception_1,
    input  wire [31:0]          wb_exc_cause_1,
    input  wire [31:0]          wb_store_addr_1,
    input  wire [31:0]          wb_store_data_1,
    input  wire [3:0]           wb_store_be_1,

    // ---- Commit (head view) — up to 2 per cycle ----
    output wire                 commit_valid_0,
    output wire [AW-1:0]        commit_tag_0,
    output wire [31:0]          commit_pc_0,
    output wire [4:0]           commit_rd_0,
    output wire                 commit_reg_write_0,
    output wire [31:0]          commit_result_0,
    output wire [PTAG_W-1:0]    commit_ptag_new_0,
    output wire [PTAG_W-1:0]    commit_ptag_old_0,
    output wire                 commit_is_store_0,
    output wire [31:0]          commit_store_addr_0,
    output wire [31:0]          commit_store_data_0,
    output wire [3:0]           commit_store_be_0,
    output wire                 commit_exception_0,
    output wire [31:0]          commit_exc_cause_0,

    output wire                 commit_valid_1,
    output wire [AW-1:0]        commit_tag_1,
    output wire [31:0]          commit_pc_1,
    output wire [4:0]           commit_rd_1,
    output wire                 commit_reg_write_1,
    output wire [31:0]          commit_result_1,
    output wire [PTAG_W-1:0]    commit_ptag_new_1,
    output wire [PTAG_W-1:0]    commit_ptag_old_1,
    output wire                 commit_is_store_1,
    output wire [31:0]          commit_store_addr_1,
    output wire [31:0]          commit_store_data_1,
    output wire [3:0]           commit_store_be_1,
    output wire                 commit_exception_1,
    output wire [31:0]          commit_exc_cause_1,

    // Number of head entries to retire this cycle (0/1/2)
    input  wire [1:0]           commit_pop_count,

    // Diagnostics
    output wire [AW:0]          count,
    output wire [AW-1:0]        head_tag
);

    // ---- Storage ----
    reg                  valid_q     [0:DEPTH-1];
    reg                  done_q      [0:DEPTH-1];
    reg [31:0]           pc_q        [0:DEPTH-1];
    reg [4:0]            rd_q        [0:DEPTH-1];
    reg                  reg_write_q [0:DEPTH-1];
    reg [31:0]           result_q    [0:DEPTH-1];
    reg                  is_store_q  [0:DEPTH-1];
    reg [31:0]           saddr_q     [0:DEPTH-1];
    reg [31:0]           sdata_q     [0:DEPTH-1];
    reg [3:0]            sbe_q       [0:DEPTH-1];
    reg                  exc_q       [0:DEPTH-1];
    reg [31:0]           cause_q     [0:DEPTH-1];
    reg                  is_branch_q [0:DEPTH-1];
    reg [PTAG_W-1:0]     ptag_new_q  [0:DEPTH-1];
    reg [PTAG_W-1:0]     ptag_old_q  [0:DEPTH-1];

    // ---- Pointers ----
    reg [AW-1:0]         head_ptr;
    reg [AW-1:0]         tail_ptr;
    reg [AW:0]           cnt;

    assign count       = cnt;
    assign head_tag    = head_ptr;
    assign full        = (cnt == DEPTH);
    assign almost_full = (cnt >= DEPTH - 1);

    // ---- Allocate ----
    // tag_0 == tail_ptr ; tag_1 == tail_ptr + 1 (only if alloc_valid_0 also)
    assign alloc_tag_0 = tail_ptr;
    assign alloc_tag_1 = tail_ptr + 1'b1;

    wire alloc_can_0 = alloc_valid_0 && (cnt < DEPTH);
    wire alloc_can_1 = alloc_valid_1 && alloc_can_0 && (cnt + 1 < DEPTH);

    wire do_alloc_0 = !flush && alloc_can_0;
    wire do_alloc_1 = !flush && alloc_can_1;

    // ---- Commit (head view) ----
    wire [AW-1:0] head_idx_0 = head_ptr;
    wire [AW-1:0] head_idx_1 = head_ptr + 1'b1;

    assign commit_valid_0       = valid_q[head_idx_0] && done_q[head_idx_0];
    assign commit_tag_0         = head_idx_0;
    assign commit_pc_0          = pc_q[head_idx_0];
    assign commit_rd_0          = rd_q[head_idx_0];
    assign commit_reg_write_0   = reg_write_q[head_idx_0];
    assign commit_result_0      = result_q[head_idx_0];
    assign commit_is_store_0    = is_store_q[head_idx_0];
    assign commit_store_addr_0  = saddr_q[head_idx_0];
    assign commit_store_data_0  = sdata_q[head_idx_0];
    assign commit_store_be_0    = sbe_q[head_idx_0];
    assign commit_exception_0   = exc_q[head_idx_0];
    assign commit_exc_cause_0   = cause_q[head_idx_0];
    assign commit_ptag_new_0    = ptag_new_q[head_idx_0];
    assign commit_ptag_old_0    = ptag_old_q[head_idx_0];

    assign commit_valid_1       = valid_q[head_idx_1] && done_q[head_idx_1] &&
                                   commit_valid_0 && (cnt >= 2);
    assign commit_tag_1         = head_idx_1;
    assign commit_pc_1          = pc_q[head_idx_1];
    assign commit_rd_1          = rd_q[head_idx_1];
    assign commit_reg_write_1   = reg_write_q[head_idx_1];
    assign commit_result_1      = result_q[head_idx_1];
    assign commit_is_store_1    = is_store_q[head_idx_1];
    assign commit_store_addr_1  = saddr_q[head_idx_1];
    assign commit_store_data_1  = sdata_q[head_idx_1];
    assign commit_store_be_1    = sbe_q[head_idx_1];
    assign commit_exception_1   = exc_q[head_idx_1];
    assign commit_exc_cause_1   = cause_q[head_idx_1];
    assign commit_ptag_new_1    = ptag_new_q[head_idx_1];
    assign commit_ptag_old_1    = ptag_old_q[head_idx_1];

    wire [1:0] do_pop = flush ? 2'd0 : commit_pop_count;
    wire do_pop_0 = (do_pop >= 2'd1);
    wire do_pop_1 = (do_pop >= 2'd2);

    // M3.5-step2 (deferred): partial flush helpers kept for future use.
    // Currently unused because rename.v full-flush is incompatible with
    // partial ROB flush (free_list double-counting). Will be enabled when
    // rename gains map snapshot / walk-back support.
    wire [AW-1:0] partial_new_tail = flush_keep_tag + (flush_keep_valid ? 1'b1 : 1'b0);
    function automatic [AW:0] age_of;
        input [AW-1:0] tag;
        input [AW-1:0] h;
        begin
            age_of = ({1'b0, tag} - {1'b0, h}) & {1'b0, {AW{1'b1}}};
        end
    endfunction
    wire [AW:0] age_keep_excl = age_of(partial_new_tail, head_ptr);
    wire _unused_partial = flush_partial | (|partial_new_tail) | (|age_keep_excl);

    // ---- Sequential update ----
    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            head_ptr <= {AW{1'b0}};
            tail_ptr <= {AW{1'b0}};
            cnt      <= {(AW+1){1'b0}};
            for (i = 0; i < DEPTH; i = i + 1) begin
                valid_q[i]     <= 1'b0;
                done_q[i]      <= 1'b0;
                pc_q[i]        <= 32'b0;
                rd_q[i]        <= 5'b0;
                reg_write_q[i] <= 1'b0;
                result_q[i]    <= 32'b0;
                is_store_q[i]  <= 1'b0;
                saddr_q[i]     <= 32'b0;
                sdata_q[i]     <= 32'b0;
                sbe_q[i]       <= 4'b0;
                exc_q[i]       <= 1'b0;
                cause_q[i]     <= 32'b0;
                is_branch_q[i] <= 1'b0;
                ptag_new_q[i]  <= {PTAG_W{1'b0}};
                ptag_old_q[i]  <= {PTAG_W{1'b0}};
            end
        end else if (flush) begin
            head_ptr <= {AW{1'b0}};
            tail_ptr <= {AW{1'b0}};
            cnt      <= {(AW+1){1'b0}};
            for (i = 0; i < DEPTH; i = i + 1) begin
                valid_q[i] <= 1'b0;
                done_q[i]  <= 1'b0;
            end
        end else begin
            // ---- Pop (commit) first ----
            if (do_pop_0) begin
                valid_q[head_idx_0] <= 1'b0;
                done_q[head_idx_0]  <= 1'b0;
            end
            if (do_pop_1) begin
                valid_q[head_idx_1] <= 1'b0;
                done_q[head_idx_1]  <= 1'b0;
            end

            // ---- Allocate ----
            if (do_alloc_0) begin
                valid_q[tail_ptr]      <= 1'b1;
                done_q[tail_ptr]       <= 1'b0;
                pc_q[tail_ptr]         <= alloc_pc_0;
                rd_q[tail_ptr]         <= alloc_rd_0;
                reg_write_q[tail_ptr]  <= alloc_reg_write_0;
                is_store_q[tail_ptr]   <= alloc_is_store_0;
                is_branch_q[tail_ptr]  <= alloc_is_branch_0;
                exc_q[tail_ptr]        <= 1'b0;
                ptag_new_q[tail_ptr]   <= alloc_ptag_new_0;
                ptag_old_q[tail_ptr]   <= alloc_ptag_old_0;
            end
            if (do_alloc_1) begin
                valid_q[tail_ptr + 1'b1]      <= 1'b1;
                done_q[tail_ptr + 1'b1]       <= 1'b0;
                pc_q[tail_ptr + 1'b1]         <= alloc_pc_1;
                rd_q[tail_ptr + 1'b1]         <= alloc_rd_1;
                reg_write_q[tail_ptr + 1'b1]  <= alloc_reg_write_1;
                is_store_q[tail_ptr + 1'b1]   <= alloc_is_store_1;
                is_branch_q[tail_ptr + 1'b1]  <= alloc_is_branch_1;
                exc_q[tail_ptr + 1'b1]        <= 1'b0;
                ptag_new_q[tail_ptr + 1'b1]   <= alloc_ptag_new_1;
                ptag_old_q[tail_ptr + 1'b1]   <= alloc_ptag_old_1;
            end

            // ---- Writeback ----
            // Note: writes to result/done allowed even on the same entry being
            // allocated (forwarding within same cycle is not expected — alloc
            // entry is fresh, wb tag is from older alloc).
            if (wb_valid_0) begin
                done_q[wb_tag_0]    <= 1'b1;
                result_q[wb_tag_0]  <= wb_result_0;
                exc_q[wb_tag_0]     <= wb_exception_0;
                cause_q[wb_tag_0]   <= wb_exc_cause_0;
                saddr_q[wb_tag_0]   <= wb_store_addr_0;
                sdata_q[wb_tag_0]   <= wb_store_data_0;
                sbe_q[wb_tag_0]     <= wb_store_be_0;
            end
            if (wb_valid_1) begin
                done_q[wb_tag_1]    <= 1'b1;
                result_q[wb_tag_1]  <= wb_result_1;
                exc_q[wb_tag_1]     <= wb_exception_1;
                cause_q[wb_tag_1]   <= wb_exc_cause_1;
                saddr_q[wb_tag_1]   <= wb_store_addr_1;
                sdata_q[wb_tag_1]   <= wb_store_data_1;
                sbe_q[wb_tag_1]     <= wb_store_be_1;
            end

            // ---- Pointer / count updates ----
            head_ptr <= head_ptr + (do_pop_0 ? 1'b1 : 1'b0)
                                 + (do_pop_1 ? 1'b1 : 1'b0);
            tail_ptr <= tail_ptr + (do_alloc_0 ? 1'b1 : 1'b0)
                                 + (do_alloc_1 ? 1'b1 : 1'b0);
            cnt <= cnt
                   + (do_alloc_0 ? 1'b1 : 1'b0)
                   + (do_alloc_1 ? 1'b1 : 1'b0)
                   - (do_pop_0   ? 1'b1 : 1'b0)
                   - (do_pop_1   ? 1'b1 : 1'b0);
        end
    end

endmodule
