// =============================================================
// tb_cpu.v — 顶层 testbench
// 通过 +PROG_HEX 宏指定要加载的程序
// 当 CPU 写 0xFFFFFFFC = 0xCAFEBABE 时认为测试结束
// =============================================================
`timescale 1ns/1ps

`ifndef PROG_HEX
  `define PROG_HEX "tb/programs/test01.hex"
`endif

module tb_cpu;
    reg clk = 0;
    reg rst_n = 0;

    always #5 clk = ~clk;  // 100MHz

    wire [31:0] dbg_pc, dbg_instr_wb, dbg_wb_data;
    wire        dbg_wb_we;
    wire [4:0]  dbg_wb_rd;

    cpu_top u_dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .dbg_pc       (dbg_pc),
        .dbg_instr_wb (dbg_instr_wb),
        .dbg_wb_we    (dbg_wb_we),
        .dbg_wb_rd    (dbg_wb_rd),
        .dbg_wb_data  (dbg_wb_data)
    );

    // 复位 + 仿真
    integer cycles = 0;
    integer instrs_retired = 0;
    integer br_total = 0;
    integer br_mispred = 0;

    // 直接窥探 DUT 内部 BPU 训练信号（仅仿真观察）
    wire dut_br_valid    = u_dut.bpu_upd_valid;
    wire dut_br_taken    = u_dut.bpu_upd_taken;
    wire dut_pred_taken  = u_dut.id_ex_pred_taken;
    wire [31:0] dut_pred_target = u_dut.id_ex_pred_target;
    wire [31:0] dut_actual_tgt  = u_dut.ex_actual_target;
    wire dut_mispredict  = u_dut.ex_mispredict;
    wire [31:0] ic_access = u_dut.u_imem.stat_access;
    wire [31:0] ic_hit    = u_dut.u_imem.stat_hit;
    wire [31:0] ic_miss   = u_dut.u_imem.stat_miss;
    wire [31:0] dc_access = u_dut.u_dmem.stat_access;
    wire [31:0] dc_hit    = u_dut.u_dmem.stat_hit;
    wire [31:0] dc_miss   = u_dut.u_dmem.stat_miss;

    initial begin
        $dumpfile("sim/cpu.vcd");
        $dumpvars(0, tb_cpu);

        rst_n = 0;
        repeat (4) @(posedge clk);
        rst_n = 1;
        $display("[TB] reset released, loading %s", `PROG_HEX);
    end

    // 监控：每条真正提交（写回且 rd != x0）的指令打印一行
    always @(posedge clk) begin
        if (rst_n) begin
            cycles <= cycles + 1;
            if (dbg_wb_we && dbg_wb_rd != 5'd0) begin
                instrs_retired <= instrs_retired + 1;
                $display("[%0t] cyc=%0d  WB  x%0d <= 0x%08h   (instr=0x%08h)",
                         $time, cycles, dbg_wb_rd, dbg_wb_data, dbg_instr_wb);
            end
            if (dut_br_valid) begin
                br_total <= br_total + 1;
                if (dut_mispredict) br_mispred <= br_mispred + 1;
            end
        end
    end

    // 简单结束条件：执行 200 个周期或 x31 = 0xCAFEBABE
    initial begin
        #2000;
        $display("\n[TB] simulation finished by timeout");
        $display("[TB] cycles=%0d  retired=%0d  CPI=%f",
                 cycles, instrs_retired,
                 (instrs_retired == 0) ? 0.0 : 1.0*cycles/instrs_retired);
        $display("[TB] I$ access=%0d hit=%0d miss=%0d miss_rate=%f",
                 ic_access, ic_hit, ic_miss,
                 (ic_access == 0) ? 0.0 : 1.0*ic_miss/ic_access);
        $display("[TB] D$ access=%0d hit=%0d miss=%0d miss_rate=%f",
                 dc_access, dc_hit, dc_miss,
                 (dc_access == 0) ? 0.0 : 1.0*dc_miss/dc_access);
        $finish;
    end

    // 检测到向 x31 写 0xCAFEBABE 即提前结束
    always @(posedge clk) begin
        if (rst_n && dbg_wb_we && dbg_wb_rd == 5'd31 && dbg_wb_data == 32'hCAFEBABE) begin
            #20;
            $display("\n[TB] PASS: x31 = 0xCAFEBABE detected");
            $display("[TB] cycles=%0d  retired=%0d  CPI=%f",
                     cycles, instrs_retired,
                     (instrs_retired == 0) ? 0.0 : 1.0*cycles/instrs_retired);
            $display("[TB] branches=%0d  mispredicts=%0d  miss_rate=%f",
                     br_total, br_mispred,
                     (br_total == 0) ? 0.0 : 1.0*br_mispred/br_total);
            $display("[TB] I$ access=%0d hit=%0d miss=%0d miss_rate=%f",
                     ic_access, ic_hit, ic_miss,
                     (ic_access == 0) ? 0.0 : 1.0*ic_miss/ic_access);
            $display("[TB] D$ access=%0d hit=%0d miss=%0d miss_rate=%f",
                     dc_access, dc_hit, dc_miss,
                     (dc_access == 0) ? 0.0 : 1.0*dc_miss/dc_access);
            $finish;
        end
    end
endmodule
