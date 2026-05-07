// =============================================================
// dmem.v — 数据侧直接映射 Cache（教学简化版）
//
// 策略：
//   - 直接映射、1 字/行
//   - 写直达（write-through）
//   - 写分配（write-allocate）
//   - 读口组合；miss 时直接从主存返回并在时钟沿回填
//
// 说明：
//   - 保持阶段 2~5 的 dmem 接口不变，无 stall 信号。
//   - 以功能正确和结构清晰为主，后续可再加入 miss penalty 握手。
// =============================================================
module dmem #(
    parameter MEM_WORDS   = 16384,
    parameter CACHE_LINES = 64
)(
    input  wire        clk,
    // Port A：原读写端口（slot0 load/store；slot1 store 暂不支持）
    input  wire [31:0] addr,
    input  wire        we,
    input  wire [3:0]  be,
    input  wire [31:0] wdata,
    output wire [31:0] rdata,
    // Port B：只读端口（供 slot1 load 在 EX1 组合读 D-Cache）
    // 时序：addr_b 组合送入；rdata_b 在同 cycle 组合返回；
    //       re_b=1 时纳入统计与 miss-on-fill；为 0 时不计入统计。
    input  wire [31:0] addr_b,
    input  wire        re_b,
    output wire [31:0] rdata_b
);
    localparam MEM_IDX_W   = $clog2(MEM_WORDS);
    localparam CACHE_IDX_W = $clog2(CACHE_LINES);
    localparam TAG_W       = 32 - CACHE_IDX_W - 2;

    // Backing store
    reg [31:0] mem [0:MEM_WORDS-1];

    // D-Cache arrays
    reg                 c_valid [0:CACHE_LINES-1];
    reg [TAG_W-1:0]     c_tag   [0:CACHE_LINES-1];
    reg [31:0]          c_data  [0:CACHE_LINES-1];

    // 统计计数（供 testbench 层级读取）
    integer stat_access;
    integer stat_hit;
    integer stat_miss;
    // Port B 统计（slot1 load 用）
    integer stat_access_b;
    integer stat_hit_b;
    integer stat_miss_b;

    wire [CACHE_IDX_W-1:0] c_idx = addr[CACHE_IDX_W+1:2];
    wire [TAG_W-1:0]       c_tg  = addr[31:CACHE_IDX_W+2];
    wire [MEM_IDX_W-1:0]   m_idx = addr[MEM_IDX_W+1:2];

    wire hit = c_valid[c_idx] && (c_tag[c_idx] == c_tg);
    wire access = we || (be != 4'b0000);

    wire [31:0] src_word = hit ? c_data[c_idx] : mem[m_idx];

    // ----- Port B (只读) -----
    wire [CACHE_IDX_W-1:0] cb_idx = addr_b[CACHE_IDX_W+1:2];
    wire [TAG_W-1:0]       cb_tg  = addr_b[31:CACHE_IDX_W+2];
    wire [MEM_IDX_W-1:0]   mb_idx = addr_b[MEM_IDX_W+1:2];
    wire hit_b = c_valid[cb_idx] && (c_tag[cb_idx] == cb_tg);
    wire [31:0] srcb_word = hit_b ? c_data[cb_idx] : mem[mb_idx];
    assign rdata_b = srcb_word;

    // 写掩码合并
    wire [31:0] be_mask = {
        {8{be[3]}}, {8{be[2]}}, {8{be[1]}}, {8{be[0]}}
    };
    wire [31:0] merged_word = (src_word & ~be_mask) | (wdata & be_mask);

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
            c_data[i]  = 32'h0;
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

        // miss 回填（读写都会触发写分配）
        if (access && !hit) begin
            c_valid[c_idx] <= 1'b1;
            c_tag[c_idx]   <= c_tg;
            c_data[c_idx]  <= we ? merged_word : mem[m_idx];
        end

        if (we) begin
            // 写直达主存
            mem[m_idx] <= merged_word;

            // 命中时更新 cache；未命中时由上面的写分配回填
            if (hit) c_data[c_idx] <= merged_word;
        end

        // ----- Port B 统计与回填（只读，不写主存）-----
        // 若 Port A 与 Port B 同 cycle 都 miss 同一行，由 Port A 完成回填，
        // 这里只在不冲突时回填，避免 race（行号相同优先 A 端）。
        if (re_b) begin
            stat_access_b <= stat_access_b + 1;
            if (hit_b) stat_hit_b  <= stat_hit_b  + 1;
            else       stat_miss_b <= stat_miss_b + 1;

            if (!hit_b && !(access && !hit && (c_idx == cb_idx))) begin
                c_valid[cb_idx] <= 1'b1;
                c_tag[cb_idx]   <= cb_tg;
                c_data[cb_idx]  <= mem[mb_idx];
            end
        end
    end
endmodule
