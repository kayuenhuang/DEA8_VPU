module dea8_sfu_gelu4 #(
  parameter COEFF_FILE="gelu_uniform256_q24.mem"
)(
  input logic clk,reset,flush,
  input logic in_valid,output logic in_ready,input logic [3:0][31:0] in_data,
  output logic out_valid,input logic out_ready,output logic [3:0][31:0] out_data
);
  logic advance;
  logic [3:0] lane_valid;
  assign advance=!out_valid||out_ready;
  assign in_ready=advance&&!reset&&!flush;
  assign out_valid=lane_valid[0]&&!reset&&!flush;
  for(genvar lane=0;lane<4;lane++)begin: lanes
    dea8_sfu_gelu_lane #(.COEFF_FILE(COEFF_FILE)) arithmetic(
      .clk,.reset,.flush,.enable(advance),.in_valid(in_valid&&in_ready),
      .in_data(in_data[lane]),.out_valid(lane_valid[lane]),.out_data(out_data[lane])
    );
  end
endmodule
