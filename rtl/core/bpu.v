// =============================================================
// bpu.v — 分支预测单元 (BTB 2-way + GShare BHT)
//
//   BTB : 32 set x 2 way = 64 项；index = pc[6:2]；
//         tag = pc[31:7]；每 set 一个 LRU bit
//   BHT : 256 项 2-bit 饱和计数器；
//         index = pc[9:2] XOR ghr[7:0]   (GShare 已启用)
//   GHR : 8-bit 全局分支历史寄存器；EX 解析每条分支/跳转后左移并填入实际方向
//
//   IF 阶段：
//     btb_hit = 任一 way tag 匹配
//     pred_taken  = btb_hit && bht_counter[1]
//     pred_target = 命中那 way 的 target
//     pred_ghr_o  = 当前 GHR 快照（IF→EX 透传）
//
//   EX 阶段反馈：
//     - BHT：用 IF 时保存的 upd_pred_ghr 重算 index 进行饱和计数更新
//     - BTB：taken 时分配/更新（LRU way 替换）；not-taken 不动
//     - GHR：左移并写入 upd_taken
// =============================================================
module bpu #(
    parameter BHT_IDX_W = 8,    // 256
    parameter BTB_IDX_W = 5,    // 32 sets
    parameter GHR_W     = 32,   // 长全局历史，GShare/TAGE 均使用 fold
    parameter T1_IDX_W  = 7,
    parameter T1_TAG_W  = 8,
    parameter T2_IDX_W  = 7,
    parameter T2_TAG_W  = 9,
    parameter CTR_W     = 3,
    parameter U_W       = 2
)(
    input  wire        clk,
    input  wire        rst_n,

    // ----- IF: 预测查询 -----
    input  wire [31:0] if_pc,
    output wire        pred_taken,
    output wire [31:0] pred_target,
    output wire [GHR_W-1:0] pred_ghr_o,   // IF 时的 GHR 快照，需随流水线透传至 EX

    // ----- 反馈/训练（来自 EX） -----
    input  wire        upd_valid,    // 本周期 EX 解析了一条分支/跳转
    input  wire [31:0] upd_pc,
    input  wire        upd_taken,
    input  wire [31:0] upd_target,
    input  wire        upd_is_uncond, // 本次训练对象是否为无条件跳转 (JAL/JALR)
    input  wire [GHR_W-1:0] upd_pred_ghr // EX 阶段告知 IF 时的 GHR 快照，以重建训练索引
);
    localparam BHT_SIZE  = 1 << BHT_IDX_W;
    localparam BTB_SETS  = 1 << BTB_IDX_W;
    localparam BTB_TAG_W = 32 - BTB_IDX_W - 2;
    localparam T1_SIZE   = 1 << T1_IDX_W;
    localparam T2_SIZE   = 1 << T2_IDX_W;

    // ----- base BHT (T0) -----
    reg [1:0] bht [0:BHT_SIZE-1];

    // ----- TAGE T1 -----
    reg                t1_valid [0:T1_SIZE-1];
    reg [T1_TAG_W-1:0] t1_tag   [0:T1_SIZE-1];
    reg [CTR_W-1:0]    t1_ctr   [0:T1_SIZE-1];
    reg [U_W-1:0]      t1_u     [0:T1_SIZE-1];

    // ----- TAGE T2 -----
    reg                t2_valid [0:T2_SIZE-1];
    reg [T2_TAG_W-1:0] t2_tag   [0:T2_SIZE-1];
    reg [CTR_W-1:0]    t2_ctr   [0:T2_SIZE-1];
    reg [U_W-1:0]      t2_u     [0:T2_SIZE-1];

    // ----- BTB 2-way -----
    reg                  btb0_valid  [0:BTB_SETS-1];
    reg [BTB_TAG_W-1:0]  btb0_tag    [0:BTB_SETS-1];
    reg [31:0]           btb0_target [0:BTB_SETS-1];
    reg                  btb0_uncond [0:BTB_SETS-1];
    reg                  btb1_valid  [0:BTB_SETS-1];
    reg [BTB_TAG_W-1:0]  btb1_tag    [0:BTB_SETS-1];
    reg [31:0]           btb1_target [0:BTB_SETS-1];
    reg                  btb1_uncond [0:BTB_SETS-1];
    reg                  btb_lru     [0:BTB_SETS-1]; // 0: way0 LRU; 1: way1 LRU

    // ----- GHR -----
    reg [GHR_W-1:0] ghr;

    integer i;
    initial begin
        for (i = 0; i < BHT_SIZE; i = i + 1) bht[i] = 2'b01;
        for (i = 0; i < BTB_SETS; i = i + 1) begin
            btb0_valid[i]  = 1'b0;
            btb0_uncond[i] = 1'b0;
            btb1_valid[i]  = 1'b0;
            btb1_uncond[i] = 1'b0;
            btb_lru[i]     = 1'b0;
        end
        for (i = 0; i < T1_SIZE; i = i + 1) begin
            t1_valid[i] = 1'b0; t1_tag[i] = {T1_TAG_W{1'b0}};
            t1_ctr[i]   = {1'b1, {(CTR_W-1){1'b0}}}; t1_u[i] = {U_W{1'b0}};
        end
        for (i = 0; i < T2_SIZE; i = i + 1) begin
            t2_valid[i] = 1'b0; t2_tag[i] = {T2_TAG_W{1'b0}};
            t2_ctr[i]   = {1'b1, {(CTR_W-1){1'b0}}}; t2_u[i] = {U_W{1'b0}};
        end
    end

    // -------- 预测 (IF) --------
    wire [BTB_IDX_W-1:0] if_btb_idx = if_pc[BTB_IDX_W+1:2];
    wire [BTB_TAG_W-1:0] if_btb_tag = if_pc[31:BTB_IDX_W+2];

    wire if_hit0 = btb0_valid[if_btb_idx] && (btb0_tag[if_btb_idx] == if_btb_tag);
    wire if_hit1 = btb1_valid[if_btb_idx] && (btb1_tag[if_btb_idx] == if_btb_tag);
    wire btb_hit = if_hit0 | if_hit1;

    // GShare BHT 索引：pc[9:2] XOR fold(ghr, BHT_IDX_W)。
    // GHR_W 可大于 BHT_IDX_W，采用分段 XOR 折叠（wrap-around fold）。
    function [BHT_IDX_W-1:0] fold_bht;
        input [GHR_W-1:0] g;
        integer k;
        reg [BHT_IDX_W-1:0] acc;
        begin
            acc = {BHT_IDX_W{1'b0}};
            for (k = 0; k < GHR_W; k = k + BHT_IDX_W) begin
                acc = acc ^ g[k +: BHT_IDX_W];
            end
            fold_bht = acc;
        end
    endfunction

    // ----- TAGE folded-history helpers (手写展开) -----
    // T1 hist=8: 7-bit idx = g[6:0] ^ {6'b0, g[7]};  8-bit tag = g[7:0]
    function [T1_IDX_W-1:0] fold_t1_idx;
        input [GHR_W-1:0] g;
        begin fold_t1_idx = g[6:0] ^ {6'b0, g[7]}; end
    endfunction
    function [T1_TAG_W-1:0] fold_t1_tag;
        input [GHR_W-1:0] g;
        begin fold_t1_tag = g[7:0]; end
    endfunction
    // T2 hist=16: 7-bit idx = g[6:0]^g[13:7]^{5'b0,g[15:14]}; 9-bit tag = g[8:0]^{2'b0,g[15:9]}
    function [T2_IDX_W-1:0] fold_t2_idx;
        input [GHR_W-1:0] g;
        begin fold_t2_idx = g[6:0] ^ g[13:7] ^ {5'b0, g[15:14]}; end
    endfunction
    function [T2_TAG_W-1:0] fold_t2_tag;
        input [GHR_W-1:0] g;
        begin fold_t2_tag = g[8:0] ^ {2'b0, g[15:9]}; end
    endfunction

    wire [BHT_IDX_W-1:0] if_pc_idx  = if_pc[BHT_IDX_W+1:2];
    wire [BHT_IDX_W-1:0] if_bht_idx = if_pc_idx ^ fold_bht(ghr);
    wire if_base_pred = bht[if_bht_idx][1];

    // TAGE IF 查表
    wire [T1_IDX_W-1:0] if_t1_idx  = if_pc[T1_IDX_W+1:2]  ^ fold_t1_idx(ghr);
    wire [T1_TAG_W-1:0] if_t1_tagc = if_pc[T1_TAG_W+9:10] ^ fold_t1_tag(ghr);
    wire [T2_IDX_W-1:0] if_t2_idx  = if_pc[T2_IDX_W+1:2]  ^ fold_t2_idx(ghr);
    wire [T2_TAG_W-1:0] if_t2_tagc = if_pc[T2_TAG_W+9:10] ^ fold_t2_tag(ghr);
    wire if_t1_present = t1_valid[if_t1_idx] && (t1_tag[if_t1_idx] == if_t1_tagc);
    wire if_t2_present = t2_valid[if_t2_idx] && (t2_tag[if_t2_idx] == if_t2_tagc);
    wire if_t1_pred    = t1_ctr[if_t1_idx][CTR_W-1];
    wire if_t2_pred    = t2_ctr[if_t2_idx][CTR_W-1];
    wire if_tage_pred  = if_t2_present ? if_t2_pred :
                         if_t1_present ? if_t1_pred : if_base_pred;

    // 命中项是否为无条件跳转。若是，pred_taken 跳过条件预测。
    wire if_hit_uncond = (if_hit0 && btb0_uncond[if_btb_idx]) ||
                         (if_hit1 && btb1_uncond[if_btb_idx]);

    assign pred_ghr_o  = ghr;
    assign pred_taken  = btb_hit && (if_hit_uncond || if_tage_pred);
    assign pred_target = if_hit0 ? btb0_target[if_btb_idx] : btb1_target[if_btb_idx];

    // -------- 训练 --------
    wire [BTB_IDX_W-1:0] upd_btb_idx = upd_pc[BTB_IDX_W+1:2];
    wire [BTB_TAG_W-1:0] upd_btb_tag = upd_pc[31:BTB_IDX_W+2];
    wire [BHT_IDX_W-1:0] upd_pc_idx  = upd_pc[BHT_IDX_W+1:2];
    wire [BHT_IDX_W-1:0] upd_bht_idx = upd_pc_idx ^ fold_bht(upd_pred_ghr);

    wire u_hit0 = btb0_valid[upd_btb_idx] && (btb0_tag[upd_btb_idx] == upd_btb_tag);
    wire u_hit1 = btb1_valid[upd_btb_idx] && (btb1_tag[upd_btb_idx] == upd_btb_tag);

    // TAGE update-side indices/tags using snapshot ghr
    wire [T1_IDX_W-1:0] u_t1_idx  = upd_pc[T1_IDX_W+1:2]  ^ fold_t1_idx(upd_pred_ghr);
    wire [T1_TAG_W-1:0] u_t1_tagc = upd_pc[T1_TAG_W+9:10] ^ fold_t1_tag(upd_pred_ghr);
    wire [T2_IDX_W-1:0] u_t2_idx  = upd_pc[T2_IDX_W+1:2]  ^ fold_t2_idx(upd_pred_ghr);
    wire [T2_TAG_W-1:0] u_t2_tagc = upd_pc[T2_TAG_W+9:10] ^ fold_t2_tag(upd_pred_ghr);
    wire u_t1_present = t1_valid[u_t1_idx] && (t1_tag[u_t1_idx] == u_t1_tagc);
    wire u_t2_present = t2_valid[u_t2_idx] && (t2_tag[u_t2_idx] == u_t2_tagc);
    wire u_t1_pred    = t1_ctr[u_t1_idx][CTR_W-1];
    wire u_t2_pred    = t2_ctr[u_t2_idx][CTR_W-1];
    wire u_base_pred  = bht[upd_bht_idx][1];
    wire [1:0] u_chosen = u_t2_present ? 2'd2 : (u_t1_present ? 2'd1 : 2'd0);
    wire u_tage_pred = (u_chosen == 2'd2) ? u_t2_pred :
                       (u_chosen == 2'd1) ? u_t1_pred : u_base_pred;
    wire u_alt_pred  = (u_chosen == 2'd2) ? (u_t1_present ? u_t1_pred : u_base_pred)
                                          : u_base_pred;
    wire u_tage_ok   = (u_tage_pred == upd_taken);
    wire u_t1_alloc_ok = (t1_u[u_t1_idx] == {U_W{1'b0}});
    wire u_t2_alloc_ok = (t2_u[u_t2_idx] == {U_W{1'b0}});

    integer j;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < BHT_SIZE; i = i + 1) bht[i] <= 2'b01;
            for (i = 0; i < BTB_SETS; i = i + 1) begin
                btb0_valid[i]  <= 1'b0;
                btb0_uncond[i] <= 1'b0;
                btb1_valid[i]  <= 1'b0;
                btb1_uncond[i] <= 1'b0;
                btb_lru[i]     <= 1'b0;
            end
            for (i = 0; i < T1_SIZE; i = i + 1) begin
                t1_valid[i] <= 1'b0; t1_tag[i] <= {T1_TAG_W{1'b0}};
                t1_ctr[i]   <= {1'b1, {(CTR_W-1){1'b0}}}; t1_u[i] <= {U_W{1'b0}};
            end
            for (i = 0; i < T2_SIZE; i = i + 1) begin
                t2_valid[i] <= 1'b0; t2_tag[i] <= {T2_TAG_W{1'b0}};
                t2_ctr[i]   <= {1'b1, {(CTR_W-1){1'b0}}}; t2_u[i] <= {U_W{1'b0}};
            end
            ghr <= {GHR_W{1'b0}};
        end else if (upd_valid) begin
            // base BHT 饰和更新（TAGE T0）
            if (upd_taken) begin
                if (bht[upd_bht_idx] != 2'b11)
                    bht[upd_bht_idx] <= bht[upd_bht_idx] + 2'b01;
            end else begin
                if (bht[upd_bht_idx] != 2'b00)
                    bht[upd_bht_idx] <= bht[upd_bht_idx] - 2'b01;
            end

            // TAGE T1/T2 仅对条件分支训练
            if (!upd_is_uncond) begin
                if (u_chosen == 2'd1) begin
                    if (upd_taken) begin
                        if (t1_ctr[u_t1_idx] != {CTR_W{1'b1}}) t1_ctr[u_t1_idx] <= t1_ctr[u_t1_idx] + 1'b1;
                    end else begin
                        if (t1_ctr[u_t1_idx] != {CTR_W{1'b0}}) t1_ctr[u_t1_idx] <= t1_ctr[u_t1_idx] - 1'b1;
                    end
                end else if (u_chosen == 2'd2) begin
                    if (upd_taken) begin
                        if (t2_ctr[u_t2_idx] != {CTR_W{1'b1}}) t2_ctr[u_t2_idx] <= t2_ctr[u_t2_idx] + 1'b1;
                    end else begin
                        if (t2_ctr[u_t2_idx] != {CTR_W{1'b0}}) t2_ctr[u_t2_idx] <= t2_ctr[u_t2_idx] - 1'b1;
                    end
                end

                if (u_chosen != 2'd0 && (u_tage_pred != u_alt_pred)) begin
                    if (u_chosen == 2'd1) begin
                        if (u_tage_ok) begin
                            if (t1_u[u_t1_idx] != {U_W{1'b1}}) t1_u[u_t1_idx] <= t1_u[u_t1_idx] + 1'b1;
                        end else begin
                            if (t1_u[u_t1_idx] != {U_W{1'b0}}) t1_u[u_t1_idx] <= t1_u[u_t1_idx] - 1'b1;
                        end
                    end else begin
                        if (u_tage_ok) begin
                            if (t2_u[u_t2_idx] != {U_W{1'b1}}) t2_u[u_t2_idx] <= t2_u[u_t2_idx] + 1'b1;
                        end else begin
                            if (t2_u[u_t2_idx] != {U_W{1'b0}}) t2_u[u_t2_idx] <= t2_u[u_t2_idx] - 1'b1;
                        end
                    end
                end

                if (!u_tage_ok) begin
                    case (u_chosen)
                        2'd0: begin
                            if (u_t1_alloc_ok) begin
                                t1_valid[u_t1_idx] <= 1'b1;
                                t1_tag[u_t1_idx]   <= u_t1_tagc;
                                t1_ctr[u_t1_idx]   <= upd_taken ? {1'b1, {(CTR_W-1){1'b0}}}
                                                                : {1'b0, {(CTR_W-1){1'b1}}};
                                t1_u[u_t1_idx]     <= {U_W{1'b0}};
                            end else if (u_t2_alloc_ok) begin
                                t2_valid[u_t2_idx] <= 1'b1;
                                t2_tag[u_t2_idx]   <= u_t2_tagc;
                                t2_ctr[u_t2_idx]   <= upd_taken ? {1'b1, {(CTR_W-1){1'b0}}}
                                                                : {1'b0, {(CTR_W-1){1'b1}}};
                                t2_u[u_t2_idx]     <= {U_W{1'b0}};
                            end else begin
                                for (j = 0; j < T1_SIZE; j = j + 1)
                                    if (t1_u[j] != {U_W{1'b0}}) t1_u[j] <= t1_u[j] - 1'b1;
                                for (j = 0; j < T2_SIZE; j = j + 1)
                                    if (t2_u[j] != {U_W{1'b0}}) t2_u[j] <= t2_u[j] - 1'b1;
                            end
                        end
                        2'd1: begin
                            if (u_t2_alloc_ok) begin
                                t2_valid[u_t2_idx] <= 1'b1;
                                t2_tag[u_t2_idx]   <= u_t2_tagc;
                                t2_ctr[u_t2_idx]   <= upd_taken ? {1'b1, {(CTR_W-1){1'b0}}}
                                                                : {1'b0, {(CTR_W-1){1'b1}}};
                                t2_u[u_t2_idx]     <= {U_W{1'b0}};
                            end else begin
                                for (j = 0; j < T2_SIZE; j = j + 1)
                                    if (t2_u[j] != {U_W{1'b0}}) t2_u[j] <= t2_u[j] - 1'b1;
                            end
                        end
                        default: ;
                    endcase
                end
            end

            // BTB：taken 时更新或分配（LRU 替换），not-taken 不动
            if (upd_taken) begin
                if (u_hit0) begin
                    btb0_target[upd_btb_idx] <= upd_target;
                    btb0_uncond[upd_btb_idx] <= upd_is_uncond;
                    btb_lru[upd_btb_idx]     <= 1'b1; // way0 MRU -> way1 LRU
                end else if (u_hit1) begin
                    btb1_target[upd_btb_idx] <= upd_target;
                    btb1_uncond[upd_btb_idx] <= upd_is_uncond;
                    btb_lru[upd_btb_idx]     <= 1'b0;
                end else begin
                    // 分配：优先填空 way；都满则替换 LRU
                    if (!btb0_valid[upd_btb_idx]) begin
                        btb0_valid [upd_btb_idx] <= 1'b1;
                        btb0_tag   [upd_btb_idx] <= upd_btb_tag;
                        btb0_target[upd_btb_idx] <= upd_target;
                        btb0_uncond[upd_btb_idx] <= upd_is_uncond;
                        btb_lru    [upd_btb_idx] <= 1'b1;
                    end else if (!btb1_valid[upd_btb_idx]) begin
                        btb1_valid [upd_btb_idx] <= 1'b1;
                        btb1_tag   [upd_btb_idx] <= upd_btb_tag;
                        btb1_target[upd_btb_idx] <= upd_target;
                        btb1_uncond[upd_btb_idx] <= upd_is_uncond;
                        btb_lru    [upd_btb_idx] <= 1'b0;
                    end else if (btb_lru[upd_btb_idx] == 1'b0) begin
                        // way0 LRU
                        btb0_valid [upd_btb_idx] <= 1'b1;
                        btb0_tag   [upd_btb_idx] <= upd_btb_tag;
                        btb0_target[upd_btb_idx] <= upd_target;
                        btb0_uncond[upd_btb_idx] <= upd_is_uncond;
                        btb_lru    [upd_btb_idx] <= 1'b1;
                    end else begin
                        // way1 LRU
                        btb1_valid [upd_btb_idx] <= 1'b1;
                        btb1_tag   [upd_btb_idx] <= upd_btb_tag;
                        btb1_target[upd_btb_idx] <= upd_target;
                        btb1_uncond[upd_btb_idx] <= upd_is_uncond;
                        btb_lru    [upd_btb_idx] <= 1'b0;
                    end
                end
            end

            // GHR 更新：左移 + upd_taken 进入
            ghr <= {ghr[GHR_W-2:0], upd_taken};
        end
    end
endmodule
