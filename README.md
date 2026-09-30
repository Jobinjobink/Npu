# NPU-Lite

Complete standalone SystemVerilog RTL set, top module `npu_top`.
One clock (`aclk`), synchronous active-low reset (`areset_n`).
Coding style: tabs, compact blocks, lowercase names, explicit module wiring.

## Architecture

CPU AXI4-Lite -> register file -> controller -> load A/B/bias -> compute -> store C -> IRQ.
External memory uses 32-bit AXI4 address/data, four-bit IDs fixed to zero,
INCR bursts of up to 16 beats, one outstanding burst across both directions.
The read and write engines split transfers at 4 KB boundaries and wait for each
burst to complete. Write completion includes the B response.

All external buffer bases must be four-byte aligned. INT8 arrays are tightly
packed little-endian: element zero is bits [7:0]. Pad each INT8 allocation to
four bytes; the final read fetches the full word and ignores unused bytes.
Outputs and biases are little-endian signed INT32, one word per element.
There is no requantization, saturation, zero point, floating point, or fused activation.
Arithmetic overflow wraps modulo 2^32.

## Operations

| OP | Operation | Inputs | Output / layout |
|---:|---|---|---|
| 0 | MatMul | A[M,K] and B[K,N], INT8 | C[M,N], INT32; row-major |
| 1 | 2D convolution | A[H,W,Cin] INT8; B[Cout,Kh,Kw,Cin] INT8 | C[Oh,Ow,Cout], INT32 |
| 2 | Vector add | A and B, each M*N INT8 elements | M*N INT32 sums |
| 3 | Element-wise multiply | A and B, each M*N INT8 elements | M*N INT32 products |
| 4 | Bias add | A and bias, each M*N INT32 elements | M*N INT32 sums; element-wise, no broadcast |
| 5 | ReLU | A, M*N INT32 elements | max(A[i],0), INT32 |
| 6 | Max pool | A[H,W,Cin], INT32 | C[Oh,Ow,Cin], INT32 |
| 7 | Reserved | Rejected | Error status and optional IRQ |

M and N must be 1..16 for ops 0,2,3,4,5; K must be 1..16 for MatMul.
Vector length is M*N (use M=1 for a short vector). Spatial ops use their own
registers and ignore M/N/K. H, W, Cin and Cout are 1..16; Cout is ignored for pool.

Convolution is neural-network cross-correlation (no kernel reversal), square
kernel 1..16, stride 1..16, symmetric zero padding 0..15. No dilation or groups.
`Oh=floor((H+2*padding-kernel)/stride)+1`, likewise Ow. The padded input must fit
the kernel, and both output dimensions must be 1..16. Input/output layout is NHWC
without a batch dimension. Kernel layout is OHWI, with input channel contiguous.

Pool uses square windows 1..16, stride 1..16, no padding, floor output size.
`Oh=floor((H-pool_size)/pool_stride)+1`, likewise Ow. Window must fit the input.
Comparison is signed INT32 and handles entirely negative windows correctly.

Four MAC lanes compute four consecutive flattened outputs in parallel. Each lane
has independent operand indexing, so odd N, row boundaries, output-channel tails,
and packed-word crossings are supported. Partial final groups mask unused lanes.
Each group takes one clear cycle, K (or Kh*Kw*Cin) MAC cycles, then up to four store
cycles. Vector operations write one element per cycle. Pool scans one sample per
cycle. Load, compute and store phases do not overlap.

## Local storage and limits

Each of A, B, bias and C holds 4096 32-bit words (16 KiB each, 64 KiB total).
A/B have four asynchronous word-read ports; bias/C have one. Writes are synchronous.
This explicit multiport register/LUT-memory model is synthesizable RTL, but does
not promise FPGA block-RAM inference. A synchronous SRAM implementation requires
read-latency changes in compute and write engines. Memories are not reset; every
used location is loaded or computed before being read by a valid job.

All transfer lengths are derived from configuration. Configurations exceeding a
buffer's capacity are rejected before memory traffic. In particular convolution
weights must satisfy `Cout*kernel*kernel*Cin <= 16384` bytes, even when each individual
dimension is in range. The maximum spatial result is 16*16*16 = 4096 INT32 words.
Address ranges must not wrap the 32-bit address space.

