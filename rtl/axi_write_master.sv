`timescale 1ns/1ps
// Sends INT32 words from the output buffer to external RAM and checks write responses.
module axi_write_master(
	input logic aclk,areset_n,start_i,
	// Controller command: byte-aligned base address and count of 32-bit words.
	// start_i is accepted only in idle; done/error are one-cycle terminal pulses.
	input logic [31:0] addr_i,words_i,
	output logic done_o,error_o,
	output logic [31:0] buf_index_o,
	input logic [31:0] buf_data_i,
	output logic [3:0] m_axi_awid,
	output logic [31:0] m_axi_awaddr,
	output logic [7:0] m_axi_awlen,
	output logic [2:0] m_axi_awsize,
	output logic [1:0] m_axi_awburst,
	output logic m_axi_awlock,
	output logic [3:0] m_axi_awcache,
	output logic [2:0] m_axi_awprot,
	output logic [3:0] m_axi_awqos,
	output logic m_axi_awvalid,
	input logic m_axi_awready,
	output logic [31:0] m_axi_wdata,
	output logic [3:0] m_axi_wstrb,
	output logic m_axi_wlast,
	output logic m_axi_wvalid,
	input logic m_axi_wready,
	input logic [3:0] m_axi_bid,
	input logic [1:0] m_axi_bresp,
	input logic m_axi_bvalid,
	output logic m_axi_bready
);
import npu_pkg::*;
typedef enum logic [2:0] {idle,setup,address,data,response,finish} state_t;
state_t state;
// addr = current burst byte address; remaining = words left in the command.
// count = words in this burst; beat = burst position; index = overall buffer position.
logic [31:0] addr,remaining,count,beat,index;
logic failed;
// Use ID 0, four-byte beats and INCR bursts; AWLEN is count minus one.
assign m_axi_awid=0;
assign m_axi_awaddr=addr;
assign m_axi_awlen=8'(count-1);
assign m_axi_awsize=2;
assign m_axi_awburst=1;
assign m_axi_awlock=0;
assign m_axi_awcache=0;
assign m_axi_awprot=0;
assign m_axi_awqos=0;
assign m_axi_awvalid=(state==address);
assign m_axi_wvalid=(state==data);
// The output buffer has combinational reads and is not modified during this phase.
// Keeping index fixed on a stall therefore keeps WDATA and WLAST stable.
assign m_axi_wdata=buf_data_i;
// Every result is a complete INT32 word, so all four byte strobes are asserted.
assign m_axi_wstrb=4'b1111;
assign m_axi_wlast=(beat==count-1);
assign m_axi_bready=(state==response);
assign buf_index_o=index;
assign done_o=(state==finish) && !failed;
assign error_o=(state==finish) && failed;
always_ff @(posedge aclk)
begin
	if(!areset_n)
	begin
		state<=idle;
		addr<=0; remaining<=0; count<=0; beat<=0; index<=0; failed<=0;
	end
	else case(state)
		idle: if(start_i)
		begin
			addr<=addr_i;
			remaining<=words_i;
			index<=0;
			failed<=0;
			if(addr_i[1:0]!=0 || words_i==0 || words_i>buffer_words)
			begin failed<=1; state<=finish; end
			else state<=setup;
		end
		// Prepare a burst without crossing a 4 KiB boundary; keep the address stable while stalled.
		setup:
		begin
			count<=burst_words(addr,remaining);
			beat<=0;
			state<=address;
		end
		address: if(m_axi_awready) state<=data;
		// WVALID is high here; advance the buffer index only when the slave accepts the word.
		data: if(m_axi_wready)
		begin
			index<=index+1;
			if(beat==count-1) state<=response;
			else beat<=beat+1;
		end
		// Sending the last W beat is not completion: wait for B and check BRESP/BID first.
		response: if(m_axi_bvalid)
		begin
			if(m_axi_bresp!=0 || m_axi_bid!=0)
			begin failed<=1; state<=finish; end
			else if(remaining==count) state<=finish;
			else
			begin
				addr<=addr+(count<<2);
				remaining<=remaining-count;
				state<=setup;
			end
		end
		// Return to idle after exactly one cycle of done_o or error_o.
		finish: state<=idle;
		default: state<=idle;
	endcase
end
endmodule
