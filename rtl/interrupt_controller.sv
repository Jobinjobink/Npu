`timescale 1ns/1ps
// Latches done/error events and raises a level interrupt for enabled pending events.
module interrupt_controller(
	input logic aclk,areset_n,
	input logic done_i,error_i,
	input logic [1:0] enable_i,clear_i,
	output logic [1:0] pending_o,
	output logic irq_o
);
// pending[0] = done, pending[1] = error; events are recorded even while masked.
// OR events after clearing so a new event wins over a simultaneous software clear.
always_ff @(posedge aclk)
	if(!areset_n) pending_o<=0;
	else pending_o<=(pending_o & ~clear_i) | {error_i,done_i};
// IRQ stays high until all enabled pending events are cleared or masked.
assign irq_o=|(pending_o & enable_i);
endmodule
