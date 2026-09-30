`timescale 1ns/1ps
// Connects the CPU register interface, controller, memory masters, compute and IRQ.
module npu_top(
	// Shared clock and synchronous active-low reset for the complete NPU.
	input logic aclk,areset_n,
	output logic irq_o,
	// CPU config/status interface: AXI4-Lite slave, register offsets on address inputs.
	input logic [31:0] s_axi_awaddr,
	input logic [2:0] s_axi_awprot,
	input logic s_axi_awvalid,
	output logic s_axi_awready,
	input logic [31:0] s_axi_wdata,
	input logic [3:0] s_axi_wstrb,
	input logic s_axi_wvalid,
	output logic s_axi_wready,
	output logic [1:0] s_axi_bresp,
	output logic s_axi_bvalid,
	input logic s_axi_bready,
	input logic [31:0] s_axi_araddr,
	input logic [2:0] s_axi_arprot,
	input logic s_axi_arvalid,
	output logic s_axi_arready,
	output logic [31:0] s_axi_rdata,
	output logic [1:0] s_axi_rresp,
	output logic s_axi_rvalid,
	input logic s_axi_rready,
	// External RAM interface: AXI4 read channels. The controller serializes reads and writes.
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
	output logic m_axi_rready,
	// External RAM interface: AXI4 write address, data and response channels.
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
// cfg is the CPU register bank; job is the controller snapshot used by the active operation.
config_t cfg,job;
logic start,busy,done,error;
logic [1:0] irq_enable,irq_clear,irq_pending,target;
logic read_start,read_done,read_error,write_start,write_done,write_error,compute_start,compute_done;
logic [31:0] read_addr,read_words,write_addr,write_words,out_height,out_width;
logic load_en,out_en;
logic [31:0] load_index,load_data,out_index,out_data;
logic [31:0] a_index [0:3],b_index [0:3],a_data [0:3],b_data [0:3];
logic [31:0] bias_index [0:0],bias_data [0:0],c_index [0:0],c_data [0:0];
// CPU-facing control and status registers, including interrupt enable/clear.
ai_axi_slave regs(.aclk(aclk),.areset_n(areset_n),.busy_i(busy),.done_i(done),.error_i(error),
	.irq_pending_i(irq_pending),.start_o(start),.cfg_o(cfg),.irq_enable_o(irq_enable),.irq_clear_o(irq_clear),
	.s_axi_awaddr(s_axi_awaddr),
	.s_axi_awprot(s_axi_awprot),
	.s_axi_awvalid(s_axi_awvalid),
	.s_axi_awready(s_axi_awready),
	.s_axi_wdata(s_axi_wdata),
	.s_axi_wstrb(s_axi_wstrb),
	.s_axi_wvalid(s_axi_wvalid),
	.s_axi_wready(s_axi_wready),
	.s_axi_bresp(s_axi_bresp),
	.s_axi_bvalid(s_axi_bvalid),
	.s_axi_bready(s_axi_bready),
	.s_axi_araddr(s_axi_araddr),
	.s_axi_arprot(s_axi_arprot),
	.s_axi_arvalid(s_axi_arvalid),
	.s_axi_arready(s_axi_arready),
	.s_axi_rdata(s_axi_rdata),
	.s_axi_rresp(s_axi_rresp),
	.s_axi_rvalid(s_axi_rvalid),
	.s_axi_rready(s_axi_rready));
// Central sequencing: issue one command, wait for completion, then start the next phase.
npu_controller control(.aclk(aclk),.areset_n(areset_n),.start_i(start),.cfg_i(cfg),.cfg_o(job),
	.busy_o(busy),.done_o(done),.error_o(error),.read_start_o(read_start),.write_start_o(write_start),
	.compute_start_o(compute_start),.read_target_o(target),.read_addr_o(read_addr),.read_words_o(read_words),
	.write_addr_o(write_addr),.write_words_o(write_words),.out_height_o(out_height),.out_width_o(out_width),
	.read_done_i(read_done),.read_error_i(read_error),.write_done_i(write_done),.write_error_i(write_error),.compute_done_i(compute_done));
// Input DMA: one common write stream is routed to the selected local buffer below.
axi_read_master reader(.aclk(aclk),.areset_n(areset_n),.start_i(read_start),.addr_i(read_addr),.words_i(read_words),
	.done_o(read_done),.error_o(read_error),.buf_wr_o(load_en),.buf_index_o(load_index),.buf_data_o(load_data),
	.m_axi_arid(m_axi_arid),
	.m_axi_araddr(m_axi_araddr),
	.m_axi_arlen(m_axi_arlen),
	.m_axi_arsize(m_axi_arsize),
	.m_axi_arburst(m_axi_arburst),
	.m_axi_arlock(m_axi_arlock),
	.m_axi_arcache(m_axi_arcache),
	.m_axi_arprot(m_axi_arprot),
	.m_axi_arqos(m_axi_arqos),
	.m_axi_arvalid(m_axi_arvalid),
	.m_axi_arready(m_axi_arready),
	.m_axi_rid(m_axi_rid),
	.m_axi_rdata(m_axi_rdata),
	.m_axi_rresp(m_axi_rresp),
	.m_axi_rlast(m_axi_rlast),
	.m_axi_rvalid(m_axi_rvalid),
	.m_axi_rready(m_axi_rready));
// Output DMA: buffer word index follows accepted AXI write beats.
axi_write_master writer(.aclk(aclk),.areset_n(areset_n),.start_i(write_start),.addr_i(write_addr),.words_i(write_words),
	.done_o(write_done),.error_o(write_error),.buf_index_o(c_index[0]),.buf_data_i(c_data[0]),
	.m_axi_awid(m_axi_awid),
	.m_axi_awaddr(m_axi_awaddr),
	.m_axi_awlen(m_axi_awlen),
	.m_axi_awsize(m_axi_awsize),
	.m_axi_awburst(m_axi_awburst),
	.m_axi_awlock(m_axi_awlock),
	.m_axi_awcache(m_axi_awcache),
	.m_axi_awprot(m_axi_awprot),
	.m_axi_awqos(m_axi_awqos),
	.m_axi_awvalid(m_axi_awvalid),
	.m_axi_awready(m_axi_awready),
	.m_axi_wdata(m_axi_wdata),
	.m_axi_wstrb(m_axi_wstrb),
	.m_axi_wlast(m_axi_wlast),
	.m_axi_wvalid(m_axi_wvalid),
	.m_axi_wready(m_axi_wready),
	.m_axi_bid(m_axi_bid),
	.m_axi_bresp(m_axi_bresp),
	.m_axi_bvalid(m_axi_bvalid),
	.m_axi_bready(m_axi_bready));
// Only the selected input buffer accepts a DMA word; compute reads these local memories.
input_a_buffer a_buffer(.aclk(aclk),.wr_en_i(load_en && target==0),.wr_index_i(load_index),.wr_data_i(load_data),.rd_index_i(a_index),.rd_data_o(a_data));
input_b_buffer b_buffer(.aclk(aclk),.wr_en_i(load_en && target==1),.wr_index_i(load_index),.wr_data_i(load_data),.rd_index_i(b_index),.rd_data_o(b_data));
bias_buffer bias_mem(.aclk(aclk),.wr_en_i(load_en && target==2),.wr_index_i(load_index),.wr_data_i(load_data),.rd_index_i(bias_index),.rd_data_o(bias_data));
// Compute fills C first; the writer reads it only after compute_done.
output_buffer c_buffer(.aclk(aclk),.wr_en_i(out_en),.wr_index_i(out_index),.wr_data_i(out_data),.rd_index_i(c_index),.rd_data_o(c_data));
// Compute works with local indices, not external RAM addresses.
compute_engine compute(.aclk(aclk),.areset_n(areset_n),.start_i(compute_start),.cfg_i(job),
	.out_height_i(out_height),.out_width_i(out_width),.total_i(write_words),.done_o(compute_done),
	.a_index_o(a_index),.b_index_o(b_index),.a_data_i(a_data),.b_data_i(b_data),
	.bias_index_o(bias_index[0]),.bias_data_i(bias_data[0]),.out_wr_o(out_en),.out_index_o(out_index),.out_data_o(out_data));
// Convert one-cycle job events into sticky pending bits and a CPU interrupt level.
interrupt_controller interrupt_inst(.aclk(aclk),.areset_n(areset_n),.done_i(done),.error_i(error),
	.enable_i(irq_enable),.clear_i(irq_clear),.pending_o(irq_pending),.irq_o(irq_o));
endmodule
