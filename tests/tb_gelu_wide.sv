`timescale 1ns/1ps
module tb_gelu_wide;
 logic clk=0; always #2 clk=~clk;
 logic reset=1,flush=0,iv=0,ir,ov,ready=1;
 logic [3:0][31:0] id,od;
 logic [63:0] vecs[0:4095];
 integer queue_id[0:8191]; integer head=0,tail=0,received=0,stalls=0,cycle=0;
 integer group_id=0,flushes=0,first_in=-1,first_out=-1,last_out=-1;
 logic held=0; logic [127:0] previous;
 dea8_sfu_gelu4_wide dut(clk,reset,flush,iv,ir,id,ov,ready,od);
 always @(posedge clk)begin
  cycle=cycle+1;
  if(reset||flush)begin head=tail;held=0;end
  else begin
   if(held && (!ov || od!==previous))$fatal(1,"STALL_HOLD");
   held=ov&&!ready;previous=od;
   if(ov&&!ready)stalls++;
   if(iv&&ir)begin queue_id[tail]=group_id;tail++;if(first_in<0)first_in=cycle;end
   if(ov&&ready)begin
    if(head==tail)$fatal(1,"UNEXPECTED_OR_STALE_OUTPUT");
    for(int l=0;l<4;l++)if(od[l]!==vecs[queue_id[head]*4+l][31:0])
     $fatal(1,"NUMERIC group=%0d lane=%0d input=%h got=%h expected=%h",queue_id[head],l,vecs[queue_id[head]*4+l][63:32],od[l],vecs[queue_id[head]*4+l][31:0]);
    if(first_out<0)first_out=cycle;
    if(received>0&&received<64&&cycle!=last_out+1)$fatal(1,"II_NOT_ONE");
    last_out=cycle;head++;received++;
   end
  end
 end
 task automatic send(input integer g);
  @(negedge clk);group_id=g;for(int l=0;l<4;l++)id[l]=vecs[g*4+l][63:32];iv=1;
  do @(posedge clk);while(!ir);
 endtask
 initial begin
  $readmemh("vectors.hex",vecs);
  repeat(4)@(negedge clk);reset=0;
  for(int g=0;g<1024;g++)begin
   send(g);
   if(g>256)begin
    @(negedge clk);iv=0;ready=(g%7!=0);
    repeat(g%3)@(negedge clk);
    ready=1;
   end
  end
  @(negedge clk);iv=0;ready=1;
  wait(received==1024);
  $display("FULL_NUMERIC_PASS comparisons=4096 latency=%0d II=1",first_out-first_in);
  for(int f=0;f<6;f++)begin
   send(f);@(negedge clk);iv=0;
   repeat(1+f*35)@(negedge clk);
   flush=1;@(negedge clk);flush=0;flushes++;
   repeat(210)@(negedge clk);
   send(100+f);@(negedge clk);iv=0;wait(head==tail);
  end
  send(200);@(negedge clk);iv=0;ready=0;
  wait(ov);repeat(5)@(negedge clk);flush=1;
  @(negedge clk);flush=0;ready=1;flushes++;
  repeat(210)@(negedge clk);
  send(201);@(negedge clk);iv=0;wait(head==tail);
  repeat(210)@(negedge clk);
  $display("GELU_WIDE_STRICT_PASS comparisons=%0d flushes=%0d stalls=%0d",received*4,flushes,stalls);$finish;
 end
 initial begin #200000;$fatal(1,"TIMEOUT");end
endmodule
