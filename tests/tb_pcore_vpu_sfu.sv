`timescale 1ns/1ps
import pcore_pkg::*;
import pcore_control_pkg::*;
import dea8_tile_link_pkg::*;
import fp32_legacy_ref_pkg::*;

// 7 Job environment for one PCore instance, K -> V -> Q -> Attention -> O -> G-U -> Down.
// The DUT, matrix, QOZ and workspace storage are real RTL; only the external
// SFU services are real RTL/IP; TB mathematics are scoreboards only. Modes:
//   TB_FUNCTIONAL   strict golden checks, legacy completion corners and the
//                   legacy fixed sink duty cycle.
//   TB_PERFORMANCE  no artificial stall at all; target VPU32/SFU4 throughput,
//                   II=1 channels, fixed service latency.
//   TB_STRESS       the same throughput model with random bubbles.
module tb_pcore_vpu_sfu #(
  parameter bit MANUAL=0,
  parameter int VPU_LANES=32,
  parameter int SFU_LANES=4,
  parameter int VPU_CMD_LAT=6,
  parameter int VPU_DONE_LAT=7,
  parameter int SFU_CMD_LAT=6,
  parameter int SFU_DONE_LAT=8,
  parameter int ROPE_LAT=8,
  parameter int ACC_RD_LAT=2,
  parameter int WORK_RD_LAT=1,
  parameter int ATTN_SLOT=434
);
  typedef enum {TB_FUNCTIONAL=0,TB_PERFORMANCE=1,TB_STRESS=2} tb_mode_e;
  logic clk=0;always #2 clk=~clk;
  logic reset=1,clear=0,job_valid=0,job_ready,done_valid,done_ready=0,busy,protocol_error;
  control_job_t job;control_completion_t done;
  logic [1:0] active_adapter;
  logic flush_valid,vpu_flush_ack=1,sfu_flush_ack;
  logic xbc_valid=0,xbc_ready,hbm_valid=0,hbm_ready,kv_valid=0,kv_ready;
  xbc4_t xbc_entry;b2_t hbm_entry,kv_entry;
  logic vector_valid,vector_ready=1,vector_done_valid=0,vector_done_ready;
  control_command_t vector_cmd;control_unit_done_t vector_done;
  logic function_valid,function_ready,function_done_valid,function_done_ready;
  control_command_t function_cmd;control_unit_done_t function_done;
  logic vector_data_valid,vector_data_ready=0,function_data_valid,function_data_ready;
  control_fp_data_t vector_data,function_data,function_result;
  logic function_result_valid,function_result_ready;
  logic vector_result_valid=0,vector_result_ready;control_quant_result_t vector_result;
  logic vector_mem_valid=0,vector_mem_ready,vector_mem_out_valid,vector_mem_out_ready=0;
  control_memory_req_t vector_mem_req;control_memory_rsp_t vector_mem_out;
  logic function_mem_valid,function_mem_ready,function_mem_out_valid,function_mem_out_ready;
  control_memory_req_t function_mem_req;control_memory_rsp_t function_mem_out;
  logic rope_req_valid=0,rope_req_ready,rope_sfu_valid,rope_sfu_ready;
  control_rope_req_t rope_req,rope_sfu_req;
  logic rope_sfu_out_valid,rope_sfu_out_ready,rope_out_valid,rope_out_ready=0;
  control_rope_rsp_t rope_sfu_out,rope_out;
  logic kv_out_valid,kv_out_ready=1,reduce_out_valid,reduce_out_ready=1;
  logic [135:0] kv_out;
  logic [511:0] reduce_out;
  logic kv_hdr_valid,kv_hdr_ready=1,kv_out_last;
  logic reduce_hdr_valid,reduce_hdr_ready=1,reduce_out_last;
  tile_header_t kv_hdr,reduce_hdr,kv_received_hdr,reduce_received_hdr;
  logic kv_commit_valid,kv_commit_ready;
  tile_commit_t kv_commit;
  bit commit_pending=0;
  int kv_beat=0,reduce_beat=0;
  assign kv_commit_valid=commit_pending;
  logic acc_rd_valid=0,acc_rd_ready,acc_data_valid,acc_data_ready=0;
  acc_sel_e acc_rd_sel;logic [9:0] acc_rd_addr;
  control_token_t acc_token;
  logic [15:0][31:0] acc_even,acc_odd;
  logic acc_wr_valid=0,acc_wr_ready;acc_write_t acc_wr;
  logic qoz_complete;qoz_region_req_t qoz_region;
  logic ext_qoz_region_valid=0,ext_qoz_region_ready,ext_qoz_wr_valid=0,ext_qoz_wr_ready;
  qoz_region_req_t ext_qoz_region;post_result_t ext_qoz_wr;logic [15:0] ext_qoz_context=16'h1234;
  logic gu_prefetch_valid,gu_prefetch_ready=1;logic [5:0] gu_prefetch_n;
  int cycle=0,job_start,issues[7],sent[7],commands[7],outputs[7],completed=0;
  int matrix_jobs=0,allowed_n=0;
  tb_mode_e mode;bit perf;bit hold_result=0;
  // Keep reference storage independent of the interface struct layout.
  logic [$bits(qvec16_t)-1:0] qgold[16][51],ogold[16][51],zgold[32][51];
  logic [$bits(qvec16_t)-1:0] kgold[2][51],vgold[2][32],pgold[55][51];
  logic [15:0][31:0] score[55][51],alpha[55][51];
  logic [31:0] m[51],lsum[51],recip[51];
  logic [31:0] reduced_gold[7][51],attention_gold[51];
  logic [15:0][31:0] scratch0[51],scratch1[51];
  bit kv_stall=0,reduce_stall=0;logic [135:0] kv_hold;logic [511:0] reduce_hold;
  bit vector_stall=0,function_stall=0;control_command_t vector_hold,function_hold;
  bit agents_enabled=1,allow_fault=0,hold_kv=0,hold_reduce=0;
  bit stress=0,corners=0;
  int seed=1;
  logic [31:0] random_state[20];
  longint coverage[24];
  int barrier_hits[7],function_commands=0,done_wait[7];
  int lifecycle_reads=0,lifecycle_releases=0,lifecycle_o_acquires=0,pv54_commits=0;
  bit q_released=0;
  bit acc_stall=0,vm_stall=0,fm_stall=0,rope_stall=0;
  logic [1023:0] acc_hold;
  control_memory_rsp_t vm_hold,fm_hold;
  control_rope_rsp_t rope_hold;
  int kv_tail_hold=0,reduce_tail_hold=0;
  bit kv_tail_seen=0,reduce_tail_seen=0;
  // Pipelined external service channels: request queues are presented II=1,
  // responses are released LAT cycles after the request was accepted.
  typedef struct packed {acc_sel_e sel;logic [9:0] addr;} acc_rd_item_t;
  acc_rd_item_t acc_rd_q[$];
  acc_write_t acc_wr_q[$];
  control_memory_req_t vm_req_q[$],fm_req_q[$];
  control_rope_req_t rope_req_q[$];
  int acc_age[$],vm_age[$],fm_age[$],rope_age[$];
  logic [1023:0] acc_rsp_q[$];
  control_memory_rsp_t vm_rsp_q[$],fm_rsp_q[$];
  control_rope_rsp_t rope_rsp_q[$];
  control_rope_rsp_t rope_sfu_rsp_q[$];
  // Performance accounting.
  int job_accept_cyc[7],first_issue_cyc[7],last_issue_cyc[7],done_cyc[7];
  int last_post_cyc[7],last_egress_cyc[7];
  int vstage_start,vstage_end,fstage_start,fstage_end,stage_dur_max[32];
  int scale_cycles=0,scale_margin_min=1000000;
  int attn_start[1024],attn_start_n,attn_qk_commits=0,attn_pv_commits=0;
  int fpace_n=0,fpace_ref=0;
  string mode_name;

  // Audited seven-VOP integration: all supported VPU commands execute real RTL.
  // BEGIN REAL QK INTEGRATION
  // Historical routing signal names retained; QK/P/SCALE/AFIN/RoPE/V/GU all use real RTL.
  // This is a TB-only routing shim; it does not change the upstream PCore RTL.
  logic qk_real_active = 1'b0;
  // BEGIN REAL P_POST INTEGRATION
  logic p_real_active = 1'b0;
  // BEGIN REAL OACC_SCALE INTEGRATION
  logic oacc_real_active = 1'b0;
  logic oacc_real_cmd;
  integer real_oacc_start_cycle, real_oacc_jobs=0;
  integer real_oacc_mem_reads, real_oacc_acc_reads, real_oacc_acc_writes;
  logic [5:0] real_oacc_tile_q;
  // V03_SCALE_SCOREBOARD_ORDERED_GOLDEN: one independent expected value per accepted ACC response.
  logic [15:0][31:0] oacc_expected_even[QOZ_O_TILES*PAIRS];
  logic [15:0][31:0] oacc_expected_odd[QOZ_O_TILES*PAIRS];
  // END REAL OACC_SCALE INTEGRATION
  // BEGIN REAL AFIN INTEGRATION (TB-only)
  logic afin_real_active = 1'b0;
  logic afin_real_cmd;
  control_token_t real_afin_token;
  integer real_afin_start_cycle, real_afin_jobs=0;
  integer real_afin_mem_req_count, real_afin_mem_reads;
  integer real_afin_acc_reads, real_afin_result_beats;
  qvec16_t real_afin_expected_even, real_afin_expected_odd;
  // END REAL AFIN INTEGRATION
  logic p_real_cmd, real_attention_active;
  logic pc_vector_data_ready, pc_vector_result_valid;
  control_quant_result_t pc_vector_result;
  integer real_p_start_cycle, real_p_data_beats, real_p_result_beats, real_p_l_writes;
  logic [5:0] real_p_tile_q;
  logic [31:0] real_p_expected_l[ROWS];
  // END REAL P_POST INTEGRATION
  logic real_qk_cmd, real_vpu_valid, real_vpu_ready;
  logic real_vpu_done_valid, real_vpu_done_ready;
  control_unit_done_t real_vpu_done;
  logic real_vpu_flush_ack;
  logic real_mem_valid, real_mem_out_ready, real_acc_rd_valid;
  logic real_acc_data_ready, real_acc_wr_valid;
  logic real_result_valid, real_data_ready;
  logic real_rope_req_valid, real_rope_out_ready;
  logic real_mem_ready, real_acc_rd_ready, real_acc_wr_ready;
  logic real_mem_out_valid, real_acc_data_valid;
  control_memory_req_t real_mem_req;
  acc_sel_e real_acc_rd_sel;
  logic [9:0] real_acc_rd_addr;
  control_token_t real_acc_token;
  acc_write_t real_acc_wr;
  control_quant_result_t real_result;
  control_rope_req_t real_rope_req;
  logic [50:0][15:0] real_qk_mask;
  logic pc_vector_ready,pc_vector_done_valid;
  control_unit_done_t pc_vector_done;
  logic pc_vector_mem_valid, pc_vector_mem_out_ready;
  control_memory_req_t pc_vector_mem_req;
  logic pc_acc_rd_valid, pc_acc_data_ready, pc_acc_wr_valid;
  acc_sel_e pc_acc_rd_sel;
  logic [9:0] pc_acc_rd_addr;
  control_token_t pc_acc_token;
  acc_write_t pc_acc_wr;
  logic pc_vpu_flush_ack;
  integer real_qk_start_cycle;
  logic [5:0] real_qk_tile_q;
  logic [31:0] qk_expected_aa[ROWS];
  assign real_qk_cmd=(vector_cmd.function_id==VECTOR_QK_POST);
  assign p_real_cmd=(vector_cmd.function_id==VECTOR_P_POST);
  assign oacc_real_cmd=(vector_cmd.function_id==VECTOR_OACC_SCALE);
  assign afin_real_cmd=(vector_cmd.function_id==VECTOR_AFIN_QUANT);
  logic projection_real_active=0;control_command_t projection_real_cmd;
  integer projection_start,projection_inputs,projection_results;
  logic [15:0][31:0] projection_first[ROWS],projection_second[ROWS];
  assign real_attention_active=projection_real_active||qk_real_active||p_real_active||oacc_real_active||afin_real_active;
  // REAL_VPU_STRESS_VALVES: delay presentation, then hold until handshake.
  logic cmd_gate,result_gate,done_gate,acc_gate,mem_gate;
  logic raw_result_valid,raw_done_valid,raw_acc_ready,raw_mem_ready;
  tb_vpu_stress_valve cmd_valve(clk,reset||clear,stress,seed,
    vector_valid&&!real_attention_active,real_vpu_ready,cmd_gate);
  tb_vpu_stress_valve result_valve(clk,reset||clear,stress,seed,
    raw_result_valid,vector_result_ready,result_gate);
  tb_vpu_stress_valve done_valve(clk,reset||clear,stress,seed,
    raw_done_valid,real_attention_active&&vector_done_ready,done_gate);
  tb_vpu_stress_valve acc_valve(clk,reset||clear,stress,seed,
    acc_data_valid,raw_acc_ready,acc_gate);
  tb_vpu_stress_valve mem_valve(clk,reset||clear,stress,seed,
    vector_mem_out_valid,raw_mem_ready,mem_gate);
  assign real_result_valid=raw_result_valid&&result_gate;
  assign real_vpu_done_valid=raw_done_valid&&done_gate;
  assign real_acc_data_ready=raw_acc_ready&&acc_gate;
  assign real_mem_out_ready=raw_mem_ready&&mem_gate;
  always @(posedge clk) if(!reset&&!clear&&stress)begin
    if(raw_result_valid&&!result_gate)coverage[5]++;
    if(raw_done_valid&&!done_gate)coverage[7]++;
  end
  assign real_vpu_valid=vector_valid&&(real_qk_cmd||p_real_cmd||oacc_real_cmd||afin_real_cmd||vector_cmd.function_id==VECTOR_ROPE_QUANT||vector_cmd.function_id==VECTOR_V_QUANT||vector_cmd.function_id==VECTOR_GU_POST)&&!real_attention_active&&cmd_gate;
  assign pc_vector_ready=real_attention_active?1'b0:((real_qk_cmd||p_real_cmd||oacc_real_cmd||afin_real_cmd||vector_cmd.function_id==VECTOR_ROPE_QUANT||vector_cmd.function_id==VECTOR_V_QUANT||vector_cmd.function_id==VECTOR_GU_POST)?(real_vpu_ready&&cmd_gate):vector_ready);
  assign real_vpu_done_ready=real_attention_active&&vector_done_ready&&done_gate;
  assign pc_vector_done_valid=real_attention_active?real_vpu_done_valid:vector_done_valid;
  assign pc_vector_done=real_attention_active?real_vpu_done:vector_done;
  assign pc_vector_mem_valid=real_attention_active?real_mem_valid:vector_mem_valid;
  assign pc_vector_mem_req=real_attention_active?real_mem_req:vector_mem_req;
  assign pc_vector_mem_out_ready=real_attention_active?real_mem_out_ready:vector_mem_out_ready;
  assign pc_acc_rd_valid=real_attention_active?real_acc_rd_valid:acc_rd_valid;
  assign pc_acc_rd_sel=real_attention_active?real_acc_rd_sel:acc_rd_sel;
  assign pc_acc_rd_addr=real_attention_active?real_acc_rd_addr:acc_rd_addr;
  assign pc_acc_token=real_attention_active?real_acc_token:acc_token;
  assign pc_acc_data_ready=real_attention_active?real_acc_data_ready:acc_data_ready;
  assign pc_acc_wr_valid=real_attention_active?real_acc_wr_valid:acc_wr_valid;
  assign pc_acc_wr=real_attention_active?real_acc_wr:acc_wr;
  assign pc_vpu_flush_ack=real_attention_active?real_vpu_flush_ack:vpu_flush_ack;
  assign pc_vector_data_ready=(p_real_active||projection_real_active)?real_data_ready:vector_data_ready;
  assign pc_vector_result_valid=(p_real_active||afin_real_active||projection_real_active)?real_result_valid:vector_result_valid;
  assign pc_vector_result=(p_real_active||afin_real_active||projection_real_active)?real_result:vector_result;

  // Mirror the EXISTING upstream TB golden mask (row 0 entirely masked;
  // block 54 lane 15 masked). This is NOT a frozen system-wide AR/last-3 mask.
  // Do not interpret this local rule as the final hardware mask contract.
  always_comb begin
    real_qk_mask='1;
    real_qk_mask[0]='0;
    if(vector_cmd.tile==6'd54)
      for(int row=1;row<ROWS;row++) real_qk_mask[row][15]=1'b0;
  end

  // Update software-side golden arrays WITHOUT issuing service requests.
  // The actual memory/ACC requests and all writes must come from the real RTL.
  task automatic real_qk_shadow_golden(input control_command_t c);
    logic [31:0] v,old_m,nm;
    for(int row=0;row<ROWS;row++)begin
      v=0;
      for(int k=0;k<TILE;k++)
        v=fp32_legacy_ref_pkg::fp32_add(v,dot_part(qgold[k][row],1+c.tile%3,128,-4));
      old_m=m[row];nm=old_m;
      for(int lane=0;lane<TILE;lane++)begin
        score[c.tile][row][lane]=real_qk_mask[row][lane]?v:32'hff800000;
        if(real32(score[c.tile][row][lane])>real32(nm))nm=score[c.tile][row][lane];
      end
      qk_expected_aa[row]=(old_m==nm)?32'd0:bits(real32(old_m)-real32(nm));
      m[row]=nm;
    end
  endtask

  always @(posedge clk)begin
    if(reset||clear)begin qk_real_active<=1'b0;p_real_active<=1'b0;oacc_real_active<=1'b0;afin_real_active<=1'b0;end
    else begin
      if(vector_valid&&pc_vector_ready&&real_qk_cmd)begin
        if(qk_real_active)$fatal(1,"real QK overlapping command");
        real_qk_start_cycle=cycle;
        real_qk_tile_q <= vector_cmd.tile;
        commands[OP_ATTENTION]++;
        real_qk_shadow_golden(vector_cmd);
        qk_real_active<=1'b1;
        $display("REAL_QK_ACCEPT tile=%0d token=%0h",vector_cmd.tile,vector_cmd.token);
      end
      if(vector_valid&&pc_vector_ready&&p_real_cmd)begin
        if(real_attention_active)$fatal(1,"real P overlapping command");
        real_p_start_cycle=cycle;
        real_p_tile_q<=vector_cmd.tile;
        real_p_data_beats=0;real_p_result_beats=0;real_p_l_writes=0;
        for(int r=0;r<ROWS;r++)real_p_expected_l[r]=lsum[r];
        commands[OP_ATTENTION]++;
        p_real_active<=1'b1;
        $display("REAL_P_ACCEPT tile=%0d token=%0h",vector_cmd.tile,vector_cmd.token);
      end
      if(p_real_active&&real_vpu_done_valid&&vector_done_ready)begin
        if(real_vpu_done.error||real_vpu_done.command.function_id!=VECTOR_P_POST)
          $fatal(1,"real P error or completion identity mismatch");
        if(real_p_data_beats!=PAIRS||real_p_result_beats!=PAIRS||real_p_l_writes!=((ROWS+TILE-1)/TILE))
          $fatal(1,"real P incomplete data=%0d results=%0d Lwrites=%0d",real_p_data_beats,real_p_result_beats,real_p_l_writes);
        if(cycle-real_p_start_cycle>stage_dur_max[VECTOR_P_POST])
          stage_dur_max[VECTOR_P_POST]=cycle-real_p_start_cycle;
        $display("REAL_P_DONE tile=%0d cycles=%0d data=%0d result=%0d lwrite=%0d",
          real_vpu_done.command.tile,cycle-real_p_start_cycle,real_p_data_beats,real_p_result_beats,real_p_l_writes);
        p_real_active<=1'b0;
      end
      if(vector_valid&&pc_vector_ready&&oacc_real_cmd)begin
        logic [31:0] accum;
        if(real_attention_active)$fatal(1,"real OACC overlapping command");
        if(vector_cmd.source!=WORK_OACC||vector_cmd.tiles!=QOZ_O_TILES||
           vector_cmd.elements!=ROWS*TILE*QOZ_O_TILES)
          $fatal(1,"real OACC command descriptor mismatch");
        real_oacc_start_cycle=cycle;
        real_oacc_tile_q<=vector_cmd.tile;
        real_oacc_mem_reads=0;real_oacc_acc_reads=0;real_oacc_acc_writes=0;
        commands[OP_ATTENTION]++;
        // Independent expected PRE-scale OACC: match original TB's PV history
        // arithmetic without forwarding behavioral service requests.
        for(int r=0;r<ROWS;r++)begin
          accum=0;
          for(int block=0;block<int'(vector_cmd.tile);block++)begin
            if(block>0)accum=mul32(accum,alpha[block][r][0]);
            accum=fp32_legacy_ref_pkg::fp32_add(accum,dot_part(pgold[block][r],1,128,0));
          end
          attention_gold[r]=accum;
        end
        oacc_real_active<=1'b1;
        $display("REAL_SCALE_ACCEPT tile=%0d token=%0h",vector_cmd.tile,vector_cmd.token);
      end
      if(oacc_real_active&&real_vpu_done_valid&&vector_done_ready)begin
        if(real_vpu_done.error||real_vpu_done.command.function_id!=VECTOR_OACC_SCALE||
           real_vpu_done.command.tile!==real_oacc_tile_q)
          $fatal(1,"real OACC Done error/identity mismatch");
        if(real_oacc_mem_reads!=((ROWS+TILE-1)/TILE)||
           real_oacc_acc_reads!=QOZ_O_TILES*PAIRS||
           real_oacc_acc_writes!=QOZ_O_TILES*PAIRS)
          $fatal(1,"real OACC count mismatch mem=%0d rd=%0d wr=%0d",
             real_oacc_mem_reads,real_oacc_acc_reads,real_oacc_acc_writes);
        if(cycle-real_oacc_start_cycle>stage_dur_max[VECTOR_OACC_SCALE])
           stage_dur_max[VECTOR_OACC_SCALE]=cycle-real_oacc_start_cycle;
        scale_cycles=cycle-real_oacc_start_cycle;
        if(ATTN_SLOT-scale_cycles<scale_margin_min)scale_margin_min=ATTN_SLOT-scale_cycles;
        real_oacc_jobs++;
        $display("REAL_SCALE_DONE tile=%0d cycles=%0d mem=%0d acc_reads=%0d acc_writes=%0d margin=%0d",
          real_oacc_tile_q,scale_cycles,real_oacc_mem_reads,
          real_oacc_acc_reads,real_oacc_acc_writes,ATTN_SLOT-scale_cycles);
        oacc_real_active<=1'b0;
      end
      // AFIN uses the real VPU (WORK_RECIP -> ACC_OACC -> RESULT -> DONE).
      // Keep the independently-computed PV-history golden; send NO behavioral traffic.
      if(vector_valid&&pc_vector_ready&&afin_real_cmd)begin : real_afin_accept
        logic [31:0] accum;
        if(real_attention_active)$fatal(1,"real AFIN overlapping command");
        if(vector_cmd.source!=WORK_OACC||vector_cmd.tiles!=QOZ_O_TILES||
           vector_cmd.elements!=ROWS*TILE*QOZ_O_TILES)
          $fatal(1,"real AFIN command descriptor mismatch");
        real_afin_start_cycle=cycle;
        real_afin_token<=vector_cmd.token;
        real_afin_mem_req_count=0;
        real_afin_mem_reads=0;
        real_afin_acc_reads=0;
        real_afin_result_beats=0;
        commands[OP_ATTENTION]++;
        for(int r=0;r<ROWS;r++)begin
          accum=0;
          for(int block=0;block<KV_BLOCKS;block++)begin
            if(block>0)accum=mul32(accum,alpha[block][r][0]);
            accum=fp32_legacy_ref_pkg::fp32_add(accum,dot_part(pgold[block][r],1,128,0));
          end
          attention_gold[r]=accum;
        end
        afin_real_active<=1'b1;
        $display("REAL_AFIN_ACCEPT token=%0h",vector_cmd.token);
      end
      if(afin_real_active&&real_vpu_done_valid&&vector_done_ready)begin
        if(real_vpu_done.error||real_vpu_done.command.function_id!=VECTOR_AFIN_QUANT||
           real_vpu_done.command.token!==real_afin_token)
          $fatal(1,"real AFIN Done error/identity mismatch");
        if(real_afin_mem_req_count!=((ROWS+TILE-1)/TILE)||
           real_afin_mem_reads!=((ROWS+TILE-1)/TILE)||
           real_afin_acc_reads!=QOZ_O_TILES*PAIRS||
           real_afin_result_beats!=QOZ_O_TILES*PAIRS)
          $fatal(1,"real AFIN count mismatch req=%0d rsp=%0d acc=%0d result=%0d",
            real_afin_mem_req_count,real_afin_mem_reads,
            real_afin_acc_reads,real_afin_result_beats);
        if(cycle-real_afin_start_cycle>stage_dur_max[VECTOR_AFIN_QUANT])
          stage_dur_max[VECTOR_AFIN_QUANT]=cycle-real_afin_start_cycle;
        real_afin_jobs++;
        $display("REAL_AFIN_DONE cycles=%0d mem_req=%0d mem_rsp=%0d acc_reads=%0d results=%0d",
          cycle-real_afin_start_cycle,real_afin_mem_req_count,real_afin_mem_reads,
          real_afin_acc_reads,real_afin_result_beats);
        afin_real_active<=1'b0;
      end
      if(qk_real_active&&real_vpu_done_valid&&vector_done_ready)begin
        if(real_vpu_done.error)$fatal(1,"real QK reported error");
        if(cycle-real_qk_start_cycle>stage_dur_max[VECTOR_QK_POST])
          stage_dur_max[VECTOR_QK_POST]=cycle-real_qk_start_cycle;
        $display("REAL_QK_DONE tile=%0d cycles=%0d",real_vpu_done.command.tile,cycle-real_qk_start_cycle);
        qk_real_active<=1'b0;
      end
    end
  end

  // For QK, compare every REAL workspace write against the existing reference.
  always @(posedge clk) if(!reset&&!clear&&qk_real_active&&real_mem_valid&&vector_mem_ready&&real_mem_req.write)begin
    case(real_mem_req.buffer_id)
      WORK_SCORE: begin
        for(int lane=0;lane<TILE;lane++)
          if(real_mem_req.mask[lane]&&real_mem_req.data[lane]!==score[real_qk_tile_q][real_mem_req.index][lane])
            $fatal(1,"real QK SCORE mismatch row=%0d lane=%0d",real_mem_req.index,lane);
      end
      WORK_M: begin
        for(int lane=0;lane<TILE;lane++)
          if(real_mem_req.mask[lane]&&real_mem_req.index+lane<ROWS&&real_mem_req.data[lane]!==m[real_mem_req.index+lane])
            $fatal(1,"real QK M mismatch row=%0d",real_mem_req.index+lane);
      end
      WORK_AA: begin
        for(int lane=0;lane<TILE;lane++)
          if(real_mem_req.mask[lane]&&real_mem_req.index+lane<ROWS&&real_mem_req.data[lane]!==qk_expected_aa[real_mem_req.index+lane])
            $fatal(1,"real QK AA mismatch row=%0d",real_mem_req.index+lane);
      end
      default: $fatal(1,"unexpected QK write buffer=%0d",real_mem_req.buffer_id);
    endcase
  end

  // Real P shadow/reference checks: independent of DUT data-path arithmetic.
  // The 26 accepted SFU beats update reference lsum and quantized pgold only.
  always @(posedge clk) if(!reset&&!clear&&p_real_active&&vector_data_valid&&pc_vector_data_ready)begin : real_p_data_golden
    logic [15:0][31:0] values;
    logic [31:0] next_l;
    logic [31:0] sum_nodes[0:30];
    int row;
    if(vector_data.tile!==real_p_tile_q||vector_data.index!==real_p_data_beats||
       vector_data.vector_valid!==row_mask(real_p_data_beats)||
       vector_data.last!==(real_p_data_beats==PAIRS-1))
      $fatal(1,"real P input stream identity/sequence mismatch beat=%0d",real_p_data_beats);
    for(int half=0;half<2;half++)begin
      row=2*real_p_data_beats+half;
      if(row<ROWS)begin
        values=half?vector_data.second:vector_data.first;
        // Independent reference with the same 16-leaf reduction grouping
        // as the VPU. FP32 addition is not associative: serial folding
        // gives different RNE results and would be an invalid exact golden.
        for(int lane=0;lane<TILE;lane++)sum_nodes[15+lane]=values[lane];
        for(int n=14;n>=0;n--)
          sum_nodes[n]=fp32_legacy_ref_pkg::fp32_add(sum_nodes[2*n+1],sum_nodes[2*n+2]);
        next_l=fp32_legacy_ref_pkg::fp32_add(
          mul32(lsum[row],alpha[real_p_tile_q][row][0]),sum_nodes[0]);
        lsum[row]=next_l;
        real_p_expected_l[row]=next_l;
        pgold[real_p_tile_q][row]=real_p_floor_quant(values);
      end
    end
    real_p_data_beats++;
  end

  // Compare *real* quantized output beats, not behavioral vector_result.
  always @(posedge clk) if(!reset&&!clear&&p_real_active&&real_result_valid&&vector_result_ready)begin : real_p_result_check
    qvec16_t expected;
    int row;
    if(real_result.tile!==real_p_tile_q||real_result.index!==real_p_result_beats||
       real_result.vector_valid!==row_mask(real_p_result_beats)||
       real_result.last!==(real_p_result_beats==PAIRS-1)||
       real_result.quant_axis!==QUANT_FEATURE_B16)
      $fatal(1,"real P result metadata mismatch beat=%0d",real_p_result_beats);
    for(int half=0;half<2;half++)begin
      row=2*real_p_result_beats+half;
      if(row<ROWS)begin
        expected=pgold[real_p_tile_q][row];
        if(real_result.vector_data[half]!==expected)
          $fatal(1,"real P quant mismatch tile=%0d row=%0d got=%h expected=%h",real_p_tile_q,row,real_result.vector_data[half],expected);
      end
    end
    real_p_result_beats++;
  end

  always @(posedge clk) if(!reset&&!clear&&p_real_active&&real_mem_valid&&vector_mem_ready&&real_mem_req.write)begin
    if(real_mem_req.buffer_id!=WORK_L)$fatal(1,"real P unexpected write buffer=%0d",real_mem_req.buffer_id);
    if(real_mem_req.index!==6'(real_p_l_writes*TILE))
      $fatal(1,"real P L write index mismatch idx=%0d beat=%0d",real_mem_req.index,real_p_l_writes);
    for(int lane=0;lane<TILE;lane++)if(real_mem_req.index+lane<ROWS)begin
      if(!real_mem_req.mask[lane]||real_mem_req.data[lane]!==real_p_expected_l[real_mem_req.index+lane])
        $fatal(1,"real P L mismatch row=%0d got=%h expected=%h",real_mem_req.index+lane,
          real_mem_req.data[lane],real_p_expected_l[real_mem_req.index+lane]);
    end
    real_p_l_writes++;
  end

  // REAL OACC_SCALE golden checks: no behavioral traffic is generated.
  // Validate the four accepted WORK_ALPHA bursts against QK shadow state.
  always @(posedge clk) if(!reset&&!clear&&oacc_real_active&&
      vector_mem_out_valid&&pc_vector_mem_out_ready)begin : oacc_alpha_read_check
    int row;
    if(real_oacc_mem_reads>=((ROWS+TILE-1)/TILE))
      $fatal(1,"real OACC extra alpha memory response");
    for(int lane=0;lane<TILE;lane++)begin
      row=real_oacc_mem_reads*TILE+lane;
      if(row<ROWS&&vector_mem_out.data[lane]!==alpha[real_oacc_tile_q][row][0])
        $fatal(1,"real OACC alpha mismatch block=%0d row=%0d got=%h exp=%h",
          real_oacc_tile_q,row,vector_mem_out.data[lane],alpha[real_oacc_tile_q][row][0]);
    end
    real_oacc_mem_reads++;
  end

  // Strictly check each ACC read against previous PV history, and compute
  // expected SCALE output independently (real-domain FP32 bit conversion).
  always @(posedge clk) if(!reset&&!clear&&oacc_real_active&&
      acc_data_valid&&pc_acc_data_ready)begin : oacc_acc_read_check
    int pair, row0, row1;
    if(real_oacc_acc_reads>=QOZ_O_TILES*PAIRS)
      $fatal(1,"real OACC extra ACC read");
    pair=real_oacc_acc_reads%PAIRS;
    row0=2*pair;row1=row0+1;
    for(int lane=0;lane<TILE;lane++)begin
      if(acc_even[lane]!==attention_gold[row0]||
          (row1<ROWS&&acc_odd[lane]!==attention_gold[row1]))
        $fatal(1,"real OACC before-scale data mismatch tile=%0d pair=%0d lane=%0d even=%h expected=%h",
          real_oacc_acc_reads/PAIRS,pair,lane,acc_even[lane],attention_gold[row0]);
      oacc_expected_even[real_oacc_acc_reads][lane]=mul32(acc_even[lane],alpha[real_oacc_tile_q][row0][0]);
      oacc_expected_odd[real_oacc_acc_reads][lane]=row1<ROWS ? mul32(acc_odd[lane],alpha[real_oacc_tile_q][row1][0]) : 32'b0;
    end
    real_oacc_acc_reads++;
  end

  // Monitor ONLY real VPU accumulator writes, preserving PCore-side valid/ready.
  always @(posedge clk) if(!reset&&!clear&&oacc_real_active&&
      real_acc_wr_valid&&acc_wr_ready)begin : oacc_acc_write_check
    int pair, tile;
    if(real_oacc_acc_writes>=QOZ_O_TILES*PAIRS)
      $fatal(1,"real OACC extra ACC write");
    if(real_oacc_acc_writes>=real_oacc_acc_reads)
      $fatal(1,"real OACC write before matching ACC response");
    tile=real_oacc_acc_writes/PAIRS;
    pair=real_oacc_acc_writes%PAIRS;
    if(real_acc_wr.sel!=ACC_OACC||real_acc_wr.addr!=tile*PAIRS+pair||
       real_acc_wr.row_valid!==row_mask(pair))
      $fatal(1,"real OACC ACC write metadata mismatch tile=%0d pair=%0d addr=%0d",
         tile,pair,real_acc_wr.addr);
    for(int lane=0;lane<TILE;lane++)begin
      if(real_acc_wr.data[0][lane]!==oacc_expected_even[real_oacc_acc_writes][lane]||
         (2*pair+1<ROWS&&real_acc_wr.data[1][lane]!==oacc_expected_odd[real_oacc_acc_writes][lane]))
        $fatal(1,"real OACC scaled ACC mismatch tile=%0d pair=%0d lane=%0d got=%h exp=%h",
          tile,pair,lane,real_acc_wr.data[0][lane],oacc_expected_even[real_oacc_acc_writes][lane]);
    end
    real_oacc_acc_writes++;
  end

  // Check all four accepted REAL AFIN WORK_RECIP read requests.
  always @(posedge clk) if(!reset&&!clear&&afin_real_active&&
      real_mem_valid&&vector_mem_ready)begin : real_afin_recip_request_check
    if(real_afin_mem_req_count>=((ROWS+TILE-1)/TILE)||real_mem_req.write||
       real_mem_req.buffer_id!=WORK_RECIP||real_mem_req.bank!=1'b0||
       real_mem_req.index!==6'(real_afin_mem_req_count*TILE)||
       real_mem_req.token!==real_afin_token)
      $fatal(1,"real AFIN RECIP request mismatch count=%0d buf=%0d idx=%0d",
        real_afin_mem_req_count,real_mem_req.buffer_id,real_mem_req.index);
    real_afin_mem_req_count++;
  end

  // Check all accepted REAL AFIN memory responses against the independent SFU RECIP array.
  always @(posedge clk) if(!reset&&!clear&&afin_real_active&&
      vector_mem_out_valid&&pc_vector_mem_out_ready)begin : real_afin_recip_response_check
    int row;
    if(real_afin_mem_reads>=((ROWS+TILE-1)/TILE)||
       vector_mem_out.token!==real_afin_token)
      $fatal(1,"real AFIN RECIP response count/token mismatch");
    for(int lane=0;lane<TILE;lane++)begin
      row=real_afin_mem_reads*TILE+lane;
      if(row<ROWS&&vector_mem_out.data[lane]!==recip[row])
        $fatal(1,"real AFIN RECIP mismatch row=%0d got=%h expected=%h",
          row,vector_mem_out.data[lane],recip[row]);
    end
    real_afin_mem_reads++;
  end

  // Verify every real ACC read versus the complete PV-history reference, then
  // calculate the expected normalized FP32 values and S02 floor-exponent quant.
  always @(posedge clk) if(!reset&&!clear&&afin_real_active&&
      acc_data_valid&&pc_acc_data_ready)begin : real_afin_acc_read_check
    logic [15:0][31:0] norm_even,norm_odd;
    int tile,pair,row0,row1;
    if(real_afin_acc_reads>=QOZ_O_TILES*PAIRS)
      $fatal(1,"real AFIN extra ACC response");
    tile=real_afin_acc_reads/PAIRS;
    pair=real_afin_acc_reads%PAIRS;
    row0=2*pair;row1=row0+1;
    norm_even='0;norm_odd='0;
    for(int lane=0;lane<TILE;lane++)begin
      if(acc_even[lane]!==attention_gold[row0]||
         (row1<ROWS&&acc_odd[lane]!==attention_gold[row1]))
        $fatal(1,"real AFIN ACC mismatch tile=%0d pair=%0d lane=%0d even=%h expected=%h",
          tile,pair,lane,acc_even[lane],attention_gold[row0]);
      norm_even[lane]=mul32(acc_even[lane],recip[row0]);
      if(row1<ROWS)norm_odd[lane]=mul32(acc_odd[lane],recip[row1]);
    end
    real_afin_expected_even=real_p_floor_quant(norm_even);
    ogold[tile][row0]=real_afin_expected_even;
    if(row1<ROWS)begin
      real_afin_expected_odd=real_p_floor_quant(norm_odd);
      ogold[tile][row1]=real_afin_expected_odd;
    end else real_afin_expected_odd='0;
    real_afin_acc_reads++;
  end

  // Check all 16*26 accepted quant result beats (metadata + bit-exact values).
  always @(posedge clk) if(!reset&&!clear&&afin_real_active&&
      real_result_valid&&vector_result_ready)begin : real_afin_result_check
    int tile,pair,row0,row1;
    if(real_afin_result_beats>=QOZ_O_TILES*PAIRS)
      $fatal(1,"real AFIN extra result");
    tile=real_afin_result_beats/PAIRS;
    pair=real_afin_result_beats%PAIRS;
    row0=2*pair;row1=row0+1;
    if(real_result.token!==real_afin_token||
       real_result.tile!==6'(tile)||real_result.index!==10'(pair)||
       real_result.vector_valid!==row_mask(pair)||
       real_result.last!==(pair==PAIRS-1)||
       real_result.quant_axis!==QUANT_FEATURE_B16||
       real_result.token_mask!=='1)
      $fatal(1,"real AFIN result metadata mismatch tile=%0d pair=%0d",tile,pair);
    if(real_result.vector_data[0]!==ogold[tile][row0])
      $fatal(1,"real AFIN quant mismatch tile=%0d row=%0d got=%h expected=%h",
        tile,row0,real_result.vector_data[0],ogold[tile][row0]);
    if(row1<ROWS&&real_result.vector_data[1]!==ogold[tile][row1])
      $fatal(1,"real AFIN quant mismatch tile=%0d row=%0d got=%h expected=%h",
        tile,row1,real_result.vector_data[1],ogold[tile][row1]);
    if(real_afin_acc_reads<=real_afin_result_beats)
      $fatal(1,"real AFIN result before ACC read");
    real_afin_result_beats++;
  end


  // Real projection VPU scoreboard. Golden operations use TB real-domain helpers,
  // with separately rounded products and adds, independent of DUT integer math.
  always @(posedge clk)begin: projection_real_scoreboard
    logic [15:0][31:0] a,b;logic [31:0] ac,bs,as_,bc;
    logic [$bits(qvec16_t)-1:0] qa,qb;integer row,tile,half,pair;
    if(reset||clear)projection_real_active<=0;
    else begin
      if(vector_valid&&pc_vector_ready&&(vector_cmd.function_id==VECTOR_ROPE_QUANT||
         vector_cmd.function_id==VECTOR_V_QUANT||vector_cmd.function_id==VECTOR_GU_POST))begin
        projection_real_active<=1;projection_real_cmd=vector_cmd;
        projection_start=cycle;projection_inputs=0;projection_results=0;
        commands[vector_cmd.job.header.op]++;
      end
      if(projection_real_active&&vector_data_valid&&real_data_ready)begin
        row=projection_inputs;
        if(vector_data.index!=row||vector_data.token!=projection_real_cmd.token||vector_data.job!=projection_real_cmd.job)
          $fatal(1,"real projection input identity");
        a=vector_data.first;b=vector_data.second;
        if(projection_real_cmd.function_id==VECTOR_GU_POST)begin
          for(int j=0;j<TILE;j++)a[j]=mul32(a[j],b[j]);
          zgold[projection_real_cmd.tile][row]=quant(a);
        end else if(projection_real_cmd.function_id==VECTOR_V_QUANT)begin
          // PCore post has already transposed into feature columns.
          vgold[projection_real_cmd.tile][row]=quant(a);
          projection_first[row]=a;projection_second[row]=b;
        end else begin projection_first[row]=a;projection_second[row]=b;end
        projection_inputs++;
      end
      if(projection_real_active&&rope_out_valid&&real_rope_out_ready)begin
        row=rope_out.request.row;
        for(int j=0;j<TILE;j++)begin
          ac=mul32(projection_first[row][j],rope_out.cosine[j]);
          bs=mul32(projection_second[row][j],rope_out.sine[j]);
          as_=mul32(projection_first[row][j],rope_out.sine[j]);
          bc=mul32(projection_second[row][j],rope_out.cosine[j]);
          a[j]=bits(real32(ac)-real32(bs));b[j]=bits(real32(as_)+real32(bc));
        end
        if(projection_real_cmd.job.header.op==OP_Q_PROJ)begin
          qgold[projection_real_cmd.tile/2][row]=quant(a);
          qgold[projection_real_cmd.tile/2+QOZ_Q_TILES/2][row]=quant(b);
        end else begin kgold[0][row]=quant(a);kgold[1][row]=quant(b);end
      end
      if(projection_real_active&&real_result_valid&&vector_result_ready)begin
        if(real_result.token!=projection_real_cmd.token)$fatal(1,"real projection result token");
        if(projection_real_cmd.function_id==VECTOR_V_QUANT)begin
          row=projection_results;qa=quant(projection_first[row]);qb=quant(projection_second[row]);
          if(real_result.tile!=projection_real_cmd.tile||real_result.index!=row||real_result.quant_axis!=QUANT_TOKEN_B16||
             real_result.vector_valid!=2'b11||real_result.token_mask!=(row>=24?16'h0007:16'hffff)||
             real_result.last!=(row==V_PACKETS_PER_TILE-1))$fatal(1,"real V result identity");
        end else begin
          pair=projection_results%PAIRS;half=projection_results/PAIRS;row=2*pair;
          tile=projection_real_cmd.function_id==VECTOR_ROPE_QUANT?
            (projection_real_cmd.job.header.op==OP_Q_PROJ?projection_real_cmd.tile/2+half*QOZ_Q_TILES/2:half):projection_real_cmd.tile;
          if(real_result.tile!=tile||real_result.index!=pair||real_result.vector_valid!=row_mask(pair)||
             real_result.quant_axis!=QUANT_FEATURE_B16||real_result.last!=(pair==PAIRS-1))$fatal(1,"real projection result identity");
          if(projection_real_cmd.function_id==VECTOR_GU_POST)begin qa=zgold[tile][row];qb=row+1<ROWS?zgold[tile][row+1]:'0;end
          else if(projection_real_cmd.job.header.op==OP_Q_PROJ)begin qa=qgold[tile][row];qb=row+1<ROWS?qgold[tile][row+1]:'0;end
          else begin qa=kgold[tile][row];qb=row+1<ROWS?kgold[tile][row+1]:'0;end
        end
        if(real_result.vector_data[0]!==qa||real_result.vector_data[1]!==qb)$fatal(1,"real projection numerical mismatch fn=%0d beat=%0d",projection_real_cmd.function_id,projection_results);
        projection_results++;
      end
      if(projection_real_active&&real_vpu_done_valid&&real_vpu_done_ready)begin
        if(real_vpu_done.error||real_vpu_done.command!==projection_real_cmd)$fatal(1,"real projection completion");
        if(projection_inputs!=(projection_real_cmd.function_id==VECTOR_V_QUANT?V_PACKETS_PER_TILE:ROWS)||
           projection_results!=(projection_real_cmd.function_id==VECTOR_V_QUANT?V_PACKETS_PER_TILE:
            (projection_real_cmd.function_id==VECTOR_ROPE_QUANT?2*PAIRS:PAIRS)))$fatal(1,"real projection counts");
        $display("REAL_PROJECTION_DONE fn=%0d cycles=%0d inputs=%0d results=%0d",projection_real_cmd.function_id,cycle-projection_start,projection_inputs,projection_results);
        if(cycle-projection_start>stage_dur_max[projection_real_cmd.function_id])stage_dur_max[projection_real_cmd.function_id]=cycle-projection_start;
        projection_real_active<=0;
      end
    end
  end
  dea8_vpu_top u_real_vpu_probe (
    .clk(clk), .reset(reset), .clear(clear), .flush_valid(flush_valid), .vpu_flush_ack(real_vpu_flush_ack),
    .vector_valid(real_vpu_valid), .vector_ready(real_vpu_ready), .vector_cmd(vector_cmd),
    .vector_done_valid(raw_done_valid), .vector_done_ready(real_vpu_done_ready), .vector_done(real_vpu_done),
    .vector_data_valid((p_real_active||projection_real_active)&&vector_data_valid), .vector_data_ready(real_data_ready), .vector_data(vector_data),
    .vector_result_valid(raw_result_valid), .vector_result_ready((p_real_active||afin_real_active||projection_real_active)&&vector_result_ready&&result_gate), .vector_result(real_result),
    .vector_mem_valid(real_mem_valid), .vector_mem_ready(vector_mem_ready), .vector_mem_req(real_mem_req),
    .vector_mem_out_valid(vector_mem_out_valid&&mem_gate), .vector_mem_out_ready(raw_mem_ready), .vector_mem_out(vector_mem_out),
    .acc_rd_valid(real_acc_rd_valid), .acc_rd_ready(acc_rd_ready),
    .acc_rd_sel(real_acc_rd_sel), .acc_rd_addr(real_acc_rd_addr), .acc_token(real_acc_token),
    .acc_data_valid(acc_data_valid&&acc_gate), .acc_data_ready(raw_acc_ready), .acc_even(acc_even), .acc_odd(acc_odd),
    .acc_wr_valid(real_acc_wr_valid), .acc_wr_ready(acc_wr_ready), .acc_wr(real_acc_wr),
    .rope_req_valid(real_rope_req_valid), .rope_req_ready(rope_req_ready), .rope_req(real_rope_req),
    .rope_out_valid(rope_out_valid), .rope_out_ready(real_rope_out_ready), .rope_out(rope_out),
    .mask_config_valid(real_vpu_valid), .mask_config(real_qk_mask)
  );
  // END REAL QK INTEGRATION

  logic pc_rope_req_valid,pc_rope_out_ready;control_rope_req_t pc_rope_req;
  assign pc_rope_req_valid=projection_real_active?real_rope_req_valid:rope_req_valid;
  assign pc_rope_req=projection_real_active?real_rope_req:rope_req;
  assign pc_rope_out_ready=projection_real_active?real_rope_out_ready:rope_out_ready;
  dea8_pcore_control #(.PCORE_ID(3'd2)) dut(
    .*,
    .vector_ready(pc_vector_ready),
    .vector_done_valid(pc_vector_done_valid), .vector_done(pc_vector_done),
    .vector_data_ready(pc_vector_data_ready),
    .vector_result_valid(pc_vector_result_valid), .vector_result(pc_vector_result),
    .vector_mem_valid(pc_vector_mem_valid), .vector_mem_req(pc_vector_mem_req),
    .vector_mem_out_ready(pc_vector_mem_out_ready),
    .acc_rd_valid(pc_acc_rd_valid), .acc_rd_sel(pc_acc_rd_sel),
    .acc_rd_addr(pc_acc_rd_addr), .acc_token(pc_acc_token),
    .acc_data_ready(pc_acc_data_ready),
    .acc_wr_valid(pc_acc_wr_valid), .acc_wr(pc_acc_wr),
    .vpu_flush_ack(pc_vpu_flush_ack),
    .rope_req_valid(pc_rope_req_valid),.rope_req(pc_rope_req),.rope_out_ready(pc_rope_out_ready)
  );

  function automatic int random_limit(input int channel,maximum);
    logic [31:0] x;
    x=random_state[channel];x^=x<<13;x^=x>>17;x^=x<<5;
    random_state[channel]=x;
    return int'(x%32'(maximum+1));
  endfunction
  task automatic delay_cycles(input int channel,maximum,counter);
    int count;
    count=stress?random_limit(channel,maximum):0;
    coverage[counter]+=count;
    repeat(count)@(negedge clk);
  endtask
  // Fixed target-hardware pipeline latency in FUNCTIONAL/PERFORMANCE, random in STRESS.
  task automatic stage_delay(input int fixed,input int channel,maximum,counter);
    if(stress)delay_cycles(channel,maximum,counter);
    else if(fixed>0)repeat(fixed)@(negedge clk);
  endtask
  task automatic source_gap(input int channel,counter);
    if(stress&&random_limit(channel,15)==0)delay_cycles(channel,7,counter);
  endtask
  task automatic barrier_wait(input int op);
    if(corners)begin
      barrier_hits[op]++;
      repeat(32)begin @(negedge clk);if(done_valid||!busy)$fatal(1,"early completion at barrier op=%0d",op);end
    end
  endtask

  // ---------------- channel primitives ----------------
  function automatic int resp_extra(input int channel);
    return stress?random_limit(channel,3):0;
  endfunction
  task automatic acc_rd_issue(input acc_sel_e sel,input int addr);
    acc_rd_item_t it;
    it.sel=sel;it.addr=10'(addr);acc_rd_q.push_back(it);
  endtask
  task automatic acc_wr_issue(input int addr,input logic [15:0][31:0] a,b);
    acc_write_t w;
    w='0;w.sel=ACC_OACC;w.addr=10'(addr);w.row_valid=row_mask(addr%PAIRS);
    w.data[0]=a;w.data[1]=b;acc_wr_q.push_back(w);
  endtask
  task automatic vm_issue(input control_command_t c,input control_buffer_e buf_id,input bit bank,
    input int index,input bit write,input logic [15:0][31:0] data);
    control_memory_req_t req;
    req='0;req.token=c.token;req.buffer_id=buf_id;req.index=6'(index);req.bank=bank;req.write=write;
    req.mask=buf_id==WORK_SCORE?'1:16'b1;req.data=data;vm_req_q.push_back(req);
  endtask
  task automatic vm_stat_write(input control_command_t c,input control_buffer_e buffer_id,
    input int index,input logic [15:0][31:0] data);
    control_memory_req_t request_item;
    request_item='0;request_item.token=c.token;request_item.buffer_id=buffer_id;
    request_item.index=6'(index);request_item.write=1;request_item.data=data;
    for(int i=0;i<TILE;i++)request_item.mask[i]=(index+i<ROWS);
    vm_req_q.push_back(request_item);
  endtask
  task automatic fm_issue(input control_command_t c,input control_buffer_e buf_id,input bit bank,
    input int index,input bit write,input logic [15:0][31:0] data);
    control_memory_req_t req;
    req='0;req.token=c.token;req.buffer_id=buf_id;req.index=6'(index);req.bank=bank;req.write=write;
    req.mask=buf_id==WORK_SCORE?'1:16'b1;req.data=data;fm_req_q.push_back(req);
  endtask
  task automatic acc_collect(output logic [15:0][31:0] a,b);
    logic [1023:0] payload;
    while(acc_rsp_q.size()==0)@(negedge clk);
    payload=acc_rsp_q.pop_front();{b,a}=payload;
  endtask
  task automatic vm_collect(output control_memory_rsp_t r);
    while(vm_rsp_q.size()==0)@(negedge clk);
    r=vm_rsp_q.pop_front();
  endtask
  task automatic fm_collect(output control_memory_rsp_t r);
    while(fm_rsp_q.size()==0)@(negedge clk);
    r=fm_rsp_q.pop_front();
  endtask
  task automatic rope_collect(output control_rope_rsp_t r);
    while(rope_rsp_q.size()==0)@(negedge clk);
    r=rope_rsp_q.pop_front();
  endtask
  // Unit completion drains only that unit's channels. SFU workspace traffic
  // may continue independently while the VPU returns its completion token.
  task automatic drain_vector_channels;
    while(acc_rd_q.size()||acc_wr_q.size()||vm_req_q.size()||rope_req_q.size()||
          acc_age.size()||vm_age.size()||rope_age.size()||
          acc_rsp_q.size()||vm_rsp_q.size()||rope_rsp_q.size()||rope_sfu_rsp_q.size())
      @(negedge clk);
  endtask
  task automatic drain_function_channels;
    while(fm_req_q.size()||fm_age.size()||fm_rsp_q.size())@(negedge clk);
  endtask
  // SFU4 / VPU32 release budget: lane throughput, not latency, limits the stream.
  task automatic pace_beat(input int values,input int lanes);
    int due;
    @(negedge clk);
    fpace_n++;
    due=fpace_ref+((fpace_n*values)+lanes-1)/lanes;
    while(cycle<due)@(negedge clk);
  endtask

  function automatic logic [31:0] bits(input real x);shortreal s;s=x;return $shortrealtobits(s);endfunction
  function automatic real real32(input logic [31:0] x);return real'($bitstoshortreal(x));endfunction
  function automatic logic [31:0] mul32(input logic [31:0] a,b);return bits(real32(a)*real32(b));endfunction
  function automatic int aint(input int row);return row%3-1;endfunction
  function automatic qvec16_t qv(input int x);qvec16_t v;v.scale=128;for(int i=0;i<TILE;i++)v.data[i*8+:8]=8'(x);return v;endfunction
  function automatic qvec16_t quant(input logic [15:0][31:0] x);
    real mx,step,v,f;int e,b,q;qvec16_t out;
    mx=0;for(int i=0;i<TILE;i++)begin v=real32(x[i]);if(v<0)v=-v;if(v>mx)mx=v;end
    step=2.0**(-133);e=0;
    while(e<254&&mx>127.0*step)begin step*=2.0;e++;end
    out='0;out.scale=8'(e);
    for(int i=0;i<TILE;i++)begin
      v=real32(x[i])/step;b=int'($floor(v));f=v-real'(b);
      q=b+int'(f>0.5||(f==0.5&&(b%2)!=0));if(q>127)q=127;if(q< -128)q=-128;
      out.data[i*8+:8]=8'(q);
    end
    return out;
  endfunction
  // Dedicated REAL P_POST reference for S02 floor-exponent MXINT8-B16.
  // Keep historical quant() for all original baseline jobs. This checker
  // determines E from the magnitude bits and performs rounding in real math,
  // independently of dea8_vpu_quant16's integer shift implementation.
  function automatic qvec16_t real_p_floor_quant(input logic [15:0][31:0] x);
    logic [30:0] max_abs;
    qvec16_t out;
    int exponent,base,q;
    real step,ratio,fraction;
    max_abs='0;
    out='0;
    for(int i=0;i<TILE;i++)begin
      if(x[i][30:23]==8'hff)
        $fatal(1,"REAL_P_GOLDEN_NONFINITE lane=%0d x=%h",i,x[i]);
      if(x[i][30:0]>max_abs)max_abs=x[i][30:0];
    end
    out.scale=max_abs[30:23];
    exponent=int'(out.scale);
    step=2.0**(exponent-133);
    for(int i=0;i<TILE;i++)begin
      ratio=real32(x[i])/step;
      base=$rtoi($floor(ratio));
      fraction=ratio-real'(base);
      q=base;
      if((fraction>0.5)||((fraction==0.5)&&((base&1)!=0)))q++;
      if(q>127)q=127;
      if(q< -127)q=-127;
      out.data[i*8+:8]=8'(q);
    end
    return out;
  endfunction
  function automatic int feature(input pcore_op_e op,input int n);
    return op==OP_Q_PROJ?n/2+(n%2)*8:n;
  endfunction
  function automatic int bint(input pcore_op_e op,input int n,col,input bit up);
    if(op==OP_GU)return up?2:1;
    if(op==OP_Q_PROJ||op==OP_K_PROJ||op==OP_V_PROJ)return 1+(feature(op,n)*TILE+col)%3;
    return 1;
  endfunction
  function automatic logic [31:0] dot_part(input qvec16_t a,input int b,e,fold);
    int dot,lead;logic [31:0] mag,norm;
    dot=0;for(int i=0;i<TILE;i++)dot+=int'($signed(a.data[8*i+:8]))*b;
    mag=dot<0?-dot:dot;lead=0;for(int i=0;i<32;i++)if(mag[i])lead=i;
    norm=mag<<(31-lead);
    return fp32_legacy_ref_pkg::pack_scaled32(dot<0,norm,lead+int'(a.scale)+e-266+fold,dot==0,0);
  endfunction
  function automatic logic [31:0] projection_golden(input pcore_op_e op,input int row,n,col);
    if(op==OP_O_PROJ||op==OP_DOWN_PROJ)return reduced_gold[op][row];
    return bits(real'(aint(row)*bint(op,n,col,0)));
  endfunction
  function automatic logic [31:0] local_projection_golden(input pcore_op_e op,input int row);
    logic [31:0] v;int count;qvec16_t a;
    count=op==OP_O_PROJ?16:(op==OP_DOWN_PROJ?32:64);v=0;
    for(int k=0;k<count;k++)begin
      a=op==OP_O_PROJ?ogold[k][row]:(op==OP_DOWN_PROJ?zgold[k][row]:qv(aint(row)));
      v=fp32_legacy_ref_pkg::fp32_add(v,dot_part(a,1,128,0));
    end
    return v;
  endfunction

  // ---------------- source agents ----------------
  // A source beat holds its payload until it is accepted so back-to-back beats
  // cost one cycle instead of two; stress gaps drop valid before pausing.
  task automatic send_b(input int transport,group,n,input bit is_kvb,input int block,input bit pv);
    b2_t b;b='0;b.tile_idx=TILE_BITS'(transport);b.group_idx=3'(group);b.epoch=job.header.epoch;
    for(int c=0;c<2;c++)begin
      b.col[c]=qv(0);
      for(int i=0;i<TILE;i++)b.col[c].data[i*8+:8]=8'(is_kvb?(pv?1:1+block%3):bint(job.header.op,n,2*group+c,transport[0]));
    end
    @(negedge clk);
    if(stress&&random_limit(is_kvb?2:1,15)==0)begin
      if(is_kvb)kv_valid=0;else hbm_valid=0;
      delay_cycles(is_kvb?2:1,7,is_kvb?2:1);
    end
    if(is_kvb)begin kv_entry=b;kv_valid=1;do @(posedge clk);while(!kv_ready);end
    else begin hbm_entry=b;hbm_valid=1;do @(posedge clk);while(!hbm_ready);end
  endtask
  task automatic send_xbc(input int k,g);
    @(negedge clk);
    if(stress&&random_limit(0,15)==0)begin xbc_valid=0;delay_cycles(0,7,0);end
    xbc_entry='0;xbc_entry.tile_idx=TILE_BITS'(k);xbc_entry.group_idx=4'(g);
    xbc_entry.row_valid=g==XBC_GROUPS-1?4'b0111:4'b1111;
    for(int r=0;r<4;r++)xbc_entry.row[r]=qv(aint(4*g+r));
    xbc_valid=1;do @(posedge clk);while(!xbc_ready);
  endtask
  // Retire only the transport this branch owns: the sibling branch may still
  // be holding a valid beat against a stalled sink.
  task automatic source_stop(input bit xbc_st,input bit kv_st);
    @(negedge clk);
    if(xbc_st)xbc_valid=0;
    if(kv_st)begin hbm_valid=0;kv_valid=0;end
  endtask
  task automatic feed_projection(input int nt,kt,input bit local_a);
    fork
      begin
        if(stress&&!local_a)begin
          int pause;pause=(seed+int'(job.header.op))%2?320:32;
          coverage[0]+=pause;repeat(pause)@(negedge clk);
        end
        if(!local_a)for(int n=0;n<nt;n++)for(int k=0;k<kt;k++)for(int g=0;g<XBC_GROUPS;g++)send_xbc(k,g);
        source_stop(1,0);
      end
      begin
        if(stress)begin
          int pause;pause=(seed+int'(job.header.op))%2?32:320;
          coverage[1]+=pause;repeat(pause)@(negedge clk);
        end
        for(int n=0;n<nt;n++)for(int k=0;k<kt;k++)for(int g=0;g<TILE/2;g++)
          send_b(local_a?(n*kt+k)%64:k,g,n,0,0,0);
        source_stop(0,1);
      end
    join
  endtask
  task automatic feed_gu;
    fork
      begin
        if(stress)begin coverage[0]+=128;repeat(128)@(negedge clk);end
        for(int n=0;n<32;n++)begin
          if(n>0)wait(allowed_n>=n);
          for(int k=0;k<64;k++)for(int g=0;g<XBC_GROUPS;g++)send_xbc(k,g);
        end
        source_stop(1,0);
      end
      begin
        if(stress)begin coverage[1]+=256;repeat(256)@(negedge clk);end
        for(int n=0;n<32;n++)for(int t=0;t<128;t++)for(int g=0;g<8;g++)send_b(t%64,g,n,0,0,0);
        source_stop(0,1);
      end
    join
  endtask
  task automatic feed_attention;
    int b;bit pv_job;
    if(stress)begin coverage[2]+=160;repeat(160)@(negedge clk);end
    for(int j=0;j<110;j++)begin
      // ATTENTION_SOURCE_GAP_FIX
      @(negedge clk);kv_valid=0;
      delay_cycles(2,15,2);
      if(j==0)begin b=0;pv_job=0;end
      else if(j==109)begin b=54;pv_job=1;end
      else begin pv_job=!j[0];b=j[0]?(j+1)/2:j/2-1;end
      for(int t=0;t<16;t++)for(int g=0;g<8;g++)begin
        if(j==109&&t==15&&g==7)begin
          // Hold the last accepted beat off the wire before the completion corner.
          @(negedge clk);kv_valid=0;hbm_valid=0;barrier_wait(OP_ATTENTION);
        end
        send_b((j*16+t)%64,g,0,1,b,pv_job);
      end
    end
    source_stop(1,1);
  endtask

  // ---------------- result emission ----------------
  // Result identity is checked by the DUT (index/token), so a held valid can
  // never be consumed twice; hold_result lets the agents stream at II=1 while
  // the manual fault environment keeps the legacy one-beat-per-two-cycles.
  task automatic result_pair(input control_command_t c,input int tile,p,input qvec16_t a,b,input bit token_axis,input logic [15:0] mask);
    // A held beat is consumed on the next rising edge, so a stress pause must
    // park the channel low first or the DUT would re-take the stale payload.
    if(stress)begin @(negedge clk);vector_result_valid=0;end
    delay_cycles(5,5,5);
    if(c.job.header.op==OP_Q_PROJ&&tile==15&&p==PAIRS-1)begin
      @(negedge clk);vector_result_valid=0;barrier_wait(OP_Q_PROJ);
    end
    if(c.job.header.op==OP_GU&&tile==31&&p==PAIRS-1)begin
      @(negedge clk);vector_result_valid=0;barrier_wait(OP_GU);
    end
    if(c.function_id==VECTOR_AFIN_QUANT&&tile==15&&p==PAIRS-1)begin
      @(negedge clk);vector_result_valid=0;barrier_wait(OP_ATTENTION);
    end
    if(clk!==1'b0)@(negedge clk);
    vector_result='0;vector_result.token=c.token;vector_result.tile=6'(tile);vector_result.index=10'(p);
    vector_result.quant_axis=token_axis?QUANT_TOKEN_B16:QUANT_FEATURE_B16;
    vector_result.vector_valid=token_axis?2'b11:row_mask(p);vector_result.token_mask=mask;
    vector_result.vector_data[0]=a;vector_result.vector_data[1]=b;
    vector_result.last=p==(token_axis?31:PAIRS-1);vector_result_valid=1;
    do @(posedge clk);while(!vector_result_ready);
    @(negedge clk);vector_result_valid=0;
  endtask

  // ---------------- legacy manual helpers (fault environment) ----------------
  task automatic memory_access(input control_command_t c,input bit sf,input control_buffer_e buffer_id,
    input int index,input bit bank,write,input logic [15:0][31:0] payload,output logic [15:0][31:0] value);
    control_memory_req_t req;
    req='0;req.token=c.token;req.buffer_id=buffer_id;req.index=6'(index);req.bank=bank;req.write=write;
    req.mask=buffer_id==WORK_SCORE?'1:16'b1;req.data=payload;
    @(negedge clk);
    if(sf)begin
      $fatal(1,"AUDIT: legacy SFU memory driver invoked");
    end else begin
      vector_mem_req=req;vector_mem_valid=1;do @(posedge clk);while(!vector_mem_ready);
      @(negedge clk);vector_mem_valid=0;
      if(!write)begin
        delay_cycles(10,9,10);
        vector_mem_out_ready=1;do @(posedge clk);while(!vector_mem_out_valid);
        if(vector_mem_out.token!=c.token)$fatal(1,"VPU memory response identity");value=vector_mem_out.data;
        @(negedge clk);vector_mem_out_ready=0;
      end
    end
  endtask

  // ---------------- vector (VPU32) agent ----------------
  // Drop ready on the same negedge that captures the beat: any cycle the agent
  // spends on post work must not let the DUT retire a second unobserved beat.
  task automatic recv_vbeat(output control_fp_data_t d);
    vector_data_ready=1;
    do @(posedge clk);while(!vector_data_valid);
    d=vector_data;@(negedge clk);vector_data_ready=0;
  endtask
  task automatic rope_quant(input control_command_t c);
    control_fp_data_t d;control_rope_rsp_t rr;int tile;
    control_rope_req_t request_item;
    logic [15:0][31:0] va[ROWS],vb[ROWS];
    logic [$bits(qvec16_t)-1:0] qa[ROWS],qb[ROWS];
    for(int r=0;r<ROWS;r++)begin
      request_item='0;request_item.token=c.token;request_item.row=6'(r);
      request_item.position=16'(c.job.position_base+r);request_item.frequency_base=c.rope_frequency_base;
      rope_req_q.push_back(request_item);
    end
    for(int r=0;r<ROWS;r++)begin
      recv_vbeat(d);
      if(d.index!=r||d.token!=c.token||d.job!=c.job||!d.vector_valid[0])$fatal(1,"RoPE stream identity");
      va[r]=d.first;vb[r]=d.second;
      for(int i=0;i<TILE;i++)begin
        if(d.first[i]!==projection_golden(c.job.header.op,r,c.tile-1,i)||d.second[i]!==projection_golden(c.job.header.op,r,c.tile,i))$fatal(1,"RoPE matrix golden");
      end
    end
    vector_data_ready=0;
    for(int r=0;r<ROWS;r++)begin
      rope_collect(rr);
      for(int i=0;i<TILE;i++)begin
        scratch0[r][i]=bits(real32(va[r][i])*real32(rr.cosine[i])-real32(vb[r][i])*real32(rr.sine[i]));
        scratch1[r][i]=bits(real32(vb[r][i])*real32(rr.cosine[i])+real32(va[r][i])*real32(rr.sine[i]));
      end
      qa[r]=quant(scratch0[r]);qb[r]=quant(scratch1[r]);
    end
    for(int h=0;h<2;h++)begin
      tile=c.job.header.op==OP_Q_PROJ?c.tile/2+h*8:h;
      for(int r=0;r<ROWS;r++)begin
        if(c.job.header.op==OP_Q_PROJ)qgold[tile][r]=h?qb[r]:qa[r];
        else kgold[tile][r]=h?qb[r]:qa[r];
      end
      for(int p=0;p<PAIRS;p++)result_pair(c,tile,p,h?qb[2*p]:qa[2*p],p<25?(h?qb[2*p+1]:qa[2*p+1]):'0,0,'1);
    end
  endtask
  task automatic v_quant(input control_command_t c);
    control_fp_data_t d;
    logic [15:0][31:0] a,b;
    logic [$bits(qvec16_t)-1:0] qa[V_PACKETS_PER_TILE],qb[V_PACKETS_PER_TILE];
    for(int j=0;j<V_PACKETS_PER_TILE;j++)begin
      recv_vbeat(d);
      for(int i=0;i<TILE;i++)begin
        int row,col;row=(j/8)*16+i;col=(j%8)*2;
        if(row<ROWS&&(d.first[i]!==projection_golden(OP_V_PROJ,row,c.tile,col)||d.second[i]!==projection_golden(OP_V_PROJ,row,c.tile,col+1)))$fatal(1,"V token packing golden");
        if(row>=ROWS&&(d.first[i]!=0||d.second[i]!=0||d.token_mask[i]))$fatal(1,"V padding");
      end
      a=d.first;b=d.second;
      vgold[c.tile][j]=quant(a);qa[j]=quant(a);qb[j]=quant(b);
    end
    vector_data_ready=0;
    for(int j=0;j<V_PACKETS_PER_TILE;j++)result_pair(c,c.tile,j,qa[j],qb[j],1,j>=24?16'h7:16'hffff);
  endtask
  task automatic gu_post(input control_command_t c);
    control_fp_data_t d;
    logic [$bits(qvec16_t)-1:0] qz[ROWS];
    for(int r=0;r<ROWS;r++)begin
      recv_vbeat(d);
      if(d.index!=r||d.second[0]!==bits(2.0*aint(r)))$fatal(1,"GU Up pair");
      for(int i=0;i<TILE;i++)scratch0[r][i]=mul32(d.first[i],d.second[i]);
      zgold[c.tile][r]=quant(scratch0[r]);qz[r]=zgold[c.tile][r];
    end
    vector_data_ready=0;
    for(int p=0;p<PAIRS;p++)result_pair(c,c.tile,p,qz[2*p],p<25?qz[2*p+1]:'0,0,'1);
  endtask
  // Statistics use the existing 16-row workspace spans; SCORE stays full-row.
  task automatic qk_post(input control_command_t c);
    logic [15:0][31:0] a,b,stat,wdata;control_memory_rsp_t rsp;
    logic [31:0] v,old_m,nm;
    logic [31:0] old_max[ROWS],aa_value[ROWS];
    acc_sel_e facc=c.attention_vpu.facc_bank?ACC_FACC_B:ACC_FACC_A;
    for(int p=0;p<PAIRS;p++)acc_rd_issue(facc,p);
    for(int base=0;base<ROWS;base+=TILE)vm_issue(c,WORK_M,1'b0,base,0,'0);
    for(int base=0;base<ROWS;base+=TILE)begin
      vm_collect(rsp);stat=rsp.data;
      for(int i=0;i<TILE;i++)if(base+i<ROWS)begin
        old_max[base+i]=stat[i];
        if(stat[i]!==m[base+i])$fatal(1,"M span readback row=%0d",base+i);
      end
    end
    for(int p=0;p<PAIRS;p++)begin
      acc_collect(a,b);
      for(int r=0;r<2;r++)if(2*p+r<ROWS)begin
        v=0;
        for(int k=0;k<TILE;k++)v=fp32_legacy_ref_pkg::fp32_add(v,dot_part(qgold[k][2*p+r],1+c.tile%3,128,-4));
        for(int i=0;i<TILE;i++)begin
          if((r?b[i]:a[i])!==v)
            $fatal(1,"QK numerical golden block=%0d row=%0d lane=%0d got=%h exp=%h",c.tile,2*p+r,i,r?b[i]:a[i],v);
          score[c.tile][2*p+r][i]=(2*p+r==0||(c.tile==54&&i==15))?32'hff800000:v;
        end
        wdata='0;
        for(int i=0;i<TILE;i++)wdata[i]=score[c.tile][2*p+r][i];
        vm_issue(c,WORK_SCORE,c.tile[0],2*p+r,1,wdata);
        old_m=old_max[2*p+r];nm=old_m;
        for(int i=0;i<TILE;i++)
          if(real32(score[c.tile][2*p+r][i])>real32(nm))nm=score[c.tile][2*p+r][i];
        // exp(old-new) is the cross-block scale; equal maxima mean no scale at
        // all, which also keeps an all -inf row free of NaN.
        aa_value[2*p+r]=(old_m==nm)?32'd0:bits(real32(old_m)-real32(nm));
        m[2*p+r]=nm;
      end
    end
    for(int base=0;base<ROWS;base+=TILE)begin
      wdata='0;for(int i=0;i<TILE;i++)if(base+i<ROWS)wdata[i]=m[base+i];
      vm_stat_write(c,WORK_M,base,wdata);
      wdata='0;for(int i=0;i<TILE;i++)if(base+i<ROWS)wdata[i]=aa_value[base+i];
      vm_stat_write(c,WORK_AA,base,wdata);
    end
  endtask
  // P_POST per block: consume the 26 P beats, read L and ALPHA for every row,
  // fold them into the running denominator and write L back (51 writes).
  task automatic p_post(input control_command_t c);
    control_fp_data_t d;control_memory_rsp_t lr,ar;
    logic [15:0][31:0] x,lstat,astat,wdata;logic [31:0] nl;
    logic [$bits(qvec16_t)-1:0] qa[PAIRS],qb[PAIRS];
    for(int p=0;p<PAIRS;p++)begin
      for(int r=0;r<2;r++)if(2*p+r<ROWS)begin
        vm_issue(c,WORK_L,1'b0,2*p+r,0,'0);
        vm_issue(c,WORK_ALPHA,c.tile[0],2*p+r,0,'0);
      end
    end
    for(int p=0;p<PAIRS;p++)begin
      recv_vbeat(d);
      if(d.index!=p||d.tile!=c.tile||d.token!=c.token)$fatal(1,"P stream identity");
      for(int r=0;r<2;r++)if(2*p+r<ROWS)begin
        vm_collect(lr);lstat=lr.data;
        vm_collect(ar);astat=ar.data;
        x=r?d.second:d.first;
        if(lstat[0]!==lsum[2*p+r])$fatal(1,"L readback row=%0d got=%h exp=%h",2*p+r,lstat[0],lsum[2*p+r]);
        if(astat[0]!==alpha[c.tile][2*p+r][0])
          $fatal(1,"ALPHA readback block=%0d row=%0d got=%h exp=%h",c.tile,2*p+r,astat[0],alpha[c.tile][2*p+r][0]);
        nl=mul32(lsum[2*p+r],astat[0]);
        for(int i=0;i<TILE;i++)nl=fp32_legacy_ref_pkg::fp32_add(nl,x[i]);
        wdata='0;wdata[0]=nl;vm_issue(c,WORK_L,1'b0,2*p+r,1,wdata);
        lsum[2*p+r]=nl;
        pgold[c.tile][2*p+r]=quant(x);
        if(r)qb[p]=pgold[c.tile][2*p+r];else qa[p]=pgold[c.tile][2*p+r];
      end
      result_pair(c,c.tile,p,qa[p],p<25?qb[p]:'0,0,'1);
    end
  endtask
  task automatic oacc_scale(input control_command_t c);
    logic [15:0][31:0] a,b,stat,dummy;logic [31:0] v;
    control_memory_rsp_t rsp;
    for(int t=0;t<QOZ_O_TILES;t++)for(int p=0;p<PAIRS;p++)begin
      acc_rd_issue(ACC_OACC,t*PAIRS+p);
      vm_issue(c,WORK_ALPHA,c.tile[0],2*p,0,'0);
    end
    for(int r=0;r<ROWS;r++)begin
      v=0;
      for(int block=0;block<int'(c.tile);block++)begin
        if(block>0)v=mul32(v,alpha[block][r][0]);
        v=fp32_legacy_ref_pkg::fp32_add(v,dot_part(pgold[block][r],1,128,0));
      end
      attention_gold[r]=v;
    end
    for(int t=0;t<QOZ_O_TILES;t++)for(int p=0;p<PAIRS;p++)begin
      acc_collect(a,b);
      vm_collect(rsp);
      for(int i=0;i<TILE;i++)begin
        if(a[i]!==attention_gold[2*p]||(p<25&&b[i]!==attention_gold[2*p+1]))
          $fatal(1,"PV before SCALE block=%0d tile=%0d pair=%0d lane=%0d even=%h expected=%h odd=%h expected_odd=%h",c.tile,t,p,i,a[i],attention_gold[2*p],b[i],attention_gold[2*p+1]);
      end
      stat=rsp.data;
      for(int i=0;i<TILE;i++)begin a[i]=mul32(a[i],stat[0]);if(p<25)b[i]=mul32(b[i],stat[1]);end
      acc_wr_issue(t*PAIRS+p,a,b);
    end
  endtask
  task automatic afin_quant(input control_command_t c);
    logic [15:0][31:0] a,b,stat,dummy;control_memory_rsp_t rsp;logic [31:0] v;
    for(int t=0;t<QOZ_O_TILES;t++)for(int p=0;p<PAIRS;p++)begin
      acc_rd_issue(ACC_OACC,t*PAIRS+p);
      vm_issue(c,WORK_RECIP,0,2*p,0,'0);
    end
    for(int r=0;r<ROWS;r++)begin
      v=0;
      for(int block=0;block<KV_BLOCKS;block++)begin
        if(block>0)v=mul32(v,alpha[block][r][0]);
        v=fp32_legacy_ref_pkg::fp32_add(v,dot_part(pgold[block][r],1,128,0));
      end
      attention_gold[r]=v;
    end
    for(int t=0;t<QOZ_O_TILES;t++)for(int p=0;p<PAIRS;p++)begin
      acc_collect(a,b);
      vm_collect(rsp);stat=rsp.data;
      for(int i=0;i<TILE;i++)begin
        if(a[i]!==attention_gold[2*p]||(p<25&&b[i]!==attention_gold[2*p+1]))$fatal(1,"PV OACC golden tile=%0d pair=%0d even=%h expected=%h odd=%h expected_odd=%h",t,p,i,a[i],attention_gold[2*p],b[i],attention_gold[2*p+1]);
        if(stat[0]!==recip[2*p]||(p<25&&stat[1]!==recip[2*p+1]))$fatal(1,"reciprocal memory");
        a[i]=mul32(a[i],stat[0]);if(p<25)b[i]=mul32(b[i],stat[1]);
      end
      ogold[t][2*p]=quant(a);if(p<25)ogold[t][2*p+1]=quant(b);
      result_pair(c,t,p,ogold[t][2*p],p<25?ogold[t][2*p+1]:'0,0,'1);
    end
  endtask
  task automatic vector_agent;
    control_command_t c;
    wait(!reset);
    forever begin
      @(posedge clk);
      if(vector_valid&&vector_ready&&vector_cmd.function_id!=VECTOR_QK_POST&&vector_cmd.function_id!=VECTOR_P_POST&&vector_cmd.function_id!=VECTOR_OACC_SCALE&&vector_cmd.function_id!=VECTOR_AFIN_QUANT&&vector_cmd.function_id!=VECTOR_ROPE_QUANT&&vector_cmd.function_id!=VECTOR_V_QUANT&&vector_cmd.function_id!=VECTOR_GU_POST)begin
        $fatal(1,"AUDIT: behavioral VPU fallback reached function=%0d",vector_cmd.function_id);
        c=vector_cmd;commands[c.job.header.op]++;@(negedge clk);acc_token=c.token;
        vector_result_valid=0;vector_data_ready=0;hold_result=1;
        vstage_start=cycle;
        stage_delay(VPU_CMD_LAT,5,37,5);
        if(corners&&(c.function_id==VECTOR_AFIN_QUANT))barrier_wait(OP_ATTENTION);
        if(c.function_id==VECTOR_OACC_SCALE||c.function_id==VECTOR_AFIN_QUANT)begin
          if(c.elements!=ROWS*TILE*QOZ_O_TILES||c.tiles!=QOZ_O_TILES||c.source!=WORK_OACC)
            $fatal(1,"OACC command descriptor");
        end else if(c.elements!=ROWS*TILE*(c.function_id==VECTOR_ROPE_QUANT?2:1))
          $fatal(1,"vector command element count");
        if(c.function_id==VECTOR_QK_POST&&(c.source!=WORK_FACC||c.destination!=WORK_SCORE))$fatal(1,"QK descriptor");
        if((c.job.header.op==OP_K_PROJ||c.job.header.op==OP_V_PROJ)&&c.destination!=WORK_KV_OUT)$fatal(1,"KV descriptor");
        case(c.function_id)
          VECTOR_ROPE_QUANT:rope_quant(c);
          VECTOR_V_QUANT:v_quant(c);
          VECTOR_GU_POST:gu_post(c);
          VECTOR_QK_POST:qk_post(c);
          VECTOR_P_POST:p_post(c);
          VECTOR_OACC_SCALE:oacc_scale(c);
          VECTOR_AFIN_QUANT:afin_quant(c);
          default:$fatal(1,"unexpected vector function");
        endcase
        @(negedge clk);vector_result_valid=0;vector_data_ready=0;hold_result=0;
        drain_vector_channels();
        vstage_end=cycle;
        if(vstage_end-vstage_start>stage_dur_max[c.function_id])stage_dur_max[c.function_id]=vstage_end-vstage_start;
        if(c.function_id==VECTOR_OACC_SCALE)begin
          scale_cycles=vstage_end-vstage_start;
          scale_margin_min=ATTN_SLOT-scale_cycles;
        end
        stage_delay(VPU_DONE_LAT,7,31,7);
        @(negedge clk);vector_done='{command:c,error:0};vector_done_valid=1;
        do @(posedge clk);while(!vector_done_ready);@(negedge clk);vector_done_valid=0;
      end
    end
  endtask

  // SFU behavioral agents removed: real SFU RTL drives all service outputs.

  logic real_sfu_error;
  control_command_t sfu_command_q;
  control_memory_req_t sfu_read_q;
  bit sfu_read_pending=0,sfu_busy=0;
  int sfu_start=0,sfu_reads=0,sfu_writes=0,sfu_results=0,real_sfu_done_count=0;
  logic [15:0][31:0] sfu_gate_gold[0:50];
  // TB-only delay adapters: all payloads still come from the real SFU RTL/IP.
  logic sf_cmd_gate,sf_result_gate,sf_done_gate;
  logic sf_ready_raw,sf_result_valid_raw,sf_done_valid_raw;
  logic sf_rope_gate,sf_rope_ready_raw;
  tb_sfu_random_valve #(.SALT(32'h1234)) sf_cmd_valve(clk,reset||clear||flush_valid,stress,seed,
    function_valid,sf_ready_raw,sf_cmd_gate);
  tb_sfu_random_valve #(.SALT(32'h5678)) sf_result_valve(clk,reset||clear||flush_valid,stress,seed,
    sf_result_valid_raw,function_result_ready,sf_result_gate);
  tb_sfu_random_valve #(.SALT(32'h9abc)) sf_done_valve(clk,reset||clear||flush_valid,stress,seed,
    sf_done_valid_raw,function_done_ready,sf_done_gate);
  tb_sfu_random_valve #(.SALT(32'hcdef)) sf_rope_valve(clk,reset||clear||flush_valid,stress,seed,
    rope_sfu_valid,sf_rope_ready_raw,sf_rope_gate);
  assign rope_sfu_ready=sf_rope_ready_raw&&sf_rope_gate;
  assign function_ready=sf_ready_raw&&sf_cmd_gate;
  assign function_result_valid=sf_result_valid_raw&&sf_result_gate;
  assign function_done_valid=sf_done_valid_raw&&sf_done_gate;
  always @(posedge clk)if(!reset&&!clear&&stress)begin
    if(sf_result_valid_raw&&!sf_result_gate)coverage[6]++;
    if(sf_done_valid_raw&&!sf_done_gate)coverage[8]++;
  end
  dea8_sfu_top #(.ROPE_POSITION_BASE(7),.ROPE_FILE("rope_base7_rom256.mem")) u_real_sfu(
    .clk,.reset,.flush(flush_valid||clear),.flush_ack(sfu_flush_ack),
    .function_valid(function_valid&&sf_cmd_gate),.function_ready(sf_ready_raw),.function_cmd,
    .function_done_valid(sf_done_valid_raw),.function_done_ready(function_done_ready&&sf_done_gate),.function_done,
    .function_data_valid,.function_data_ready,.function_data,.function_result_valid(sf_result_valid_raw),
    .function_result_ready(function_result_ready&&sf_result_gate),.function_result,
    .function_mem_valid,.function_mem_ready,.function_mem_req,.function_mem_out_valid,.function_mem_out_ready,.function_mem_out,
    .rope_valid(rope_sfu_valid&&sf_rope_gate),.rope_ready(sf_rope_ready_raw),.rope_req(rope_sfu_req),
    .rope_out_valid(rope_sfu_out_valid),.rope_out_ready(rope_sfu_out_ready),.rope_out(rope_sfu_out),
    .protocol_error(real_sfu_error));
  logic sf_result_held=0,sf_done_held=0,sf_memory_held=0;
  control_fp_data_t sf_result_hold;
  control_unit_done_t sf_done_hold;
  control_memory_req_t sf_memory_hold;
  always @(posedge clk)begin
    if(reset||clear||flush_valid)begin sf_result_held=0;sf_done_held=0;sf_memory_held=0;end
    else begin
      if(sf_result_held&&(!sf_result_valid_raw||function_result!==sf_result_hold))$fatal(1,"SFU result changed under backpressure");
      if(sf_done_held&&(!sf_done_valid_raw||function_done!==sf_done_hold))$fatal(1,"SFU done changed under backpressure");
      if(sf_memory_held&&(!function_mem_valid||function_mem_req!==sf_memory_hold))$fatal(1,"SFU request changed under backpressure");
      sf_result_held=sf_result_valid_raw&&!(function_result_ready&&sf_result_gate);sf_result_hold=function_result;
      sf_done_held=sf_done_valid_raw&&!(function_done_ready&&sf_done_gate);sf_done_hold=function_done;
      sf_memory_held=function_mem_valid&&!function_mem_ready;sf_memory_hold=function_mem_req;
    end
  end
  always @(negedge clk)if(!reset&&function_mem_valid&&function_mem_req.write&&
      sfu_command_q.function_id==FUNCTION_ALPHA_EXP&&sfu_command_q.tile==1&&function_mem_req.index==8)
    $display("SFU_EXP_REPRO input=%h output=%h old_golden=%h",qk_expected_aa[8],function_mem_req.data[0],alpha[1][8][0]);
  always @(posedge clk)begin: sfu_independent_scoreboard
    logic [31:0] expected; real x,t,angle;
    if(reset||clear||flush_valid)begin sfu_busy=0;sfu_read_pending=0;end
    else begin
      if(real_sfu_error)$fatal(1,"real SFU protocol_error state=%0d",u_real_sfu.state);
      if(function_valid&&function_ready)begin
        if(sfu_busy)$fatal(1,"SFU overlapping command");
        sfu_command_q=function_cmd;sfu_busy=1;sfu_start=cycle;
        function_commands++;sfu_reads=0;sfu_writes=0;sfu_results=0;
        if(function_cmd.function_id==FUNCTION_ALPHA_EXP)
          for(int r=0;r<ROWS;r++)alpha[function_cmd.tile][r][0]=bits($exp(real32(qk_expected_aa[r])));
        if(function_cmd.function_id==FUNCTION_RECIP)
          for(int r=0;r<ROWS;r++)recip[r]=lsum[r]==0?0:bits(1.0/real32(lsum[r]));
        $display("REAL_SFU_ACCEPT fn=%0d tile=%0d cycle=%0d",function_cmd.function_id,function_cmd.tile,cycle);
      end
      if(function_data_valid&&function_data_ready)begin
        if(!sfu_busy||sfu_command_q.function_id!=FUNCTION_GELU)$fatal(1,"SFU unexpected input");
        for(int i=0;i<TILE;i++)begin
          if(function_data.first[i]!==bits(aint(function_data.index)))$fatal(1,"Gate golden");
          x=real32(function_data.first[i]);t=$sqrt(2.0/3.141592653589793)*(x+0.044715*x*x*x);
          sfu_gate_gold[function_data.index][i]=bits(0.5*x*(2.0/(1.0+$exp(-2.0*t))));
        end
      end
      if(function_mem_valid&&function_mem_ready)begin
        if(function_mem_req.token!==sfu_command_q.token)$fatal(1,"SFU request token");
        if(function_mem_req.write)begin
          expected=sfu_command_q.function_id==FUNCTION_ALPHA_EXP?alpha[sfu_command_q.tile][function_mem_req.index][0]:recip[function_mem_req.index];
          if(function_mem_req.data[0]!==expected)$fatal(1,"SFU_NUMERIC_WRITE fn=%0d tile=%0d row=%0d got=%h expected=%h",sfu_command_q.function_id,sfu_command_q.tile,function_mem_req.index,function_mem_req.data[0],expected);
          sfu_writes++;
        end else begin
          if(sfu_read_pending)$fatal(1,"SFU read credit exceeded");
          sfu_read_q=function_mem_req;sfu_read_pending=1;sfu_reads++;
        end
      end
      if(function_mem_out_valid&&function_mem_out_ready)begin
        if(!sfu_read_pending||function_mem_out.token!==sfu_command_q.token)$fatal(1,"SFU response identity");
        case(sfu_read_q.buffer_id)
          WORK_AA:if(function_mem_out.data[0]!==qk_expected_aa[sfu_read_q.index])$fatal(1,"SFU AA input");
          WORK_L:if(function_mem_out.data[0]!==lsum[sfu_read_q.index])$fatal(1,"SFU L input");
          WORK_M:if(function_mem_out.data[0]!==m[sfu_read_q.index])$fatal(1,"SFU M input");
          WORK_SCORE:for(int i=0;i<TILE;i++)if(function_mem_out.data[i]!==score[sfu_command_q.tile][sfu_read_q.index][i])$fatal(1,"SFU SCORE input");
          default:$fatal(1,"SFU unknown read buffer");
        endcase
        sfu_read_pending=0;
      end
      if(function_result_valid&&function_result_ready)begin
        if(function_result.token!==sfu_command_q.token||function_result.job!==sfu_command_q.job||function_result.index!=sfu_results)$fatal(1,"SFU result identity/order");
        for(int h=0;h<2;h++)if(function_result.vector_valid[h])begin
          for(int i=0;i<TILE;i++)begin
            if(sfu_command_q.function_id==FUNCTION_GELU)expected=sfu_gate_gold[function_result.index][i];
            else expected=score[sfu_command_q.tile][2*sfu_results+h][i]==32'hff800000 ? 0 : bits($exp(real32(score[sfu_command_q.tile][2*sfu_results+h][i])-real32(m[2*sfu_results+h])));
            if((h?function_result.second[i]:function_result.first[i])!==expected)$fatal(1,"SFU_NUMERIC_RESULT fn=%0d tile=%0d pair=%0d half=%0d lane=%0d got=%h expected=%h",sfu_command_q.function_id,sfu_command_q.tile,sfu_results,h,i,h?function_result.second[i]:function_result.first[i],expected);
          end
        end
        sfu_results++;
      end
      if(function_done_valid&&function_done_ready)begin
        if(!sfu_busy||sfu_read_pending||function_done.command!==sfu_command_q||function_done.error)$fatal(1,"SFU completion");
        if(sfu_command_q.function_id==FUNCTION_GELU&&sfu_results!=51)$fatal(1,"SFU GELU count");
        if(sfu_command_q.function_id==FUNCTION_P_EXP&&(sfu_results!=26||sfu_reads!=102))$fatal(1,"SFU P count");
        if((sfu_command_q.function_id==FUNCTION_ALPHA_EXP||sfu_command_q.function_id==FUNCTION_RECIP)&&(sfu_reads!=51||sfu_writes!=51))$fatal(1,"SFU scalar count");
        if(cycle-sfu_start>stage_dur_max[sfu_command_q.function_id])stage_dur_max[sfu_command_q.function_id]=cycle-sfu_start;
        real_sfu_done_count++;sfu_busy=0;
        $display("REAL_SFU_DONE fn=%0d cycles=%0d reads=%0d writes=%0d results=%0d",sfu_command_q.function_id,cycle-sfu_start,sfu_reads,sfu_writes,sfu_results);
      end
      if(rope_sfu_out_valid&&rope_sfu_out_ready)for(int i=0;i<TILE;i++)begin
        angle=rope_sfu_out.request.position*(10000.0**(-2.0*(rope_sfu_out.request.frequency_base+i)/256.0));
        if(rope_sfu_out.cosine[i]!==bits($cos(angle))||rope_sfu_out.sine[i]!==bits($sin(angle)))$fatal(1,"SFU RoPE bitwise coefficient");
      end
    end
  end
  initial begin: unit_agents
    forever begin
      wait(agents_enabled&&!reset&&!clear);
      fork
        vector_agent();
        begin wait(!agents_enabled||clear||reset);end
      join_any
      disable fork;
    end
  end

  // ---------------- channel drivers and per-cycle bookkeeping ----------------
  always @(negedge clk)begin: channel_present
    acc_rd_item_t read_item;
    if(!reset&&agents_enabled)begin
    if(stress)begin
      kv_out_ready=random_limit(13,4)!=0;
      reduce_out_ready=random_limit(14,4)!=0;
      vector_ready=random_limit(3,4)!=0;
    end else begin
      kv_out_ready=perf?1:cycle%7!=0;
      reduce_out_ready=perf?1:cycle%5!=0;
      vector_ready=perf?1:cycle%11!=0;
    end
    if(corners&&kv_out_valid&&kv_out_last&&kv_hdr.tile_seq==1&&!kv_tail_seen)begin kv_tail_seen=1;kv_tail_hold=32;barrier_hits[job.header.op]++;end
    if(corners&&reduce_out_valid&&reduce_out_last&&reduce_hdr.tile_seq==63&&!reduce_tail_seen)begin reduce_tail_seen=1;reduce_tail_hold=32;barrier_hits[job.header.op]++;end
    if(kv_tail_hold>0)begin kv_out_ready=0;kv_tail_hold--;if(done_valid)$fatal(1,"KV tail done");end
    if(reduce_tail_hold>0)begin reduce_out_ready=0;reduce_tail_hold--;if(done_valid)$fatal(1,"reduce tail done");end
    if(hold_kv)kv_out_ready=0;
    if(hold_reduce)reduce_out_ready=0;
    // Response release: LAT cycles after the request was accepted, II=1.
    acc_data_ready=acc_age.size()>0&&acc_age[0]>=ACC_RD_LAT-1;
    vector_mem_out_ready=vm_age.size()>0&&vm_age[0]>=WORK_RD_LAT-1;
    rope_out_ready=rope_age.size()>0&&rope_age[0]>=ROPE_LAT-1;
    // Request presentation, one beat per cycle while the queue is non-empty.
    if(acc_rd_q.size()>0)begin read_item=acc_rd_q[0];acc_rd_valid=1;acc_rd_sel=read_item.sel;acc_rd_addr=read_item.addr;end
    else acc_rd_valid=0;
    if(acc_wr_q.size()>0)begin acc_wr_valid=1;acc_wr=acc_wr_q[0];end
    else acc_wr_valid=0;
    if(vm_req_q.size()>0)begin vector_mem_valid=1;vector_mem_req=vm_req_q[0];end
    else vector_mem_valid=0;
    if(rope_req_q.size()>0)begin rope_req_valid=1;rope_req=rope_req_q[0];end
    else rope_req_valid=0;
    end
  end

  always @(posedge clk)if(reset||clear)begin
    kv_stall=0;reduce_stall=0;vector_stall=0;function_stall=0;
    acc_stall=0;vm_stall=0;fm_stall=0;rope_stall=0;
    q_released=0;
    acc_rd_q.delete();acc_wr_q.delete();vm_req_q.delete();fm_req_q.delete();rope_req_q.delete();
    acc_age.delete();vm_age.delete();fm_age.delete();rope_age.delete();
    acc_rsp_q.delete();vm_rsp_q.delete();fm_rsp_q.delete();rope_rsp_q.delete();rope_sfu_rsp_q.delete();
  end else begin
    cycle++;
    if(!agents_enabled)begin
      acc_rd_q.delete();acc_wr_q.delete();vm_req_q.delete();fm_req_q.delete();rope_req_q.delete();
      acc_age.delete();vm_age.delete();fm_age.delete();rope_age.delete();
      acc_rsp_q.delete();vm_rsp_q.delete();fm_rsp_q.delete();rope_rsp_q.delete();rope_sfu_rsp_q.delete();
    end else begin
      // Request acceptance pops the queue head and starts the response timer.
      // The timer starts one below zero so that LAT is measured from the
      // accepting edge, not from the edge that already carried it.
      if(acc_rd_valid&&acc_rd_ready)begin acc_rd_q.pop_front();acc_age.push_back(-1-resp_extra(9));end
      if(acc_wr_valid&&acc_wr_ready)acc_wr_q.pop_front();
      if(vector_mem_valid&&vector_mem_ready)begin
        vm_req_q.pop_front();
        if(!vector_mem_req.write)vm_age.push_back(-1-resp_extra(10));
      end
      if(rope_req_valid&&rope_req_ready)rope_req_q.pop_front();
      // Response transfer captures the payload for the waiting collector.
      if(acc_data_valid&&acc_data_ready)begin acc_rsp_q.push_back({acc_odd,acc_even});void'(acc_age.pop_front());end
      if(vector_mem_out_valid&&vector_mem_out_ready)begin vm_rsp_q.push_back(vector_mem_out);void'(vm_age.pop_front());end
      if(rope_out_valid&&pc_rope_out_ready)begin if(!projection_real_active)rope_rsp_q.push_back(rope_out);void'(rope_age.pop_front());end
      // RoPE hop: the external service answers in request order.
      if(rope_sfu_valid&&rope_sfu_ready)rope_age.push_back(-1-resp_extra(12));
      foreach(acc_age[i])acc_age[i]++;
      foreach(vm_age[i])vm_age[i]++;
      foreach(fm_age[i])fm_age[i]++;
      foreach(rope_age[i])rope_age[i]++;
    end
    if(cycle%10000==0)$display("CONTROL_PROGRESS cycle=%0d op=%0d issues=%0d post=%0d capture=%0d index=%0d vec=%0d sfu=%0d region=%0d",
      cycle,job.header.op,issues[job.header.op],dut.post_service.state_q,dut.post_service.capture_q,dut.post_service.index_q,
      dut.vheld_q.function_id,dut.fheld_q.function_id,qoz_region.owner);
    if(protocol_error&&!allow_fault)$fatal(1,"control fault status=%0d post=%b engine=%b op=%0d",dut.status_q,dut.se,dut.ee,job.header.op);
    if(xbc_valid&&!xbc_ready)coverage[13]++;
    if(hbm_valid&&!hbm_ready)coverage[14]++;
    if(kv_valid&&!kv_ready)coverage[15]++;
    if(vector_valid&&!pc_vector_ready)coverage[3]++;
    if(function_valid&&!function_ready)coverage[4]++;
    if(acc_data_valid&&!pc_acc_data_ready)coverage[9]++;
    if((vector_mem_out_valid&&!pc_vector_mem_out_ready)||(function_mem_out_valid&&!function_mem_out_ready))coverage[10]++;
    if(rope_sfu_valid&&!rope_sfu_ready)coverage[11]++;
    if(rope_out_valid&&!rope_out_ready)coverage[12]++;
    if(kv_out_valid&&!kv_out_ready)coverage[16]++;
    if(reduce_out_valid&&!reduce_out_ready)coverage[17]++;
    if(dut.exec.dispatch.matrix.req_valid)begin
      if(issues[job.header.op]==0)first_issue_cyc[job.header.op]=cycle;
      issues[job.header.op]++;last_issue_cyc[job.header.op]=cycle;
    end
    if(dut.exec.dispatch.req.start&&active_adapter==1)begin
      matrix_jobs++;
      if(attn_start_n<1024)attn_start[attn_start_n]=cycle;
      attn_start_n++;
    end
    if(active_adapter==1&&dut.exec.attention.mdv&&dut.exec.attention.mdr)begin
      if(dut.exec.attention.md.op==MATRIX_PV)attn_pv_commits++;else attn_qk_commits++;
    end
    if(gu_prefetch_valid&&gu_prefetch_ready)allowed_n=gu_prefetch_n;
    if(kv_stall&&(!kv_out_valid||kv_out!==kv_hold))$fatal(1,"KV changed while stalled");
    if(reduce_stall&&(!reduce_out_valid||reduce_out!==reduce_hold))$fatal(1,"reduce changed while stalled");
    kv_stall=kv_out_valid&&!kv_out_ready;reduce_stall=reduce_out_valid&&!reduce_out_ready;kv_hold=kv_out;reduce_hold=reduce_out;
    if(vector_stall&&(!vector_valid||vector_cmd!==vector_hold))$fatal(1,"vector command changed while stalled");
    if(function_stall&&(!function_valid||function_cmd!==function_hold))$fatal(1,"function command changed while stalled");
    vector_stall=vector_valid&&!pc_vector_ready;function_stall=function_valid&&!function_ready;vector_hold=vector_cmd;function_hold=function_cmd;
    if(acc_stall&&(!acc_data_valid||{acc_odd,acc_even}!==acc_hold))$fatal(1,"ACC response changed while stalled");
    if(vm_stall&&(!vector_mem_out_valid||vector_mem_out!==vm_hold))$fatal(1,"VPU memory response changed while stalled");
    if(fm_stall&&(!function_mem_out_valid||function_mem_out!==fm_hold))$fatal(1,"SFU memory response changed while stalled");
    if(rope_stall&&(!rope_out_valid||rope_out!==rope_hold))$fatal(1,"RoPE response changed while stalled");
    acc_stall=acc_data_valid&&!pc_acc_data_ready;acc_hold={acc_odd,acc_even};
    vm_stall=vector_mem_out_valid&&!pc_vector_mem_out_ready;vm_hold=vector_mem_out;
    fm_stall=function_mem_out_valid&&!function_mem_out_ready;fm_hold=function_mem_out;
    rope_stall=rope_out_valid&&!pc_rope_out_ready;rope_hold=rope_out;
    if(active_adapter==1&&dut.exec.qout&&dut.exec.qout_ready)lifecycle_reads++;
    if(active_adapter==1&&dut.exec.qrelease&&dut.exec.qrelease_ready)begin
      if(dut.exec.qoz.store.rd_out_valid||dut.exec.qread)$fatal(1,"Q release before reads drain");
      q_released=1;lifecycle_releases++;
    end
    if(active_adapter==1&&dut.exec.qoz_req_valid&&dut.exec.region_req_ready&&dut.exec.qoz_req.owner==QOZ_O)begin
      if(!q_released)$fatal(1,"O acquire before Q release");
      lifecycle_o_acquires++;
    end
    if(active_adapter==1&&dut.exec.attention.mdv&&dut.exec.attention.mdr&&dut.exec.attention.md.op==MATRIX_PV&&dut.exec.attention.md.block_id==54)pv54_commits++;
    if(function_valid&&function_ready&&function_cmd.function_id==FUNCTION_RECIP&&pv54_commits!=1)$fatal(1,"RECIP before PV54 commit");
    if(pc_vector_result_valid&&vector_result_ready)last_post_cyc[job.header.op]=cycle;
    if(function_result_valid&&function_result_ready)last_post_cyc[job.header.op]=cycle;
    if(kv_hdr_valid&&kv_hdr_ready)begin
      if(kv_hdr.transfer_id!=job.transfer.transfer_id||kv_hdr.transfer_epoch!=job.transfer.transfer_epoch||
         kv_hdr.destination_id!=job.transfer.destination_id||kv_hdr.token_origin!=job.transfer.token_origin||
         kv_hdr.source_id!=job.core_id||kv_hdr.rows!=ROWS||kv_hdr.columns!=TILE||kv_hdr.reserved!=0||
         kv_hdr.kind!=(job.header.op==OP_K_PROJ?TILE_K:TILE_V)||
         kv_hdr.column_base!=(job.header.op==OP_K_PROJ?job.rope_pair_base+128*kv_hdr.tile_seq:32*job.core_id+16*kv_hdr.tile_seq))
        $fatal(1,"KV descriptor");
      kv_received_hdr=kv_hdr;kv_beat=0;
    end
    if(reduce_hdr_valid&&reduce_hdr_ready)begin
      if(reduce_hdr.transfer_id!=job.transfer.transfer_id||reduce_hdr.transfer_epoch!=job.transfer.transfer_epoch||
         reduce_hdr.destination_id!=job.transfer.destination_id||reduce_hdr.token_origin!=job.transfer.token_origin||
         reduce_hdr.source_id!=job.core_id||reduce_hdr.rows!=ROWS||reduce_hdr.columns!=TILE||reduce_hdr.reserved!=0||
         reduce_hdr.kind!=(job.header.op==OP_O_PROJ?TILE_O:TILE_DOWN)||reduce_hdr.column_base!=16*reduce_hdr.tile_seq)
        $fatal(1,"Reduce descriptor");
      reduce_received_hdr=reduce_hdr;reduce_beat=0;
    end
    if(kv_out_valid&&kv_out_ready)begin
      qvec16_t expected;int tile;
      last_egress_cyc[job.header.op]=cycle;tile=kv_received_hdr.tile_seq;
      if(sent[job.header.op]!=tile*(job.header.op==OP_K_PROJ?51:64)+kv_beat)$fatal(1,"KV order");
      if(job.header.op==OP_K_PROJ)expected=kgold[tile][kv_beat];
      else begin
        logic [15:0][31:0] vals;
        for(int i=0;i<TILE;i++)vals[i]=(kv_beat/16*16+i<ROWS)?projection_golden(OP_V_PROJ,kv_beat/16*16+i,tile,kv_beat%16):0;
        expected=quant(vals);
      end
      if(kv_out[135:128]!==expected.scale||kv_out[127:0]!==expected.data)$fatal(1,"KV data/scale");
      if(kv_out_last!=(kv_beat==(job.header.op==OP_K_PROJ?50:63)))$fatal(1,"KV last");
      kv_beat++;sent[job.header.op]++;
      if(kv_out_last)begin
        kv_commit='{transfer_id:kv_received_hdr.transfer_id,transfer_epoch:kv_received_hdr.transfer_epoch,
          tile_seq:kv_received_hdr.tile_seq,source_id:kv_received_hdr.source_id,status:0,reserved:0};
        commit_pending=1;
      end
    end
    if(kv_commit_valid&&kv_commit_ready)commit_pending=0;
    if(reduce_out_valid&&reduce_out_ready)begin
      last_egress_cyc[job.header.op]=cycle;
      if(sent[job.header.op]!=reduce_received_hdr.tile_seq*ROWS+reduce_beat)$fatal(1,"Reduce order");
      for(int i=0;i<TILE;i++)if(reduce_out[32*i+:32]!==projection_golden(job.header.op,reduce_beat,reduce_received_hdr.tile_seq,i))$fatal(1,"Reduce numerical golden");
      if(reduce_out_last!=(reduce_beat==ROWS-1))$fatal(1,"Reduce last");
      reduce_beat++;sent[job.header.op]++;
    end
  end

  task automatic run_job(input pcore_op_e op,input int id,expected_issues);
    int job_cycles,span,steady_max,steady_sum,steady_n;
    if(op==OP_O_PROJ||op==OP_DOWN_PROJ)
      for(int r=0;r<ROWS;r++)reduced_gold[op][r]=local_projection_golden(op,r);
    @(negedge clk);job='0;job.header='{job_id:16'(id),epoch:4'd3,head:3'd1,op:op};
    job.data_context=16'h1234;job.user_tag=64'ha5a5000000000000|id;job.position_base=7;job.core_id=2;job.rope_pair_base=32;
    job.transfer='{transfer_id:16'(id),transfer_epoch:16'd9,destination_id:16'(op),token_origin:16'd831};
    kv_tail_seen=0;reduce_tail_seen=0;
    if(op==OP_ATTENTION)attn_start_n=0;
    job_valid=1;do @(posedge clk);while(!job_ready);job_start=cycle;job_accept_cyc[op]=cycle;@(negedge clk);job_valid=0;
    fork
      begin
        case(op)
          OP_K_PROJ,OP_V_PROJ:feed_projection(2,64,0);
          OP_Q_PROJ:feed_projection(16,64,0);
          OP_ATTENTION:feed_attention();
          OP_O_PROJ:feed_projection(64,16,1);
          OP_GU:feed_gu();
          OP_DOWN_PROJ:feed_projection(64,32,1);
        endcase
      end
      begin
        wait(done_valid);
        done_cyc[op]=cycle;
        if(done.job!==job||done.status!=CONTROL_OK||issues[op]!=expected_issues)$fatal(1,"Job completion op=%0d issues=%0d expected=%0d",op,issues[op],expected_issues);
        $display("CONTROL_JOB op=%0d cycles=%0d issues=%0d sent=%0d commands=%0d",op,cycle-job_start,issues[op],sent[op],commands[op]);
        job_cycles=cycle-job_accept_cyc[op];
        span=last_issue_cyc[op]-first_issue_cyc[op]+1;
        $display("JOB_PERF op=%s cycles=%0d matrix_issues=%0d first_issue=%0d last_issue=%0d matrix_span=%0d matrix_util=%0d.%02d%% job_matrix_occupancy=%0d.%02d%% post_tail=%0d egress_tail=%0d commands=%0d",
          op_name(op),
          job_cycles,issues[op],first_issue_cyc[op],last_issue_cyc[op],span,
          issues[op]*100/span,(issues[op]*10000/span)%100,
          issues[op]*100/job_cycles,(issues[op]*10000/job_cycles)%100,
          done_cyc[op]-last_issue_cyc[op],done_cyc[op]-last_egress_cyc[op],commands[op]);
        if(op==OP_ATTENTION)begin
          steady_max=0;steady_sum=0;steady_n=0;
          for(int i=5;i+6<attn_start_n;i++)begin
            int iv;iv=attn_start[i+1]-attn_start[i];
            if(iv>steady_max)steady_max=iv;steady_sum+=iv;steady_n++;
          end
          $display("ATTN_PERF qk_jobs=%0d pv_jobs=%0d matrix_body=%0d steady_interval_max=%0d steady_interval_avg=%0d qk_post_max=%0d alpha_max=%0d p_exp_max=%0d p_post_max=%0d scale_cycles=%0d scale_margin_min=%0d recip=%0d afin=%0d total_cycles=%0d",
            attn_qk_commits,attn_pv_commits,issues[op],steady_max,
            steady_n?steady_sum/steady_n:0,stage_dur_max[VECTOR_QK_POST],stage_dur_max[FUNCTION_ALPHA_EXP],
            stage_dur_max[FUNCTION_P_EXP],stage_dur_max[VECTOR_P_POST],
            scale_cycles,scale_margin_min,stage_dur_max[FUNCTION_RECIP],stage_dur_max[VECTOR_AFIN_QUANT],job_cycles);
        end
        done_wait[op]=stress?4+random_limit(7,31):4;
        repeat(done_wait[op])begin @(negedge clk);if(!done_valid||job_ready||done.job!==job||done.status!=CONTROL_OK)$fatal(1,"completion hold");end
        done_ready=1;@(negedge clk);done_ready=0;completed++;
      end
    join
  endtask
  function automatic string op_name(input pcore_op_e op);
    case(op)
      OP_Q_PROJ:return "Q";OP_K_PROJ:return "K";OP_V_PROJ:return "V";
      OP_ATTENTION:return "ATTENTION";OP_O_PROJ:return "O";OP_GU:return "GU";default:return "DOWN";
    endcase
  endfunction
  task automatic prepare_q;
    logic [15:0][31:0] a,b;real angle,cs,sn,x,y;
    for(int group=0;group<8;group++)for(int r=0;r<ROWS;r++)begin
      for(int i=0;i<TILE;i++)begin
        x=aint(r)*bint(OP_Q_PROJ,2*group,i,0);y=aint(r)*bint(OP_Q_PROJ,2*group+1,i,0);
        angle=(7+r)*(10000.0**(-2.0*(group*TILE+i)/256.0));cs=real32(bits($cos(angle)));sn=real32(bits($sin(angle)));
        a[i]=bits(x*cs-y*sn);b[i]=bits(y*cs+x*sn);
      end
      qgold[group][r]=quant(a);qgold[group+8][r]=quant(b);
    end
    @(negedge clk);ext_qoz_region='0;ext_qoz_region.header='{job_id:16'd30,epoch:4'd3,head:3'd1,op:OP_Q_PROJ};
    ext_qoz_region.owner=QOZ_Q;ext_qoz_region.tiles=16;ext_qoz_region_valid=1;
    do @(posedge clk);while(!ext_qoz_region_ready);@(negedge clk);ext_qoz_region_valid=0;
    for(int t=0;t<16;t++)for(int p=0;p<PAIRS;p++)begin
      ext_qoz_wr='0;ext_qoz_wr.header=ext_qoz_region.header;ext_qoz_wr.n=6'(t);
      ext_qoz_wr.pair_data.tile_idx=6'(t);ext_qoz_wr.pair_data.pair_idx=PAIR_BITS'(p);
      ext_qoz_wr.pair_data.row_valid=row_mask(p);
      ext_qoz_wr.pair_data.row[0]=qgold[t][2*p];if(p<25)ext_qoz_wr.pair_data.row[1]=qgold[t][2*p+1];ext_qoz_wr.last=p==PAIRS-1;
      ext_qoz_wr_valid=1;do @(posedge clk);while(!ext_qoz_wr_ready);@(negedge clk);ext_qoz_wr_valid=0;
    end
  endtask
  initial begin
    string mode_s;
    agents_enabled=!MANUAL;
    if($value$plusargs("MODE=%s",mode_s))begin
      if(mode_s=="PERFORMANCE")mode=TB_PERFORMANCE;
      else if(mode_s=="STRESS")mode=TB_STRESS;
      else mode=TB_FUNCTIONAL;
    end else mode=$test$plusargs("STRESS")?TB_STRESS:TB_FUNCTIONAL;
    stress=(mode==TB_STRESS)||$test$plusargs("STRESS");
    perf=(mode==TB_PERFORMANCE)||(mode==TB_STRESS);
    corners=$test$plusargs("CORNERS");
    mode_name=(mode==TB_PERFORMANCE)?"PERFORMANCE":(mode==TB_STRESS)?"STRESS":"FUNCTIONAL";
    if($value$plusargs("SEED=%d",seed))begin end
    for(int i=0;i<20;i++)random_state[i]=32'(seed)^(32'h9e3779b9*32'(i+1));
    for(int i=0;i<24;i++)coverage[i]=0;
    for(int i=0;i<7;i++)begin barrier_hits[i]=0;done_wait[i]=0;end
    for(int i=0;i<32;i++)stage_dur_max[i]=0;
    job='0;vector_done='0;vector_result='0;xbc_entry='0;hbm_entry='0;kv_entry='0;acc_wr='0;
    ext_qoz_region='0;ext_qoz_wr='0;
    for(int i=0;i<7;i++)begin
      issues[i]=0;sent[i]=0;commands[i]=0;outputs[i]=0;
      job_accept_cyc[i]=0;first_issue_cyc[i]=0;last_issue_cyc[i]=0;done_cyc[i]=0;last_post_cyc[i]=0;last_egress_cyc[i]=0;
    end
    for(int r=0;r<ROWS;r++)begin m[r]=32'hff800000;lsum[r]=0;end
    repeat(35)@(negedge clk);reset=0;
    if(MANUAL)wait(1'b0);
    if($test$plusargs("ATTENTION_ONLY"))begin
      prepare_q();run_job(OP_ATTENTION,4,45760);
      if(!qoz_complete||qoz_region.owner!=QOZ_O||matrix_jobs!=110)$fatal(1,"Attention-only count");
      if(real_oacc_jobs!=KV_BLOCKS-1)$fatal(1,"real OACC job count=%0d expected=%0d",real_oacc_jobs,KV_BLOCKS-1);
      if(real_afin_jobs!=1)$fatal(1,"real AFIN job count=%0d expected=1",real_afin_jobs);
      $display("tb_pcore_control PASS attention_only=1 attention_jobs=110 real_softmax=1 workspace=1 O_commit=1 mode=%s",mode_name);$finish;
    end
    if($test$plusargs("GU_ONLY"))begin
      run_job(OP_GU,6,106496);run_job(OP_DOWN_PROJ,7,53248);
      $display("tb_pcore_control PASS gu_down_only=1 real_gelu=1 Z_chain=1 mode=%s",mode_name);$finish;
    end
    if($test$plusargs("K_ONLY"))begin
      run_job(OP_K_PROJ,1,3328);
      $display("tb_pcore_control PASS k_only=1 rope=1 quant=1 mode=%s",mode_name);$finish;
    end
    run_job(OP_K_PROJ,1,3328);
    run_job(OP_V_PROJ,2,3328);
    run_job(OP_Q_PROJ,3,26624);
    if(!qoz_complete||qoz_region.owner!=QOZ_Q)$fatal(1,"Q not committed");
    run_job(OP_ATTENTION,4,45760);
    if(!qoz_complete||qoz_region.owner!=QOZ_O||matrix_jobs!=110)$fatal(1,"Attention O/matrix count");
    run_job(OP_O_PROJ,5,26624);
    run_job(OP_GU,6,106496);
    run_job(OP_DOWN_PROJ,7,53248);
    if(sent[OP_K_PROJ]!=102||sent[OP_V_PROJ]!=128||sent[OP_O_PROJ]!=3264||sent[OP_DOWN_PROJ]!=3264)$fatal(1,"egress counts");
    if(lifecycle_reads!=55*16*PAIRS||lifecycle_releases!=1||lifecycle_o_acquires!=1||pv54_commits!=1)$fatal(1,"Attention lifecycle coverage reads=%0d release=%0d acquire=%0d tail=%0d",lifecycle_reads,lifecycle_releases,lifecycle_o_acquires,pv54_commits);
    if(stress)begin
      for(int i=0;i<18;i++)$display("STRESS_BIN channel=%0d count=%0d",i,coverage[i]);
      for(int i=0;i<13;i++)if(coverage[i]==0)$fatal(1,"missing stress coverage channel=%0d",i);
      if(coverage[16]==0||coverage[17]==0)$fatal(1,"missing egress stress coverage");
    end
    $display("CONTROL_LIFECYCLE Q_reads=%0d Q_release=%0d O_acquire=%0d PV54_commit=%0d",lifecycle_reads,lifecycle_releases,lifecycle_o_acquires,pv54_commits);
    for(int i=0;i<7;i++)begin
      if(corners&&barrier_hits[i]==0)$fatal(1,"missing completion corner op=%0d",i);
      $display("CONTROL_COVER_JOB op=%0d issues=%0d packets=%0d vpu=%0d barrier=%0d done_hold=%0d",i,issues[i],sent[i],commands[i],barrier_hits[i],done_wait[i]);
    end
    $display("CONTROL_COVER seed=%0d stress=%0d xbc_gap=%0d hbm_gap=%0d kvb_gap=%0d vcmd_stall=%0d fcmd_stall=%0d vresult_delay=%0d fresult_delay=%0d vdone_delay=%0d fdone_delay=%0d acc_backpressure=%0d workspace_backpressure=%0d rope_request_stall=%0d rope_response_stall=%0d kv_out_stall=%0d reduce_out_stall=%0d sfu_commands=%0d",seed,stress,coverage[0],coverage[1],coverage[2],coverage[3],coverage[4],coverage[5],coverage[6],coverage[7],coverage[8],coverage[9],coverage[10],coverage[11],coverage[12],coverage[16],coverage[17],function_commands);
    if(real_sfu_done_count!=143)$fatal(1,"real SFU command coverage count=%0d",real_sfu_done_count);
    $display("REAL_SFU_SEVEN_JOB_COVER commands=%0d model_driver=0",real_sfu_done_count);
    $display("tb_pcore_control PASS jobs=7 issues=265408 attention_jobs=110 real_rope=1 real_gelu=1 real_softmax=1 all_mask_row=1 q_o_z_chain=1 egress_backpressure=1 mode=%s vpu_lanes=%0d sfu_lanes=%0d rope_lat=%0d acc_rd_lat=%0d work_lat=%0d",
      mode_name,VPU_LANES,SFU_LANES,ROPE_LAT,ACC_RD_LAT,WORK_RD_LAT);$finish;
  end
  initial begin #12000000;$fatal(1,"control watchdog op=%0d stage=%0d vec=%0d sfu=%0d",job.header.op,dut.post_service.state_q,dut.vheld_q.function_id,dut.fheld_q.function_id);end
endmodule

// TB-only valve: never withdraw a presented beat while the sink stalls.
module tb_vpu_stress_valve(input logic clk,reset,enabled,input integer seed,
  input logic upstream_valid,downstream_ready,output logic allow);
  integer age=0;
  wire [31:0] unsigned_seed=seed;
  wire [31:0] hold_cycles=2+(unsigned_seed%4);
  assign allow=!enabled||(age>=hold_cycles);
  always @(posedge clk)begin
    if(reset||!enabled)age<=0;
    else if(upstream_valid)begin
      if(allow&&downstream_ready)age<=0;
      else if(!allow)age<=age+1;
    end else age<=0;
  end
endmodule

// Delay presentation, then keep it asserted until the actual consumer accepts it.
module tb_sfu_random_valve #(parameter logic [31:0] SALT=1)(
 input logic clk,reset,enabled,input integer seed,
 input logic upstream_valid,downstream_ready,output logic allow);
 logic [31:0] rng=1;integer age=0,budget=1;logic presented=0;
 logic [31:0] next_rng;
 always_comb begin next_rng=rng;next_rng^=next_rng<<13;next_rng^=next_rng>>17;next_rng^=next_rng<<5;end
 assign allow=!enabled||presented;
 always @(posedge clk)begin
  if(reset||!enabled)begin rng<=32'(seed)^SALT;age<=0;budget<=1;presented<=0;end
  else if(!upstream_valid)begin age<=0;presented<=0;end
  else if(presented)begin if(downstream_ready)begin age<=0;presented<=0;end end
  else if(age==0)begin rng<=next_rng;budget<=1+int'(next_rng%7);age<=1;end
  else if(age>=budget)presented<=1;
  else age<=age+1;
 end
endmodule
