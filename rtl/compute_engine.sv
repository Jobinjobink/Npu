`timescale 1ns/1ps
// Selects arithmetic and generates local buffer indices for all seven operations.
module compute_engine(
	input logic aclk,areset_n,start_i,
	// Controller holds this validated job stable until compute completes.
	// out_height_i describes the shape; indexing below needs only width and total count.
	input npu_pkg::config_t cfg_i,
	input logic [31:0] out_height_i,out_width_i,total_i,
	output logic done_o,
	// Four combinational word-read ports feed the four MAC lanes independently.
	output logic [31:0] a_index_o [0:3],b_index_o [0:3],
	input logic [31:0] a_data_i [0:3],b_data_i [0:3],
	output logic [31:0] bias_index_o,
	input logic [31:0] bias_data_i,
	output logic out_wr_o,
	output logic [31:0] out_index_o,out_data_o
);
import npu_pkg::*;
typedef enum logic [3:0] {idle,clear_acc,mac_step,store_acc,vector_step,
	pool_clear,pool_step,pool_store,finish} state_t;
state_t state;
// base = first output in a group; step = reduction/window sample; lane = result being stored.
// terms = products accumulated per output: K for MatMul, kernel*kernel*Cin for conv.
logic [31:0] base,step,lane,terms;
logic [31:0] a_element [0:3],b_element [0:3];
logic [3:0] valid_lane,in_bounds;
logic signed [7:0] a_bytes [0:3][0:3],b_bytes [0:3][0:3];
logic signed [7:0] mac_a [0:3],mac_b [0:3];
logic signed [31:0] acc [0:3],alu_a,alu_b,alu_result,relu_result,pool_max;
integer oi,oc,oy,ox,ic,kr,kc,iy,ix;
assign terms=(cfg_i.op==op_matmul) ? cfg_i.k : cfg_i.kernel*cfg_i.kernel*cfg_i.in_channels;
assign done_o=(state==finish);
// Each lane selects a byte from its own buffer word; low index bits select that byte.
// Convolution padding supplies zero to the multiplier rather than reading outside A.
// Explicit generate region for Quartus compatibility.
genvar lane_idx;
generate
for(lane_idx=0;lane_idx<4;lane_idx=lane_idx+1)
begin : operand_lane
	int8_unpacker au(.data_i(a_data_i[lane_idx]),.data_o(a_bytes[lane_idx]));
	int8_unpacker bu(.data_i(b_data_i[lane_idx]),.data_o(b_bytes[lane_idx]));
	assign mac_a[lane_idx]=in_bounds[lane_idx] ? a_bytes[lane_idx][a_element[lane_idx][1:0]] : 8'sd0;
	assign mac_b[lane_idx]=b_bytes[lane_idx][b_element[lane_idx][1:0]];
end
endgenerate
mac_array mac(.aclk(aclk),.areset_n(areset_n),.clear_i(state==clear_acc),
	.enable_i(state==mac_step),.lane_valid_i(valid_lane),.a_i(mac_a),.b_i(mac_b),.acc_o(acc));
vector_alu alu(.a_i(alu_a),.b_i(alu_b),.multiply_i(cfg_i.op==op_mul),.result_o(alu_result));
relu_unit relu(.data_i($signed(a_data_i[0])),.data_o(relu_result));
max_pool_unit pool(.aclk(aclk),.areset_n(areset_n),.clear_i(state==pool_clear),
	.enable_i(state==pool_step),.data_i($signed(a_data_i[0])),.max_o(pool_max));
// Generate local element addresses, then convert packed INT8 indices to word indices.
// Default values disable unused paths and prevent combinational latches.
always_comb
begin
	oi=0; oc=0; oy=0; ox=0; ic=0; kr=0; kc=0; iy=0; ix=0;
	valid_lane=0;
	in_bounds=0;
	bias_index_o=base;
	for(int i=0;i<4;i=i+1)
	begin
		a_element[i]=0; b_element[i]=0;
		a_index_o[i]=0; b_index_o[i]=0;
		// Mask a partial final group when fewer than four output elements remain.
		if(state==mac_step && base+32'(i)<total_i)
		begin
			valid_lane[i]=1;
			in_bounds[i]=1;
			if(cfg_i.op==op_matmul)
			begin
				// For flattened output q: row=q/N, col=q%N; multiply A[row,step] by B[step,col].
				a_element[i]=((base+32'(i))/cfg_i.n)*cfg_i.k+step;
				b_element[i]=step*cfg_i.n+(base+32'(i))%cfg_i.n;
			end
			else
			begin
				// Decode flattened output q into output channel, x and y (channel is contiguous).
				oi=int'(base)+i;
				oc=oi%int'(cfg_i.out_channels);
				ox=(oi/int'(cfg_i.out_channels))%int'(out_width_i);
				oy=oi/int'(cfg_i.out_channels*out_width_i);
				// Decode the reduction step into input channel and kernel position.
				ic=int'(step%cfg_i.in_channels);
				kc=int'((step/cfg_i.in_channels)%cfg_i.kernel);
				kr=int'(step/(cfg_i.in_channels*cfg_i.kernel));
				// Map the kernel position to the input, including stride and symmetric padding.
				iy=oy*int'(cfg_i.stride)+kr-int'(cfg_i.padding);
				ix=ox*int'(cfg_i.stride)+kc-int'(cfg_i.padding);
				in_bounds[i]=(iy>=0 && ix>=0 && iy<int'(cfg_i.height) && ix<int'(cfg_i.width));
				if(in_bounds[i]) a_element[i]=32'((iy*int'(cfg_i.width)+ix)*int'(cfg_i.in_channels)+ic);
				b_element[i]=32'(oc)*terms+step;
			end
			// Four INT8 values share a word: index>>2 chooses the word; index[1:0] chooses its byte.
			a_index_o[i]=a_element[i]>>2;
			b_index_o[i]=b_element[i]>>2;
		end
	end
	// Bias/ReLU use word indices directly; vector add/multiply use packed-byte indices.
	if(state==vector_step)
	begin
		a_element[0]=base; b_element[0]=base;
		a_index_o[0]=(cfg_i.op==op_add || cfg_i.op==op_mul) ? base>>2 : base;
		b_index_o[0]=base>>2;
	end
	// Scan one pooling window for one channel; channels never mix in a maximum.
	if(state==pool_step)
	begin
		ic=int'(base%cfg_i.in_channels);
		ox=int'((base/cfg_i.in_channels)%out_width_i);
		oy=int'(base/(cfg_i.in_channels*out_width_i));
		kr=int'(step/cfg_i.pool_size);
		kc=int'(step%cfg_i.pool_size);
		iy=oy*int'(cfg_i.pool_stride)+kr;
		ix=ox*int'(cfg_i.pool_stride)+kc;
		a_index_o[0]=32'((iy*int'(cfg_i.width)+ix)*int'(cfg_i.in_channels)+ic);
	end
end
always_comb
begin
	// Bias input defaults to full INT32; add/multiply instead sign-extend the selected INT8 bytes.
	alu_a=$signed(a_data_i[0]);
	alu_b=$signed(bias_data_i);
	if(cfg_i.op==op_add || cfg_i.op==op_mul)
	begin
		alu_a={{24{a_bytes[0][base[1:0]][7]}},a_bytes[0][base[1:0]]};
		alu_b={{24{b_bytes[0][base[1:0]][7]}},b_bytes[0][base[1:0]]};
	end
	// Select the active arithmetic result; the single output write port stores one word per cycle.
	out_wr_o=0; out_index_o=base; out_data_o=0;
	case(state)
		store_acc:
		begin out_wr_o=1; out_index_o=base+lane; out_data_o=acc[lane[1:0]]; end
		vector_step:
		begin out_wr_o=1; out_data_o=(cfg_i.op==op_relu) ? relu_result : alu_result; end
		pool_store:
		begin out_wr_o=1; out_data_o=pool_max; end
		default: begin end
	endcase
end
always_ff @(posedge aclk)
begin
	if(!areset_n) begin state<=idle; base<=0; step<=0; lane<=0; end
	else case(state)
		idle: if(start_i)
		begin
			base<=0; step<=0; lane<=0;
			if(cfg_i.op==op_matmul || cfg_i.op==op_conv) state<=clear_acc;
			else if(cfg_i.op==op_pool) state<=pool_clear;
			else state<=vector_step;
		end
		// Clear old sums, accumulate all terms, then store the four lane results sequentially.
		// The final MAC update is visible in the following store cycle (nonblocking assignment timing).
		clear_acc: begin step<=0; lane<=0; state<=mac_step; end
		mac_step: if(step+1==terms) state<=store_acc; else step<=step+1;
		store_acc:
		begin
			if(base+lane+1==total_i) state<=finish;
			else if(lane==3) begin base<=base+4; state<=clear_acc; end
			else lane<=lane+1;
		end
		vector_step:
			if(base+1==total_i) state<=finish; else base<=base+1;
		// Reset maximum for each new window, scan all samples, then store the final maximum.
		pool_clear: begin step<=0; state<=pool_step; end
		pool_step: if(step+1==cfg_i.pool_size*cfg_i.pool_size) state<=pool_store; else step<=step+1;
		pool_store:
			if(base+1==total_i) state<=finish; else begin base<=base+1; state<=pool_clear; end
		finish: state<=idle;
		default: state<=idle;
	endcase
end
endmodule
