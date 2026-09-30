`timescale 1ns/1ps
// Rejects unsafe job configurations and derives buffer sizes before any memory access.
module config_check(
	input npu_pkg::config_t cfg_i,
	output logic valid_o,
	output logic [31:0] a_words_o,b_words_o,bias_words_o,out_words_o,
	output logic [31:0] out_height_o,out_width_o
);
import npu_pkg::*;
logic dims_ok,spatial_ok;
logic [31:0] a_bytes,b_bytes;
// An extra address bit detects transfer ranges that would wrap past 32-bit memory.
logic [32:0] a_end,b_end,bias_end,c_end;
always_comb
begin
	dims_ok=(cfg_i.m>=1 && cfg_i.m<=16 && cfg_i.n>=1 && cfg_i.n<=16);
	spatial_ok=(cfg_i.height>=1 && cfg_i.height<=16 && cfg_i.width>=1 && cfg_i.width<=16 &&
		cfg_i.in_channels>=1 && cfg_i.in_channels<=16);
	valid_o=1;
	a_bytes=0; b_bytes=0; bias_words_o=0; out_words_o=0;
	out_height_o=0; out_width_o=0;
	// Derive only the operands needed by the selected operation; a zero size skips a buffer.
	case(cfg_i.op)
		// A and B each use one byte per element; every C element uses one 32-bit word.
		op_matmul:
		begin
			valid_o=dims_ok && cfg_i.k>=1 && cfg_i.k<=16;
			if(valid_o)
			begin a_bytes=cfg_i.m*cfg_i.k; b_bytes=cfg_i.k*cfg_i.n; out_words_o=cfg_i.m*cfg_i.n; end
		end
		// Add/multiply consume packed INT8; bias/ReLU consume full INT32 source words.
		op_add,op_mul,op_bias,op_relu:
		begin
			valid_o=dims_ok;
			if(valid_o)
			begin
				out_words_o=cfg_i.m*cfg_i.n;
				if(cfg_i.op==op_add || cfg_i.op==op_mul)
				begin a_bytes=out_words_o; b_bytes=out_words_o; end
				else a_bytes=out_words_o<<2;
				if(cfg_i.op==op_bias) bias_words_o=out_words_o;
			end
		end
		// Validate stride and padded dimensions before division or unsigned subtraction.
		// Input is HWC, weights are [output channel,kernel row,kernel col,input channel].
		op_conv:
		begin
			valid_o=spatial_ok && cfg_i.out_channels>=1 && cfg_i.out_channels<=16 &&
				cfg_i.kernel>=1 && cfg_i.kernel<=16 && cfg_i.stride>=1 && cfg_i.stride<=16 && cfg_i.padding<=15;
			if(valid_o)
			begin
				if(cfg_i.height+2*cfg_i.padding<cfg_i.kernel || cfg_i.width+2*cfg_i.padding<cfg_i.kernel) valid_o=0;
				else
				begin
					out_height_o=(cfg_i.height+2*cfg_i.padding-cfg_i.kernel)/cfg_i.stride+1;
					out_width_o=(cfg_i.width+2*cfg_i.padding-cfg_i.kernel)/cfg_i.stride+1;
					valid_o=(out_height_o<=16 && out_width_o<=16);
					a_bytes=cfg_i.height*cfg_i.width*cfg_i.in_channels;
					b_bytes=cfg_i.out_channels*cfg_i.kernel*cfg_i.kernel*cfg_i.in_channels;
					out_words_o=out_height_o*out_width_o*cfg_i.out_channels;
				end
			end
		end
		// Pool consumes INT32 samples and preserves channels; only complete unpadded windows are used.
		op_pool:
		begin
			valid_o=spatial_ok && cfg_i.pool_size>=1 && cfg_i.pool_size<=16 &&
				cfg_i.pool_stride>=1 && cfg_i.pool_stride<=16 && cfg_i.pool_size<=cfg_i.height && cfg_i.pool_size<=cfg_i.width;
			if(valid_o)
			begin
				out_height_o=(cfg_i.height-cfg_i.pool_size)/cfg_i.pool_stride+1;
				out_width_o=(cfg_i.width-cfg_i.pool_size)/cfg_i.pool_stride+1;
				a_bytes=(cfg_i.height*cfg_i.width*cfg_i.in_channels)<<2;
				out_words_o=out_height_o*out_width_o*cfg_i.in_channels;
			end
		end
		default: valid_o=0;
	endcase
	// Round packed INT8 byte counts up to whole AXI words; software must pad allocations.
	a_words_o=(a_bytes+3)>>2;
	b_words_o=(b_bytes+3)>>2;
	a_end={1'b0,cfg_i.a_base}+({1'b0,a_words_o}<<2);
	b_end={1'b0,cfg_i.b_base}+({1'b0,b_words_o}<<2);
	bias_end={1'b0,cfg_i.bias_base}+({1'b0,bias_words_o}<<2);
	c_end={1'b0,cfg_i.c_base}+({1'b0,out_words_o}<<2);
	// Reject oversized buffers and unaligned/wrapping address ranges before issuing AXI.
	if(a_words_o==0 || out_words_o==0 || a_words_o>buffer_words || b_words_o>buffer_words ||
		bias_words_o>buffer_words || out_words_o>buffer_words) valid_o=0;
	if(cfg_i.a_base[1:0]!=0 || cfg_i.c_base[1:0]!=0 || a_end>33'h100000000 || c_end>33'h100000000) valid_o=0;
	if(b_words_o!=0 && (cfg_i.b_base[1:0]!=0 || b_end>33'h100000000)) valid_o=0;
	if(bias_words_o!=0 && (cfg_i.bias_base[1:0]!=0 || bias_end>33'h100000000)) valid_o=0;
end
endmodule
