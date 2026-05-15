// =============================================================
// dmem.v — 数据侧 2-way set-associative D-Cache（4 字/行）
//
// 策略：
//   - 2-way set associative，64 sets * 2 ways * 4 words = 2 KB
//   - LRU 替换（每 set 1 bit：0 表示 way0 是 LRU，1 表示 way1 是 LRU）
//   - 写直达 (write-through) + 写分配 (write-allocate)
//   - 读口组合；miss 时直接从主存返回该字，并在时钟沿回填整行
//
// 接口与之前版本完全兼容（无 stall 信号、无 miss penalty）。
// 这是 P1.5：消 conflict miss（dotprod/matmul 中 A[i]/B[i] 映射到同一 set
// 的踢出问题）。
// =============================================================
module dmem #(
    parameter MEM_WORDS    = 16384,
    parameter CACHE_SETS   = 64,
    parameter LINE_WORDS   = 4              // 4 字/行
)(
    input  wire        clk,
    // Port A：原读写端口
    input  wire [31:0] addr,
    input  wire        we,
    input  wire [3:0]  be,
    input  wire [31:0] wdata,
    output wire [31:0] rdata,
    // Port B：slot1 memory port
    input  wire [31:0] addr_b,
    input  wire        re_b,
    input  wire        we_b,
    input  wire [3:0]  be_b,
    input  wire [31:0] wdata_b,
    output wire [31:0] rdata_b
);
    localparam MEM_IDX_W   = $clog2(MEM_WORDS);
    localparam SET_IDX_W   = $clog2(CACHE_SETS);
    localparam OFF_W       = $clog2(LINE_WORDS);          // 2
    localparam BLK_BITS    = 32 * LINE_WORDS;             // 128
    localparam TAG_W       = 32 - SET_IDX_W - OFF_W - 2;

    // Backing store
    reg [31:0] mem [0:MEM_WORDS-1];

    // 2 路 D-Cache：c_valid/tag/data 都按 way 平铺
    reg                 c_valid [0:1][0:CACHE_SETS-1];
    reg [TAG_W-1:0]     c_tag   [0:1][0:CACHE_SETS-1];
    reg [BLK_BITS-1:0]  c_data  [0:1][0:CACHE_SETS-1];
    // LRU bit per set: 0 表示 way0 是 LRU（应被替换），1 表示 way1 是 LRU
    reg                 c_lru   [0:CACHE_SETS-1];

    // 统计
    integer stat_access;
    integer stat_hit;
    integer stat_miss;
    integer stat_access_b;
    integer stat_hit_b;
    integer stat_miss_b;

    // ----- Port A 地址解码 -----
    wire [OFF_W-1:0]     a_off  = addr[OFF_W+1:2];
    wire [SET_IDX_W-1:0] a_idx  = addr[SET_IDX_W+OFF_W+1 : OFF_W+2];
    wire [TAG_W-1:0]     a_tg   = addr[31 : SET_IDX_W+OFF_W+2];
    wire [MEM_IDX_W-1:0] a_midx = addr[MEM_IDX_W+1:2];
    wire [MEM_IDX_W-1:0] a_blk_base = {addr[MEM_IDX_W+1:OFF_W+2], {OFF_W{1'b0}}};

    wire a_hit0 = c_valid[0][a_idx] && (c_tag[0][a_idx] == a_tg);
    wire a_hit1 = c_valid[1][a_idx] && (c_tag[1][a_idx] == a_tg);
    wire a_hit  = a_hit0 || a_hit1;
    wire a_hit_way = a_hit1;                    // 命中时落在哪一路（0/1）
    // miss 时按 LRU 选 victim way；若有空 way 优先填空 way
    wire a_have_empty = !c_valid[0][a_idx] || !c_valid[1][a_idx];
    wire a_empty_way  = !c_valid[0][a_idx] ? 1'b0 : 1'b1;
    wire a_victim_way = a_have_empty ? a_empty_way : c_lru[a_idx];

    wire access = we || (be != 4'b0000);

    wire [31:0] cache_word_a = a_hit0 ? c_data[0][a_idx][a_off*32 +: 32]
                                      : c_data[1][a_idx][a_off*32 +: 32];
    wire [31:0] src_word     = a_hit ? cache_word_a : mem[a_midx];

    // ----- Port B 地址解码 -----
    wire [OFF_W-1:0]     b_off   = addr_b[OFF_W+1:2];
    wire [SET_IDX_W-1:0] b_idx   = addr_b[SET_IDX_W+OFF_W+1 : OFF_W+2];
    wire [TAG_W-1:0]     b_tg    = addr_b[31 : SET_IDX_W+OFF_W+2];
    wire [MEM_IDX_W-1:0] b_midx  = addr_b[MEM_IDX_W+1:2];
    wire [MEM_IDX_W-1:0] b_blk_base = {addr_b[MEM_IDX_W+1:OFF_W+2], {OFF_W{1'b0}}};

    wire b_hit0 = c_valid[0][b_idx] && (c_tag[0][b_idx] == b_tg);
    wire b_hit1 = c_valid[1][b_idx] && (c_tag[1][b_idx] == b_tg);
    wire b_hit  = b_hit0 || b_hit1;
    wire b_have_empty = !c_valid[0][b_idx] || !c_valid[1][b_idx];
    wire b_empty_way  = !c_valid[0][b_idx] ? 1'b0 : 1'b1;
    wire b_victim_way = b_have_empty ? b_empty_way : c_lru[b_idx];

    wire [31:0] cache_word_b = b_hit0 ? c_data[0][b_idx][b_off*32 +: 32]
                                      : c_data[1][b_idx][b_off*32 +: 32];
    wire [31:0] srcb_word    = b_hit ? cache_word_b : mem[b_midx];
    assign rdata_b = srcb_word;

    // 写掩码合并（仅作用在 a_off 位置那一字上）
    wire [31:0] be_mask = {
        {8{be[3]}}, {8{be[2]}}, {8{be[1]}}, {8{be[0]}}
    };
    wire [31:0] merged_word = (src_word & ~be_mask) | (wdata & be_mask);
    wire [31:0] be_mask_b = {
        {8{be_b[3]}}, {8{be_b[2]}}, {8{be_b[1]}}, {8{be_b[0]}}
    };
    wire [31:0] merged_word_b = (srcb_word & ~be_mask_b) | (wdata_b & be_mask_b);

    // 装配 refill 行（Port A）：从 mem 读 LINE_WORDS 字；若 we 命中那一字则替换
    integer w;
    reg [BLK_BITS-1:0] refill_block;
    always @(*) begin
        refill_block = {BLK_BITS{1'b0}};
        for (w = 0; w < LINE_WORDS; w = w + 1) begin
            if (we && (a_off == w[OFF_W-1:0]))
                refill_block[w*32 +: 32] = merged_word;
            else
                refill_block[w*32 +: 32] = mem[a_blk_base + w[MEM_IDX_W-1:0]];
        end
    end

    // 命中行写回时仅替换 a_off 那一字（用于命中 way 的 c_data 更新）
    reg [BLK_BITS-1:0] hit_writeback_block;
    always @(*) begin
        hit_writeback_block = a_hit0 ? c_data[0][a_idx] : c_data[1][a_idx];
        if (we) hit_writeback_block[a_off*32 +: 32] = merged_word;
    end

    // Port B refill
    reg [BLK_BITS-1:0] refill_block_b;
    always @(*) begin
        refill_block_b = {BLK_BITS{1'b0}};
        for (w = 0; w < LINE_WORDS; w = w + 1) begin
            if (we_b && (b_off == w[OFF_W-1:0]))
                refill_block_b[w*32 +: 32] = merged_word_b;
            else
                refill_block_b[w*32 +: 32] = mem[b_blk_base + w[MEM_IDX_W-1:0]];
        end
    end

    reg [BLK_BITS-1:0] hit_writeback_block_b;
    always @(*) begin
        hit_writeback_block_b = b_hit0 ? c_data[0][b_idx] : c_data[1][b_idx];
        if (we_b) hit_writeback_block_b[b_off*32 +: 32] = merged_word_b;
    end

    integer i, k;
    initial begin
        stat_access = 0;
        stat_hit    = 0;
        stat_miss   = 0;
        stat_access_b = 0;
        stat_hit_b    = 0;
        stat_miss_b   = 0;
        for (i = 0; i < MEM_WORDS; i = i + 1) mem[i] = 32'h0;
        for (k = 0; k < 2; k = k + 1) begin
            for (i = 0; i < CACHE_SETS; i = i + 1) begin
                c_valid[k][i] = 1'b0;
                c_tag[k][i]   = {TAG_W{1'b0}};
                c_data[k][i]  = {BLK_BITS{1'b0}};
            end
        end
        for (i = 0; i < CACHE_SETS; i = i + 1) c_lru[i] = 1'b0;
    end

    // 组合读：load 时 miss 也能直接看到主存值
    assign rdata = src_word;

    always @(posedge clk) begin
        if (access) begin
            stat_access <= stat_access + 1;
            if (a_hit) stat_hit <= stat_hit + 1;
            else       stat_miss <= stat_miss + 1;
        end

        // miss 回填到 victim way（读写都会触发写分配）
        if (access && !a_hit) begin
            c_valid[a_victim_way][a_idx] <= 1'b1;
            c_tag  [a_victim_way][a_idx] <= a_tg;
            c_data [a_victim_way][a_idx] <= refill_block;
            // 新填的 way 变成 MRU → 另一路成为 LRU
            c_lru[a_idx] <= ~a_victim_way;
        end else if (access && a_hit) begin
            // hit：被命中的 way 成为 MRU
            c_lru[a_idx] <= ~a_hit_way;
        end

        if (we) begin
            // 写直达主存（仅那一字）
            mem[a_midx] <= merged_word;
            // 命中时更新 cache 行内对应字
            if (a_hit0) c_data[0][a_idx] <= hit_writeback_block;
            if (a_hit1) c_data[1][a_idx] <= hit_writeback_block;
        end

        // ----- Port B 统计与读写 -----
        // Port A 与 Port B 同 cycle 同 set 都 miss 时优先 A，B 跳过回填
        if (re_b || we_b) begin
            stat_access_b <= stat_access_b + 1;
            if (b_hit) stat_hit_b  <= stat_hit_b  + 1;
            else       stat_miss_b <= stat_miss_b + 1;

            if (!b_hit && !(access && !a_hit && (a_idx == b_idx))) begin
                c_valid[b_victim_way][b_idx] <= 1'b1;
                c_tag  [b_victim_way][b_idx] <= b_tg;
                c_data [b_victim_way][b_idx] <= refill_block_b;
                c_lru[b_idx] <= ~b_victim_way;
            end else if (b_hit && !(access && a_hit && (a_idx == b_idx))) begin
                // B hit 且与 A 不冲突 → 更新 LRU（如与 A 冲突，A 已更新过）
                c_lru[b_idx] <= ~b_hit1;
            end

            if (we_b && !(access && (a_idx == b_idx))) begin
                mem[b_midx] <= merged_word_b;
                if (b_hit0) c_data[0][b_idx] <= hit_writeback_block_b;
                if (b_hit1) c_data[1][b_idx] <= hit_writeback_block_b;
            end
        end
    end
endmodule
