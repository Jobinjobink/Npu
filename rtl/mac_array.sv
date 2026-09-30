`timescale 1ns/1ps
// Four independent signed INT8 x INT8 multiply-accumulate lanes with INT32 accumulators.
module mac_array(
	input logic aclk,areset_n,clear_i,enable_i,
	input logic [3:0] lane_valid_i,
	input logic signed [7:0] a_i [0:3],b_i [0:3],
	output logic signed [31:0] acc_o [0:3]
);
// Keep the full signed 16-bit product, then sign-extend it before accumulating.
logic signed [15:0] product [0:3];
// Replicate four hardware lanes using explicit Quartus-compatible generate syntax.
genvar i;
generate
for(i=0;i<4;i=i+1)
begin : mac_lane
	assign product[i]=a_i[i]*b_i[i];
	always_ff @(posedge aclk)
	begin
		// Reset and clear have priority over accumulation; clear starts a new output group.
		if(!areset_n || clear_i) acc_o[i]<=0;
		// Only valid lanes update; masked tail lanes retain their accumulator values.
		else if(enable_i && lane_valid_i[i])
			acc_o[i]<=acc_o[i]+{{16{product[i][15]}},product[i]};
	end
end
endgenerate
endmodule