## Register map

See [REGISTER_MAP.md](REGISTER_MAP.md). Registers reset to zero; software must set
every field required by an operation. The interconnect must provide register-window
offsets on the 32-bit Lite address bus. Unmapped/unaligned accesses return SLVERR.

1. Wait for STATUS.busy=0; write the operation, bases and required dimensions.
2. Initialize source memory and perform any platform-specific cache maintenance.
3. Clear IRQ_PENDING (write 3), optionally set IRQ_ENABLE (write 3).
4. Write CONTROL=1. This snapshots the configuration and clears sticky DONE/ERROR.
5. Poll STATUS or wait for IRQ; check ERROR before using output memory.
6. Clear pending interrupts with W1C and perform required output-cache maintenance.

Configuration writes and START while busy return SLVERR. There is no job queue.
Readback, IRQ control and status clearing remain accessible during execution.
IRQ_PENDING records events even when masked. Enabling a pending event asserts IRQ.
STATUS and IRQ_PENDING have independent W1C bits; START clears STATUS only.
New events take precedence over simultaneous clearing. Busy remains high through
the terminal event cycle and drops when the controller returns to idle.

AXI response/ID errors terminate the job; a read error drains the current burst
through RLAST before reporting failure, and a write error waits for B. No further
bursts are issued after an error. Output may be partially written on a write error.
Malformed RLAST is detected, but an AXI slave that never sends RLAST can stall
indefinitely. There is no watchdog or software abort. Reset must be coordinated
with the AXI interconnect/slave; resetting this master alone during an outstanding
transaction is unsupported. AXI4 USER and REGION optional signals are not exposed.

## Files and build

`filelist.f` lists all 18 RTL files in compilation order (package first).
`rtl/ai_axi_slave.sv` is the CPU register slave; `config_check.sv` validates shapes
and computes transfer sizes. `npu_controller.sv` sequences the job, and `npu_top.sv`
connects it to both AXI masters, four buffers, compute and interrupt blocks.

From this directory, with a SystemVerilog-capable tool:

```sh
slang --top npu_top -f filelist.f
slang --top tb_npu -f filelist.f tb/tb_npu.sv
verilator --binary --timing --top-module tb_npu -Wno-fatal -f filelist.f tb/tb_npu.sv
./obj_dir/Vtb_npu
```

The self-checking testbench has 19 jobs, deterministic software-generated expected
results, independent AW/W arrival, bus stalls, 4 KB boundary splits, invalid
configuration checks, read/write response errors, and IRQ checks. Test data is
embedded; no external data files are required. See [VALIDATION.md](VALIDATION.md)
for exactly which checks were executed. The revised RTL passed the complete 19-job testbench in ModelSim Intel FPGA
Edition 10.5b; see VALIDATION.md for tool versions and remaining limits.

Variable index arithmetic and division are deliberately straightforward for
learning; synthesis area/timing are not optimized or measured. No technology
constraints, timing closure, formal AXI verification, or silicon sign-off is included.

## Quartus compatibility revision

The three hardware replication loops now use explicit `generate/endgenerate`,
separately declared `genvar`s and named blocks. This corrects the reported Quartus
18.1 syntax errors in mac_array, int8_unpacker and compute_engine. Arithmetic,
register offsets and external interfaces are unchanged. All explanatory comments
are retained. Named generated scopes change internal simulation hierarchy paths;
the included testbench does not depend on those internal paths.

Replace the old RTL files in your Quartus project with this revision. Keep all
files assigned as SystemVerilog and select `npu_top` as top level. Put npu_pkg.sv
first. `npu_sources.qsf` supplies the ordered source assignments and processor
setting; it deliberately does not select a board, device, pins or clock constraint.
For a Quartus project located in this directory, source that file from its QSF.
Remove duplicate/old source assignments if necessary. Keep the testbench out of
the synthesis source list.

ModelSim console regression, from this directory:

```text
vsim -c -do scripts/run_modelsim.do
```

Verified for this revision: Quartus Prime Lite 18.1 Analysis & Elaboration
passed with zero errors and three case-completeness warnings; ModelSim ran all
19 test jobs successfully. Full FPGA synthesis/fitting/timing remain unverified.
