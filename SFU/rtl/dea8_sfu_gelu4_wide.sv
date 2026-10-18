// Real four-lane FP64 GELU_tanh datapath; FP32 ports and one final RNE conversion.
// Matches legacy evaluation order: .5*x * (2/(1+exp(-2*sqrt(2/pi)*(x+.044715*x*x*x)))).
// IP latencies (generated configuration): MUL12 ADD14 EXP45 RECIP35; total168, II1.
module dea8_sfu_gelu4_wide(
 input logic clk,reset,flush,in_valid,output logic in_ready,
 input logic [3:0][31:0] in_data,
 output logic out_valid,input logic out_ready,output logic [3:0][31:0] out_data);
 import dea8_sfu_precision_pkg::*;
 localparam int M=12,A=14,E=45,D=35;
 localparam int XFINAL=4*M+2*A+E+D;
 localparam int LAT=XFINAL+M;
 localparam logic [63:0] C=64'h3fa6e4e26d4801f7;
 localparam logic [63:0] SQRT_2_PI=64'h3fe9884533d43651;
 logic [1:0] reset_hold,warmup;
 logic active,advance;
 logic [3:0][31:0] xdelay[0:XFINAL-1];
 logic [3:0][3:0] exceptional[0:LAT-1];
 logic [3:0][8:0] v;
 logic [3:0][8:0][63:0] y;
 always_ff @(posedge clk)
  if(reset||flush)reset_hold<=2'b11;else reset_hold<={1'b0,reset_hold[1]};
 assign active=!reset&&!flush&&(reset_hold==0);
 always_ff @(posedge clk)if(!active)warmup<=0;else warmup<={warmup[0],1'b1};
 assign out_valid=active&&v[0][8];
 assign advance=!out_valid||out_ready;
 assign in_ready=active&&(&warmup)&&advance;
 // Data delay has no reset: permits shift-register/RAM inference in a later synthesis.
 always_ff @(posedge clk)if(advance)begin
  xdelay[0]<=in_data;
  for(int i=1;i<XFINAL;i++)xdelay[i]<=xdelay[i-1];
 end
 always_ff @(posedge clk)begin
  if(!active)for(int i=0;i<LAT;i++)exceptional[i]<='0;
  else if(advance)begin
   for(int l=0;l<4;l++)exceptional[0][l]<={(&in_data[l][30:23])&&(|in_data[l][22:0]),in_data[l][30:0]==31'h7f800000,in_data[l][30:0]==0,in_data[l][31]};
   for(int i=1;i<LAT;i++)exceptional[i]<=exceptional[i-1];
  end
 end
 function automatic logic [63:0] negative_twice(input logic [63:0] x);
  if(x[62:52]==2047)return {~x[63],x[62:0]};
  if(x[62:52]==2046)return {~x[63],11'h7ff,52'b0};
  if(x[62:52]==0)return {~x[63],10'b0,x[51],x[50:0],1'b0};
  return {~x[63],11'(x[62:52]+11'd1),x[51:0]};
 endfunction
 // Denominator is >=1 or +Inf. Reciprocal lies in [0,1]; scaling by two is exact.
 function automatic logic [63:0] twice_positive(input logic [63:0] x);
  if(x[62:52]==0)return {x[63],10'b0,x[51:0],1'b0};
  if(x[62:52]==2047)return x;
  return {x[63],11'(x[62:52]+11'd1),x[51:0]};
 endfunction
 function automatic logic [63:0] half_original(input logic [31:0] x);
  logic [63:0] z;z=fp32_to_fp64(x);
  if(z[62:52]==0||z[62:52]==2047)return z;
  return {z[63],11'(z[62:52]-11'd1),z[51:0]};
 endfunction
 for(genvar l=0;l<4;l++)begin: lanes
  sfu_gmul64_ip m0(.aclk(clk),.aclken(advance),.aresetn(active),
   .s_axis_a_tvalid(in_valid&&in_ready),.s_axis_a_tdata(C),
   .s_axis_b_tvalid(in_valid&&in_ready),.s_axis_b_tdata(fp32_to_fp64(in_data[l])),
   .m_axis_result_tvalid(v[l][0]),.m_axis_result_tdata(y[l][0]));
  sfu_gmul64_ip m1(.aclk(clk),.aclken(advance),.aresetn(active),
   .s_axis_a_tvalid(v[l][0]),.s_axis_a_tdata(y[l][0]),
   .s_axis_b_tvalid(v[l][0]),.s_axis_b_tdata(fp32_to_fp64(xdelay[M-1][l])),
   .m_axis_result_tvalid(v[l][1]),.m_axis_result_tdata(y[l][1]));
  sfu_gmul64_ip m2(.aclk(clk),.aclken(advance),.aresetn(active),
   .s_axis_a_tvalid(v[l][1]),.s_axis_a_tdata(y[l][1]),
   .s_axis_b_tvalid(v[l][1]),.s_axis_b_tdata(fp32_to_fp64(xdelay[2*M-1][l])),
   .m_axis_result_tvalid(v[l][2]),.m_axis_result_tdata(y[l][2]));
  sfu_gadd64_ip a0(.aclk(clk),.aclken(advance),.aresetn(active),
   .s_axis_a_tvalid(v[l][2]),.s_axis_a_tdata(fp32_to_fp64(xdelay[3*M-1][l])),
   .s_axis_b_tvalid(v[l][2]),.s_axis_b_tdata(y[l][2]),
   .m_axis_result_tvalid(v[l][3]),.m_axis_result_tdata(y[l][3]));
  sfu_gmul64_ip m3(.aclk(clk),.aclken(advance),.aresetn(active),
   .s_axis_a_tvalid(v[l][3]),.s_axis_a_tdata(SQRT_2_PI),
   .s_axis_b_tvalid(v[l][3]),.s_axis_b_tdata(y[l][3]),
   .m_axis_result_tvalid(v[l][4]),.m_axis_result_tdata(y[l][4]));
  sfu_exp64_ip exponential(.aclk(clk),.aclken(advance),.aresetn(active),
   .s_axis_a_tvalid(v[l][4]),.s_axis_a_tdata(negative_twice(y[l][4])),
   .m_axis_result_tvalid(v[l][5]),.m_axis_result_tdata(y[l][5]));
  sfu_gadd64_ip a1(.aclk(clk),.aclken(advance),.aresetn(active),
   .s_axis_a_tvalid(v[l][5]),.s_axis_a_tdata(64'h3ff0000000000000),
   .s_axis_b_tvalid(v[l][5]),.s_axis_b_tdata(y[l][5]),
   .m_axis_result_tvalid(v[l][6]),.m_axis_result_tdata(y[l][6]));
  sfu_recip64_ip divide(.aclk(clk),.aclken(advance),.aresetn(active),
   .s_axis_a_tvalid(v[l][6]),.s_axis_a_tdata(y[l][6]),
   .m_axis_result_tvalid(v[l][7]),.m_axis_result_tdata(y[l][7]));
  sfu_gmul64_ip m4(.aclk(clk),.aclken(advance),.aresetn(active),
   .s_axis_a_tvalid(v[l][7]),.s_axis_a_tdata(half_original(xdelay[XFINAL-1][l])),
   .s_axis_b_tvalid(v[l][7]),.s_axis_b_tdata(twice_positive(y[l][7])),
   .m_axis_result_tvalid(v[l][8]),.m_axis_result_tdata(y[l][8]));
  always_comb begin
   if(exceptional[LAT-1][l][3])out_data[l]=32'h7fc00000;
   else if(exceptional[LAT-1][l][2])out_data[l]=exceptional[LAT-1][l][0] ? 32'd0 : 32'h7f800000;
   else if(exceptional[LAT-1][l][1])out_data[l]={exceptional[LAT-1][l][0],31'b0};
   else out_data[l]=fp64_to_fp32_rne(y[l][8]);
  end
 end
endmodule
