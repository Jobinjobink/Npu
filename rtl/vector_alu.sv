`timescale 1ns/1ps
// Combinational add/multiply datapath; bias add also uses the addition path.
module vector_alu(
	input logic signed [31:0] a_i,b_i,
	input logic multiply_i,
	output logic signed [31:0] result_o
);
// The 32-bit result wraps on overflow; no saturation or requantization is performed.
assign result_o=multiply_i ? a_i*b_i : a_i+b_i;
endmodule
