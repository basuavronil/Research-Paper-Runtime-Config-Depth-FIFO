// ============================================================================
// reconfig_fifo.v
// Runtime Reconfigurable-Depth FIFO with explicit bit-level clock-gating
// of unused pointer MSBs.
//
// MAX_DEPTH  = 64  (ADDR_WIDTH = 6)
// depth_sel  = 2'b00 -> depth 8   (active_bits = 3)
//              2'b01 -> depth 16  (active_bits = 4)
//              2'b10 -> depth 32  (active_bits = 5)
//              2'b11 -> depth 64  (active_bits = 6)
//
// Reconfiguration is only latched when the FIFO is empty (interlock),
// otherwise wr_ptr/rd_ptr comparisons would be meaningless mid-flight.
// ============================================================================
`timescale 1ns/1ps

module reconfig_fifo #(
    parameter DATA_WIDTH = 8,
    parameter MAX_DEPTH  = 64,
    parameter ADDR_WIDTH = 6            // log2(MAX_DEPTH)
)(
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire [1:0]              depth_sel,   // requested depth (see header)
    input  wire                    wr_en,
    input  wire                    rd_en,
    input  wire [DATA_WIDTH-1:0]   din,
    output reg  [DATA_WIDTH-1:0]   dout,
    output wire                    full,
    output wire                    empty,
    output wire [ADDR_WIDTH:0]     count,
    output wire [2:0]              active_bits_o,   // for verification/debug
    output wire [ADDR_WIDTH-1:0]   ptr_gate_mask_o  // 1 = bit is live, 0 = clock-gated
);

    // ------------------------------------------------------------------
    // Storage: fixed physical array (BRAM/LUTRAM sized for MAX_DEPTH).
    // What shrinks with depth_sel is *switching activity*, not silicon
    // area -- see paper discussion of why FPGAs gate toggling, not Vdd.
    // ------------------------------------------------------------------
    reg [DATA_WIDTH-1:0] mem [0:MAX_DEPTH-1];

    // ------------------------------------------------------------------
    // Safe reconfiguration: only load a new depth when FIFO is empty
    // ------------------------------------------------------------------
    reg [1:0] depth_sel_reg;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            depth_sel_reg <= 2'b11;              // default: full depth 64
        else if (empty)
            depth_sel_reg <= depth_sel;
    end

    // active_bits: number of pointer LSBs that are "live" for this depth
    reg [2:0] active_bits;
    always @(*) begin
        case (depth_sel_reg)
            2'b00: active_bits = 3'd3;   // depth 8
            2'b01: active_bits = 3'd4;   // depth 16
            2'b10: active_bits = 3'd5;   // depth 32
            default: active_bits = 3'd6; // depth 64
        endcase
    end

    // Per-bit gate mask: bit i is enabled iff i < active_bits
    wire [ADDR_WIDTH-1:0] gate_mask;
    genvar gi;
    generate
        for (gi = 0; gi < ADDR_WIDTH; gi = gi + 1) begin : GM
            assign gate_mask[gi] = (gi < active_bits);
        end
    endgenerate
    assign ptr_gate_mask_o = gate_mask;
    assign active_bits_o   = active_bits;

    wire [ADDR_WIDTH-1:0] depth_mask_addr = (({{ADDR_WIDTH{1'b1}}}) >> (ADDR_WIDTH - active_bits));
    // e.g. active_bits=3 -> depth_mask_addr = 6'b000111 (depth-1 = 7)

    // ------------------------------------------------------------------
    // Write pointer: address bits + 1 wrap bit.
    // Unused MSBs (i >= active_bits) are individually clock-gated
    // (CE = 0) and forced to 0 -- they never toggle, which is what
    // shows up as near-zero dynamic power on those flops in the
    // Vivado power report for small depth_sel.
    // ------------------------------------------------------------------
    reg [ADDR_WIDTH-1:0] wr_addr, rd_addr;
    reg wr_wrap, rd_wrap;

    wire wr_fire = wr_en & ~full;
    wire rd_fire = rd_en & ~empty;

    wire wr_at_top = (wr_addr == depth_mask_addr);
    wire rd_at_top = (rd_addr == depth_mask_addr);

    // Verilog doesn't allow a bit-select directly on a parenthesized
    // expression, so materialize the incremented value first, then
    // pick bit i out of it below.
    wire [ADDR_WIDTH-1:0] wr_addr_inc = wr_addr + 1'b1;
    wire [ADDR_WIDTH-1:0] rd_addr_inc = rd_addr + 1'b1;

    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_addr <= {ADDR_WIDTH{1'b0}};
            wr_wrap <= 1'b0;
        end else if (wr_fire) begin
            for (i = 0; i < ADDR_WIDTH; i = i + 1) begin
                if (gate_mask[i]) begin                 // CE=1: live bit
                    if (wr_at_top)
                        wr_addr[i] <= 1'b0;              // synchronous wrap
                    else
                        wr_addr[i] <= wr_addr_inc[i]; // normal increment, bit i
                end
                // else: CE=0 -> holds previous value (already 0, gated)
            end
            if (wr_at_top)
                wr_wrap <= ~wr_wrap;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_addr <= {ADDR_WIDTH{1'b0}};
            rd_wrap <= 1'b0;
        end else if (rd_fire) begin
            for (i = 0; i < ADDR_WIDTH; i = i + 1) begin
                if (gate_mask[i]) begin
                    if (rd_at_top)
                        rd_addr[i] <= 1'b0;
                    else
                        rd_addr[i] <= rd_addr_inc[i];
                end
            end
            if (rd_at_top)
                rd_wrap <= ~rd_wrap;
        end
    end

    // ------------------------------------------------------------------
    // Memory access (unused rows for the active depth are simply never
    // addressed, so they never toggle either)
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        if (wr_fire)
            mem[wr_addr] <= din;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            dout <= {DATA_WIDTH{1'b0}};
        else if (rd_fire)
            dout <= mem[rd_addr];
    end

    // ------------------------------------------------------------------
    // Status flags
    // ------------------------------------------------------------------
    assign empty = (wr_addr == rd_addr) && (wr_wrap == rd_wrap);
    assign full  = (wr_addr == rd_addr) && (wr_wrap != rd_wrap);

    assign count = full ? (depth_mask_addr + 1'b1) :
                   (wr_addr >= rd_addr) ? (wr_addr - rd_addr)
                                         : (depth_mask_addr + 1'b1 - rd_addr + wr_addr);

endmodule
