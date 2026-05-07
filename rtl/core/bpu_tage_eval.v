// =============================================================
// bpu_tage_eval.v — TAGE-2L 离线评估器（32-bit GHR + folded history 真版）
//
// 影子模块，不参与 PC 选择；与 GShare BPU 并行重放每条已解析分支，
// 比较命中率，为 step3 是否切换实际 BPU 提供数据。
//
// 历史与折叠（关键升级）：
//   GHR_W = 32（与 BPU 同步）。
//   T1 history len = 8；T2 history len = 16。
//   折叠规则（XOR fold）：
//     fold_idx_t1 = XOR all 8-bit chunks of GHR[7:0]   → IDX_W=7 取低 7
//     fold_tag_t1 = XOR all 8-bit chunks of GHR[7:0]   → TAG_W=8
//     fold_idx_t2 = XOR all 8-bit chunks of GHR[15:0]  → IDX_W=7
//     fold_tag_t2 = (XOR 8-bit chunks of GHR[15:0])    → TAG_W=8
//   即长历史 fold 到短宽度，类似 Seznec L-TAGE 的 CSR 思路（这里直接组合 XOR
//   而非 CSR；与流水线下游解耦，仅用于评估）。
//
// 拓扑：
//   * Base T0 : 256-entry 2-bit BHT；与 BPU 同 fold(GHR,8) 索引 → 公平基线
//   * Table T1: 128 项；hist=8；ctr=3-bit；u=2-bit
//   * Table T2: 128 项；hist=16；ctr=3-bit；u=2-bit
//
// 预测优先级：T2 hit → T2，否则 T1 hit → T1，否则 base。
// altpred、ctr/u 更新、分配策略与教科书 TAGE 一致：
//   * Base 始终更新
//   * chosen 表 ctr 饱和更新
//   * tage_pred != alt_pred 时 u 增/减
//   * 误预测时往更长的表分配（找 u==0），都没 → age 全表
//   * uncond 分支不参与
// =============================================================
module bpu_tage_eval #(
    parameter GHR_W      = 32,
    parameter BASE_IDX_W = 8,
    parameter T1_IDX_W   = 7,
    parameter T1_TAG_W   = 8,
    parameter T1_HIST_W  = 8,
    parameter T2_IDX_W   = 7,
    parameter T2_TAG_W   = 9,
    parameter T2_HIST_W  = 16,
    parameter CTR_W      = 3,
    parameter U_W        = 2
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        upd_valid,
    input  wire [31:0] upd_pc,
    input  wire [GHR_W-1:0] upd_pred_ghr,
    input  wire        upd_taken,
    input  wire        upd_is_uncond,

    output reg  [31:0] tage_total,
    output reg  [31:0] tage_t1_hit,
    output reg  [31:0] tage_t2_hit,
    output reg  [31:0] tage_t1_use,
    output reg  [31:0] tage_t2_use,
    output reg  [31:0] tage_correct,
    output reg  [31:0] gshare_correct,
    output reg  [31:0] tage_t1_alloc,
    output reg  [31:0] tage_t2_alloc,
    output reg  [31:0] tage_alloc_fail
);
    localparam BASE_SIZE = 1 << BASE_IDX_W;
    localparam T1_SIZE   = 1 << T1_IDX_W;
    localparam T2_SIZE   = 1 << T2_IDX_W;

    // ============= folded history (手写展开) =============
    // base: pc XOR fold(GHR_32, 8) = XOR 四个 8-bit chunk
    function [BASE_IDX_W-1:0] fold_base;
        input [GHR_W-1:0] g;
        begin
            fold_base = g[7:0] ^ g[15:8] ^ g[23:16] ^ g[31:24];
        end
    endfunction

    // T1: hist=8 bit 里提 7-bit idx 与 8-bit tag
    function [T1_IDX_W-1:0] fold_t1_idx;
        input [GHR_W-1:0] g;
        begin
            // 7-bit = g[6:0] ^ {6'b0, g[7]}
            fold_t1_idx = g[6:0] ^ {6'b0, g[7]};
        end
    endfunction
    function [T1_TAG_W-1:0] fold_t1_tag;
        input [GHR_W-1:0] g;
        begin
            fold_t1_tag = g[7:0];
        end
    endfunction

    // T2: hist=16 bit
    function [T2_IDX_W-1:0] fold_t2_idx;
        input [GHR_W-1:0] g;
        begin
            // 7-bit idx = XOR three slices: g[6:0], g[13:7], {5'b0, g[15:14]}
            fold_t2_idx = g[6:0] ^ g[13:7] ^ {5'b0, g[15:14]};
        end
    endfunction
    function [T2_TAG_W-1:0] fold_t2_tag;
        input [GHR_W-1:0] g;
        begin
            // 9-bit tag = XOR two slices: g[8:0], {2'b0, g[15:9]}
            fold_t2_tag = g[8:0] ^ {2'b0, g[15:9]};
        end
    endfunction

    // ============= Storage =============
    reg [1:0]           base_bht [0:BASE_SIZE-1];
    reg                 t1_valid [0:T1_SIZE-1];
    reg [T1_TAG_W-1:0]  t1_tag   [0:T1_SIZE-1];
    reg [CTR_W-1:0]     t1_ctr   [0:T1_SIZE-1];
    reg [U_W-1:0]       t1_u     [0:T1_SIZE-1];
    reg                 t2_valid [0:T2_SIZE-1];
    reg [T2_TAG_W-1:0]  t2_tag   [0:T2_SIZE-1];
    reg [CTR_W-1:0]     t2_ctr   [0:T2_SIZE-1];
    reg [U_W-1:0]       t2_u     [0:T2_SIZE-1];

    integer i;
    initial begin
        for (i = 0; i < BASE_SIZE; i = i + 1) base_bht[i] = 2'b01;
        for (i = 0; i < T1_SIZE; i = i + 1) begin
            t1_valid[i] = 1'b0; t1_tag[i] = {T1_TAG_W{1'b0}};
            t1_ctr[i]   = {1'b1, {(CTR_W-1){1'b0}}}; t1_u[i] = {U_W{1'b0}};
        end
        for (i = 0; i < T2_SIZE; i = i + 1) begin
            t2_valid[i] = 1'b0; t2_tag[i] = {T2_TAG_W{1'b0}};
            t2_ctr[i]   = {1'b1, {(CTR_W-1){1'b0}}}; t2_u[i] = {U_W{1'b0}};
        end
    end

    // ============= Combinational lookup =============
    wire [BASE_IDX_W-1:0] base_idx = upd_pc[BASE_IDX_W+1:2] ^ fold_base(upd_pred_ghr);

    wire [T1_IDX_W-1:0] t1_idx      = upd_pc[T1_IDX_W+1:2]    ^ fold_t1_idx(upd_pred_ghr);
    wire [T1_TAG_W-1:0] t1_tag_calc = upd_pc[T1_TAG_W+9:10]   ^ fold_t1_tag(upd_pred_ghr);
    wire [T2_IDX_W-1:0] t2_idx      = upd_pc[T2_IDX_W+1:2]    ^ fold_t2_idx(upd_pred_ghr);
    wire [T2_TAG_W-1:0] t2_tag_calc = upd_pc[T2_TAG_W+9:10]   ^ fold_t2_tag(upd_pred_ghr);

    wire base_pred  = base_bht[base_idx][1];
    wire t1_present = t1_valid[t1_idx] && (t1_tag[t1_idx] == t1_tag_calc);
    wire t2_present = t2_valid[t2_idx] && (t2_tag[t2_idx] == t2_tag_calc);
    wire t1_pred    = t1_ctr[t1_idx][CTR_W-1];
    wire t2_pred    = t2_ctr[t2_idx][CTR_W-1];

    wire [1:0] chosen = t2_present ? 2'd2 : (t1_present ? 2'd1 : 2'd0);
    wire tage_pred = (chosen == 2'd2) ? t2_pred :
                     (chosen == 2'd1) ? t1_pred : base_pred;
    wire alt_pred  = (chosen == 2'd2) ? (t1_present ? t1_pred : base_pred) :
                     (chosen == 2'd1) ? base_pred : base_pred;

    wire base_ok = (base_pred == upd_taken);
    wire tage_ok = (tage_pred == upd_taken);

    wire t1_alloc_ok = (t1_u[t1_idx] == {U_W{1'b0}});
    wire t2_alloc_ok = (t2_u[t2_idx] == {U_W{1'b0}});

    // ============= Sequential update =============
    integer j;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tage_total      <= 32'd0;
            tage_t1_hit     <= 32'd0;
            tage_t2_hit     <= 32'd0;
            tage_t1_use     <= 32'd0;
            tage_t2_use     <= 32'd0;
            tage_correct    <= 32'd0;
            gshare_correct  <= 32'd0;
            tage_t1_alloc   <= 32'd0;
            tage_t2_alloc   <= 32'd0;
            tage_alloc_fail <= 32'd0;
            for (j = 0; j < BASE_SIZE; j = j + 1) base_bht[j] <= 2'b01;
            for (j = 0; j < T1_SIZE; j = j + 1) begin
                t1_valid[j] <= 1'b0; t1_tag[j] <= {T1_TAG_W{1'b0}};
                t1_ctr[j]   <= {1'b1, {(CTR_W-1){1'b0}}}; t1_u[j] <= {U_W{1'b0}};
            end
            for (j = 0; j < T2_SIZE; j = j + 1) begin
                t2_valid[j] <= 1'b0; t2_tag[j] <= {T2_TAG_W{1'b0}};
                t2_ctr[j]   <= {1'b1, {(CTR_W-1){1'b0}}}; t2_u[j] <= {U_W{1'b0}};
            end
        end else if (upd_valid && !upd_is_uncond) begin
            tage_total <= tage_total + 32'd1;
            if (t1_present)     tage_t1_hit    <= tage_t1_hit    + 32'd1;
            if (t2_present)     tage_t2_hit    <= tage_t2_hit    + 32'd1;
            if (chosen == 2'd1) tage_t1_use    <= tage_t1_use    + 32'd1;
            if (chosen == 2'd2) tage_t2_use    <= tage_t2_use    + 32'd1;
            if (tage_ok)        tage_correct   <= tage_correct   + 32'd1;
            if (base_ok)        gshare_correct <= gshare_correct + 32'd1;

            // Base BHT 始终饱和更新
            if (upd_taken) begin
                if (base_bht[base_idx] != 2'b11)
                    base_bht[base_idx] <= base_bht[base_idx] + 2'b01;
            end else begin
                if (base_bht[base_idx] != 2'b00)
                    base_bht[base_idx] <= base_bht[base_idx] - 2'b01;
            end

            // chosen ctr
            if (chosen == 2'd1) begin
                if (upd_taken) begin
                    if (t1_ctr[t1_idx] != {CTR_W{1'b1}}) t1_ctr[t1_idx] <= t1_ctr[t1_idx] + 1'b1;
                end else begin
                    if (t1_ctr[t1_idx] != {CTR_W{1'b0}}) t1_ctr[t1_idx] <= t1_ctr[t1_idx] - 1'b1;
                end
            end else if (chosen == 2'd2) begin
                if (upd_taken) begin
                    if (t2_ctr[t2_idx] != {CTR_W{1'b1}}) t2_ctr[t2_idx] <= t2_ctr[t2_idx] + 1'b1;
                end else begin
                    if (t2_ctr[t2_idx] != {CTR_W{1'b0}}) t2_ctr[t2_idx] <= t2_ctr[t2_idx] - 1'b1;
                end
            end

            // u 更新
            if (chosen != 2'd0 && (tage_pred != alt_pred)) begin
                if (chosen == 2'd1) begin
                    if (tage_ok) begin
                        if (t1_u[t1_idx] != {U_W{1'b1}}) t1_u[t1_idx] <= t1_u[t1_idx] + 1'b1;
                    end else begin
                        if (t1_u[t1_idx] != {U_W{1'b0}}) t1_u[t1_idx] <= t1_u[t1_idx] - 1'b1;
                    end
                end else begin
                    if (tage_ok) begin
                        if (t2_u[t2_idx] != {U_W{1'b1}}) t2_u[t2_idx] <= t2_u[t2_idx] + 1'b1;
                    end else begin
                        if (t2_u[t2_idx] != {U_W{1'b0}}) t2_u[t2_idx] <= t2_u[t2_idx] - 1'b1;
                    end
                end
            end

            // 分配（误预测时）
            if (!tage_ok) begin
                case (chosen)
                    2'd0: begin
                        if (t1_alloc_ok) begin
                            t1_valid[t1_idx] <= 1'b1;
                            t1_tag[t1_idx]   <= t1_tag_calc;
                            t1_ctr[t1_idx]   <= upd_taken ? {1'b1, {(CTR_W-1){1'b0}}}
                                                          : {1'b0, {(CTR_W-1){1'b1}}};
                            t1_u[t1_idx]     <= {U_W{1'b0}};
                            tage_t1_alloc    <= tage_t1_alloc + 32'd1;
                        end else if (t2_alloc_ok) begin
                            t2_valid[t2_idx] <= 1'b1;
                            t2_tag[t2_idx]   <= t2_tag_calc;
                            t2_ctr[t2_idx]   <= upd_taken ? {1'b1, {(CTR_W-1){1'b0}}}
                                                          : {1'b0, {(CTR_W-1){1'b1}}};
                            t2_u[t2_idx]     <= {U_W{1'b0}};
                            tage_t2_alloc    <= tage_t2_alloc + 32'd1;
                        end else begin
                            for (j = 0; j < T1_SIZE; j = j + 1)
                                if (t1_u[j] != {U_W{1'b0}}) t1_u[j] <= t1_u[j] - 1'b1;
                            for (j = 0; j < T2_SIZE; j = j + 1)
                                if (t2_u[j] != {U_W{1'b0}}) t2_u[j] <= t2_u[j] - 1'b1;
                            tage_alloc_fail <= tage_alloc_fail + 32'd1;
                        end
                    end
                    2'd1: begin
                        if (t2_alloc_ok) begin
                            t2_valid[t2_idx] <= 1'b1;
                            t2_tag[t2_idx]   <= t2_tag_calc;
                            t2_ctr[t2_idx]   <= upd_taken ? {1'b1, {(CTR_W-1){1'b0}}}
                                                          : {1'b0, {(CTR_W-1){1'b1}}};
                            t2_u[t2_idx]     <= {U_W{1'b0}};
                            tage_t2_alloc    <= tage_t2_alloc + 32'd1;
                        end else begin
                            for (j = 0; j < T2_SIZE; j = j + 1)
                                if (t2_u[j] != {U_W{1'b0}}) t2_u[j] <= t2_u[j] - 1'b1;
                            tage_alloc_fail <= tage_alloc_fail + 32'd1;
                        end
                    end
                    default: ;
                endcase
            end
        end
    end
endmodule
