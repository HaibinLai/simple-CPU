// rename.v — Register renaming unit (M3.4a observability skeleton)
//
// Architecture:
//  - 48 physical regs (ptag 0..47, 6 bit)
//  - ARF ptags 0..31 fixed-mapped to architectural regs
//  - 16 "spec" ptags (32..47) managed by free_list
//  - On flush: map[i] <- i, free_list <- {32..47}, busy <- 0
//
// In M3.4a: observability only; cpu_top reads outputs but does NOT use them.

`include "defines.v"

module rename #(
    parameter PRF_SIZE = 48,
    parameter PTAG_W   = 6,
    parameter SPEC_BASE = 32,
    parameter SPEC_CNT  = 16
)(
    input  wire                   clk,
    input  wire                   rst_n,
    input  wire                   flush,

    input  wire [4:0]             s0_rs1,
    input  wire [4:0]             s0_rs2,
    input  wire [4:0]             s0_rd,
    input  wire                   s0_alloc,
    input  wire [4:0]             s1_rs1,
    input  wire [4:0]             s1_rs2,
    input  wire [4:0]             s1_rd,
    input  wire                   s1_alloc,

    output wire [PTAG_W-1:0]      s0_rs1_ptag,
    output wire [PTAG_W-1:0]      s0_rs2_ptag,
    output wire [PTAG_W-1:0]      s0_rd_ptag_new,
    output wire [PTAG_W-1:0]      s0_rd_ptag_old,
    output wire [PTAG_W-1:0]      s1_rs1_ptag,
    output wire [PTAG_W-1:0]      s1_rs2_ptag,
    output wire [PTAG_W-1:0]      s1_rd_ptag_new,
    output wire [PTAG_W-1:0]      s1_rd_ptag_old,

    output wire                   stall,

    input  wire                   wb0_valid,
    input  wire [PTAG_W-1:0]      wb0_ptag,
    input  wire                   wb1_valid,
    input  wire [PTAG_W-1:0]      wb1_ptag,

    input  wire                   commit0_valid,
    input  wire [PTAG_W-1:0]      commit0_ptag_old,
    input  wire                   commit1_valid,
    input  wire [PTAG_W-1:0]      commit1_ptag_old,

    output wire [4:0]             free_count,
    output wire [PRF_SIZE-1:0]    busy_vec
);

    reg [PTAG_W-1:0]   map [0:31];
    reg [PRF_SIZE-1:0] busy;
    assign busy_vec = busy;

    reg [PTAG_W-1:0]   fl_mem [0:SPEC_CNT-1];
    reg [4:0]          fl_head, fl_tail;
    reg [4:0]          fl_cnt;
    assign free_count = fl_cnt;

    // combinational lookups
    wire [PTAG_W-1:0] s0_map_rs1 = (s0_rs1 == 5'd0) ? {PTAG_W{1'b0}} : map[s0_rs1];
    wire [PTAG_W-1:0] s0_map_rs2 = (s0_rs2 == 5'd0) ? {PTAG_W{1'b0}} : map[s0_rs2];
    wire [PTAG_W-1:0] s0_map_rd  = (s0_rd  == 5'd0) ? {PTAG_W{1'b0}} : map[s0_rd];

    wire [PTAG_W-1:0] s0_new = fl_mem[fl_head];
    wire [PTAG_W-1:0] s1_new = fl_mem[(fl_head + 5'd1) % SPEC_CNT];

    wire s1_rs1_eq_s0_rd = s0_alloc && (s0_rd != 5'd0) && (s1_rs1 == s0_rd);
    wire s1_rs2_eq_s0_rd = s0_alloc && (s0_rd != 5'd0) && (s1_rs2 == s0_rd);
    wire s1_rd_eq_s0_rd  = s0_alloc && (s0_rd != 5'd0) && s1_alloc && (s1_rd == s0_rd) && (s1_rd != 5'd0);

    wire [PTAG_W-1:0] s1_map_rs1_raw = (s1_rs1 == 5'd0) ? {PTAG_W{1'b0}} : map[s1_rs1];
    wire [PTAG_W-1:0] s1_map_rs2_raw = (s1_rs2 == 5'd0) ? {PTAG_W{1'b0}} : map[s1_rs2];
    wire [PTAG_W-1:0] s1_map_rd_raw  = (s1_rd  == 5'd0) ? {PTAG_W{1'b0}} : map[s1_rd];

    assign s0_rs1_ptag    = s0_map_rs1;
    assign s0_rs2_ptag    = s0_map_rs2;
    assign s0_rd_ptag_new = s0_new;
    assign s0_rd_ptag_old = s0_map_rd;

    assign s1_rs1_ptag    = s1_rs1_eq_s0_rd ? s0_new : s1_map_rs1_raw;
    assign s1_rs2_ptag    = s1_rs2_eq_s0_rd ? s0_new : s1_map_rs2_raw;
    assign s1_rd_ptag_new = s1_new;
    assign s1_rd_ptag_old = s1_rd_eq_s0_rd  ? s0_new : s1_map_rd_raw;

    wire s0_real_alloc = s0_alloc && (s0_rd != 5'd0);
    wire s1_real_alloc = s1_alloc && (s1_rd != 5'd0);
    wire [1:0] need = {1'b0, s0_real_alloc} + {1'b0, s1_real_alloc};
    assign stall = (fl_cnt < {3'b0, need});

    wire alloc0_ok = s0_real_alloc && !stall;
    wire alloc1_ok = s1_real_alloc && !stall;
    wire push0_ok  = commit0_valid && (commit0_ptag_old >= SPEC_BASE);
    wire push1_ok  = commit1_valid && (commit1_ptag_old >= SPEC_BASE);

    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < 32; i = i + 1)
                map[i] <= i[PTAG_W-1:0];
            busy <= {PRF_SIZE{1'b0}};
            for (i = 0; i < SPEC_CNT; i = i + 1)
                fl_mem[i] <= (SPEC_BASE + i);
            fl_head <= 5'd0;
            fl_tail <= 5'd0;
            fl_cnt  <= SPEC_CNT[4:0];
        end else if (flush) begin
            for (i = 0; i < 32; i = i + 1)
                map[i] <= i[PTAG_W-1:0];
            busy <= {PRF_SIZE{1'b0}};
            for (i = 0; i < SPEC_CNT; i = i + 1)
                fl_mem[i] <= (SPEC_BASE + i);
            fl_head <= 5'd0;
            fl_tail <= 5'd0;
            fl_cnt  <= SPEC_CNT[4:0];
        end else begin
            // map updates (slot1 wins on same-rd by program order)
            if (alloc0_ok) map[s0_rd] <= s0_new;
            if (alloc1_ok) map[s1_rd] <= s1_new;

            // busy: alloc sets, wb clears
            if (alloc0_ok) busy[s0_new]  <= 1'b1;
            if (alloc1_ok) busy[s1_new]  <= 1'b1;
            if (wb0_valid) busy[wb0_ptag] <= 1'b0;
            if (wb1_valid) busy[wb1_ptag] <= 1'b0;

            // free list head advance (pops)
            case ({alloc1_ok, alloc0_ok})
                2'b00: fl_head <= fl_head;
                2'b01: fl_head <= (fl_head + 5'd1) % SPEC_CNT;
                2'b10: fl_head <= (fl_head + 5'd1) % SPEC_CNT;
                2'b11: fl_head <= (fl_head + 5'd2) % SPEC_CNT;
            endcase

            // free list tail advance + memory writes (pushes)
            case ({push1_ok, push0_ok})
                2'b00: fl_tail <= fl_tail;
                2'b01: begin
                    fl_mem[fl_tail] <= commit0_ptag_old;
                    fl_tail <= (fl_tail + 5'd1) % SPEC_CNT;
                end
                2'b10: begin
                    fl_mem[fl_tail] <= commit1_ptag_old;
                    fl_tail <= (fl_tail + 5'd1) % SPEC_CNT;
                end
                2'b11: begin
                    fl_mem[fl_tail] <= commit0_ptag_old;
                    fl_mem[(fl_tail + 5'd1) % SPEC_CNT] <= commit1_ptag_old;
                    fl_tail <= (fl_tail + 5'd2) % SPEC_CNT;
                end
            endcase

            fl_cnt <= fl_cnt
                      - (alloc0_ok ? 5'd1 : 5'd0)
                      - (alloc1_ok ? 5'd1 : 5'd0)
                      + (push0_ok  ? 5'd1 : 5'd0)
                      + (push1_ok  ? 5'd1 : 5'd0);
        end
    end

endmodule
