`timescale 1ns/1ps
// Fetches 32-bit words from external RAM into a local input buffer using AXI4 bursts.
module axi_read_master(
	input logic aclk,areset_n,start_i,
	// Controller command: byte-aligned base address and count of 32-bit words.
	// start_i is accepted only in idle; done/error are one-cycle terminal pulses.
	input logic [31:0] addr_i,words_i,
	output logic done_o,error_o,
	output logic buf_wr_o,
	output logic [31:0] buf_index_o,buf_data_o,
	output logic [3:0] m_axi_arid,
	output logic [31:0] m_axi_araddr,
	output logic [7:0] m_axi_arlen,
	output logic [2:0] m_axi_arsize,
	output logic [1:0] m_axi_arburst,
	output logic m_axi_arlock,
	output logic [3:0] m_axi_arcache,
	output logic [2:0] m_axi_arprot,
	output logic [3:0] m_axi_arqos,
	output logic m_axi_arvalid,
	input logic m_axi_arready,
	input logic [3:0] m_axi_rid,
	input logic [31:0] m_axi_rdata,
	input logic [1:0] m_axi_rresp,
	input logic m_axi_rlast,
	input logic m_axi_rvalid,
	output logic m_axi_rready
);
import npu_pkg::*;
typedef enum logic [2:0] {idle,setup,address,data,finish} state_t;
state_t state;
// addr = current burst byte address; remaining = words left in the command.
// count = words in this burst; beat = burst position; index = overall buffer position.
logic [31:0] addr,remaining,count,beat,index;
logic failed;
// Only ID 0 is used: one outstanding transaction, 4-byte beats, INCR addressing.
// AXI encodes burst length as beats minus one, and size as log2(bytes per beat).
assign m_axi_arid=0;
assign m_axi_araddr=addr;
assign m_axi_arlen=8'(count-1);
assign m_axi_arsize=2;
assign m_axi_arburst=1;
assign m_axi_arlock=0;
assign m_axi_arcache=0;
assign m_axi_arprot=0;
assign m_axi_arqos=0;
assign m_axi_arvalid=(state==address);
assign m_axi_rready=(state==data);
// Store only accepted, successful beats; index advances on the same clock edge.
// The top level selects A, B or bias; this block only provides word index and data.
assign buf_wr_o=m_axi_rvalid && m_axi_rready && !failed &&
	(m_axi_rresp==0) && (m_axi_rid==0) && (beat<count);
assign buf_index_o=index;
assign buf_data_o=m_axi_rdata;
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
		address: if(m_axi_arready) state<=data;
		// RREADY is high in this state, so RVALID here means a completed data handshake.
		data: if(m_axi_rvalid)
		begin
			// Check response, ID, and whether RLAST occurs on the expected final beat.
			if(m_axi_rresp!=0 || m_axi_rid!=0 || m_axi_rlast!=(beat==count-1)) failed<=1;
			// Drain to RLAST even after a response error; never abandon a live burst.
			if(m_axi_rlast)
			begin
				if(failed || m_axi_rresp!=0 || m_axi_rid!=0 || beat!=count-1 || remaining==count)
					state<=finish;
				else
				begin
					addr<=addr+(count<<2);
					remaining<=remaining-count;
					state<=setup;
				end
			end
			if(beat<count) begin beat<=beat+1; index<=index+1; end
		end
		// Return to idle after exactly one cycle of done_o or error_o.
		finish: state<=idle;
		default: state<=idle;
	endcase
end
endmodule
