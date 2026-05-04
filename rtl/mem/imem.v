// =============================================================
// imem.v — 指令侧直接映射 Cache（教学简化版）
//
// 结构：
//   - Backing store: mem[]（程序通过 $readmemh 预加载）
//   - I-Cache: 直接映射、1 字/行
//   - 读口：组合逻辑；miss 时返回主存数据，并在时钟沿填充 cache line
//
// 说明：
//   - 为了保持阶段 2~5 的 CPU 顶层接口不变，此模块不暴露 stall。
//   - 这是功能正确优先的教学模型，时序上等价于“零额外 miss 代价”。
// =============================================================
module imem #(
    parameter MEM_WORDS   = 16384,
    parameter HEX_FILE    = "tb/programs/test01.hex",
    parameter CACHE_LINES = 64
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire [31:0] addr,
    output wire [31:0] rdata,
    input  wire [31:0] addr1,
    output wire [31:0] rdata1
);
    localparam MEM_IDX_W   = $clog2(MEM_WORDS);
    localparam CACHE_IDX_W = $clog2(CACHE_LINES);
    localparam TAG_W       = 32 - CACHE_IDX_W - 2;

    // Backing store
    reg [31:0] mem [0:MEM_WORDS-1];

    // I-Cache arrays
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

    wire hit = (c_valid[c_idx] == 1'b1) && (c_tag[c_idx] == c_tg);

    wire [CACHE_IDX_W-1:0] c_idx1 = addr1[CACHE_IDX_W+1:2];
    wire [TAG_W-1:0]       c_tg1  = addr1[31:CACHE_IDX_W+2];
    wire [MEM_IDX_W-1:0]   m_idx1 = addr1[MEM_IDX_W+1:2];

    wire hit1 = (c_valid[c_idx1] == 1'b1) && (c_tag[c_idx1] == c_tg1);
    wire [1:0] hit_count = {1'b0, hit} + {1'b0, hit1};
    wire [1:0] miss_count = 2 - hit_count;

    integer i;
    initial begin
        stat_access = 0;
        stat_hit    = 0;
        stat_miss   = 0;
        for (i = 0; i < MEM_WORDS; i = i + 1) mem[i] = 32'h00000013;
        for (i = 0; i < CACHE_LINES; i = i + 1) begin
            c_valid[i] = 1'b0;
            c_tag[i]   = {TAG_W{1'b0}};
            c_data[i]  = 32'h00000013;
        end
        $readmemh(HEX_FILE, mem);
    end

    // 组合读：hit 取 cache，miss 直接取主存
    assign rdata = hit ? c_data[c_idx] : mem[m_idx];
    assign rdata1 = hit1 ? c_data[c_idx1] : mem[m_idx1];

    // miss 回填
    always @(posedge clk) begin
        if (!rst_n) begin
            stat_access <= 0;
            stat_hit    <= 0;
            stat_miss   <= 0;
        end else begin
            stat_access <= stat_access + 2;
            stat_hit    <= stat_hit + hit_count;
            stat_miss   <= stat_miss + miss_count;

            if (!hit) begin
                c_valid[c_idx] <= 1'b1;
                c_tag[c_idx]   <= c_tg;
                c_data[c_idx]  <= mem[m_idx];
            end

            if (!hit1) begin
                c_valid[c_idx1] <= 1'b1;
                c_tag[c_idx1]   <= c_tg1;
                c_data[c_idx1]  <= mem[m_idx1];
            end
        end
    end
endmodule
