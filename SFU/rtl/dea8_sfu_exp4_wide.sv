// Four real binary64 subtract/exp IP lanes, narrowed once to FP32 RNE.
// External FP32 ports, global backpressure and flush semantics are retained.
module dea8_sfu_exp4_wide(
 input logic clk,reset,flush,in_valid,output logic in_ready,
 input logic [3:0][31:0] in_score,in_max,
 output logic out_valid,input logic out_ready,output logic [3:0][31:0] out_data);
 import dea8_sfu_precision_pkg::*;
 logic [1:0] reset_hold,warmup;
 logic active,advance;
 logic [3:0] sub_valid,result_valid;
 logic [3:0][63:0] difference,wide_result;
 always_ff @(posedge clk)
  if(reset||flush)reset_hold<=2'b11;else reset_hold<={1'b0,reset_hold[1]};
 assign active=!reset&&!flush&&(reset_hold==0);
 always_ff @(posedge clk)if(!active)warmup<=0;else warmup<={warmup[0],1'b1};
 assign out_valid=active&&result_valid[0];
 assign advance=!out_valid||out_ready;
 assign in_ready=active&&(&warmup)&&advance;
 for(genvar lane=0;lane<4;lane++)begin: lanes
  sfu_sub64_ip subtract(.aclk(clk),.aclken(advance),.aresetn(active),
   .s_axis_a_tvalid(in_valid&&in_ready),.s_axis_a_tdata(fp32_to_fp64(in_score[lane])),
   .s_axis_b_tvalid(in_valid&&in_ready),.s_axis_b_tdata(fp32_to_fp64(in_max[lane])),
   .m_axis_result_tvalid(sub_valid[lane]),.m_axis_result_tdata(difference[lane]));
  sfu_exp64_ip exponential(.aclk(clk),.aclken(advance),.aresetn(active),
   .s_axis_a_tvalid(sub_valid[lane]),.s_axis_a_tdata(difference[lane]),
   .m_axis_result_tvalid(result_valid[lane]),.m_axis_result_tdata(wide_result[lane]));
  assign out_data[lane]=fp64_to_fp32_rne(wide_result[lane]);
 end
endmodule
