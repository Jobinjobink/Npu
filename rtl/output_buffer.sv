`timescale 1ns/1ps
// Stores computed INT32 results until the AXI write master transfers them to RAM.
module output_buffer(
	input logic aclk,
	// Local indices count 32-bit words, not external byte addresses.
	input logic wr_en_i,
	input logic [31:0] wr_index_i,wr_data_i,
	input logic [31:0] rd_index_i [0:0],
	output logic [31:0] rd_data_o [0:0]
);
import npu_pkg::*;
// Memory is not reset; the controller fills used locations before consuming them.
logic [31:0] mem [0:buffer_words-1];
// A write happens only on the rising edge with wr_en_i asserted.
always_ff @(posedge aclk)
	if(wr_en_i && wr_index_i<buffer_words)
		mem[wr_index_i]<=wr_data_i;
// Asynchronous reads: data follows the selected word without an extra clock cycle.
// Out-of-range reads return zero; these ports are not synchronous SRAM ports.
always_comb
	for(int i=0;i<1;i=i+1)
		rd_data_o[i]=(rd_index_i[i]<buffer_words) ? mem[rd_index_i[i]] : 32'b0;
endmodule
