module dea8_sfu_recip_wide(
 input logic clk,reset,flush,in_valid,output logic in_ready,
 input logic [31:0] in_data,output logic out_valid,input logic out_ready,
 output logic [31:0] out_data);
 import dea8_sfu_precision_pkg::*;
 localparam int LATENCY=35; // Generated sfu_recip64_ip C_Latency, recorded in config.
 logic [1:0] reset_hold,warmup;
 logic active,advance,result_valid;
 logic [63:0] result_data;
 logic [LATENCY-1:0] zero_q;
 always_ff @(posedge clk)
  if(reset||flush)reset_hold<=2'b11;else reset_hold<={1'b0,reset_hold[1]};
 assign active=!reset&&!flush&&(reset_hold==0);
 always_ff @(posedge clk)if(!active)warmup<=0;else warmup<={warmup[0],1'b1};
 assign out_valid=active&&result_valid;
 assign out_data=zero_q[LATENCY-1] ? 32'd0 : fp64_to_fp32_rne(result_data);
 assign advance=!out_valid||out_ready;
 assign in_ready=active&&(&warmup)&&advance;
 always_ff @(posedge clk)
  if(!active)zero_q<=0;else if(advance)zero_q<={zero_q[LATENCY-2:0],(in_data[30:0]==0)};
 sfu_recip64_ip reciprocal(.aclk(clk),.aclken(advance),.aresetn(active),
  .s_axis_a_tvalid(in_valid&&in_ready),
  .s_axis_a_tdata(fp32_to_fp64(in_data[30:0]==0 ? 32'h3f800000 : in_data)),
  .m_axis_result_tvalid(result_valid),.m_axis_result_tdata(result_data));
endmodule
