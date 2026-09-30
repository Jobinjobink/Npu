`timescale 1ns/1ps
// ReLU activation: replace a negative signed INT32 value with zero.
module relu_unit(
	input logic signed [31:0] data_i,
	output logic signed [31:0] data_o
);
// The top bit is the sign bit of a two's-complement INT32 value.
assign data_o=data_i[31] ? 32'sd0 : data_i;
endmodule
