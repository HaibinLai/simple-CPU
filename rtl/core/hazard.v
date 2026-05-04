// =============================================================
// hazard.v — Load-use 冒险检测（可组合多级）
//
// 支持两组可选检查：
//   1) ID/EX 中的 load 与 ID 源寄存器相关
//   2) EX/AGU 中的 load 与 ID 源寄存器相关
//
// 顶层可通过传入 ex_agu_mem_read=0 来屏蔽第 2 类检查，
// 以配合 MEM->EX load 前递做性能优化。
// =============================================================
module hazard (
    input  wire       id_ex_mem_read,
    input  wire [4:0] id_ex_rd,
    input  wire       ex_agu_mem_read,
    input  wire [4:0] ex_agu_rd,
    input  wire [4:0] id_rs1,
    input  wire [4:0] id_rs2,
    input  wire       id_use_rs1,
    input  wire       id_use_rs2,
    output wire       stall          // 1 = 本周期需要 stall
);
    wire rs1_dep_id_ex = id_use_rs1 && (id_ex_rd == id_rs1);
    wire rs2_dep_id_ex = id_use_rs2 && (id_ex_rd == id_rs2);
    wire rs1_dep_ex_agu = id_use_rs1 && (ex_agu_rd == id_rs1);
    wire rs2_dep_ex_agu = id_use_rs2 && (ex_agu_rd == id_rs2);

    wire hazard_id_ex = id_ex_mem_read &&
                        (id_ex_rd != 5'd0) &&
                        (rs1_dep_id_ex || rs2_dep_id_ex);

    wire hazard_ex_agu = ex_agu_mem_read &&
                         (ex_agu_rd != 5'd0) &&
                         (rs1_dep_ex_agu || rs2_dep_ex_agu);

    assign stall = hazard_id_ex || hazard_ex_agu;
endmodule
