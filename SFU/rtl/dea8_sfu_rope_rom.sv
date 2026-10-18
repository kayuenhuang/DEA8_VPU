import pcore_pkg::*;
import pcore_control_pkg::*;

// Four coefficient pairs per synchronous RAM read, four reads per response.
// A fixed coefficient window is bound to POSITION_BASE. No modulo aliasing.
module dea8_sfu_rope_rom #(
  parameter int POSITION_BASE=816,
  parameter int POSITION_COUNT=51,
  parameter ROM_FILE="rope_base816_rom256.mem",
  parameter RAM_STYLE="block"
)(
  input logic clk,reset,flush,
  output logic flush_ack,
  input logic req_valid,output logic req_ready,input logic [$bits(control_rope_req_t)-1:0] req,
  output logic rsp_valid,input logic rsp_ready,output logic [$bits(control_rope_rsp_t)-1:0] rsp,
  output logic protocol_error
);
  localparam int DEPTH=POSITION_COUNT*32;
  localparam int ADDR_BITS=$clog2(DEPTH);
  (* ram_style=RAM_STYLE *) logic [255:0] coefficients[0:DEPTH-1];
  logic [255:0] ram_data;
  typedef enum logic [1:0] {IDLE,READS,HOLD} state_t;
  state_t state;
  logic [ADDR_BITS-1:0] address_base;
  logic [2:0] issued,returned;
  logic read_pending;
  control_rope_rsp_t answer;
  control_rope_req_t request;
  assign request=req;
  logic legal,read_enable;
  initial $readmemh(ROM_FILE,coefficients);
  assign legal=(request.position>=POSITION_BASE)&&
               (int'(request.position)<POSITION_BASE+POSITION_COUNT)&&
               (request.frequency_base<=112)&&(request.frequency_base[3:0]==0)&&
               (request.row<ROWS);
  assign req_ready=!reset&&!flush&&!protocol_error&&(state==IDLE)&&legal;
  assign rsp_valid=!reset&&!flush&&(state==HOLD);
  assign rsp=answer;
  assign flush_ack=flush&&!reset;
  assign read_enable=!reset&&!flush&&(state==READS)&&(issued<4);
  // No reset on the RAM output register: permits synchronous block/ultra RAM.
  always_ff @(posedge clk)
    if(read_enable) ram_data<=coefficients[address_base+issued];
  always_ff @(posedge clk) begin
    if(reset||flush) begin
      state<=IDLE;answer<='0;address_base<='0;
      issued<=0;returned<=0;read_pending<=0;protocol_error<=0;
    end else begin
      read_pending<=read_enable;
      if(req_valid&&(state==IDLE)&&!legal) protocol_error<=1;
      case(state)
        IDLE: if(req_valid&&req_ready) begin
          answer<='0;answer.request<=request;
          address_base<=ADDR_BITS'((int'(request.position)-POSITION_BASE)*32+
                                   int'(request.frequency_base)/4);
          issued<=0;returned<=0;state<=READS;
        end
        READS: begin
          if(read_enable) issued<=issued+1;
          if(read_pending) begin
            for(int lane=0;lane<4;lane++) begin
              answer.cosine[returned*4+lane]<=ram_data[lane*64+:32];
              answer.sine[returned*4+lane]<=ram_data[lane*64+32+:32];
            end
            returned<=returned+1;
            if(returned==3) state<=HOLD;
          end
        end
        HOLD: if(rsp_valid&&rsp_ready) state<=IDLE;
        default: begin state<=IDLE;protocol_error<=1;end
      endcase
    end
  end
endmodule
