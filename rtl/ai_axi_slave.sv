`timescale 1ns/1ps
// CPU-facing AXI4-Lite register bank: accepts configuration and reports job status.
module ai_axi_slave(
	input logic aclk,areset_n,
	// Controller events and live status; done/error become sticky software-visible bits.
	input logic busy_i,done_i,error_i,
	input logic [1:0] irq_pending_i,
	output logic start_o,
	output npu_pkg::config_t cfg_o,
	output logic [1:0] irq_enable_o,irq_clear_o,
	// AXI4-Lite write address (AW), write data (W), and write response (B).
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
	// AXI4-Lite read address (AR) and read response/data (R). Addresses are register offsets.
	input logic [31:0] s_axi_araddr,
	input logic [2:0] s_axi_arprot,
	input logic s_axi_arvalid,
	output logic s_axi_arready,
	output logic [31:0] s_axi_rdata,
	output logic [1:0] s_axi_rresp,
	output logic s_axi_rvalid,
	input logic s_axi_rready
);
import npu_pkg::*;
// AW and W can arrive in either order, so hold each independently until both are present.
logic aw_hold,w_hold;
logic [31:0] awaddr,wdata;
logic [3:0] wstrb;
logic [1:0] status;
logic [31:0] read_data;
logic read_ok;
// Allow one pending write response; do not overwrite held requests under backpressure.
assign s_axi_awready=!aw_hold && !s_axi_bvalid;
assign s_axi_wready=!w_hold && !s_axi_bvalid;
assign s_axi_arready=!s_axi_rvalid;
// Read mux: STATUS packs {error,done,busy}; IRQ bits are {error,done}.
// The complete offset table and access rules are in REGISTER_MAP.md.
always_comb
begin
	read_data=0;
	read_ok=(s_axi_araddr[1:0]==0);
	case(s_axi_araddr)
		32'h00: read_data=0;
		32'h04: read_data={29'b0,status,busy_i};
		32'h08: read_data={30'b0,irq_enable_o};
		32'h0c: read_data={30'b0,irq_pending_i};
		32'h10: read_data=cfg_o.op;
		32'h14: read_data=cfg_o.a_base;
		32'h18: read_data=cfg_o.b_base;
		32'h1c: read_data=cfg_o.bias_base;
		32'h20: read_data=cfg_o.c_base;
		32'h24: read_data=cfg_o.m;
		32'h28: read_data=cfg_o.n;
		32'h2c: read_data=cfg_o.k;
		32'h30: read_data=cfg_o.height;
		32'h34: read_data=cfg_o.width;
		32'h38: read_data=cfg_o.kernel;
		32'h3c: read_data=cfg_o.stride;
		32'h40: read_data=cfg_o.padding;
		32'h44: read_data=cfg_o.in_channels;
		32'h48: read_data=cfg_o.out_channels;
		32'h4c: read_data=cfg_o.pool_size;
		32'h50: read_data=cfg_o.pool_stride;

		default: read_ok=0;
	endcase
end
always_ff @(posedge aclk)
begin
	if(!areset_n)
	begin
		cfg_o<='0;
		aw_hold<=0;
		w_hold<=0;
		awaddr<=0;
		wdata<=0;
		wstrb<=0;
		s_axi_bvalid<=0;
		s_axi_bresp<=0;
		s_axi_rvalid<=0;
		s_axi_rdata<=0;
		s_axi_rresp<=0;
		start_o<=0;
		status<=0;
		irq_enable_o<=0;
		irq_clear_o<=0;
	end
	else
	begin
		// START and IRQ clear are one-clock pulses, not persistent control levels.
		start_o<=0;
		irq_clear_o<=0;
		if(s_axi_awvalid && s_axi_awready)
		begin
			aw_hold<=1;
			awaddr<=s_axi_awaddr;
		end
		if(s_axi_wvalid && s_axi_wready)
		begin
			w_hold<=1;
			wdata<=s_axi_wdata;
			wstrb<=s_axi_wstrb;
		end
		if(s_axi_bvalid && s_axi_bready) s_axi_bvalid<=0;
		// Commit exactly once after both channels have arrived; hold BVALID until BREADY.
		if(aw_hold && w_hold && !s_axi_bvalid)
		begin
			aw_hold<=0;
			w_hold<=0;
			s_axi_bvalid<=1;
			s_axi_bresp<=0;
			case(awaddr)
				// CONTROL bit 0 starts a job; reject a busy request rather than queueing it.
				32'h00:
				begin
					if(wstrb[0] && wdata[0])
					begin
						if(busy_i || start_o) s_axi_bresp<=2'b10;
						else begin start_o<=1; status<=0; end
					end
				end
				// W1C means writing 1 clears that sticky bit; writing 0 leaves it unchanged.
				32'h04: if(wstrb[0]) status<=status & ~wdata[2:1];
				32'h08: if(wstrb[0]) irq_enable_o<=wdata[1:0];
				32'h0c: if(wstrb[0]) irq_clear_o<=wdata[1:0];
				// Configuration is writable only while idle; byte strobes preserve untouched bytes.
				32'h10: if(busy_i || start_o) s_axi_bresp<=2'b10;
					else cfg_o.op<=merge_bytes(cfg_o.op,wdata,wstrb);
				32'h14: if(busy_i || start_o) s_axi_bresp<=2'b10;
					else cfg_o.a_base<=merge_bytes(cfg_o.a_base,wdata,wstrb);
				32'h18: if(busy_i || start_o) s_axi_bresp<=2'b10;
					else cfg_o.b_base<=merge_bytes(cfg_o.b_base,wdata,wstrb);
				32'h1c: if(busy_i || start_o) s_axi_bresp<=2'b10;
					else cfg_o.bias_base<=merge_bytes(cfg_o.bias_base,wdata,wstrb);
				32'h20: if(busy_i || start_o) s_axi_bresp<=2'b10;
					else cfg_o.c_base<=merge_bytes(cfg_o.c_base,wdata,wstrb);
				32'h24: if(busy_i || start_o) s_axi_bresp<=2'b10;
					else cfg_o.m<=merge_bytes(cfg_o.m,wdata,wstrb);
				32'h28: if(busy_i || start_o) s_axi_bresp<=2'b10;
					else cfg_o.n<=merge_bytes(cfg_o.n,wdata,wstrb);
				32'h2c: if(busy_i || start_o) s_axi_bresp<=2'b10;
					else cfg_o.k<=merge_bytes(cfg_o.k,wdata,wstrb);
				32'h30: if(busy_i || start_o) s_axi_bresp<=2'b10;
					else cfg_o.height<=merge_bytes(cfg_o.height,wdata,wstrb);
				32'h34: if(busy_i || start_o) s_axi_bresp<=2'b10;
					else cfg_o.width<=merge_bytes(cfg_o.width,wdata,wstrb);
				32'h38: if(busy_i || start_o) s_axi_bresp<=2'b10;
					else cfg_o.kernel<=merge_bytes(cfg_o.kernel,wdata,wstrb);
				32'h3c: if(busy_i || start_o) s_axi_bresp<=2'b10;
					else cfg_o.stride<=merge_bytes(cfg_o.stride,wdata,wstrb);
				32'h40: if(busy_i || start_o) s_axi_bresp<=2'b10;
					else cfg_o.padding<=merge_bytes(cfg_o.padding,wdata,wstrb);
				32'h44: if(busy_i || start_o) s_axi_bresp<=2'b10;
					else cfg_o.in_channels<=merge_bytes(cfg_o.in_channels,wdata,wstrb);
				32'h48: if(busy_i || start_o) s_axi_bresp<=2'b10;
					else cfg_o.out_channels<=merge_bytes(cfg_o.out_channels,wdata,wstrb);
				32'h4c: if(busy_i || start_o) s_axi_bresp<=2'b10;
					else cfg_o.pool_size<=merge_bytes(cfg_o.pool_size,wdata,wstrb);
				32'h50: if(busy_i || start_o) s_axi_bresp<=2'b10;
					else cfg_o.pool_stride<=merge_bytes(cfg_o.pool_stride,wdata,wstrb);

				default: s_axi_bresp<=2'b10;
			endcase
		end
		// New completion/error events take priority over a simultaneous status clear.
		if(done_i) status[0]<=1;
		if(error_i) status[1]<=1;
		if(s_axi_rvalid && s_axi_rready) s_axi_rvalid<=0;
		// Capture read data at AR handshake and hold it stable until the CPU accepts R.
		if(s_axi_arvalid && s_axi_arready)
		begin
			s_axi_rvalid<=1;
			s_axi_rdata<=read_data;
			s_axi_rresp<=read_ok ? 2'b00 : 2'b10;
		end
	end
end
endmodule
