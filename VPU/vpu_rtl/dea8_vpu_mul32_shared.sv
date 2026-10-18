// One shared 2x16-lane FP32 bank, five internal stages, II=1.
// classify -> mantissa product -> exponent/leading bit -> RNE -> pack.
module dea8_vpu_mul32_shared(
 input logic clk,reset,clear,in_valid,output logic out_valid,
 input dea8_vpu_math_pkg::pair_fp_t a,b,
 output dea8_vpu_math_pkg::pair_fp_t y,output logic [1:0] error);
 import dea8_vpu_math_pkg::*;
 logic [4:0] valid_q;
 always_ff @(posedge clk)if(reset||clear)valid_q<=0;else valid_q<={valid_q[3:0],in_valid};
 assign out_valid=valid_q[4];
 for(genvar r=0;r<2;r++)begin: rows
  logic [15:0] bad;
  for(genvar j=0;j<16;j++)begin: lanes
   logic [23:0] ma,mb;
   // base in [-298,210], normalized exponent in [-298,257];
   // exponent+127+round <=385. Signed 10-bit arithmetic is exact.
   logic signed [9:0] base_q,base2,exp3,exp4;
   logic [47:0] prod2;logic [25:0] sig3;
   logic [24:0] rounded4; // RNE normalized product <=2^24; underflow result <=2^23.
   logic [31:0] special1,special2,special3,special4;
   logic sp1,sp2,sp3,sp4,sg1,sg2,sg3,sg4,under3,under4;
   logic bad1,bad2,bad3,bad4;
   integer lead;
   // Normalize once, then keep 24 significand bits plus guard and sticky.
   // The low discarded product bits affect sticky, including gradual underflow.
   function automatic logic [31:0] normalize_product(input logic [47:0] prod);
    logic [63:0] n0,n32,n16,n8,n4,n2,n1;
    logic z32,z16,z8,z4,z2;logic [5:0] zeros,highest;
    n0={prod,16'b0};
    z32=!(|n0[63:32]);n32=z32?{n0[31:0],32'b0}:n0;
    z16=!(|n32[63:48]);n16=z16?{n32[47:0],16'b0}:n32;
    z8=!(|n16[63:56]);n8=z8?{n16[55:0],8'b0}:n16;
    z4=!(|n8[63:60]);n4=z4?{n8[59:0],4'b0}:n8;
    z2=!(|n4[63:62]);n2=z2?{n4[61:0],2'b0}:n4;
    n1=n2[63]?n2:{n2[62:0],1'b0};
    zeros={z32,z16,z8,z4,z2,!n2[63]};
    highest=(|prod)?6'd47-zeros:6'd0;
    return {highest,n1[63:39],|n1[38:0]};
   endfunction
   function automatic logic [24:0] round_significand(input logic [25:0] value,input integer distance);
    logic [25:0] s16,s8,s4,s2,s1;
    s16=distance[4]?{16'b0,value[25:17],|value[16:0]}:value;
    s8=distance[3]?{8'b0,s16[25:9],|s16[8:0]}:s16;
    s4=distance[2]?{4'b0,s8[25:5],|s8[4:0]}:s8;
    s2=distance[1]?{2'b0,s4[25:3],|s4[2:0]}:s4;
    s1=distance[0]?{1'b0,s2[25:2],|s2[1:0]}:s2;
    if(distance>=26)s1={25'b0,|value};
    return {1'b0,s1[25:2]}+25'(s1[1]&&(s1[0]||s1[2]));
   endfunction
   logic [31:0] normalized;
   always_comb begin normalized=normalize_product(prod2);lead=int'(normalized[31:26]);end
   always_ff @(posedge clk)begin
    if(in_valid)begin
    ma<={(|a[r][j][30:23]),a[r][j][22:0]};mb<={(|b[r][j][30:23]),b[r][j][22:0]};
    base_q<=10'((a[r][j][30:23]==0?-126:int'(a[r][j][30:23])-127)+
               (b[r][j][30:23]==0?-126:int'(b[r][j][30:23])-127)-46);
    sg1<=a[r][j][31]^b[r][j][31];bad1<=nonfinite(a[r][j])||nonfinite(b[r][j]);
    sp1<=nonfinite(a[r][j])||nonfinite(b[r][j])||a[r][j][30:0]==0||b[r][j][30:0]==0;
    if((nonfinite(a[r][j])&&(|a[r][j][22:0]))||(nonfinite(b[r][j])&&(|b[r][j][22:0]))||
       (a[r][j][30:0]==31'h7f800000&&b[r][j][30:0]==0)||(b[r][j][30:0]==31'h7f800000&&a[r][j][30:0]==0))special1<=32'h7fc00000;
    else if(nonfinite(a[r][j])||nonfinite(b[r][j]))special1<={a[r][j][31]^b[r][j][31],8'hff,23'b0};
    else special1<={a[r][j][31]^b[r][j][31],31'b0};
    end
    if(valid_q[0])begin
    prod2<=ma*mb;base2<=base_q;sg2<=sg1;sp2<=sp1;special2<=special1;bad2<=bad1;
    end
    if(valid_q[1])begin
    sig3<=normalized[25:0];exp3<=base2+$signed(10'(lead));under3<=base2+$signed(10'(lead))<-126;
    sg3<=sg2;sp3<=sp2;special3<=special2;bad3<=bad2;
    // exp3 determines the gradual-underflow shift of the normalized significand.
    end
    if(valid_q[2])begin
    rounded4<=round_significand(sig3,under3?(-126-int'(exp3)):0);
    exp4<=exp3;under4<=under3;sg4<=sg3;sp4<=sp3;special4<=special3;bad4<=bad3;
    end
    if(valid_q[3])begin
    if(sp4)y[r][j]<=special4;
    else if(under4)y[r][j]<=rounded4>=25'h0800000 ? {sg4,8'h01,23'b0}:{sg4,8'b0,rounded4[22:0]};
    else if(exp4+$signed({9'b0,rounded4[24]})>127)y[r][j]<={sg4,8'hff,23'b0};
    else y[r][j]<={sg4,8'(exp4+127+$signed({9'b0,rounded4[24]})),(rounded4[24]?rounded4[23:1]:rounded4[22:0])};
    bad[j]<=bad4||(sp4?nonfinite(special4):(!under4&&exp4+$signed({9'b0,rounded4[24]})>127));
    end
   end
  end
  assign error[r]=|bad;
 end
endmodule


