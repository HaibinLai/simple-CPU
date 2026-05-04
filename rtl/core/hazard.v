// =============================================================
// hazard.v — Load-use 冒险检测
//
// 当 ID/EX 中的指令是 LOAD 且其目标寄存器
// 与 ID 阶段当前指令的 rs1 或 rs2 相同时，
// 必须 stall 一个周期：
//   - 冻结 PC（保持当前 PC）
//   - 冻结 IF/ID（保持当前 instr）
//   - ID/EX 注入气泡（清掉控制信号）
// =============================================================
module hazard (
    input  wire       id_ex_mem_read,
    input  wire [4:0] id_ex_rd,
    input  wire [4:0] id_rs1,
    input  wire [4:0] id_rs2,
    output wire       stall          // 1 = 本周期需要 stall
);
    assign stall = id_ex_mem_read &&
                   (id_ex_rd != 5'd0) &&
                   ((id_ex_rd == id_rs1) || (id_ex_rd == id_rs2));
endmodule
