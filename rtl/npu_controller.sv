`timescale 1ns/1ps
// Sequences one complete job: validate -> load inputs -> compute -> store results.
module npu_controller(
	input logic aclk,areset_n,start_i,
	input npu_pkg::config_t cfg_i,
	output npu_pkg::config_t cfg_o,
	output logic busy_o,done_o,error_o,
	output logic read_start_o,write_start_o,compute_start_o,
	// Read target: 0 = A, 1 = B, 2 = bias; all transfer counts below are words.
	output logic [1:0] read_target_o,
	output logic [31:0] read_addr_o,read_words_o,write_addr_o,write_words_o,
	output logic [31:0] out_height_o,out_width_o,
	input logic read_done_i,read_error_i,write_done_i,write_error_i,compute_done_i
);
typedef enum logic [3:0] {idle,check_cfg,read_a,wait_a,read_b,wait_b,read_bias,wait_bias,
	compute_start,compute_wait,write_start,write_wait,done_state,error_state} state_t;
state_t state;
logic valid_cfg;
logic [31:0] a_words,b_words,bias_words,out_words;
// Validate the captured job, so transfer lengths and compute settings agree throughout execution.
config_check checker_inst(.cfg_i(cfg_o),.valid_o(valid_cfg),.a_words_o(a_words),
	.b_words_o(b_words),.bias_words_o(bias_words),.out_words_o(out_words),
	.out_height_o(out_height_o),.out_width_o(out_width_o));
// Busy includes the terminal event cycle; done/error pulse for one clock before idle.
assign busy_o=(state!=idle);
assign done_o=(state==done_state);
assign error_o=(state==error_state);
assign compute_start_o=(state==compute_start);
assign write_start_o=(state==write_start);
assign write_addr_o=cfg_o.c_base;
assign write_words_o=out_words;
// Command states pulse START once; wait states keep the selected read target stable.
always_comb
begin
	read_start_o=0; read_addr_o=cfg_o.a_base; read_words_o=a_words; read_target_o=0;
	case(state)
		read_a: read_start_o=1;
		read_b,wait_b:
		begin read_start_o=(state==read_b); read_addr_o=cfg_o.b_base; read_words_o=b_words; read_target_o=1; end
		read_bias,wait_bias:
		begin read_start_o=(state==read_bias); read_addr_o=cfg_o.bias_base; read_words_o=bias_words; read_target_o=2; end
		default: begin end
	endcase
end
always_ff @(posedge aclk)
begin
	if(!areset_n) begin state<=idle; cfg_o<='0; end
	else case(state)
		// Snapshot CPU configuration on START; an active job never follows later register changes.
		idle: if(start_i) begin cfg_o<=cfg_i; state<=check_cfg; end
		check_cfg: state<=valid_cfg ? read_a : error_state;
		read_a: state<=wait_a;
		// Only fetch B or bias when its derived word count is nonzero.
		wait_a: if(read_error_i) state<=error_state;
			else if(read_done_i) state<=(b_words!=0) ? read_b : ((bias_words!=0) ? read_bias : compute_start);
		read_b: state<=wait_b;
		wait_b: if(read_error_i) state<=error_state; else if(read_done_i) state<=compute_start;
		read_bias: state<=wait_bias;
		wait_bias: if(read_error_i) state<=error_state; else if(read_done_i) state<=compute_start;
		// Inputs are fully loaded before compute starts; no DMA/compute overlap in this version.
		compute_start: state<=compute_wait;
		compute_wait: if(compute_done_i) state<=write_start;
		write_start: state<=write_wait;
		// Report success only after the writer receives the final successful AXI B response.
		write_wait: if(write_error_i) state<=error_state; else if(write_done_i) state<=done_state;
		done_state,error_state: state<=idle;
		default: state<=error_state;
	endcase
end
endmodule
