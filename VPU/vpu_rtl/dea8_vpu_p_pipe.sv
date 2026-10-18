// P_POST: four independently rounded reduction levels, then one rounded ADD.
// Sum latency=16, complete latency=20, II=1. RoPE reuses all 32 ADD nodes
// as one parallel four-stage bank; P and RoPE are mutually exclusive jobs.
module dea8_vpu_p_pipe(input logic clk,reset,clear,in_valid,
 input dea8_vpu_math_pkg::pair_fp_t x,
 input dea8_vpu_math_pkg::scalars_t product,
 input logic [1:0] product_error,
 input logic [1:0] input_error,
 input logic rope_mode,rope_in_valid,
 input dea8_vpu_math_pkg::pair_fp_t rope_a,rope_b,
 output logic rope_out_valid,output dea8_vpu_math_pkg::pair_fp_t rope_y,
 output logic out_valid,output dea8_vpu_math_pkg::scalars_t lvalue,
 output logic [1:0] error);
 import dea8_vpu_math_pkg::*;
 logic [19:0] v;logic [3:0] rope_v;
 logic [1:0] e[20];logic [1:0] me[11];
 scalars_t prod_delay[11];
 always_ff @(posedge clk)begin
  if(reset||clear)begin v<=0;rope_v<=0;end
  else begin v<={v[18:0],in_valid};rope_v<={rope_v[2:0],rope_in_valid};end
  e[0]<=input_error;for(int i=1;i<20;i++)e[i]<=e[i-1];
  prod_delay[0]<=product;me[0]<=product_error;
  for(int i=1;i<11;i++)begin prod_delay[i]<=prod_delay[i-1];me[i]<=me[i-1];end
 end
 for(genvar r=0;r<2;r++)begin: rows
  logic [31:0] node_y[16],node_a[16],node_b[16];
  logic [3:0] me_final;
  for(genvar n=0;n<16;n++)begin: nodes
   if(n<8)begin
    assign node_a[n]=x[r][2*n];assign node_b[n]=x[r][2*n+1];
   end else if(n<12)begin
    assign node_a[n]=node_y[2*(n-8)];assign node_b[n]=node_y[2*(n-8)+1];
   end else if(n<14)begin
    assign node_a[n]=node_y[8+2*(n-12)];assign node_b[n]=node_y[9+2*(n-12)];
   end else if(n==14)begin
    assign node_a[n]=node_y[12];assign node_b[n]=node_y[13];
   end else begin
    assign node_a[n]=prod_delay[10][r];assign node_b[n]=node_y[14];
   end
   wire sum_valid=(n<8)?in_valid:((n<12)?v[3]:((n<14)?v[7]:((n==14)?v[11]:v[15])));
   dea8_vpu_add_pipe add(.clk,.reset,.clear,
    .in_valid(rope_mode?rope_in_valid:sum_valid),
    .a(rope_mode?rope_a[r][n]:node_a[n]),.b(rope_mode?rope_b[r][n]:node_b[n]),
    .out_valid(),.y(node_y[n]));
   assign rope_y[r][n]=node_y[n];
  end
  assign lvalue[r]=node_y[15];
  always_ff @(posedge clk)me_final<={me_final[2:0],me[10][r]};
  assign error[r]=e[19][r]||me_final[3]||nonfinite(lvalue[r]);
 end
 assign out_valid=v[19];
 assign rope_out_valid=rope_v[3];
endmodule
