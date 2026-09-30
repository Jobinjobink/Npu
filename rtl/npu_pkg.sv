`timescale 1ns/1ps
// Shared operation codes, configuration fields and helpers used by all blocks.
package npu_pkg;
	// Fixed opcode mapping: 000 MatMul, 001 conv, 010 add, 011 multiply,
	// 100 bias add, 101 ReLU, 110 max pool; 111 is reserved.
	localparam logic [2:0] op_matmul=0, op_conv=1, op_add=2, op_mul=3,
		op_bias=4, op_relu=5, op_pool=6;
	// 4096 words x 4 bytes = 16 KiB per buffer.
	localparam int buffer_words=4096;
	// Register values travel together; the controller snapshots this structure on START.
	typedef struct packed {
		logic [31:0] op; // Operation register; upper bits must also be zero for a valid opcode.
		logic [31:0] a_base; // External RAM byte address of source A.
		logic [31:0] b_base; // External RAM byte address of B / weights.
		logic [31:0] bias_base; // External RAM byte address of INT32 biases.
		logic [31:0] c_base; // External RAM byte address of INT32 results.
		logic [31:0] m; // MatMul rows; also part of vector length M*N.
		logic [31:0] n; // MatMul columns; also part of vector length M*N.
		logic [31:0] k; // MatMul reduction length: A[M,K] times B[K,N].
		logic [31:0] height; // Spatial input height H.
		logic [31:0] width; // Spatial input width W.
		logic [31:0] kernel; // Square convolution kernel side length.
		logic [31:0] stride; // Convolution window step in input pixels.
		logic [31:0] padding; // Zero padding on each side of the convolution input.
		logic [31:0] in_channels; // Channel count for convolution and pooling inputs.
		logic [31:0] out_channels; // Number of convolution filters / output channels.
		logic [31:0] pool_size; // Square max-pool window side length.
		logic [31:0] pool_stride; // Pool window step in input pixels.

	} config_t;
	// WSTRB selects which bytes a CPU write updates; preserve the other bytes.
	function automatic logic [31:0] merge_bytes(input logic [31:0] old_data,
		input logic [31:0] new_data,input logic [3:0] strb);
		for(int i=0;i<4;i=i+1)
			merge_bytes[i*8+:8]=strb[i] ? new_data[i*8+:8] : old_data[i*8+:8];
	endfunction
	// Choose the smallest of remaining words, 16 beats and space before the next 4 KiB boundary.
	function automatic logic [31:0] burst_words(input logic [31:0] addr,
		input logic [31:0] remaining);
		logic [31:0] count;
		begin
			count=(4096-{20'b0,addr[11:0]})>>2;
			if(count>16) count=16;
			if(count>remaining) count=remaining;
			burst_words=count;
		end
	endfunction
endpackage
