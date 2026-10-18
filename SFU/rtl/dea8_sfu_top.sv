import pcore_pkg::*;
import pcore_control_pkg::*;

// First integration candidate. Bounded buffers and one memory read in flight.
// Performance is deliberately reported from tests, never inferred from SFU4.
module dea8_sfu_top #(
  parameter int ROPE_POSITION_BASE=816,
  parameter ROPE_FILE="rope_base816_rom256.mem",
  parameter GELU_FILE="gelu_uniform256_q24.mem"
)(
  input logic clk,reset,flush,output logic flush_ack,
  input logic function_valid,output logic function_ready,input logic [$bits(control_command_t)-1:0] function_cmd,
  output logic function_done_valid,input logic function_done_ready,output logic [$bits(control_unit_done_t)-1:0] function_done,
  input logic function_data_valid,output logic function_data_ready,input logic [$bits(control_fp_data_t)-1:0] function_data,
  output logic function_result_valid,input logic function_result_ready,output logic [$bits(control_fp_data_t)-1:0] function_result,
  output logic function_mem_valid,input logic function_mem_ready,output logic [$bits(control_memory_req_t)-1:0] function_mem_req,
  input logic function_mem_out_valid,output logic function_mem_out_ready,input logic [$bits(control_memory_rsp_t)-1:0] function_mem_out,
  input logic rope_valid,output logic rope_ready,input logic [$bits(control_rope_req_t)-1:0] rope_req,
  output logic rope_out_valid,input logic rope_out_ready,output logic [$bits(control_rope_rsp_t)-1:0] rope_out,
  output logic protocol_error
);
  typedef enum logic [3:0] {IDLE,GIN,GPIPE,MREQ,MRSP,EPIPE,RPIPE,MWR,RESULT,DONE} state_t;
  state_t state;
  control_command_t command_q;
  control_command_t incoming_command;
  control_fp_data_t incoming_data;
  control_memory_rsp_t incoming_memory;
  control_memory_req_t memory_request;
  control_unit_done_t completion;
  assign incoming_command=function_cmd;
  assign incoming_data=function_data;
  assign incoming_memory=function_mem_out;
  assign function_mem_req=memory_request;
  control_fp_data_t answer;
  logic [5:0] row_or_pair;
  logic [1:0] read_phase;
  logic [3:0] sent_groups,received_groups;
  logic [1:0] write_slot;
  logic [2:0] scalar_count;
  logic [15:0][31:0] first_q,second_q;
  logic [31:0] max0,max1,scalar;
  logic error_q,rope_error,rope_flush_ack;
  assign completion='{command:command_q,error:error_q};
  logic giv,gir,gov,eiv,eir,eov,riv,rir,rov;
  logic [3:0][31:0] gi,go,es,em,eo;
  logic [31:0] ro;
  int group_count;
  assign flush_ack=flush&&!reset;
  assign protocol_error=error_q||rope_error;
  assign function_ready=!reset&&!flush&&!error_q&&(state==IDLE);
  assign function_done_valid=!reset&&!flush&&(state==DONE);
  assign function_done=completion;
  assign function_data_ready=!reset&&!flush&&(state==GIN);
  assign function_result_valid=!reset&&!flush&&(state==RESULT);
  assign function_result=answer;
  assign function_mem_valid=!reset&&!flush&&((state==MREQ)||(state==MWR));
  assign function_mem_out_ready=!reset&&!flush&&(state==MRSP);
  always_comb begin
    memory_request='0;memory_request.token=command_q.token;
    memory_request.index=row_or_pair;memory_request.mask=16'b1;
    if(command_q.function_id==FUNCTION_ALPHA_EXP&&state!=MWR)memory_request.index=6'(row_or_pair+read_phase);
    if(command_q.function_id==FUNCTION_P_EXP)begin
      memory_request.index=6'(int'(row_or_pair)*2+(read_phase>=2));
      if(!read_phase[0])begin
        memory_request.buffer_id=WORK_SCORE;memory_request.bank=command_q.tile[0];
        memory_request.mask='1;
      end else memory_request.buffer_id=WORK_M;
    end else if(command_q.function_id==FUNCTION_ALPHA_EXP)memory_request.buffer_id=WORK_AA;
    else memory_request.buffer_id=WORK_L;
    if(state==MWR)begin
      memory_request.write=1;memory_request.data[0]=command_q.function_id==FUNCTION_ALPHA_EXP ? answer.first[write_slot] : scalar;
      if(command_q.function_id==FUNCTION_ALPHA_EXP)begin
        memory_request.buffer_id=WORK_ALPHA;memory_request.bank=command_q.tile[0];
      end else memory_request.buffer_id=WORK_RECIP;
    end
  end
  always_comb begin
    gi='0;es='0;em='0;
    group_count=command_q.function_id==FUNCTION_P_EXP?((row_or_pair==PAIRS-1)?4:8):1;
    for(int lane=0;lane<4;lane++)begin
      if(sent_groups<4)gi[lane]=first_q[int'(sent_groups)*4+lane];
      if(command_q.function_id==FUNCTION_P_EXP)begin
        if(sent_groups<4)begin es[lane]=first_q[int'(sent_groups)*4+lane];em[lane]=max0;end
        else if(sent_groups<8)begin es[lane]=second_q[(int'(sent_groups)-4)*4+lane];em[lane]=max1;end
        // Never evaluate -Inf - (-Inf) for an all-masked row.
        if(es[lane]==32'hff800000)em[lane]=0;
      end else es[lane]=first_q[lane];
    end
  end
  assign giv=(state==GPIPE)&&(sent_groups<4)&&!reset&&!flush;
  assign eiv=(state==EPIPE)&&(int'(sent_groups)<group_count)&&!reset&&!flush;
  assign riv=(state==RPIPE)&&(sent_groups==0)&&!reset&&!flush;
  dea8_sfu_gelu4_wide gelu4(
    .clk,.reset,.flush,.in_valid(giv),.in_ready(gir),.in_data(gi),
    .out_valid(gov),.out_ready(1'b1),.out_data(go));
  dea8_sfu_exp4_wide exp4(.clk,.reset,.flush,.in_valid(eiv),.in_ready(eir),
    .in_score(es),.in_max(em),.out_valid(eov),.out_ready(1'b1),.out_data(eo));
  dea8_sfu_recip_wide recip(.clk,.reset,.flush,.in_valid(riv),.in_ready(rir),.in_data(first_q[0]),
    .out_valid(rov),.out_ready(1'b1),.out_data(ro));
  dea8_sfu_rope_rom #(.POSITION_BASE(ROPE_POSITION_BASE),.ROM_FILE(ROPE_FILE),.RAM_STYLE("block")) rope(
    .clk,.reset,.flush,.flush_ack(rope_flush_ack),.req_valid(rope_valid),.req_ready(rope_ready),.req(rope_req),
    .rsp_valid(rope_out_valid),.rsp_ready(rope_out_ready),.rsp(rope_out),.protocol_error(rope_error));
  always_ff @(posedge clk)begin
    if(reset||flush)begin
      state<=IDLE;command_q<='0;answer<='0;row_or_pair<=0;read_phase<=0;
      sent_groups<=0;received_groups<=0;first_q<='0;second_q<='0;
      max0<=0;max1<=0;scalar<=0;error_q<=0;write_slot<=0;scalar_count<=0;
    end else begin
      case(state)
        IDLE:if(function_valid&&function_ready)begin
          command_q<=incoming_command;row_or_pair<=0;read_phase<=0;answer<='0;
          case(incoming_command.function_id)
            FUNCTION_GELU:state<=GIN;
            FUNCTION_ALPHA_EXP,FUNCTION_P_EXP,FUNCTION_RECIP:state<=MREQ;
            default:begin error_q<=1;state<=DONE;end
          endcase
        end
        GIN:if(function_data_valid&&function_data_ready)begin
          if(incoming_data.job!=command_q.job||incoming_data.token!=command_q.token||
             incoming_data.index!=row_or_pair||incoming_data.tile!=command_q.tile||
             incoming_data.vector_valid!=2'b01||incoming_data.last!=(row_or_pair==ROWS-1))begin
            error_q<=1;state<=DONE;
          end else begin
            first_q<=incoming_data.first;answer<=incoming_data;answer.second<='0;
            sent_groups<=0;received_groups<=0;state<=GPIPE;
          end
        end
        GPIPE:begin
          if(giv&&gir)sent_groups<=sent_groups+1;
          if(gov)begin
            for(int lane=0;lane<4;lane++)answer.first[int'(received_groups)*4+lane]<=go[lane];
            received_groups<=received_groups+1;
            if(received_groups==3)state<=RESULT;
          end
        end
        MREQ:if(function_mem_valid&&function_mem_ready)state<=MRSP;
        MRSP:if(function_mem_out_valid&&function_mem_out_ready)begin
          if(incoming_memory.token!=command_q.token)begin error_q<=1;state<=DONE;end
          else if(command_q.function_id==FUNCTION_P_EXP)begin
            case(read_phase)
              0:first_q<=incoming_memory.data;
              1:max0<=incoming_memory.data[0];
              2:second_q<=incoming_memory.data;
              3:max1<=incoming_memory.data[0];
            endcase
            if(read_phase==3||(row_or_pair==PAIRS-1&&read_phase==1))begin
              sent_groups<=0;received_groups<=0;answer<='0;
              answer.job<=command_q.job;answer.token<=command_q.token;answer.tile<=command_q.tile;
              answer.index<=row_or_pair;answer.last<=row_or_pair==PAIRS-1;
              answer.vector_valid<=row_or_pair==PAIRS-1?2'b01:2'b11;state<=EPIPE;
            end else begin read_phase<=read_phase+1;state<=MREQ;end
          end else if(command_q.function_id==FUNCTION_ALPHA_EXP)begin
            first_q[read_phase]<=incoming_memory.data[0];
            if(read_phase==3 || int'(row_or_pair)+int'(read_phase)==ROWS-1)begin
              scalar_count<=3'(read_phase)+1;write_slot<=0;
              sent_groups<=0;received_groups<=0;state<=EPIPE;
            end else begin read_phase<=read_phase+1;state<=MREQ;end
          end else begin
            first_q<=incoming_memory.data;sent_groups<=0;received_groups<=0;
            state<=RPIPE;
          end
        end
        EPIPE:begin
          if(eiv&&eir)sent_groups<=sent_groups+1;
          if(eov)begin
            if(command_q.function_id==FUNCTION_P_EXP)begin
              for(int lane=0;lane<4;lane++)begin
                if(received_groups<4)answer.first[int'(received_groups)*4+lane]<=eo[lane];
                else answer.second[(int'(received_groups)-4)*4+lane]<=eo[lane];
              end
              received_groups<=received_groups+1;
              if(int'(received_groups)==group_count-1)state<=RESULT;
            end else begin answer.first[0]<=eo[0];answer.first[1]<=eo[1];answer.first[2]<=eo[2];answer.first[3]<=eo[3];state<=MWR;end
          end
        end
        RPIPE:begin
          if(riv&&rir)sent_groups<=1;
          if(rov)begin scalar<=ro;state<=MWR;end
        end
        MWR:if(function_mem_valid&&function_mem_ready)begin
          if(row_or_pair==ROWS-1)state<=DONE;
          else if(command_q.function_id==FUNCTION_ALPHA_EXP&&int'(write_slot)+1<int'(scalar_count))begin
            row_or_pair<=row_or_pair+1;write_slot<=write_slot+1;
          end else begin row_or_pair<=row_or_pair+1;read_phase<=0;state<=MREQ;end
        end
        RESULT:if(function_result_valid&&function_result_ready)begin
          if(row_or_pair==(command_q.function_id==FUNCTION_GELU?ROWS-1:PAIRS-1))state<=DONE;
          else begin
            row_or_pair<=row_or_pair+1;read_phase<=0;
            state<=command_q.function_id==FUNCTION_GELU?GIN:MREQ;
          end
        end
        DONE:if(function_done_valid&&function_done_ready)state<=IDLE;
        default:begin error_q<=1;state<=DONE;end
      endcase
    end
  end
endmodule
