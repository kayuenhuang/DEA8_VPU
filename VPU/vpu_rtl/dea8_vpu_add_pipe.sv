// Four arithmetic stages: classify/align, raw add, normalize, RNE/pack.
// Every node retains one independent FP32 rounding, II=1; flush invalidates valid.
module dea8_vpu_add_pipe(input logic clk,reset,clear,in_valid,
 input logic [31:0] a,b, output logic out_valid, output logic [31:0] y);
 import dea8_fp32_v3_pkg::*;
  function automatic fp_add_pre_t prepare_compact(input logic [31:0] a,b);
    fp_add_pre_t p;
    logic [7:0] ea,eb,big_e,small_e,diff;
    logic [23:0] ma,mb,big_m,small_m;
    logic a_big,a_nan,b_nan,a_inf,b_inf;
    ea=(a[30:23]==0)?8'd1:a[30:23];eb=(b[30:23]==0)?8'd1:b[30:23];
    ma={(|a[30:23]),a[22:0]};mb={(|b[30:23]),b[22:0]};
    // Raw magnitude order is identical for all finite FP32 encodings, including subnormals.
    a_big=(a[30:0]>=b[30:0]);
    big_e=a_big?ea:eb;small_e=a_big?eb:ea;diff=big_e-small_e;
    big_m=a_big?ma:mb;small_m=a_big?mb:ma;
    a_nan=(&a[30:23])&&(|a[22:0]);b_nan=(&b[30:23])&&(|b[22:0]);
    a_inf=a[30:0]==FP_INF[30:0];b_inf=b[30:0]==FP_INF[30:0];
    p.special=a_nan||b_nan||a_inf||b_inf;
    p.special_value=(a_nan||b_nan||(a_inf&&b_inf&&(a[31]!=b[31])))?FP_QNAN:{(a_inf?a[31]:b[31]),FP_INF[30:0]};
    p.sign_result=a_big?a[31]:b[31];p.zero_sign=a[31]&&b[31];p.subtract=a[31]^b[31];
    p.exponent={1'b0,big_e};p.big_x={1'b0,big_m,3'b0};
    p.small_x=shift_right_jam28({1'b0,small_m,3'b0},diff);
    return p;
  endfunction


 fp_add_pre_t pre_q,raw_pre_q,norm_pre_q;
 wire [27:0] raw_q;logic [27:0] norm_q;
 dea8_vpu_dsp_addsub raw_alu(.clk,.reset(reset||clear),.ce(valid_q[0]),.subtract(pre_q.subtract),.a(pre_q.big_x),.b(pre_q.small_x),.y(raw_q));
 logic [8:0] exp_q;
 logic zero_q;
 logic [3:0] valid_q;
 logic [27:0] norm_d;
 logic [31:0] priority_word;logic [7:0] nonzero_groups;
 logic [2:0] group_shift;logic [3:0] top_nibble;logic [1:0] nibble_shift;
 logic [4:0] wanted,shift,norm_budget_q;logic norm_uncapped_q,cap_shift;
 logic [8:0] exp_d,exp_final;
 logic [24:0] rounded,adjusted;
 logic [7:0] exp_field;
 always_comb begin
  // Find the first nonzero nibble without normalizing a second wide data copy.
  priority_word={raw_q[26:0],5'b0};
  for(int g=0;g<8;g++)nonzero_groups[7-g]=|priority_word[31-4*g -:4];
  casez(nonzero_groups)
   8'b1???????:group_shift=0;8'b01??????:group_shift=1;
   8'b001?????:group_shift=2;8'b0001????:group_shift=3;
   8'b00001???:group_shift=4;8'b000001??:group_shift=5;
   8'b0000001?:group_shift=6;default:group_shift=7;
  endcase
  top_nibble=priority_word[31-4*group_shift -:4];
  casez(top_nibble)
   4'b1???:nibble_shift=0;4'b01??:nibble_shift=1;
   4'b001?:nibble_shift=2;default:nibble_shift=3;
  endcase
  wanted={group_shift,nibble_shift};
  cap_shift=(group_shift>norm_budget_q[4:2])||
   ((group_shift==norm_budget_q[4:2])&&(nibble_shift>norm_budget_q[1:0]));
  shift=(!norm_uncapped_q&&cap_shift)?norm_budget_q:wanted;
  // One barrel shifter handles both normal cancellation and subnormal results.
  norm_d=raw_q[27]?{1'b0,raw_q[27:2],raw_q[1]|raw_q[0]}:(raw_q<<shift);
  exp_d=raw_q[27]?(raw_pre_q.exponent+9'd1):(raw_pre_q.exponent-{4'b0,shift});
  rounded={1'b0,norm_q[26:3]}+25'(norm_q[2]&&(norm_q[1]||norm_q[0]||norm_q[3]));
  adjusted=rounded[24]?(rounded>>1):rounded;
  exp_final=exp_q+9'(rounded[24]);
  exp_field=(exp_final==1&&!adjusted[23])?0:exp_final[7:0];
 end
 always_ff @(posedge clk) begin
  if(reset||clear)valid_q<=0;
  else valid_q<={valid_q[2:0],in_valid};
  if(in_valid)pre_q<=prepare_compact(a,b);
  if(valid_q[0])begin
   raw_pre_q<=pre_q;
   norm_budget_q<=pre_q.exponent[4:0]-5'd1;
   norm_uncapped_q<=(|pre_q.exponent[8:5])||(pre_q.exponent[4:0]==0);
  end
  if(valid_q[1])begin norm_pre_q<=raw_pre_q;norm_q<=norm_d;exp_q<=exp_d;zero_q<=raw_q==0;end
  if(valid_q[2])begin
  if(norm_pre_q.special)y<=norm_pre_q.special_value;
  else if(zero_q)y<={norm_pre_q.zero_sign,31'b0};
  else if(exp_final>=255)y<={norm_pre_q.sign_result,FP_INF[30:0]};
  else y<={norm_pre_q.sign_result,exp_field,adjusted[22:0]};
  end
 end
 assign out_valid=valid_q[3];
endmodule

// Four arithmetic stages: classify/align, raw add, normalize, RNE/pack.
// Every node retains one independent FP32 rounding, II=1; flush invalidates valid.
module dea8_vpu_add_stall(input logic clk,reset,clear,in_valid,advance,
 input logic [31:0] a,b, output logic out_valid, output logic [31:0] y);
 import dea8_fp32_v3_pkg::*;
  function automatic fp_add_pre_t prepare_compact(input logic [31:0] a,b);
    fp_add_pre_t p;
    logic [7:0] ea,eb,big_e,small_e,diff;
    logic [23:0] ma,mb,big_m,small_m;
    logic a_big,a_nan,b_nan,a_inf,b_inf;
    ea=(a[30:23]==0)?8'd1:a[30:23];eb=(b[30:23]==0)?8'd1:b[30:23];
    ma={(|a[30:23]),a[22:0]};mb={(|b[30:23]),b[22:0]};
    // Raw magnitude order is identical for all finite FP32 encodings, including subnormals.
    a_big=(a[30:0]>=b[30:0]);
    big_e=a_big?ea:eb;small_e=a_big?eb:ea;diff=big_e-small_e;
    big_m=a_big?ma:mb;small_m=a_big?mb:ma;
    a_nan=(&a[30:23])&&(|a[22:0]);b_nan=(&b[30:23])&&(|b[22:0]);
    a_inf=a[30:0]==FP_INF[30:0];b_inf=b[30:0]==FP_INF[30:0];
    p.special=a_nan||b_nan||a_inf||b_inf;
    p.special_value=(a_nan||b_nan||(a_inf&&b_inf&&(a[31]!=b[31])))?FP_QNAN:{(a_inf?a[31]:b[31]),FP_INF[30:0]};
    p.sign_result=a_big?a[31]:b[31];p.zero_sign=a[31]&&b[31];p.subtract=a[31]^b[31];
    p.exponent={1'b0,big_e};p.big_x={1'b0,big_m,3'b0};
    p.small_x=shift_right_jam28({1'b0,small_m,3'b0},diff);
    return p;
  endfunction


 fp_add_pre_t pre_q,raw_pre_q,norm_pre_q;
 wire [27:0] raw_q;logic [27:0] norm_q;
 dea8_vpu_dsp_addsub raw_alu(.clk,.reset(reset||clear),.ce(advance&&valid_q[0]),.subtract(pre_q.subtract),.a(pre_q.big_x),.b(pre_q.small_x),.y(raw_q));
 logic [8:0] exp_q;
 logic zero_q;
 logic [3:0] valid_q;
 logic [27:0] norm_d;
 logic [31:0] priority_word;logic [7:0] nonzero_groups;
 logic [2:0] group_shift;logic [3:0] top_nibble;logic [1:0] nibble_shift;
 logic [4:0] wanted,shift,norm_budget_q;logic norm_uncapped_q,cap_shift;
 logic [8:0] exp_d,exp_final;
 logic [24:0] rounded,adjusted;
 logic [7:0] exp_field;
 always_comb begin
  // Find the first nonzero nibble without normalizing a second wide data copy.
  priority_word={raw_q[26:0],5'b0};
  for(int g=0;g<8;g++)nonzero_groups[7-g]=|priority_word[31-4*g -:4];
  casez(nonzero_groups)
   8'b1???????:group_shift=0;8'b01??????:group_shift=1;
   8'b001?????:group_shift=2;8'b0001????:group_shift=3;
   8'b00001???:group_shift=4;8'b000001??:group_shift=5;
   8'b0000001?:group_shift=6;default:group_shift=7;
  endcase
  top_nibble=priority_word[31-4*group_shift -:4];
  casez(top_nibble)
   4'b1???:nibble_shift=0;4'b01??:nibble_shift=1;
   4'b001?:nibble_shift=2;default:nibble_shift=3;
  endcase
  wanted={group_shift,nibble_shift};
  cap_shift=(group_shift>norm_budget_q[4:2])||
   ((group_shift==norm_budget_q[4:2])&&(nibble_shift>norm_budget_q[1:0]));
  shift=(!norm_uncapped_q&&cap_shift)?norm_budget_q:wanted;
  // One barrel shifter handles both normal cancellation and subnormal results.
  norm_d=raw_q[27]?{1'b0,raw_q[27:2],raw_q[1]|raw_q[0]}:(raw_q<<shift);
  exp_d=raw_q[27]?(raw_pre_q.exponent+9'd1):(raw_pre_q.exponent-{4'b0,shift});
  rounded={1'b0,norm_q[26:3]}+25'(norm_q[2]&&(norm_q[1]||norm_q[0]||norm_q[3]));
  adjusted=rounded[24]?(rounded>>1):rounded;
  exp_final=exp_q+9'(rounded[24]);
  exp_field=(exp_final==1&&!adjusted[23])?0:exp_final[7:0];
 end
 always_ff @(posedge clk) begin
  if(reset||clear)valid_q<=0;
  else if(advance)valid_q<={valid_q[2:0],in_valid};
  if(advance)begin
  if(in_valid)pre_q<=prepare_compact(a,b);
  if(valid_q[0])begin
   raw_pre_q<=pre_q;
   norm_budget_q<=pre_q.exponent[4:0]-5'd1;
   norm_uncapped_q<=(|pre_q.exponent[8:5])||(pre_q.exponent[4:0]==0);
  end
  if(valid_q[1])begin norm_pre_q<=raw_pre_q;norm_q<=norm_d;exp_q<=exp_d;zero_q<=raw_q==0;end
  if(valid_q[2])begin
  if(norm_pre_q.special)y<=norm_pre_q.special_value;
  else if(zero_q)y<={norm_pre_q.zero_sign,31'b0};
  else if(exp_final>=255)y<={norm_pre_q.sign_result,FP_INF[30:0]};
  else y<={norm_pre_q.sign_result,exp_field,adjusted[22:0]};
  end
  end
 end
 assign out_valid=valid_q[3];
endmodule
