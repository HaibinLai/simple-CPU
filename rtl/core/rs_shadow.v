// rs_shadow.v — Tomasulo Phase T2a: shadow Reservation Station (observability only)
//
// Purpose
// -------
// Run a 4-entry unified RS *in parallel* with the real in-order pipeline,
// driven by the same dispatch / CDB events. Does NOT control issue: the real
// pipeline is unchanged. Just exposes counters that quantify how much OoO
// scheduling could buy us before we commit to T2b (replacing in-order issue
// with RS-driven issue).
//
// What we measure
//   alloc_count           : entries allocated (== ALU dispatches observed)
//   issue_count           : entries that became ready (rs1 & rs2 ready) and
//                           were "issued" by the shadow scheduler
//   full_stall_count      : cycles dispatch wanted to alloc but RS was full
//                           (== back-pressure RS would create on dispatch)
//   wait_cycles_total     : sum over all issued entries of (cycles spent in
//                           RS waiting for any operand). 0 == ready at alloc.
//   ready_at_alloc_count  : entries ready immediately at alloc (best case)
//   max_occupancy         : peak number of valid entries seen
//
// Issue policy (shadow): pick oldest valid entry whose rs1 & rs2 are ready.
//   - Operand "ready at alloc" iff !busy_vec[ptag] OR ptag==0 OR ptag==rd_self_skip.
//   - CDB lanes wake up matching ptags the cycle they broadcast (combinational
//     same-cycle wakeup).
//   - One issue per cycle (matches our single ALU pipe today).
//
// Flush: drop everything (mirrors current full-flush semantics).

