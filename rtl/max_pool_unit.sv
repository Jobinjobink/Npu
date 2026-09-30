`timescale 1ns/1ps
// Tracks the largest signed INT32 sample within one pooling window.
module max_pool_unit(
	input logic aclk,areset_n,clear_i,enable_i,
	input logic signed [31:0] data_i,
	output logic signed [31:0] max_o
);
// valid distinguishes an empty window from a window whose maximum really is zero.
logic valid;
always_ff @(posedge aclk)
begin
	// Clear between windows so samples from the previous window cannot affect this one.
	if(!areset_n || clear_i)
	begin
		valid<=0;
		max_o<=0;
	end
	else if(enable_i)
	begin
		valid<=1;
		// Accept the first sample even when negative; initializing the comparison to zero would be wrong.
		if(!valid || data_i>max_o) max_o<=data_i;
	end
end
endmodule
