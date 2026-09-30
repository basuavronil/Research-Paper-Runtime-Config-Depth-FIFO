# Technical Deep-Dive: Runtime Reconfigurable-Depth Synchronous FIFO (`reconfig_fifo.v`)

## 1. Architectural Overview

The `reconfig_fifo` is a high-efficiency, runtime-scalable synchronous FIFO designed to minimize **dynamic power consumption** in FPGA and ASIC designs. 

Traditional FIFOs sized for peak traffic conditions (N = 64) incur fixed dynamic switching power penalties regardless of instantaneous throughput demands. In shallow operating modes (e.g., streaming burst packets requiring only 8 or 16 entries), driving high-order address bits and wide comparison logic wastes clock-tree power and induces redundant flip-flop toggling.

This architecture mitigates dynamic power overhead through **fine-grained bit-level clock-enable (CE) pointer gating** and **dynamic address bound masking**, maintaining a fixed physical memory layout while scaling switching activity strictly to match active workload requirements.

                  +----------------------------------------------+
                  |            Configuration Control             |
                  |  depth_sel [1:0] ----> Interlock Logic       |
                  +------------------------------+---------------+
                                                 |
                                                 v
                                    +--------------------------+
                                    | active_bits & gate_mask  |
                                    +------------+-------------+
                                                 |
                  +------------------------------+------------------------------+
                  |                                                             |
                  v                                                             v
     +--------------------------+                                  +--------------------------+
     |   Write Pointer Logic    |                                  |    Read Pointer Logic    |
     | [wr_addr] + [wr_wrap]    |                                  |  [rd_addr] + [rd_wrap]   |
     | (Gated per bit MSB->LSB) |                                  | (Gated per bit MSB->LSB) |
     +------------+-------------+                                  +------------+-------------+
                  |                                                             |
                  +------------------------------+------------------------------+
                                                 |
                                                 v
                                    +--------------------------+
                                    |  LUTRAM / BRAM Storage   |
                                    |    mem[0 : MAX_DEPTH-1]  |
                                    +--------------------------+

---

## 2. Dynamic Depth Encoding & Pointer Masking

The operational depth is selected dynamically via the `depth_sel` control port. Active pointer widths adjust dynamically to accommodate power-of-two depths (8, 16, 32, 64):

| `depth_sel` | Active Mode | Active Pointer Bits (`active_bits`) | Active Address Range | `depth_mask_addr` | `gate_mask` (`ADDR_WIDTH=6`) |
| :---: | :---: | :---: | :---: | :---: | :---: |
| `2'b00` | **Depth 8** | `3'd3` | `0x00` – `0x07` | `6'b000111` | `6'b000111` |
| `2'b01` | **Depth 16** | `3'd4` | `0x00` – `0x0F` | `6'b001111` | `6'b001111` |
| `2'b10` | **Depth 32** | `3'd5` | `0x00` – `0x1F` | `6'b011111` | `6'b011111` |
| `2'b11` | **Depth 64** | `3'd6` | `0x00` – `0x3F` | `6'b111111` | `6'b111111` |

---

## 3. Core RTL Features & Implementation Breakdown

### A. Safe Dynamic Interlock (`depth_sel_reg`)
```verilog
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        depth_sel_reg <= 2'b11; // Default to maximum depth (64)
    else if (empty)
        depth_sel_reg <= depth_sel;
end
