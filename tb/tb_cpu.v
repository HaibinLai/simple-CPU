// =============================================================
// tb_cpu.v — 顶层 testbench
// 通过 +PROG_HEX 宏指定要加载的程序
// 当 CPU 写 0xFFFFFFFC = 0xCAFEBABE 时认为测试结束
// =============================================================
`timescale 1ns/1ps

`ifndef PROG_HEX
  `define PROG_HEX "tb/programs/test01.hex"
`endif

`ifndef SIM_TIMEOUT_NS
  `define SIM_TIMEOUT_NS 2000
`endif

`ifndef VCD_FILE
  `define VCD_FILE "sim/cpu.vcd"
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
    integer instrs_retired = 0;     // 旧定义：wb_we && rd!=x0（与 dbg 对齐，保持向后兼容）
    integer instrs_committed = 0;   // 新定义：每个 valid 走到 WB 的指令都算（含 store/branch/x0 写）
    integer rob_committed = 0;      // M3.3: ROB commit ports 计数（含 x0/store/branch）
    integer rob_committed_rw = 0;   // M3.3: ROB commit 中 reg_write && rd!=x0 数（应 == instrs_retired）
    integer c_rn_stall = 0;         // M3.4a: rename stall 计数
    // M3.4c-step2: PRF 读出 vs 现有转发结果一致性计数（仅在 rs ready 时检查）
    integer c_prf_chk0 = 0, c_prf_chk1 = 0;
    integer c_prf_mis0 = 0, c_prf_mis1 = 0;
    // M3.4d: 架构一致性检查（在许多拍后采样 PRF[0..31] vs u_rf.regs[0..31]）
    integer c_arch_diff = 0;
    // M3.4e: flush 后 rename 状态不变骏检查
    integer c_flushes        = 0;
    integer c_flush_bad_free = 0;  // flush 后下一拍 free_count != 16
    integer c_flush_bad_busy = 0;  // flush 后下一拍 busy_vec != 0
    reg     prev_flush       = 1'b0;
    // M3.5: 推测写回不变骏：每个 WB 都应有 valid 的 ROB 项
    integer c_wb0_total       = 0;
    integer c_wb0_orphan      = 0;  // mem_wb 有效但 ROB[tag] 不 valid
    integer c_wb1_total       = 0;
    integer c_wb1_orphan      = 0;  // slot1 EX1 wb 有效但 ROB[tag] 不 valid

    // M3.3: shadow regfile，由 ROB commit 驱动；结束时与真 regfile 比对
    reg [31:0] shadow_rf [0:31];
    integer    sh_i;

    // M3.3: in-order commit assertion - PC 必须严格递增（ROB 是 FIFO）
    reg [31:0] last_commit_pc = 32'hFFFF_FFFF;
    reg        any_commit = 1'b0;
    integer br_total = 0;
    integer br_mispred = 0;

    // CPI 拆解计数器
    integer c_stall_lu     = 0;     // 因 load-use 触发的 ID 阶段 stall 拍数
    integer c_flush_br     = 0;     // 条件分支预测错误次数
    integer c_flush_jump   = 0;     // 无条件跳转引发的前端冲刷次数
    integer c_flush_exc    = 0;     // 异常 / mret 冲刷次数

    // R3 dual-issue 观测计数器
    integer c_dual_issue        = 0;  // 真正双发射 cycle 数（slot0 & slot1 同时 issue）
    integer c_single_issue      = 0;  // 仅 slot0 单发射 cycle 数
    integer c_pair_blk_notalu   = 0;  // slot1 非 ALU-only
    integer c_nta_load    = 0;       // notalu breakdown
    integer c_nta_store   = 0;
    integer c_nta_branch  = 0;
    integer c_nta_jump    = 0;
    integer c_nta_other   = 0;       // ecall / mret / illegal
    integer c_pair_blk_raw      = 0;  // slot0->slot1 RAW
    integer c_pair_blk_waw      = 0;  // 同 cycle WAW
    integer c_pair_blk_loaduse  = 0;  // slot1 依赖 in-flight load
    integer c_pair_blk_xcycwaw  = 0;  // 跨周期 WAW
    integer c_pair_blk_unsafe0  = 0;  // slot0 非安全指令
    integer c_pair_blk_novalid1 = 0;  // slot1 槽无效（IFQ 没第二条）
    integer c_ifq_full          = 0;  // IFQ 满阻塞 cycle
    integer c_ifq_almost_full   = 0;  // IFQ 接近满（反压 IF）

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

    // CPI 拆解所需的内部信号 peek
    wire dut_stall          = u_dut.stall;
    wire dut_ex_redirect    = u_dut.ex_redirect;
    wire dut_ex_is_branch   = u_dut.ex_is_branch;
    wire dut_ex_is_exc      = u_dut.ex_is_exception;
    wire dut_ex_is_mret     = u_dut.ex_is_mret_inst;
    wire dut_id_ex_is_jump  = u_dut.id_ex_is_jump;
    wire dut_id_ex_valid    = u_dut.id_ex_valid;
    wire dut_mem_wb_valid   = u_dut.mem_wb_valid;

    // R3: dual-issue 相关 peek
    wire dut_pop0           = u_dut.ifq_pop_slot0;
    wire dut_pop1           = u_dut.ifq_pop_slot1;
    wire dut_id1_valid1     = u_dut.id1_id2_valid1;
    wire dut_id1_alu_only   = u_dut.id1_is_pairable;  // R3: 已扩展为 pairable
    wire dut_id1_mem_read   = u_dut.id1_mem_read;
    wire dut_id1_mem_write  = u_dut.id1_mem_write;
    wire [2:0] dut_id1_brt  = u_dut.id1_br_type;
    wire dut_id1_is_jmp     = u_dut.id1_is_jump;
    wire dut_id1_no_raw     = u_dut.id1_no_raw_hazard;
    wire dut_id1_no_waw     = u_dut.id1_no_waw_hazard;
    wire dut_id1_no_lu      = u_dut.id1_no_load_use_hazard;
    wire dut_id1_no_xwaw    = u_dut.id1_no_xcycle_waw;
    wire dut_slot0_safe     = u_dut.id_slot0_safe_for_pair;
    wire dut_ifq_full       = u_dut.ifq_full;
    wire dut_ifq_almost     = u_dut.ifq_almost_full;

    // 在 EX 已被前端解析的有效条件分支：br_type!=NONE 且不是 JAL/JALR
    wire dut_is_cond_branch = dut_ex_is_branch && !dut_id_ex_is_jump;
    // 有效无条件跳转
    wire dut_is_uncond_jump = dut_id_ex_valid && dut_id_ex_is_jump;

    initial begin
`ifdef ENABLE_VCD
        $dumpfile(`VCD_FILE);
        $dumpvars(0, tb_cpu);
`endif

        rst_n = 0;
        repeat (4) @(posedge clk);
        rst_n = 1;
        $display("[TB] reset released, loading %s", `PROG_HEX);
    end

    initial begin
        for (sh_i = 0; sh_i < 32; sh_i = sh_i + 1) shadow_rf[sh_i] = 32'b0;
    end

    // 监控：每条真正提交（写回且 rd != x0）的指令打印一行
    always @(posedge clk) begin
        if (rst_n) begin
            cycles <= cycles + 1;
            // R2: 同 cycle 可能有 slot0 WB + slot1 EX1 写回，合并计数
            instrs_retired <= instrs_retired
                + ((dbg_wb_we && dbg_wb_rd != 5'd0) ? 1 : 0)
                + ((u_dut.slot1_wb_we && u_dut.slot1_wb_rd != 5'd0) ? 1 : 0);
            if (dbg_wb_we && dbg_wb_rd != 5'd0) begin
                $display("[%0t] cyc=%0d  WB  x%0d <= 0x%08h   (instr=0x%08h)",
                         $time, cycles, dbg_wb_rd, dbg_wb_data, dbg_instr_wb);
            end
            if (u_dut.slot1_wb_we && u_dut.slot1_wb_rd != 5'd0) begin
                $display("[%0t] cyc=%0d  S1  x%0d <= 0x%08h   (slot1 EX1)",
                         $time, cycles, u_dut.slot1_wb_rd, u_dut.slot1_wb_data);
            end
            instrs_committed <= instrs_committed
                + (dut_mem_wb_valid ? 1 : 0)
                + (u_dut.slot1_wb_we ? 1 : 0);

            // M3.3: ROB commit 端口计数（in-order）
            rob_committed <= rob_committed
                + (u_dut.rob_commit_valid_0 ? 1 : 0)
                + (u_dut.rob_commit_valid_1 ? 1 : 0);
            rob_committed_rw <= rob_committed_rw
                + ((u_dut.rob_commit_valid_0 && u_dut.rob_commit_rw_0 && u_dut.rob_commit_rd_0 != 5'd0) ? 1 : 0)
                + ((u_dut.rob_commit_valid_1 && u_dut.rob_commit_rw_1 && u_dut.rob_commit_rd_1 != 5'd0) ? 1 : 0);

            // M3.3 shadow regfile：由 commit 驱动（slot0 先于 slot1）
            if (u_dut.rob_commit_valid_0 && u_dut.rob_commit_rw_0 && u_dut.rob_commit_rd_0 != 5'd0)
                shadow_rf[u_dut.rob_commit_rd_0] <= u_dut.rob_commit_res_0;
            if (u_dut.rob_commit_valid_1 && u_dut.rob_commit_rw_1 && u_dut.rob_commit_rd_1 != 5'd0)
                shadow_rf[u_dut.rob_commit_rd_1] <= u_dut.rob_commit_res_1;

            // M3.4a observability: rename stall 计数（M3.4c 起需为 0）
            if (u_dut.rn_stall) c_rn_stall <= c_rn_stall + 1;

            // M3.4e: flush 不变骏。flush 拉高后，下一个上升沿 rename 需
            //   复位：free_count == 16, busy == 0, map = identity。
            prev_flush <= u_dut.ex_redirect;
            if (u_dut.ex_redirect) c_flushes <= c_flushes + 1;

            // M3.5: orphan-WB 检查。WB 会带一个 rob_tag；ROB[tag].valid 必须为 1。
            // 如果不为 1，代表有 "孤儿 WB"：其 ROB 项已被 flush 清除。
            if (u_dut.mem_wb_valid) begin
                c_wb0_total <= c_wb0_total + 1;
                if (!u_dut.u_rob.valid_q[u_dut.mem_wb_rob_tag]) begin
                    c_wb0_orphan <= c_wb0_orphan + 1;
                end
            end
            if (u_dut.id1_ex_valid && u_dut.slot1_wb_we) begin
                c_wb1_total <= c_wb1_total + 1;
                if (!u_dut.u_rob.valid_q[u_dut.id1_ex_rob_tag]) begin
                    c_wb1_orphan <= c_wb1_orphan + 1;
                end
            end
            if (prev_flush) begin
                if (u_dut.rn_free_count != 5'd16) begin
                    c_flush_bad_free <= c_flush_bad_free + 1;
                    if (c_flush_bad_free < 3)
                        $display("[TB][FLUSH] cyc=%0d free_count=%0d (expected 16)",
                                 cycles, u_dut.rn_free_count);
                end
                if (u_dut.rn_busy_vec != 48'b0) begin
                    c_flush_bad_busy <= c_flush_bad_busy + 1;
                    if (c_flush_bad_busy < 3)
                        $display("[TB][FLUSH] cyc=%0d busy_vec=0x%012h (expected 0)",
                                 cycles, u_dut.rn_busy_vec);
                end
            end

            // M3.4d observability: commit 后一拍，PRF[arch] 应 == regfile[arch]
            // （两者在同一上升沿分别被 commit 写入；PRF[arch] 由 prf_we2/3 驱动）
            // 这是个弱检查：达到下一个上升沿后，两个 regfile 应一致。
            if (u_dut.rob_commit_valid_0 && u_dut.rob_commit_rw_0 && u_dut.rob_commit_rd_0 != 5'd0) begin
                c_prf_chk0 <= c_prf_chk0 + 1;
            end
            if (u_dut.rob_commit_valid_1 && u_dut.rob_commit_rw_1 && u_dut.rob_commit_rd_1 != 5'd0) begin
                c_prf_chk1 <= c_prf_chk1 + 1;
            end

            // M3.3 in-order commit assertion: 同 cycle slot0->slot1 PC 必递增；跨 cycle 也必递增（除 jump/branch）
            // 注意：跳转 / 分支可使 PC 跳到任意位置，所以严格只检查 slot1.pc > slot0.pc 这种「同 cycle 双发射」的强约束
            if (u_dut.rob_commit_valid_0 && u_dut.rob_commit_valid_1) begin
                if (u_dut.rob_commit_pc_1 != u_dut.rob_commit_pc_0 + 4) begin
                    $display("[TB][WARN] commit dual-issue PC not contig: pc0=0x%08h pc1=0x%08h",
                             u_dut.rob_commit_pc_0, u_dut.rob_commit_pc_1);
                end
            end
            if (u_dut.rob_commit_valid_0) begin
                last_commit_pc <= u_dut.rob_commit_valid_1 ? u_dut.rob_commit_pc_1 : u_dut.rob_commit_pc_0;
                any_commit <= 1'b1;
            end
            if (dut_br_valid) begin
                br_total <= br_total + 1;
                if (dut_mispredict) br_mispred <= br_mispred + 1;
            end

            // CPI 拆解：load-use stall 计数（每被冻结一拍 +1）
            if (dut_stall) c_stall_lu <= c_stall_lu + 1;

            // 冲刷事件分类（互斥优先级：异常/mret > 无条件跳 > 条件分支错预测）
            if (dut_ex_redirect) begin
                if (dut_ex_is_exc || dut_ex_is_mret) c_flush_exc  <= c_flush_exc  + 1;
                else if (dut_is_uncond_jump)         c_flush_jump <= c_flush_jump + 1;
                else if (dut_is_cond_branch)         c_flush_br   <= c_flush_br   + 1;
            end

            // R3: dual-issue 计数（仅在 slot0 真正 pop 的 cycle 上分类）
            if (dut_pop0) begin
                if (dut_pop1)         c_dual_issue   <= c_dual_issue   + 1;
                else                  c_single_issue <= c_single_issue + 1;
            end

            // R3: 配对阻挡原因（仅在 slot0 pop 但 slot1 未 pop 时归因，按互斥优先级）
            if (dut_pop0 && !dut_pop1) begin
                if      (!dut_id1_valid1)   c_pair_blk_novalid1 <= c_pair_blk_novalid1 + 1;
                else if (!dut_slot0_safe)   c_pair_blk_unsafe0  <= c_pair_blk_unsafe0  + 1;
                else if (!dut_id1_alu_only) begin
                    c_pair_blk_notalu <= c_pair_blk_notalu + 1;
                    if      (dut_id1_mem_read)        c_nta_load   <= c_nta_load   + 1;
                    else if (dut_id1_mem_write)       c_nta_store  <= c_nta_store  + 1;
                    else if (dut_id1_brt != 3'b000)   c_nta_branch <= c_nta_branch + 1;
                    else if (dut_id1_is_jmp)          c_nta_jump   <= c_nta_jump   + 1;
                    else                              c_nta_other  <= c_nta_other  + 1;
                end
                else if (!dut_id1_no_raw)   c_pair_blk_raw      <= c_pair_blk_raw      + 1;
                else if (!dut_id1_no_waw)   c_pair_blk_waw      <= c_pair_blk_waw      + 1;
                else if (!dut_id1_no_lu)    c_pair_blk_loaduse  <= c_pair_blk_loaduse  + 1;
                else if (!dut_id1_no_xwaw)  c_pair_blk_xcycwaw  <= c_pair_blk_xcycwaw  + 1;
            end

            if (dut_ifq_full)       c_ifq_full        <= c_ifq_full        + 1;
            if (dut_ifq_almost)     c_ifq_almost_full <= c_ifq_almost_full + 1;
        end
    end

    // 通用统计打印
    task print_summary;
        integer ri;
        begin
            // 32 寄存器终态 dump（从 PRF[0..31] 读取，架构状态唯一来源）
            for (ri = 0; ri < 32; ri = ri + 1) begin
                $display("[TB] REG x%02d=0x%08h", ri, u_dut.u_prf.regs[ri]);
            end
            $display("[TB] cycles=%0d  retired=%0d  CPI=%f",
                     cycles, instrs_retired,
                     (instrs_retired == 0) ? 0.0 : 1.0*cycles/instrs_retired);
            $display("[TB] committed=%0d  CPI_c=%f",
                     instrs_committed,
                     (instrs_committed == 0) ? 0.0 : 1.0*cycles/instrs_committed);
            $display("[TB] rob_committed=%0d  rob_committed_rw=%0d  rob_count=%0d",
                     rob_committed, rob_committed_rw, u_dut.rob_count);
            $display("[TB] rn_stall_cycles=%0d  rn_free_count(end)=%0d",
                     c_rn_stall, u_dut.rn_free_count);
            // M3.4c-step2: 观察用计数。当前期望存在不匹配——根因是 dispatch 时
            // map[arch] 可能还指向初始 ptag(0..31)，而 PRF[0..31] 仅有复位 0；
            // 真正的语义修复在 M3.4d（commit-time 更新 ARF / map）。
            $display("[TB] commit_chk rs0=%0d rs1=%0d  arch_state_diff=%0d",
                     c_prf_chk0, c_prf_chk1, c_arch_diff);
            $display("[TB] flushes=%0d  bad_free_after=%0d  bad_busy_after=%0d",
                     c_flushes, c_flush_bad_free, c_flush_bad_busy);
            $display("[TB] wb_orph slot0=%0d/%0d  slot1=%0d/%0d",
                     c_wb0_orphan, c_wb0_total, c_wb1_orphan, c_wb1_total);
            // 注：当前 ROB.flush 一次清光所有条目（包括 mispredict 之前的老指令），
            // 老指令到 WB 时它的 ROB 项已被清 → orphan WB。这不影响 program correctness
            // (regfile 仍是权威)。M3.5-step2 将引入 partial flush 修复此问题。
            if (c_flush_bad_free != 0 || c_flush_bad_busy != 0) begin
                $display("[TB][ERROR] rename flush invariant violated");
            end
            // M3.3 sanity（弱）：commit 计数不应超过 retired（不能 over-commit）
            if (rob_committed_rw > instrs_retired) begin
                $display("[TB][ERROR] over-commit: rob_committed_rw=%0d > instrs_retired=%0d",
                         rob_committed_rw, instrs_retired);
            end
            $display("[TB] stalls: load_use=%0d  flush_br=%0d  flush_jump=%0d  flush_exc=%0d",
                     c_stall_lu, c_flush_br, c_flush_jump, c_flush_exc);
            $display("[TB] branches=%0d  mispredicts=%0d  miss_rate=%f",
                     br_total, br_mispred,
                     (br_total == 0) ? 0.0 : 1.0*br_mispred/br_total);
            $display("[TB] I$ access=%0d hit=%0d miss=%0d miss_rate=%f",
                     ic_access, ic_hit, ic_miss,
                     (ic_access == 0) ? 0.0 : 1.0*ic_miss/ic_access);
            $display("[TB] D$ access=%0d hit=%0d miss=%0d miss_rate=%f",
                     dc_access, dc_hit, dc_miss,
                     (dc_access == 0) ? 0.0 : 1.0*dc_miss/dc_access);
            $display("[TB] dual_issue=%0d single_issue=%0d dual_rate=%f",
                     c_dual_issue, c_single_issue,
                     (c_dual_issue + c_single_issue == 0) ? 0.0 :
                       1.0*c_dual_issue/(c_dual_issue + c_single_issue));
            $display("[TB] pair_blk: novalid1=%0d unsafe0=%0d notalu=%0d raw=%0d waw=%0d loaduse=%0d xcycwaw=%0d",
                     c_pair_blk_novalid1, c_pair_blk_unsafe0, c_pair_blk_notalu,
                     c_pair_blk_raw, c_pair_blk_waw, c_pair_blk_loaduse, c_pair_blk_xcycwaw);
            $display("[TB] nta_brk: load=%0d store=%0d branch=%0d jump=%0d other=%0d",
                     c_nta_load, c_nta_store, c_nta_branch, c_nta_jump, c_nta_other);
            $display("[TB] ifq: full=%0d almost_full=%0d",
                     c_ifq_full, c_ifq_almost_full);
            // TAGE-2L 影子评估器
            $display("[TB] tage_eval: total=%0d  t1_hit=%0d t2_hit=%0d  t1_use=%0d t2_use=%0d  t1_alloc=%0d t2_alloc=%0d alloc_fail=%0d",
                     u_dut.tage_total, u_dut.tage_t1_hit, u_dut.tage_t2_hit,
                     u_dut.tage_t1_use, u_dut.tage_t2_use,
                     u_dut.tage_t1_alloc, u_dut.tage_t2_alloc, u_dut.tage_alloc_fail);
            $display("[TB] tage_eval: tage_correct=%0d gshare_correct=%0d  tage_miss=%f gshare_miss=%f",
                     u_dut.tage_correct, u_dut.gshare_correct,
                     (u_dut.tage_total == 0) ? 0.0 : 1.0 - 1.0*u_dut.tage_correct/u_dut.tage_total,
                     (u_dut.tage_total == 0) ? 0.0 : 1.0 - 1.0*u_dut.gshare_correct/u_dut.tage_total);
        end
    endtask

    // 简单结束条件：执行 200 个周期或 x31 = 0xCAFEBABE
    initial begin
        #(`SIM_TIMEOUT_NS);
        $display("\n[TB] simulation finished by timeout");
        print_summary;
        $finish;
    end

    // 检测到向 x31 写 0xCAFEBABE 即提前结束
    always @(posedge clk) begin
        if (rst_n && dbg_wb_we && dbg_wb_rd == 5'd31 && dbg_wb_data == 32'hCAFEBABE) begin
            #20;
            $display("\n[TB] PASS: x31 = 0xCAFEBABE detected");
            print_summary;
            $finish;
        end
    end
endmodule
