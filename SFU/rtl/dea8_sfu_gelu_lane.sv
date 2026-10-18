import dea8_sfu_fixed_pkg::*;
// Candidate only: uniform quadratic interpolation, Q24 coefficients, Q18 fraction.
// Measured error is reported separately; not assumed equivalent to ideal GELU.
module dea8_sfu_gelu_lane #(
  parameter COEFF_FILE="gelu_uniform256_q24.mem"
)(
  input logic clk,reset,flush,enable,
  input logic in_valid,input logic [31:0] in_data,
  output logic out_valid,output logic [31:0] out_data
);
  (* rom_style="block" *) logic [95:0] coeff_rom[0:255];
  logic [95:0] coeff;
  logic [17:0] fraction1,fraction2,fraction3;
  logic [5:0] valid_q,special_q;
  logic [31:0] passthrough[0:5];
  logic [31:0] normal_result;
  logic signed [31:0] xfixed,c0_2,c0_3,c1_2,horner3,result4,sum5;
  logic [25:0] biased;
  logic [31:0] special_data;
  logic special;
  (* use_dsp="yes" *) logic signed [50:0] product2,product3;
  initial $readmemh(COEFF_FILE,coeff_rom);
  always_comb begin
    xfixed=fp32_to_q22(in_data);
    biased=26'(xfixed+32'sd33554432);
    special=0;special_data=0;
    if(in_data[30:23]==255)begin
      special=1;
      if(in_data[22:0]!=0)special_data=32'h7fc00000;
      else special_data=in_data[31]?32'd0:in_data;
    end else if(in_data[30:0]==0)begin special=1;special_data=in_data;end
    else if(in_data[30:0]>=31'h41000000)begin
      special=1;special_data=in_data[31]?32'd0:in_data;
    end
  end
  assign out_valid=valid_q[5];
  assign out_data=special_q[5]?passthrough[5]:normal_result;
  always_ff @(posedge clk) begin
    if(enable&&in_valid)coeff<=coeff_rom[biased[25:18]];
    if(reset||flush)begin
      valid_q<=0;special_q<=0;
      fraction1<=0;fraction2<=0;fraction3<=0;
      c0_2<=0;c0_3<=0;c1_2<=0;horner3<=0;result4<=0;
      product2<=0;product3<=0;sum5<=0;normal_result<=0;
      for(int i=0;i<6;i++)passthrough[i]<=0;
    end else if(enable)begin
      valid_q<={valid_q[4:0],in_valid};
      special_q<={special_q[4:0],special};
      passthrough[0]<=special_data;
      for(int i=1;i<6;i++)passthrough[i]<=passthrough[i-1];
      fraction1<=biased[17:0];
      product2<=$signed(coeff[95:64])*$signed({1'b0,fraction1});
      c1_2<=$signed(coeff[63:32]);c0_2<=$signed(coeff[31:0]);fraction2<=fraction1;
      horner3<=c1_2+32'(product2>>>18);c0_3<=c0_2;fraction3<=fraction2;
      product3<=horner3*$signed({1'b0,fraction3});
      // c0 must follow the multiplier's registered result.
      result4<=c0_3;
      sum5<=result4+32'(product3>>>18);
      normal_result<=q24_to_fp32(sum5);
    end
  end
endmodule
