package dea8_sfu_fixed_pkg;
  // Signed Q24 -> FP32, round-to-nearest ties-to-even. Integer range < 2^31.
  function automatic logic [31:0] q24_to_fp32(input logic signed [31:0] value);
    logic negative;
    logic [31:0] magnitude,retained;
    logic [32:0] rounded;
    logic guard_bit,sticky;
    logic [7:0] exponent;
    int leading,shift;
    begin
      negative=value[31];magnitude=negative?(~value+1):value;
      leading=0;for(int i=0;i<32;i++)if(magnitude[i])leading=i;
      exponent=8'(127+leading-24);retained=0;guard_bit=0;sticky=0;
      if(leading<=23)retained=magnitude<<(23-leading);
      else begin
        shift=leading-23;retained=magnitude>>shift;
        guard_bit=magnitude[shift-1];
        for(int i=0;i<32;i++)if(i<shift-1)sticky|=magnitude[i];
      end
      rounded={1'b0,retained}+(guard_bit&&(sticky||retained[0]));
      if(rounded[24])begin rounded=rounded>>1;exponent=exponent+1;end
      if(magnitude==0)return 32'd0;
      return {negative,exponent,rounded[22:0]};
    end
  endfunction
  function automatic logic signed [31:0] fp32_to_q22(input logic [31:0] value);
    logic [31:0] magnitude;
    int shift;
    begin
      magnitude={8'b0,1'b1,value[22:0]};
      shift=int'(value[30:23])-128;
      if(value[30:23]==0)magnitude=0;
      else if(shift>=0)magnitude=magnitude<<shift;
      else if(shift<=-32)magnitude=0;
      else magnitude=magnitude>>(-shift);
      return value[31]?-$signed(magnitude):$signed(magnitude);
    end
  endfunction
endpackage
