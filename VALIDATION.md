# Validation report — Quartus compatibility revision

Prepared 2026-09-30. Results below apply to the explicit-generate RTL revision.

## Fix

Added explicit generate/endgenerate regions, separately declared genvars, and
named generated blocks in int8_unpacker.sv, mac_array.sv and compute_engine.sv.
The compute generate variable is lane_idx to keep it distinct from procedural
loop variables. Module ports, arithmetic, register map and memory layout are
unchanged. All 18 RTL files retain their explanatory comments.

## ModelSim compilation and simulation — passed

ModelSim Intel FPGA Edition 10.5b compiled all 18 RTL files plus tb_npu.sv:
**Errors: 0, Warnings: 0**. It then elaborated the full hierarchy and executed
the self-checking testbench to normal completion at **50040 ns**:

```text
PASS: 19 jobs, all seven opcodes, stalls, errors, IRQ and 4KB splitting
```

The simulator reported **Errors: 0, Warnings: 0** at completion. Its command
transcript also includes two Tcl notices about onbreak/onerror being intended
for macro files; neither affected the regression. The included run_modelsim.do
places these handlers in a macro file for subsequent runs.

Full runtime transcript: validation/modelsim_simulation.log.

The self-checking SystemVerilog testbench contains 19 jobs:

- Four MatMuls: 1x1x1, M=3/N=5/K=7, M=4/N=16/K=8, and maximum 16x16x16.
- Signed INT8 add and multiply with a 15-element tail.
- INT32 bias add including wraparound, and INT32 ReLU including signed extremes.
- Three convolution shapes covering channels, padding, stride, odd output count,
  and groups of four outputs that cross spatial/channel boundaries.
- Two all-negative INT32 max-pool cases, including multiple channels.
- Four invalid jobs: reserved opcode, zero M, M above 16, and unaligned A address.
- Read-response and write-response error injection.

The memory model inserts deterministic AR/AW/W and R stalls. Sources and destination
start at the last word of a 4 KB page, exercising burst splitting. Checks also cover
one outstanding transaction, WLAST/WSTRB, selected payload stability under stall,
independent Lite AW/W order, Lite response backpressure, byte strobes, invalid
register accesses, busy START/config rejection, and interrupt assertion/clearing.
Expected arithmetic values were generated independently using integer formulas and
embedded in the testbench.


## Earlier validation

The previous implicit-generate version passed Slang/pyslang 12.0.0 compilation
and elaboration with zero errors/warnings. That did not establish compatibility
with Quartus 18.1. This revision was checked using the installed Intel tools.
The earlier claim that no simulator was available is superseded: ModelSim was
found under the Intel FPGA installation, outside the system search path.

## Limits

Passing this regression does not prove exhaustive functional or AXI correctness.
No place-and-route, timing closure, board pin assignment, formal verification,
hardware test or independent AXI protocol checker was performed. The selected
device for the isolated Quartus check is not a claim about the user's board.
The multiport combinational buffers and variable index arithmetic have not been
optimized for FPGA resources or a particular clock target.

## Quartus Analysis & Elaboration — passed

Quartus Prime Lite 18.1.0 Build 625, top npu_top, Cyclone V family, isolated
project configured for 5CSEMA5F31C6:

```text
quartus_map --analysis_and_elaboration --read_settings_files=on --write_settings_files=off npu -c npu
Quartus Prime Analysis & Elaboration was successful. 0 errors, 3 warnings
```

Completed 2026-09-30 at 11:20:13. Elapsed time 16 minutes 32 seconds; reported
peak virtual memory 6534 MB. Source files and the complete hierarchy passed
Quartus syntax/semantic checks and netlist extraction. This is not a full
Analysis & Synthesis, fitter, assembler or timing-analysis run.

The three warnings are 10762: Quartus cannot check completeness of the 32-bit
case expressions in the register read/write decoders and operation decoder.
All three include explicit default branches. The regression checks unmapped
register accesses and invalid operations. No warnings were suppressed.
Two informational 10008 messages concern display regrouping of multidimensional
operand-byte arrays by the EDA Netlist Writer; they did not prevent elaboration.

Full report and summary are included in validation/. Device-specific fit and
resource use remain unverified. Use the user's actual device/pin/clock settings
for implementation; the included source-assignment file does not override them.
