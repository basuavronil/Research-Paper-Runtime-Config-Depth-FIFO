// ============================================================================
// reconfig_fifo_fixed.v
// Runtime Reconfigurable-Depth FIFO without parameters (Hardcoded Max Depth 64, 8-bit Data)
// ============================================================================
`timescale 1ns/1ps

module reconfig_fifo_fixed (
    input  wire       clk,
    input  wire       rst_n,
    input  wire [1:0] depth_sel,       // requested depth (8, 16, 32, 64)
    input  wire       wr_en,
    input  wire       rd_en,
    input  wire [7:0] din,
    output reg  [7:0] dout,
    output wire       full,
    output wire       empty,
    output wire [6:0] count,           // 6 bits address + 1 wrap bit
    output wire [2:0] active_bits_o,   // for verification/debug
    output wire [5:0] ptr_gate_mask_o  // 6-bit gate mask
);

    // Hardcoded physical memory array (64 entries of 8 bits)
    reg [7:0] mem [0:63];

    // Safe reconfiguration: only load a new depth when FIFO is empty
    reg [1:0] depth_sel_reg;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            depth_sel_reg <= 2'b11; // default: full depth 64
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
    wire [5:0] gate_mask;
    genvar gi;
    generate
        for (gi = 0; gi < 6; gi = gi + 1) begin : GM
            assign gate_mask[gi] = (gi < active_bits);
        end
    endgenerate
    assign ptr_gate_mask_o = gate_mask;
    assign active_bits_o   = active_bits;

    wire [5:0] depth_mask_addr = (6'b111111 >> (6 - active_bits));

    // Write & Read Pointers with Bit-Level Clock-Gating
    reg [5:0] wr_addr, rd_addr;
    reg       wr_wrap, rd_wrap;

    wire wr_fire = wr_en & ~full;
    wire rd_fire = rd_en & ~empty;

    wire wr_at_top = (wr_addr == depth_mask_addr);
    wire rd_at_top = (rd_addr == depth_mask_addr);

    wire [5:0] wr_addr_inc = wr_addr + 1'b1;
    wire [5:0] rd_addr_inc = rd_addr + 1'b1;

    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_addr <= 6'b0;
            wr_wrap <= 1'b0;
        end else if (wr_fire) begin
            for (i = 0; i < 6; i = i + 1) begin
                if (gate_mask[i]) begin
                    if (wr_at_top)
                        wr_addr[i] <= 1'b0;
                    else
                        wr_addr[i] <= wr_addr_inc[i];
                end
            end
            if (wr_at_top)
                wr_wrap <= ~wr_wrap;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_addr <= 6'b0;
            rd_wrap <= 1'b0;
        end else if (rd_fire) begin
            for (i = 0; i < 6; i = i + 1) begin
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

    // Memory Access
    always @(posedge clk) begin
        if (wr_fire)
            mem[wr_addr] <= din;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            dout <= 8'b0;
        else if (rd_fire)
            dout <= mem[rd_addr];
    end

    // Status Flags & Occupancy Counter
    assign empty = (wr_addr == rd_addr) && (wr_wrap == rd_wrap);
    assign full  = (wr_addr == rd_addr) && (wr_wrap != rd_wrap);

    assign count = full ? (depth_mask_addr + 1'b1) :
                   (wr_addr >= rd_addr) ? (wr_addr - rd_addr)
                                        : (depth_mask_addr + 1'b1 - rd_addr + wr_addr);

endmodule
