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
    parameter GHR_W     = 8
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

    // ----- BHT (GShare) -----
    reg [1:0] bht [0:BHT_SIZE-1];

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
    end

    // -------- 预测 (IF) --------
    wire [BTB_IDX_W-1:0] if_btb_idx = if_pc[BTB_IDX_W+1:2];
    wire [BTB_TAG_W-1:0] if_btb_tag = if_pc[31:BTB_IDX_W+2];

    wire if_hit0 = btb0_valid[if_btb_idx] && (btb0_tag[if_btb_idx] == if_btb_tag);
    wire if_hit1 = btb1_valid[if_btb_idx] && (btb1_tag[if_btb_idx] == if_btb_tag);
    wire btb_hit = if_hit0 | if_hit1;

    // GShare BHT 索引: pc[9:2] XOR ghr
    // GShare 启用：pc[9:2] XOR ghr_snapshot。训练端使用 IF 时的 GHR 快照。
    // 默认参数下 BHT_IDX_W==GHR_W==8，Verilog 自动宽度对齐。
    wire [BHT_IDX_W-1:0] if_pc_idx  = if_pc[BHT_IDX_W+1:2];
    wire [GHR_W-1:0]     ghr_snap   = ghr;
    wire [BHT_IDX_W-1:0] if_bht_idx = if_pc_idx ^ ghr_snap;
    wire bht_taken = bht[if_bht_idx][1];
    // 命中项是否为无条件跳转。若是，pred_taken 跳过 BHT 门控。
    wire if_hit_uncond = (if_hit0 && btb0_uncond[if_btb_idx]) ||
                         (if_hit1 && btb1_uncond[if_btb_idx]);

    assign pred_ghr_o  = ghr;
    assign pred_taken  = btb_hit && (if_hit_uncond || bht_taken);
    assign pred_target = if_hit0 ? btb0_target[if_btb_idx] : btb1_target[if_btb_idx];

    // -------- 训练 --------
    wire [BTB_IDX_W-1:0] upd_btb_idx = upd_pc[BTB_IDX_W+1:2];
    wire [BTB_TAG_W-1:0] upd_btb_tag = upd_pc[31:BTB_IDX_W+2];
    wire [BHT_IDX_W-1:0] upd_pc_idx  = upd_pc[BHT_IDX_W+1:2];
    wire [BHT_IDX_W-1:0] upd_bht_idx = upd_pc_idx ^ upd_pred_ghr;

    wire u_hit0 = btb0_valid[upd_btb_idx] && (btb0_tag[upd_btb_idx] == upd_btb_tag);
    wire u_hit1 = btb1_valid[upd_btb_idx] && (btb1_tag[upd_btb_idx] == upd_btb_tag);

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
            ghr <= {GHR_W{1'b0}};
        end else if (upd_valid) begin
            // BHT 饱和更新
            if (upd_taken) begin
                if (bht[upd_bht_idx] != 2'b11)
                    bht[upd_bht_idx] <= bht[upd_bht_idx] + 2'b01;
            end else begin
                if (bht[upd_bht_idx] != 2'b00)
                    bht[upd_bht_idx] <= bht[upd_bht_idx] - 2'b01;
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
