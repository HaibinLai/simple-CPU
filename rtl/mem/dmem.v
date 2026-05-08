// =============================================================
// dmem.v — 数据侧直接映射 Cache（教学简化版，4 字/行版本）
//
// 策略：
//   - 直接映射、4 字/行（16 字节）
//   - 写直达（write-through）
//   - 写分配（write-allocate）
//   - 读口组合；miss 时直接从主存返回该字，并在时钟沿回填整行
//
// 接口与 1-字/行版本完全兼容（无 stall 信号、无 miss penalty）。
// 这是 P1 优化：用 4 字/行换取空间局部性 + 4 倍容量。
// =============================================================
module dmem #(
    parameter MEM_WORDS    = 16384,
    parameter CACHE_LINES  = 64,
    parameter LINE_WORDS   = 4              // 4 字/行
)(
    input  wire        clk,
    // Port A：原读写端口
    input  wire [31:0] addr,
    input  wire        we,
    input  wire [3:0]  be,
    input  wire [31:0] wdata,
    output wire [31:0] rdata,
    // Port B：只读端口（slot1 LOAD）
    input  wire [31:0] addr_b,
    input  wire        re_b,
    output wire [31:0] rdata_b
);
    localparam MEM_IDX_W   = $clog2(MEM_WORDS);
    localparam CACHE_IDX_W = $clog2(CACHE_LINES);
    localparam OFF_W       = $clog2(LINE_WORDS);          // 2
    localparam BLK_BITS    = 32 * LINE_WORDS;             // 128
    localparam TAG_W       = 32 - CACHE_IDX_W - OFF_W - 2;

    // Backing store
    reg [31:0] mem [0:MEM_WORDS-1];

    // D-Cache arrays (line = LINE_WORDS 个 32-bit 字，pack 成 128-bit)
    reg                 c_valid [0:CACHE_LINES-1];
    reg [TAG_W-1:0]     c_tag   [0:CACHE_LINES-1];
    reg [BLK_BITS-1:0]  c_data  [0:CACHE_LINES-1];

    // 统计
    integer stat_access;
    integer stat_hit;
    integer stat_miss;
    integer stat_access_b;
    integer stat_hit_b;
    integer stat_miss_b;

    // ----- Port A 地址解码 -----
    wire [OFF_W-1:0]       a_off  = addr[OFF_W+1:2];
    wire [CACHE_IDX_W-1:0] c_idx  = addr[CACHE_IDX_W+OFF_W+1 : OFF_W+2];
    wire [TAG_W-1:0]       c_tg   = addr[31 : CACHE_IDX_W+OFF_W+2];
    wire [MEM_IDX_W-1:0]   m_idx  = addr[MEM_IDX_W+1:2];
    // 行起始字在 mem[] 内的索引（最低 OFF_W 位清零）
    wire [MEM_IDX_W-1:0]   m_blk_base = {addr[MEM_IDX_W+1:OFF_W+2], {OFF_W{1'b0}}};

    wire hit    = c_valid[c_idx] && (c_tag[c_idx] == c_tg);
    wire access = we || (be != 4'b0000);

    // 从 cache 行里挑出当前字
    wire [31:0] cache_word_a = c_data[c_idx][a_off*32 +: 32];
    wire [31:0] src_word     = hit ? cache_word_a : mem[m_idx];

    // ----- Port B 地址解码 -----
    wire [OFF_W-1:0]       b_off   = addr_b[OFF_W+1:2];
    wire [CACHE_IDX_W-1:0] cb_idx  = addr_b[CACHE_IDX_W+OFF_W+1 : OFF_W+2];
    wire [TAG_W-1:0]       cb_tg   = addr_b[31 : CACHE_IDX_W+OFF_W+2];
    wire [MEM_IDX_W-1:0]   mb_idx  = addr_b[MEM_IDX_W+1:2];
    wire [MEM_IDX_W-1:0]   mb_blk_base = {addr_b[MEM_IDX_W+1:OFF_W+2], {OFF_W{1'b0}}};
    wire hit_b = c_valid[cb_idx] && (c_tag[cb_idx] == cb_tg);
    wire [31:0] cache_word_b = c_data[cb_idx][b_off*32 +: 32];
    wire [31:0] srcb_word    = hit_b ? cache_word_b : mem[mb_idx];
    assign rdata_b = srcb_word;

    // 写掩码合并（仅作用在 a_off 位置那一字上）
    wire [31:0] be_mask = {
        {8{be[3]}}, {8{be[2]}}, {8{be[1]}}, {8{be[0]}}
    };
    wire [31:0] merged_word = (src_word & ~be_mask) | (wdata & be_mask);

    // 装配整行：以 miss-fill 时从 mem 读出 4 字为基础，
    // 若 we && a_off==k，则把第 k 字替换为 merged_word。
    // 用 generate 不太方便（LINE_WORDS 是参数但小且固定），直接展开 4 字。
    // 通用化：循环。
    integer w;
    reg [BLK_BITS-1:0] refill_block;
    always @(*) begin
        refill_block = {BLK_BITS{1'b0}};
        for (w = 0; w < LINE_WORDS; w = w + 1) begin
            // m_blk_base+w 字
            if (we && (a_off == w[OFF_W-1:0]))
                refill_block[w*32 +: 32] = merged_word;
            else
                refill_block[w*32 +: 32] = mem[m_blk_base + w[MEM_IDX_W-1:0]];
        end
    end

    // 命中行写回时仅替换 a_off 那一字，其余字保持
    reg [BLK_BITS-1:0] hit_writeback_block;
    always @(*) begin
        hit_writeback_block = c_data[c_idx];
        if (we) hit_writeback_block[a_off*32 +: 32] = merged_word;
    end

    // Port B refill 整行（不写 mem，不会被 we 改写）
    reg [BLK_BITS-1:0] refill_block_b;
    always @(*) begin
        refill_block_b = {BLK_BITS{1'b0}};
        for (w = 0; w < LINE_WORDS; w = w + 1) begin
            refill_block_b[w*32 +: 32] = mem[mb_blk_base + w[MEM_IDX_W-1:0]];
        end
    end

    integer i;
    initial begin
        stat_access = 0;
        stat_hit    = 0;
        stat_miss   = 0;
        stat_access_b = 0;
        stat_hit_b    = 0;
        stat_miss_b   = 0;
        for (i = 0; i < MEM_WORDS; i = i + 1) mem[i] = 32'h0;
        for (i = 0; i < CACHE_LINES; i = i + 1) begin
            c_valid[i] = 1'b0;
            c_tag[i]   = {TAG_W{1'b0}};
            c_data[i]  = {BLK_BITS{1'b0}};
        end
    end

    // 组合读：load 时 miss 也能直接看到主存值
    assign rdata = src_word;

    always @(posedge clk) begin
        if (access) begin
            stat_access <= stat_access + 1;
            if (hit) stat_hit <= stat_hit + 1;
            else     stat_miss <= stat_miss + 1;
        end

        // miss 回填整行（读写都会触发写分配）
        if (access && !hit) begin
            c_valid[c_idx] <= 1'b1;
            c_tag[c_idx]   <= c_tg;
            c_data[c_idx]  <= refill_block;
        end

        if (we) begin
            // 写直达主存（仅那一字）
            mem[m_idx] <= merged_word;
            // 命中时更新 cache 行内对应字
            if (hit) c_data[c_idx] <= hit_writeback_block;
        end

        // ----- Port B 统计与回填（只读，不写主存）-----
        // 若 Port A 与 Port B 同 cycle 都 miss 同一行，优先 A 端，
        // B 端跳过回填以避免 race。
        if (re_b) begin
            stat_access_b <= stat_access_b + 1;
            if (hit_b) stat_hit_b  <= stat_hit_b  + 1;
            else       stat_miss_b <= stat_miss_b + 1;

            if (!hit_b && !(access && !hit && (c_idx == cb_idx))) begin
                c_valid[cb_idx] <= 1'b1;
                c_tag[cb_idx]   <= cb_tg;
                c_data[cb_idx]  <= refill_block_b;
            end
        end
    end
endmodule
