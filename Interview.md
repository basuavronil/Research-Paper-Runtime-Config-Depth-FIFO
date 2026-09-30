## 1. The Elevator Pitch (The "What" and "Why")

> "In modern SoC and FPGA designs, standard FIFOs are statically sized for peak throughput—for example, 64 entries. However, during burst-shallow or low-traffic phases, a 64-entry FIFO still incurs the full dynamic switching power overhead of its high-order pointer bits, clock trees, and comparison logic, even when only using 8 or 16 entries. To solve this, I designed and verified a Runtime-Reconfigurable Synchronous FIFO that dynamically scales its active depth across 8, 16, 32, and 64 entry windows without requiring re-synthesis. By utilizing fine-grained bit-level clock gating on pointer registers and an empty-state interlock, we achieve monotonic dynamic power scaling while maintaining a fixed physical memory footprint."

## 2. Defining the Operational "Windows" (Depth Modes)

In this architecture, the FIFO's operational scope is broken down into four distinct **active windows** selected dynamically via a `depth_sel[1:0]` control bus:

* **Window 1 (Depth 8):** `depth_sel = 2'b00` | Active pointer bits = `3` (`active_bits = 3`) | Address range: `0x00` to `0x07`.
* **Window 2 (Depth 16):** `depth_sel = 2'b01` | Active pointer bits = `4` (`active_bits = 4`) | Address range: `0x00` to `0x0F`.
* **Window 3 (Depth 32):** `depth_sel = 2'b10` | Active pointer bits = `5` (`active_bits = 5`) | Address range: `0x00` to `0x1F`.
* **Window 4 (Depth 64):** `depth_sel = 2'b11` | Active pointer bits = `6` (`active_bits = 6`) | Address range: `0x00` to `0x3F`.

---

## 3. How Masking and Pointer Logic Function Across Windows

To make these windows functional, the architecture relies on two key hardware mechanisms: `gate_mask` and `depth_mask_addr`.

### A. Bit-Level Clock-Gating (`gate_mask`)
* **How it works:** A parameterized `generate` loop creates a per-bit enable mask: `assign gate_mask[gi] = (gi < active_bits);`.
* **In the Window Context:** 
  * If operating in Window 8 (`active_bits = 3`), the `gate_mask` evaluates to `6'b000111`. Bits `[5:3]` evaluate to `1'b0`.
  * During the pointer increment loop (`always @(posedge clk)`), the flip-flop update condition checks `if (gate_mask[i])`.
* **The Power Win:** Unused upper bits (i >= 3) are given a clock-enable (`CE = 0`) and forced to `0`. During synthesis in **AMD Vivado**, these static zero assignments map directly to clock-enable primitives, entirely eliminating toggle activity on bits `[5:3]` during Window 8 operation.

### B. Address Boundary & Rollover (`depth_mask_addr`)
* **How it works:** Instead of hardcoding a maximum depth wrap point (like 63), the boundary is calculated dynamically: `depth_mask_addr = (6'b111111 >> (6 - active_bits))`.
* **In the Window Context:** For Window 1 (Depth 8), `depth_mask_addr` resolves to `6'b000111` (decimal `7`). When the write pointer `wr_addr` reaches `7`, the next increment synchronously wraps back to `0` rather than counting up to `63`. This confines the FIFO strictly to the active window.

## 5. Power Comparison & Verification Methodology

To prove that switching windows actually saves power, a rigorous post-implementation verification flow was executed:

* **Simulation Workloads:** Created testbenches that exercised the FIFO under identical throughput conditions across all four windows (Window 8, 16, 32, and 64).
* **SAIF Generation:** Ran post-implementation timing simulations in **AMD Vivado**, capturing switching activity into a **Switching Activity Interchange Format (.saif)** file.
* **Power Analysis Findings:**
  * Feeding the SAIF file into Vivado's Power Analyzer revealed **monotonic power scaling**.
  * When operating in Window 8, dynamic switching power on the pointer logic and clock trees dropped significantly compared to Window 64. Because high-order bits `[5:3]` were clock-gated and held static, their transition density (`VDD * C * alpha * f`) dropped to near-zero, proving the efficacy of the architectural gating strategy.

---

## 6. Anticipated Interview Follow-Up Questions & Answers

* **Q: Why don't you also power-gate or clock-gate the RAM storage array itself for unused entries?**
  * **A:** In FPGA architectures (like Xilinx UltraScale/Series-7), RAM blocks (LUTRAM or Block RAM) have fixed minimum primitive sizes. Dynamic power in FPGAs is dominated by routing and logic toggle activity rather than macro leakage. Gate-level clock gating on the address pointers and registers yields the highest return on investment for FPGA resource utilization without violating primitive boundaries. For an ASIC implementation, you could extend this with memory-bank power gating (`VDD` clamping or local sleep transistors).

* **Q: What happens if `depth_sel` changes while `empty` is LOW?**
  * **A:** The interlock register `depth_sel_reg` ignores the new request until the FIFO drains completely. This ensures transactional integrity. If immediate reconfiguration is required, a flush signal would first need to be asserted to drive `empty` high.
