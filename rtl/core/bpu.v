// =============================================================
// bpu.v — 分支预测单元 (BTB + BHT)
//
//   BTB : 16 项直接映射，索引 = pc[5:2]
//         tag = pc[31:6]，存储跳转目标地址
//   BHT : 64 项 2-bit 饱和计数器，索引 = pc[7:2]
//         11 / 10 = predict taken；01 / 00 = not taken
//
//   IF 阶段：用 PC 同时查 BTB / BHT
//     - btb_hit && counter >= 2 → predict taken（输出 BTB 目标）
//     - 否则 → predict not-taken（IF 走 PC+4）
//
//   EX 阶段（后端）反馈分支真实结果，本模块同步更新：
//     - BHT：朝真实方向饱和移动
//     - BTB：taken 时分配/更新表项；not-taken 时不动 BTB
// =============================================================
module bpu #(
    parameter BHT_IDX_W = 6,   // 64 项
    parameter BTB_IDX_W = 4    // 16 项
)(
    input  wire        clk,
    input  wire        rst_n,

    // ----- IF: 预测查询 -----
    input  wire [31:0] if_pc,
    output wire        pred_taken,
    output wire [31:0] pred_target,

    // ----- 反馈/训练（来自 EX） -----
    input  wire        upd_valid,    // 本周期 EX 解析了一条分支/跳转
    input  wire [31:0] upd_pc,
    input  wire        upd_taken,
    input  wire [31:0] upd_target
);
    localparam BHT_SIZE = 1 << BHT_IDX_W;
    localparam BTB_SIZE = 1 << BTB_IDX_W;
    localparam BTB_TAG_W = 32 - BTB_IDX_W - 2;

    reg [1:0] bht [0:BHT_SIZE-1];

    reg                  btb_valid  [0:BTB_SIZE-1];
    reg [BTB_TAG_W-1:0]  btb_tag    [0:BTB_SIZE-1];
    reg [31:0]           btb_target [0:BTB_SIZE-1];

    integer i;
    initial begin
        for (i = 0; i < BHT_SIZE; i = i + 1) bht[i] = 2'b01;     // 弱不跳
        for (i = 0; i < BTB_SIZE; i = i + 1) btb_valid[i]  = 1'b0;
    end

    // -------- 预测 --------
    wire [BHT_IDX_W-1:0] if_bht_idx = if_pc[BHT_IDX_W+1:2];
    wire [BTB_IDX_W-1:0] if_btb_idx = if_pc[BTB_IDX_W+1:2];
    wire [BTB_TAG_W-1:0] if_btb_tag = if_pc[31:BTB_IDX_W+2];

    wire btb_hit = btb_valid[if_btb_idx] && (btb_tag[if_btb_idx] == if_btb_tag);
    wire bht_taken = bht[if_bht_idx][1];

    assign pred_taken  = btb_hit && bht_taken;
    assign pred_target = btb_target[if_btb_idx];

    // -------- 训练 --------
    wire [BHT_IDX_W-1:0] upd_bht_idx = upd_pc[BHT_IDX_W+1:2];
    wire [BTB_IDX_W-1:0] upd_btb_idx = upd_pc[BTB_IDX_W+1:2];
    wire [BTB_TAG_W-1:0] upd_btb_tag = upd_pc[31:BTB_IDX_W+2];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < BHT_SIZE; i = i + 1) bht[i] <= 2'b01;
            for (i = 0; i < BTB_SIZE; i = i + 1) btb_valid[i]  <= 1'b0;
        end else if (upd_valid) begin
            // BHT 饱和更新
            if (upd_taken) begin
                if (bht[upd_bht_idx] != 2'b11)
                    bht[upd_bht_idx] <= bht[upd_bht_idx] + 2'b01;
            end else begin
                if (bht[upd_bht_idx] != 2'b00)
                    bht[upd_bht_idx] <= bht[upd_bht_idx] - 2'b01;
            end

            // BTB：taken 时分配/更新（not-taken 不动）
            if (upd_taken) begin
                btb_valid [upd_btb_idx] <= 1'b1;
                btb_tag   [upd_btb_idx] <= upd_btb_tag;
                btb_target[upd_btb_idx] <= upd_target;
            end
        end
    end
endmodule