`include "defines.v"

module rs_shadow #(
    parameter DEPTH  = 4,
    parameter PTAG_W = 6,
    parameter ROB_W  = 4
)(
    input  wire                  clk,
    input  wire                  rst_n,
    input  wire                  flush,

    // Dispatch event (from cpu_top: slot0 ALU op being pushed into ID/EX)
    input  wire                  alloc_valid,
    input  wire [PTAG_W-1:0]     alloc_rs1_ptag,
    input  wire [PTAG_W-1:0]     alloc_rs2_ptag,
    input  wire                  alloc_rs1_ready,   // !busy at alloc time
    input  wire                  alloc_rs2_ready,
    input  wire [PTAG_W-1:0]     alloc_rd_ptag,
    input  wire [ROB_W-1:0]      alloc_rob_tag,

    // CDB lanes (from cpu_top T1 wires)
    input  wire                  cdb0_valid,
    input  wire [PTAG_W-1:0]     cdb0_ptag,
    input  wire                  cdb1_valid,
    input  wire [PTAG_W-1:0]     cdb1_ptag,

    // Observability counters
    output reg  [31:0]           alloc_count,
    output reg  [31:0]           issue_count,
    output reg  [31:0]           full_stall_count,
    output reg  [31:0]           wait_cycles_total,
    output reg  [31:0]           ready_at_alloc_count,
    output reg  [31:0]           max_occupancy
);

    // entry storage
    reg                  v       [0:DEPTH-1];   // valid
    reg [PTAG_W-1:0]     rs1     [0:DEPTH-1];
    reg [PTAG_W-1:0]     rs2     [0:DEPTH-1];
    reg                  rs1_rdy [0:DEPTH-1];
    reg                  rs2_rdy [0:DEPTH-1];
    reg [PTAG_W-1:0]     rd      [0:DEPTH-1];
    reg [ROB_W-1:0]      rob     [0:DEPTH-1];
    reg [31:0]           age     [0:DEPTH-1];   // cycles since alloc (saturating)

    // ---- combinational helpers ----
    integer i;

    // wakeup from CDB (combinational, same-cycle)
    wire [DEPTH-1:0] wake_rs1, wake_rs2;
    genvar gi;
    generate
        for (gi = 0; gi < DEPTH; gi = gi + 1) begin : g_wake
            assign wake_rs1[gi] = v[gi] && !rs1_rdy[gi] &&
                ((cdb0_valid && (cdb0_ptag == rs1[gi])) ||
                 (cdb1_valid && (cdb1_ptag == rs1[gi])));
            assign wake_rs2[gi] = v[gi] && !rs2_rdy[gi] &&
                ((cdb0_valid && (cdb0_ptag == rs2[gi])) ||
                 (cdb1_valid && (cdb1_ptag == rs2[gi])));
        end
    endgenerate

    // post-wakeup ready snapshot for issue selection
    wire [DEPTH-1:0] entry_ready;
    generate
        for (gi = 0; gi < DEPTH; gi = gi + 1) begin : g_rdy
            assign entry_ready[gi] = v[gi] &&
                                     (rs1_rdy[gi] || wake_rs1[gi]) &&
                                     (rs2_rdy[gi] || wake_rs2[gi]);
        end
    endgenerate

    // pick oldest ready (largest age). Sequential priority over DEPTH.
    reg                  issue_v;
    reg [$clog2(DEPTH):0] issue_idx;   // one extra bit, harmless
    reg [31:0]           issue_age;
    always @* begin
        issue_v   = 1'b0;
        issue_idx = {($clog2(DEPTH)+1){1'b0}};
        issue_age = 32'b0;
        for (i = 0; i < DEPTH; i = i + 1) begin
            if (entry_ready[i] && (!issue_v || age[i] > issue_age)) begin
                issue_v   = 1'b1;
                issue_idx = i[$clog2(DEPTH):0];
                issue_age = age[i];
            end
        end
    end

    // free slot for alloc (lowest-index empty)
    reg                  free_v;
    reg [$clog2(DEPTH):0] free_idx;
    always @* begin
        free_v   = 1'b0;
        free_idx = {($clog2(DEPTH)+1){1'b0}};
        for (i = 0; i < DEPTH; i = i + 1) begin
            if (!free_v && !v[i]) begin
                free_v   = 1'b1;
                free_idx = i[$clog2(DEPTH):0];
            end
        end
    end

    // accept alloc only if there is room (after this cycle's issue clears one)
    // Simplification: model RS as updated-after-issue, so an issue this cycle
    // frees a slot for the same-cycle alloc.
    wire alloc_will_have_slot = free_v ||
                                (issue_v && (issue_idx != free_idx));
    // (The above is approximate; for DEPTH small the dominant case is issue
    // frees a slot if no slot was already free.)
    wire alloc_take = alloc_valid && alloc_will_have_slot;
    wire alloc_blocked = alloc_valid && !alloc_will_have_slot;

    // current occupancy (pre-update)
    reg [$clog2(DEPTH+1)-1:0] occ_now;
    always @* begin
        occ_now = {($clog2(DEPTH+1)){1'b0}};
        for (i = 0; i < DEPTH; i = i + 1)
            if (v[i]) occ_now = occ_now + 1'b1;
    end

    // ---- sequential update ----
    integer w;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (w = 0; w < DEPTH; w = w + 1) begin
                v[w]       <= 1'b0;
                rs1_rdy[w] <= 1'b0;
                rs2_rdy[w] <= 1'b0;
                age[w]     <= 32'b0;
                rs1[w]     <= {PTAG_W{1'b0}};
                rs2[w]     <= {PTAG_W{1'b0}};
                rd[w]      <= {PTAG_W{1'b0}};
                rob[w]     <= {ROB_W{1'b0}};
            end
            alloc_count          <= 32'b0;
            issue_count          <= 32'b0;
            full_stall_count     <= 32'b0;
            wait_cycles_total    <= 32'b0;
            ready_at_alloc_count <= 32'b0;
            max_occupancy        <= 32'b0;
        end else if (flush) begin
            for (w = 0; w < DEPTH; w = w + 1) begin
                v[w]       <= 1'b0;
                rs1_rdy[w] <= 1'b0;
                rs2_rdy[w] <= 1'b0;
                age[w]     <= 32'b0;
            end
            // counters retained across flushes
        end else begin
            // 1) wakeup (latch ready bits set this cycle)
            for (w = 0; w < DEPTH; w = w + 1) begin
                if (wake_rs1[w]) rs1_rdy[w] <= 1'b1;
                if (wake_rs2[w]) rs2_rdy[w] <= 1'b1;
                // age++ on every cycle the entry is valid (saturate at 32'hFFFF_FFFF)
                if (v[w] && age[w] != 32'hFFFF_FFFF)
                    age[w] <= age[w] + 32'd1;
            end

            // 2) issue (clear valid)
            if (issue_v) begin
                v[issue_idx]   <= 1'b0;
                issue_count    <= issue_count + 32'd1;
                wait_cycles_total <= wait_cycles_total + age[issue_idx];
            end

            // 3) alloc (write into a free slot; if issue cleared a slot
            //    we may write into that slot — pick the one identified by
            //    free_idx; if none free, but issue cleared one, write into
            //    the issued slot)
            if (alloc_take) begin
                // Choose target: prefer pre-existing free slot; otherwise
                // re-use the issued slot (only when alloc_will_have_slot
                // depended on the issue freeing a slot).
                // Simple selection follows the same combinational helpers.
                if (free_v) begin
                    v[free_idx]      <= 1'b1;
                    rs1[free_idx]    <= alloc_rs1_ptag;
                    rs2[free_idx]    <= alloc_rs2_ptag;
                    rs1_rdy[free_idx]<= alloc_rs1_ready ||
                                        (cdb0_valid && cdb0_ptag == alloc_rs1_ptag) ||
                                        (cdb1_valid && cdb1_ptag == alloc_rs1_ptag);
                    rs2_rdy[free_idx]<= alloc_rs2_ready ||
                                        (cdb0_valid && cdb0_ptag == alloc_rs2_ptag) ||
                                        (cdb1_valid && cdb1_ptag == alloc_rs2_ptag);
                    rd[free_idx]     <= alloc_rd_ptag;
                    rob[free_idx]    <= alloc_rob_tag;
                    age[free_idx]    <= 32'b0;
                end else if (issue_v) begin
                    v[issue_idx]      <= 1'b1;
                    rs1[issue_idx]    <= alloc_rs1_ptag;
                    rs2[issue_idx]    <= alloc_rs2_ptag;
                    rs1_rdy[issue_idx]<= alloc_rs1_ready ||
                                         (cdb0_valid && cdb0_ptag == alloc_rs1_ptag) ||
                                         (cdb1_valid && cdb1_ptag == alloc_rs1_ptag);
                    rs2_rdy[issue_idx]<= alloc_rs2_ready ||
                                         (cdb0_valid && cdb0_ptag == alloc_rs2_ptag) ||
                                         (cdb1_valid && cdb1_ptag == alloc_rs2_ptag);
                    rd[issue_idx]     <= alloc_rd_ptag;
                    rob[issue_idx]    <= alloc_rob_tag;
                    age[issue_idx]    <= 32'b0;
                end
                alloc_count <= alloc_count + 32'd1;
                if (alloc_rs1_ready && alloc_rs2_ready)
                    ready_at_alloc_count <= ready_at_alloc_count + 32'd1;
            end

            if (alloc_blocked) full_stall_count <= full_stall_count + 32'd1;

            if ({24'b0, occ_now} > max_occupancy)
                max_occupancy <= {24'b0, occ_now};
        end
    end

endmodule
