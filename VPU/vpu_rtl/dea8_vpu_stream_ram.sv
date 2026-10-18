module dea8_vpu_stream_ram #(parameter int DW=1024,AW=5)(
 input logic clk,we,rd_en,
 input logic [AW-1:0] wr_addr,rd_addr,
 input logic [DW-1:0] wr_data,output logic [DW-1:0] rd_data
);
 (* ram_style="block" *) logic [DW-1:0] mem[0:(1<<AW)-1];
 always_ff @(posedge clk)begin
  if(we)mem[wr_addr]<=wr_data;
  if(rd_en)rd_data<=mem[rd_addr];
 end
endmodule
