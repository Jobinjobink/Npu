`timescale 1ns/1ps
// Splits one packed 32-bit word into four signed INT8 operands; no clock is required.
module int8_unpacker(
	input logic [31:0] data_i,
	output logic signed [7:0] data_o [0:3]
);
// Little-endian packing: lane 0 gets bits [7:0], lane 3 gets bits [31:24].
// Explicit generate syntax keeps this compatible with Quartus map.
genvar i;
generate
for(i=0;i<4;i=i+1)
begin : unpack_lane
	assign data_o[i]=$signed(data_i[i*8+:8]);
end
endgenerate
endmodule
