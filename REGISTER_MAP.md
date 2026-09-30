# Register map

32-bit, four-byte aligned offsets, all reset values zero. Configuration registers
are RW while idle and read-only while busy (writes get SLVERR). WSTRB merges selected
bytes on configuration writes. Control/status/IRQ actions require WSTRB[0].

| Offset | Name | Access | Description |
|---|---|---|---|
| 0x00 | CONTROL | W1P / read 0 | Bit 0 START; accepted only while idle; other bits ignored. |
| 0x04 | STATUS | RO + W1C | Bit 0 busy (RO), bit 1 done (sticky/W1C), bit 2 error (sticky/W1C). |
| 0x08 | IRQ_ENABLE | RW | Bit 0 done enable, bit 1 error enable; other bits read zero. |
| 0x0C | IRQ_PENDING | RO + W1C | Bit 0 done pending, bit 1 error pending; write 1 to clear. |
| 0x10 | OP | RW | Operation 0..6; full 32-bit value validated (upper bits must be zero). |
| 0x14 | A_BASE | RW | Source A address; used by every operation. |
| 0x18 | B_BASE | RW | Source B / weights address; used by 0,1,2,3. |
| 0x1C | BIAS_BASE | RW | INT32 bias-array address; used by 4. |
| 0x20 | C_BASE | RW | Destination INT32 address; used by every operation. |
| 0x24 | M | RW | Rows / vector shape M, 1..16; used by 0,2,3,4,5. |
| 0x28 | N | RW | Columns / vector shape N, 1..16; used by 0,2,3,4,5. |
| 0x2C | K | RW | MatMul reduction length K, 1..16; used by 0. |
| 0x30 | HEIGHT | RW | Input height H, 1..16; used by 1,6. |
| 0x34 | WIDTH | RW | Input width W, 1..16; used by 1,6. |
| 0x38 | KERNEL | RW | Square convolution kernel size, 1..16; used by 1. |
| 0x3C | STRIDE | RW | Convolution stride, 1..16; used by 1. |
| 0x40 | PADDING | RW | Convolution symmetric zero padding, 0..15; used by 1. |
| 0x44 | IN_CHANNELS | RW | Input channels Cin, 1..16; used by 1,6. |
| 0x48 | OUT_CHANNELS | RW | Convolution output channels Cout, 1..16; used by 1. |
| 0x4C | POOL_SIZE | RW | Square max-pool window, 1..16; used by 6. |
| 0x50 | POOL_STRIDE | RW | Pool stride, 1..16; used by 6. |

All other offsets return SLVERR. Error status combines invalid configuration and
AXI transfer/protocol errors; this baseline has no separate error-code register.
No transfer-byte registers: dimensions and datatypes determine transfer lengths.

Example: MatMul A[4,8] * B[8,16], A at 0x1000, B at 0x2000, C at 0x3000:

```text
write 0x10 = 0       OP=MatMul
write 0x14 = 0x1000  A_BASE
write 0x18 = 0x2000  B_BASE
write 0x20 = 0x3000  C_BASE
write 0x24 = 4       M
write 0x28 = 16      N
write 0x2C = 8       K
write 0x0C = 3       clear pending
write 0x08 = 3       enable done/error IRQ
write 0x00 = 1       start
```

This reads 32 A bytes and 128 B bytes, computes 64 results, and writes 256 bytes.
ReLU/bias/pool can consume a previous job's INT32 output directly. Feeding that
output into an INT8 operation requires software requantization first.
