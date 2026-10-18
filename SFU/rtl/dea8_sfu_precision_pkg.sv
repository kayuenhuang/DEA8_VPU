// Exact bit conversions at the SFU boundary. No real/$exp/math simulation code.
package dea8_sfu_precision_pkg;
 function automatic logic [63:0] fp32_to_fp64(input logic [31:0] x);
  logic [10:0] exponent;
  logic [63:0] mantissa;
  integer lead;
  if(x[30:23]==255)return {x[31],11'h7ff,x[22:0],29'b0};
  if(x[30:23]!=0)begin
   exponent=11'(int'(x[30:23])+896);
   return {x[31],exponent,x[22:0],29'b0};
  end
  if(x[22:0]==0)return {x[31],63'b0};
  lead=0;for(int k=0;k<23;k++)if(x[k])lead=k;
  exponent=11'(874+lead);
  mantissa={41'b0,x[22:0]}<<(52-lead);
  return {x[31],exponent,mantissa[51:0]};
 endfunction
 function automatic logic [31:0] fp64_to_fp32_rne(input logic [63:0] x);
  logic [63:0] mantissa,rounded,remainder,halfway;
  integer exponent,distance;
  if(x[62:52]==2047)begin
   if(|x[51:0])return 32'h7fc00000;
   return {x[63],8'hff,23'b0};
  end
  // Every binary64 subnormal is smaller than half the minimum binary32 subnormal.
  if(x[62:52]==0)return {x[63],31'b0};
  exponent=int'(x[62:52])-1023;
  if(exponent>127)return {x[63],8'hff,23'b0};
  mantissa={11'b0,1'b1,x[51:0]};
  if(exponent>=-126)begin
   rounded=(mantissa>>29)+64'(mantissa[28]&&((|mantissa[27:0])||mantissa[29]));
   if(rounded[24])begin rounded=rounded>>1;exponent++;end
   if(exponent>127)return {x[63],8'hff,23'b0};
   return {x[63],8'(exponent+127),rounded[22:0]};
  end
  distance=-exponent-97;
  if(distance>53)return {x[63],31'b0};
  rounded=mantissa>>distance;
  remainder=mantissa&((64'b1<<distance)-64'b1);
  halfway=64'b1<<(distance-1);
  rounded=rounded+64'((remainder>halfway)||((remainder==halfway)&&rounded[0]));
  if(rounded[23])return {x[63],8'h01,23'b0};
  return {x[63],8'b0,rounded[22:0]};
 endfunction
endpackage
