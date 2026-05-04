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
    input  wire [31:0] addr,
    input  wire        we,
    input  wire [3:0]  be,
    input  wire [31:0] wdata,
    output wire [31:0] rdata
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

    wire [CACHE_IDX_W-1:0] c_idx = addr[CACHE_IDX_W+1:2];
    wire [TAG_W-1:0]       c_tg  = addr[31:CACHE_IDX_W+2];
    wire [MEM_IDX_W-1:0]   m_idx = addr[MEM_IDX_W+1:2];

    wire hit = c_valid[c_idx] && (c_tag[c_idx] == c_tg);
    wire access = we || (be != 4'b0000);

    wire [31:0] src_word = hit ? c_data[c_idx] : mem[m_idx];

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
    end
endmodule
