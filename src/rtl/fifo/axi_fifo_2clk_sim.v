//
// Copyright 2016 Ettus Research
// Copyright 2018 Ettus Research, a National Instruments Company
//
// SPDX-License-Identifier: LGPL-3.0-or-later
//

module axi_fifo_2clk #(
    parameter SYNC_STAGES = 2,
    parameter SIZE        = 10,
    parameter WIDTH       = 32,
    parameter PIPELINE    = "<UNUSED>")
(
    input reset,
    input i_aclk,
    input [WIDTH-1:0] i_tdata,
    input i_tvalid,
    output reg i_tready = 1'b0,
    input o_aclk,
    output [WIDTH-1:0] o_tdata,
    output o_tvalid,
    input o_tready
);

    // Read side of the memory, before the output register stage.
    wire [WIDTH-1:0] r_tdata;
    reg              r_tvalid = 1'b0;
    wire             r_tready;

    localparam FIFOSIZE = (SIZE < 5) ? 5 : SIZE;

    // Synchronizers
    wire o_rst_sync, i_rst_sync;
    synchronizer #(
        .INITIAL_VAL(1'b1),
        .WIDTH(1),
        .STAGES(SYNC_STAGES))
    synchronizer_i_rst (
        .clk(i_aclk), .rst(1'b0),
        .in(reset), .out(i_rst_sync));
    synchronizer #(
        .INITIAL_VAL(1'b1),
        .WIDTH(1),
        .STAGES(SYNC_STAGES))
    synchronizer_o_rst (
        .clk(o_aclk), .rst(1'b0),
        .in(reset), .out(o_rst_sync));

    // Gray counters.  Every flag compares Gray codes: the binary pointers are
    // a bijection of them, so comparing them is the same test without a
    // Gray-to-binary conversion in the far clock domain.  That conversion
    // followed by pointer arithmetic was the longest path in the bus domain
    // (10.8 ns: seven LUT levels and a carry chain from a synchroniser flop).
    reg [FIFOSIZE-1:0] wr_addr, rd_addr;
    wire [FIFOSIZE-1:0] wr_addr_gray_sync, wr_addr_gray, rd_addr_gray_sync, rd_addr_gray;
    wire [FIFOSIZE-1:0] wr_addr_gray_next, rd_addr_gray_next;
    synchronizer #(
        .INITIAL_VAL(0),
        .WIDTH(FIFOSIZE),
        .STAGES(SYNC_STAGES))
    synchronizer_rd_addr_gray (
        .clk(i_aclk), .rst(o_rst_sync),
        .in(rd_addr_gray), .out(rd_addr_gray_sync));
    synchronizer #(
        .INITIAL_VAL(0),
        .WIDTH(FIFOSIZE),
        .STAGES(SYNC_STAGES))
    synchronizer_wr_addr_gray (
        .clk(o_aclk), .rst(i_rst_sync),
        .in(wr_addr_gray), .out(wr_addr_gray_sync));
    bin2gray #(.WIDTH(FIFOSIZE))
    bin2gray_wr_addr (.bin(wr_addr), .gray(wr_addr_gray));
    bin2gray #(.WIDTH(FIFOSIZE))
    bin2gray_rd_addr (.bin(rd_addr), .gray(rd_addr_gray));
    // The pointer one past the next write (read): the "one slot left" test.
    // Its inputs are local registers, so the increment is a short carry chain
    // that runs in parallel with the synchronised value it is compared with.
    bin2gray #(.WIDTH(FIFOSIZE))
    bin2gray_wr_next (.bin(wr_addr + 1'b1), .gray(wr_addr_gray_next));
    bin2gray #(.WIDTH(FIFOSIZE))
    bin2gray_rd_next (.bin(rd_addr + 1'b1), .gray(rd_addr_gray_next));

    reg i_full;
    reg o_empty;

    reg [WIDTH:0] mem[0:2**(FIFOSIZE)-1];
    integer i;
    initial begin
        for (i = 0; i < 1 << FIFOSIZE; i = i + 1) begin
            mem[i] = 'd0;
        end
    end

    // Write
    always @(posedge i_aclk) begin
        if (i_rst_sync) begin
            wr_addr <= 'd0;
        end else begin
            if (i_tvalid & i_tready) begin
                mem[wr_addr] <= i_tdata;
                wr_addr      <= wr_addr + 1'b1;
            end
        end
    end

    // Write side: ready and full.  A write is accepted until the pointer is
    // one behind the synchronised read pointer; that slot stays unused, which
    // is what the 2^FIFOSIZE-entry pointer pair requires (the original
    // behaviour, kept).
    always @(posedge i_aclk) begin
        if (i_rst_sync) begin
            i_tready <= 1'b0;
            i_full   <= 1'b0;
        end else begin
            if ((wr_addr_gray_next == rd_addr_gray_sync) & i_tvalid & i_tready) begin
                i_tready <= 1'b0;
                i_full   <= 1'b1;
            end else if ((wr_addr_gray != rd_addr_gray_sync) & i_full) begin
                i_tready <= 1'b1;
                i_full   <= 1'b0;
            end
            if ((wr_addr_gray == rd_addr_gray_sync) & ~i_full) begin
                i_tready <= 1'b1;
            end
        end
    end

    // Read
    always @(posedge o_aclk) begin
        if (o_rst_sync) begin
            rd_addr <= 'd0;
        end else begin
            if (r_tvalid & r_tready) begin
                rd_addr <= rd_addr + 1'b1;
            end
        end
    end

    assign r_tdata = mem[rd_addr];

    // The memory maps onto a block RAM read without an output register
    // (2.5 ns clock-to-out on Kintex-7).  A two-entry flop stage gives the
    // consumer a registered interface, as PIPELINE = "OUT" does in the
    // original implementation built on the vendor FIFO core.
    axi_fifo_flop2 #(.WIDTH(WIDTH)) out_reg (
        .clk(o_aclk), .reset(o_rst_sync), .clear(1'b0),
        .i_tdata(r_tdata), .i_tvalid(r_tvalid), .i_tready(r_tready),
        .o_tdata(o_tdata), .o_tvalid(o_tvalid), .o_tready(o_tready),
        .space(), .occupied());

    // Read side: valid and empty.  Same Gray comparisons, mirrored.
    always @(posedge o_aclk) begin
        if (o_rst_sync) begin
            r_tvalid <= 1'b0;
            o_empty  <= 1'b1;
        end else begin
            if ((rd_addr_gray_next == wr_addr_gray_sync) & r_tready & r_tvalid) begin
                r_tvalid <= 1'b0;
                o_empty  <= 1'b1;
            end else if ((rd_addr_gray != wr_addr_gray_sync) & o_empty) begin
                r_tvalid <= 1'b1;
                o_empty  <= 1'b0;
            end
        end
    end

endmodule
