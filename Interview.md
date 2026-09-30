## 1. The Elevator Pitch (The "What" and "Why")

> "In modern SoC and FPGA designs, standard FIFOs are statically sized for peak throughput—for example, 64 entries. However, during burst-shallow or low-traffic phases, a 64-entry FIFO still incurs the full dynamic switching power overhead of its high-order pointer bits, clock trees, and comparison logic, even when only using 8 or 16 entries. To solve this, I designed and verified a Runtime-Reconfigurable Synchronous FIFO that dynamically scales its active depth across 8, 16, 32, and 64 entry windows without requiring re-synthesis. By utilizing fine-grained bit-level clock gating on pointer registers and an empty-state interlock, we achieve monotonic dynamic power scaling while maintaining a fixed physical memory footprint."

## 2. Defining the Operational "Windows" (Depth Modes)

In this architecture, the FIFO's operational scope is broken down into four distinct **active windows** selected dynamically via a `depth_sel[1:0]` control bus:

* **Window 1 (Depth 8):** `depth_sel = 2'b00` | Active pointer bits = `3` (`active_bits = 3`) | Address range: `0x00` to `0x07`.
* **Window 2 (Depth 16):** `depth_sel = 2'b01` | Active pointer bits = `4` (`active_bits = 4`) | Address range: `0x00` to `0x0F`.
* **Window 3 (Depth 32):** `depth_sel = 2'b10` | Active pointer bits = `5` (`active_bits = 5`) | Address range: `0x00` to `0x1F`.
* **Window 4 (Depth 64):** `depth_sel = 2'b11` | Active pointer bits = `6` (`active_bits = 6`) | Address range: `0x00` to `0x3F`.

---

## 3. How Masking and Pointer Logic Function Across Windows (Intuitive Breakdown)

Think of your FIFO pointer like a digital odometer or a counter with 6 digits (Bits 0 through 5). Normally, it counts all the way from 0 up to 63. Here is how the two key mechanisms work to control it:

### A. `gate_mask` (The "Turn Off Unused Wires" Switch)
* **The Problem:** Even if you only want to use **8 entries** (which only needs the first 3 bits: Bit 0, Bit 1, and Bit 2), a standard 6-bit counter will still let Bits 3, 4, and 5 flip back and forth randomly as data flows. Every time a wire or flip-flop flips (0 to 1 or 1 to 0), it burns dynamic power.
* **What `gate_mask` does:** It acts like a bouncer or a power switch. 
  * When you select **Window 8**, `gate_mask` creates a pattern: `000111`. 
  * The `1`s tell the lower 3 bits: *"Keep working normally."*
  * The `0`s tell the upper bits (Bits 3, 4, and 5): *"Freeze! You are not needed right now. Turn off your clock and stay locked at zero."*
* **The Result:** Because those upper bits are completely frozen and never toggle, they stop wasting electricity, which is why your power drops significantly in shallow modes.

---

### B. `depth_mask_addr` (The "Shortened Running Track" Boundary)
* **The Problem:** If you are running a race on a 63-meter track (Depth 64), but you suddenly want to run a short 8-meter sprint (Depth 8), you need a way to turn around early instead of running all the way to the end.
* **What `depth_mask_addr` does:** It calculates a temporary **turn-around point** based on your window size.
  * For Window 8, it sets the limit at `7` (binary `000111`).
  * As your write pointer counts up (`0, 1, 2, 3, 4, 5, 6, 7`), the moment it hits `7`, `depth_mask_addr` steps in and says: *"Stop! Don't go to 8. Wrap straight back around to 0 right now."*
* **The Result:** It traps your data safely inside that small 8-entry window (addresses 0 to 7) without letting it spill over into the rest of the 64-entry memory array.

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
