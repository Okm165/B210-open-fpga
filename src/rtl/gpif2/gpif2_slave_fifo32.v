//
// Copyright 2011-2013 Ettus Research LLC
// Copyright 2018 Ettus Research, a National Instruments Company
//
// SPDX-License-Identifier: LGPL-3.0-or-later
//


//////////////////////////////////////////////////////////////////////////////////

//this is a FIFO master interface for the FX3 in "slave fifo" mode.

module gpif2_slave_fifo32
#(
    //sizes for fifo64 2 clock cascade fifos
    parameter DATA_RX_FIFO_SIZE = 12, //max vita pkt size
    parameter DATA_TX_FIFO_SIZE = 12, //max vita pkt size
    parameter CTRL_RX_FIFO_SIZE = 5,  //small resp packets
    parameter CTRL_TX_FIFO_SIZE = 5, //small ctrl packets

    //address constants for the endpoints
    parameter ADDR_DATA_TX = 2'b00,
    parameter ADDR_DATA_RX = 2'b01,
    parameter ADDR_CTRL_TX = 2'b10,
    parameter ADDR_CTRL_RX = 2'b11
)
   (
    // GPIF signals
    input gpif_clk,
    input gpif_rst,
    input gpif_enb,
    inout [31:0] gpif_d,
    input [3:0] gpif_ctl,
    output sloe,
    output slrd,
    output slwr,
    output slcs,
    output pktend,
    output [1:0] fifoadr,
    // FIFO interfaces
    input fifo_clk,
    input fifo_rst,
    // TX Data interface to DSP
    output [63:0] tx_tdata, output tx_tlast, output tx_tvalid, input tx_tready,
    // RX Data interface to DSP
    input [63:0] rx_tdata, input rx_tlast, input rx_tvalid, output rx_tready,
    // Incomming control interface
    output [63:0] ctrl_tdata, output ctrl_tlast, output ctrl_tvalid, input ctrl_tready,
    // Outgoing control interface
    input [63:0] resp_tdata, input resp_tlast, input resp_tvalid, output resp_tready,
    // Debug Signals
    output [31:0] debug
    );

   reg 		  fifo_nearly_full;
   wire 	  ctrl_tx_fifo_nearly_full, data_tx_fifo_nearly_full;
   wire 	  ctrl_tx_fifo_has_space, data_tx_fifo_has_space;


    assign slcs = 1'b0;

    //
    // I/O-block registers.
    //
    // The register next to every GPIF pad has to be the one inside the I/O block (ILOGIC / OLOGIC):
    // the Ettus constraints ask for exactly that (INST "GPIF_*" IOB = TRUE), and it is what gives the
    // bus a pad timing that does not move with the routing. The place-and-route engine of this flow
    // (nextpnr-himbaechel) never packs an ordinary flip-flop into an I/O block, so the boundary
    // registers are instantiated:
    //
    //   input   IDDR, Q1 only  = the rising-edge sample, an ordinary posedge flip-flop with CE
    //   output  ODDR, D1 == D2 = an ordinary posedge flip-flop (both halves of the cycle carry D1)
    //   T       ODDR, D1 == D2, Q to the T pin of the IOBUF only = the tristate flip-flop
    //
    // An ODDR's Q may drive one output buffer and nothing else. So each registered output exists
    // twice: <name>_r (fifoadr_r, sloe_r, ...) and gpif_data_out are the fabric registers the logic
    // below reads, exactly as before, and the ODDR is a second copy of the same register at the pad.
    // Both load the same next value <name>_n on the same clock edge, so they are equal in every
    // cycle. The next values come from the combinational half of the bus state machine.
    //
    // Power-up: the original sloe, slrd, slwr and pktend had a synchronous set and no initial value,
    // which synthesis turns into an FDSE, and an FDSE without INIT comes up 1 (Vivado, and this flow:
    // nextpnr programs an undefined FDSE INIT as 1). The other registers were FDREs and come up 0.
    // So the bus comes up idle: strobes high, FPGA parking the data lines at 0, thread 0. The pad
    // copies carry those values in INIT. The fabric copies of the four strobes need theirs written
    // out: with the set folded into <name>_n they are plain flip-flops now, which would come up 0.
    // gpif_rst needs no pin on the pad copies, it reaches them through <name>_n.
    //
    reg        sloe_r = 1'b1, slrd_r = 1'b1, slwr_r = 1'b1, pktend_r = 1'b1;  // fabric copies of the output ports
    reg [1:0]  fifoadr_r;
    reg        sloe_n, slrd_n, slwr_n, pktend_n;                // next values
    reg [1:0]  fifoadr_n;
    reg [31:0] gpif_data_out_n;

    ODDR #(.DDR_CLK_EDGE("SAME_EDGE"), .INIT(1'b1), .SRTYPE("SYNC")) oddr_sloe
      (.C(gpif_clk), .CE(1'b1), .R(1'b0), .S(1'b0), .D1(sloe_n), .D2(sloe_n), .Q(sloe));
    ODDR #(.DDR_CLK_EDGE("SAME_EDGE"), .INIT(1'b1), .SRTYPE("SYNC")) oddr_slrd
      (.C(gpif_clk), .CE(1'b1), .R(1'b0), .S(1'b0), .D1(slrd_n), .D2(slrd_n), .Q(slrd));
    ODDR #(.DDR_CLK_EDGE("SAME_EDGE"), .INIT(1'b1), .SRTYPE("SYNC")) oddr_slwr
      (.C(gpif_clk), .CE(1'b1), .R(1'b0), .S(1'b0), .D1(slwr_n), .D2(slwr_n), .Q(slwr));
    ODDR #(.DDR_CLK_EDGE("SAME_EDGE"), .INIT(1'b1), .SRTYPE("SYNC")) oddr_pktend
      (.C(gpif_clk), .CE(1'b1), .R(1'b0), .S(1'b0), .D1(pktend_n), .D2(pktend_n), .Q(pktend));
    ODDR #(.DDR_CLK_EDGE("SAME_EDGE"), .INIT(1'b0), .SRTYPE("SYNC")) oddr_fifoadr0
      (.C(gpif_clk), .CE(1'b1), .R(1'b0), .S(1'b0), .D1(fifoadr_n[0]), .D2(fifoadr_n[0]), .Q(fifoadr[0]));
    ODDR #(.DDR_CLK_EDGE("SAME_EDGE"), .INIT(1'b0), .SRTYPE("SYNC")) oddr_fifoadr1
      (.C(gpif_clk), .CE(1'b1), .R(1'b0), .S(1'b0), .D1(fifoadr_n[1]), .D2(fifoadr_n[1]), .Q(fifoadr[1]));

    //
    // DMA FIFO ready and watermark flags
    // These are double registered not for meta stability protection, but to make timing closure easier
    // since the first register is locked in the I/O pad.
    //
    wire fx3_ready, fx3_wmark;      // the registers locked in the I/O pad: IDDR.Q1
    reg fx3_ready1, fx3_wmark1;
    IDDR #(.DDR_CLK_EDGE("SAME_EDGE"), .INIT_Q1(1'b0), .INIT_Q2(1'b0), .SRTYPE("SYNC")) iddr_fx3_ready
      (.C(gpif_clk), .CE(1'b1), .R(1'b0), .S(1'b0), .D(gpif_ctl[0]), .Q1(fx3_ready), .Q2());
    IDDR #(.DDR_CLK_EDGE("SAME_EDGE"), .INIT_Q1(1'b0), .INIT_Q2(1'b0), .SRTYPE("SYNC")) iddr_fx3_wmark
      (.C(gpif_clk), .CE(1'b1), .R(1'b0), .S(1'b0), .D(gpif_ctl[1]), .Q1(fx3_wmark), .Q2());
    always @(posedge gpif_clk) fx3_ready1 <= fx3_ready;
    always @(posedge gpif_clk) fx3_wmark1 <= fx3_wmark;

    //
    // GPIF input and output data lines, tristate
    //
    wire [31:0] gpif_data_in;       // IDDR.Q1 of every data pad
    reg [31:0] gpif_data_out;
    // Read strobe pipeline.
    reg slrd1, slrd2, slrd3, slrd4, slrd5;

    // was: always @(posedge gpif_clk) if (~slrd2) gpif_data_in <= gpif_d;
	// Update data register only when something useful is read.
	// Hold values until we know if they are end of packets for single beat reads.
    wire gpif_data_in_ce = ~slrd2;

    // was: assign gpif_d = sloe ? gpif_data_out[31:0] : 32'bz;
    // T of an IOBUF is high for high impedance, so the tristate flip-flop holds ~sloe. The inversion
    // is logic in front of the ODDR (the tristate flip-flop has no usable input inverter).
    wire gpif_d_t_n = ~sloe_n;
    wire [31:0] gpif_d_i;           // pad -> IDDR
    wire [31:0] gpif_d_o;           // ODDR (copy of gpif_data_out) -> pad
    wire [31:0] gpif_d_t;           // ODDR (copy of ~sloe_r), one per pad -> T

    genvar gpif_bit;
    generate
      for (gpif_bit = 0; gpif_bit < 32; gpif_bit = gpif_bit + 1) begin : gpif_d_pad
        IOBUF iobuf
          (.IO(gpif_d[gpif_bit]), .I(gpif_d_o[gpif_bit]), .T(gpif_d_t[gpif_bit]), .O(gpif_d_i[gpif_bit]));
        IDDR #(.DDR_CLK_EDGE("SAME_EDGE"), .INIT_Q1(1'b0), .INIT_Q2(1'b0), .SRTYPE("SYNC")) iddr_data_in
          (.C(gpif_clk), .CE(gpif_data_in_ce), .R(1'b0), .S(1'b0),
           .D(gpif_d_i[gpif_bit]), .Q1(gpif_data_in[gpif_bit]), .Q2());
        ODDR #(.DDR_CLK_EDGE("SAME_EDGE"), .INIT(1'b0), .SRTYPE("SYNC")) oddr_data_out
          (.C(gpif_clk), .CE(1'b1), .R(1'b0), .S(1'b0),
           .D1(gpif_data_out_n[gpif_bit]), .D2(gpif_data_out_n[gpif_bit]), .Q(gpif_d_o[gpif_bit]));
        ODDR #(.DDR_CLK_EDGE("SAME_EDGE"), .INIT(1'b0), .SRTYPE("SYNC")) oddr_data_t
          (.C(gpif_clk), .CE(1'b1), .R(1'b0), .S(1'b0),
           .D1(gpif_d_t_n), .D2(gpif_d_t_n), .Q(gpif_d_t[gpif_bit]));
      end
    endgenerate

   // ////////////////////////////////////////////////////////////////////
   // GPIF bus master state machine

    wire wr_fifo_xfer, wr_fifo_eop;
    wire [31:0] wr_fifo_data;
    reg read_ready_go, write_ready_go;

    reg [3:0] state; //state machine current state
    localparam STATE_IDLE  = 0;
    localparam STATE_THINK = 1;
    localparam STATE_READ  = 2;
    localparam STATE_WRITE = 3;
    localparam STATE_WAIT = 4;
    localparam STATE_READ_FLUSH = 5;
    localparam STATE_WRITE_FLUSH = 6;
    localparam STATE_READ_SINGLE = 7;


    // General purpose pseudo-state counter.
    reg [2:0] idle_cycles;

    // Select next address (endpoint) to be processed
    reg [1:0] last_addr, next_addr;

    wire      local_fifo_ready;

    // Track size of a wriet burst to look for FX3 corner cases related to 2^n sized bursts.
    reg [15:0] transfer_size;


    always @(posedge gpif_clk)
     if (gpif_rst) begin
        slrd1 <= 1'b1;
        slrd2 <= 1'b1;
        slrd3 <= 1'b1;
        slrd4 <= 1'b1;
        slrd5 <= 1'b1;
     end else begin
        slrd1 <= slrd_r;
        slrd2 <= slrd1;
        slrd3 <= slrd2;
        slrd4 <= slrd3;
        slrd5 <= slrd4;
     end

   // End of packet pipeline for reads.
   reg 	rx_eop, rx_eop1, rx_eop2;

   // This pipeline tracks the end of a CHDR TX packet seperately from the local FIFO becoming full.
   // This is because a true packet end causes a tlast assertion to the FIFO, where as a full local FIFO only requires
   // the GPIF transaction to be ended before local FIFO overflow occurs.
    always @(posedge gpif_clk)
      if (gpif_rst) begin
        rx_eop1 <= 1;
        rx_eop2 <= 1;
      end else begin
        rx_eop2 <= rx_eop1;
        rx_eop1 <= rx_eop;
    end

   reg first_read;
   reg pad = 0;

   // //////////////////////////////////////////////////////////////
   // FX2 slave FIFO bus master state machine
   //
    // The state machine is written as its combinational half (the next value <reg>_n of every register
    // it owns, from the current registers) and a bank of registers. The body is the original clocked
    // block with each "<reg> <= value" rewritten as "<reg>_n = value": the last assignment still wins,
    // every read is of a current register, and a register nothing assigns keeps its value. The next
    // values exist as nets because the pad copies of the output registers (ODDRs, above) load them too.
    reg [3:0]  state_n;
    reg [2:0]  idle_cycles_n;
    reg        first_read_n;
    reg [1:0]  last_addr_n;
    reg        rx_eop_n;
    reg [15:0] transfer_size_n;
    reg        pad_n;

    always @*
    begin
        state_n = state;
        sloe_n = sloe_r;
        slrd_n = slrd_r;
        slwr_n = slwr_r;
        pktend_n = pktend_r;
        gpif_data_out_n = gpif_data_out;
        idle_cycles_n = idle_cycles;
        fifoadr_n = fifoadr_r;
        first_read_n = first_read;
        last_addr_n = last_addr;
        rx_eop_n = rx_eop;
        transfer_size_n = transfer_size;
        pad_n = pad;

    if(gpif_rst) begin
        state_n = STATE_IDLE;
        sloe_n = 1;
        slrd_n = 1;
        slwr_n = 1;
        pktend_n = 1;
        gpif_data_out_n = 32'b0;
        idle_cycles_n = 3'h0;
        fifoadr_n = 0;
        first_read_n = 1'b0;
        last_addr_n = 2'b0;
        rx_eop_n = 1'b0;
        transfer_size_n = 1;
        pad_n = 0;

    end
    else if (gpif_enb) begin
      case (state)

      //
      // Increment fifoadr to point at next thread, set all strobes to idle,
      //
        STATE_IDLE: begin
          sloe_n = 1;
          slrd_n = 1;
          slwr_n = 1;
          pktend_n = 1;
          gpif_data_out_n = 32'b0;
          fifoadr_n = next_addr;
          state_n = STATE_WAIT;
          idle_cycles_n = 3'h0;
       	  rx_eop_n = 1'b0;
          first_read_n = 1'b0;
        end

      //
      // If the current thread we are pointing at (fifoadr) can not immediately proceed
      // then quickly move to the next thread. Once we are pointing at a thread that can proceed locally
      // wait for 8 clock cycles to allow fifoadr to propogate to FX3, and corresponding flag state to
      // propogate back to FPGA and through resampling flops. At this point transition to STATE_THINK
      // to evaluate remote flag.
      //
        STATE_WAIT: begin
       // Current thread can proceed locally
          if (local_fifo_ready) begin
            idle_cycles_n = idle_cycles + 1'b1;
          if (idle_cycles == 3'b111) state_n = STATE_THINK; // Could shorten this delay, flags now stable for several clocks.
          end
       // ....move onto next thread.
          else begin
            idle_cycles_n = 3'b0;
            //fifoadr <= fifoadr + 2'b1;
            fifoadr_n = next_addr;

          end
        end

      //
      // Flags from FX3 now stable. Make a decision about what type of transaction to start.
      //
        STATE_THINK: begin
        // This is written like a priority encoder but in reality read_ready_go and
        // write_ready_go are mutually exclusive by design.
          if (fx3_ready1 && fx3_wmark1 && read_ready_go) begin
            state_n = STATE_READ;
            slrd_n = 0;
            rx_eop_n = 1'b0;
            first_read_n = 1'b1; // Set unconditional read flag to kick off transaction
            sloe_n = 0; // FX3 drives the data bus.
          end else if (fx3_ready1 && ~fx3_wmark1 && read_ready_go) begin
            state_n = STATE_READ_SINGLE;
            slrd_n = 0;
            sloe_n = 0; // FX3 drives the data bus.
          end else if (fx3_ready1 && write_ready_go && wr_fifo_eop && (transfer_size[7:0] == 0)) begin // remember that write_ready_go shows 1 cycle old status.
            // If an exact multiple of the native USB packet size (1K USB3, 512B USB2) has been transfered
            // and TLAST is asserted (but the transfer is less than a full FX3 DMA buffer - this is
            // indicated when the watermark will terminate the transfer in this case) then we will pad the packet
            // for one more cycle to ensure it does not get stuck in the FX3.
            pktend_n = 1'b1; // Active low - De-asserted
            slwr_n = 1'b0; //Active low - Asserted, write to FX3.
            transfer_size_n = transfer_size + 1; // Increment transfer_size.
            gpif_data_out_n = wr_fifo_data; // Always latch data from FIFO's into output register
            pad_n = 1;
          end else if ((fx3_ready1 && write_ready_go && wr_fifo_eop) | pad) begin  // remember that write_ready_go shows 1 cycle old status.
            // Its the end of a CHDR packet and we are not on a FX3 corner case size.
            // Go IDLE with pktend and slwr asserted to write the last data.
            pktend_n = 1'b0; // Active low - Asserted,
            state_n = STATE_WRITE_FLUSH;
            idle_cycles_n = 3'd5; // Stay in flush 3 cycles
            slwr_n = 1'b0; // Active low - Asserted, write to FX3
            transfer_size_n = 1; // End of packet will release FX3 DMA buffer, reset transfer size count.
            gpif_data_out_n = wr_fifo_data; // Always latch data from FIFO's into output register
            pad_n = 0; // Reset pad
          end else if (fx3_ready1 && write_ready_go) begin // remember that write_ready_go shows 1 cycle old status.
           // There is (an unknown amount of) data ready to send to FX from local FIFO.
            state_n = STATE_WRITE;
            slwr_n = 1'b0;  // Active low - Write strobe active
            gpif_data_out_n = wr_fifo_data; // Always latch data from FIFO's into output register
            transfer_size_n = transfer_size + 1; // Account for current cycles transfer
          end
          else begin
            state_n = STATE_IDLE;
          end

            idle_cycles_n = 3'h0;
            last_addr_n = fifoadr_r;
        end // case: STATE_THINK

      // Got here because READY flag asserted but watermark deaaserted...QED there's less than the watermarks
      // worth of data to read from FX remaining in this DMA page. Need to do that with single beat reads
      // followed by rechecking the READY flag to see if it deassserted indicating that the page emptied.
      // Since we have the read data from FX3 earlier than we have a flag to inspect we keep the data in
      // gpif_data_in until we know if we are commiting it to the FIFO with or without an asserted TLAST.
      //
      STATE_READ_SINGLE: begin
        if (idle_cycles == 0) begin
    	// Deassert read strobe after reading single 32bit word
          slrd_n = 1'b1;
          idle_cycles_n = idle_cycles + 1;
	      end else if (idle_cycles == 5) begin
		// READY1 flag now reflect effects of last read.
        if (!fx3_ready1) begin
           state_n = STATE_IDLE;
           sloe_n = 1'b1;
        end else begin
        // Initiate another READ beat.
           state_n = STATE_READ_SINGLE;
           slrd_n = 1'b0;
        end
        idle_cycles_n = 0;
        end else begin
          // All other idle_cycles counts.
          idle_cycles_n = idle_cycles + 1;
        end
      end // case: STATE_READ_SINGLE


      // If flag first_read and ~slrd3 have gone deasserted
      // (meaning that the watermark deasserted 5 clock cycles ago or local FIFO full) transition to STATE_IDLE.
      // If watermark deasserted 2 cycles ago de-assert slrd ...read data is still traveling in the pipeline.
      // Whilst ~slrd3 stays asserted keep the first_read flag armed.
      // Trigger TLAST only for transfer ended by watermark (Which indicates a true packet end), not local full FIFO.
      STATE_READ: begin

        if (~fx3_wmark1 | fifo_nearly_full) begin
          // Either end of packet or local FIFO full is imminent, start shutting down this read burst.
          slrd_n = 1'b1;  // Active low - Take read strobe inactive
          state_n = STATE_READ_FLUSH;
        end else begin
           slrd_n = 1'b0; // Active low - Keep read strobe active.
        end

        if (~fx3_wmark1)
          // Put TLAST into pipeline to mark end of packet
          rx_eop_n = 1'b1;

        if (~slrd3)
          // Reset first_read flag as slrd assertion progresses down pipeline
         first_read_n = 1'b0;
      end // case: STATE_READ

      // SLRD has been deasserted but data continues to flow from FX3 into FPGA until pipeline empties.
      STATE_READ_FLUSH: begin
        slrd_n = 1'b1; // Active low - Keep read strobe inactive.
        rx_eop_n = 1'b0; // EOP indication can be reset now - Already traveling in the pipeline if it was active.
        if (~slrd3)
          // Reset first_read flag as slrd assertion progresses down pipeline
          first_read_n = 1'b0;
        if (!first_read && slrd3) begin // Active low signal
          // Last data of burst will be written to FIFO next clock edge so transition to IDLE also.
          state_n = STATE_IDLE;
          sloe_n = 1'b1; // Active low - Resume parking bus with FPGA driving.
        end
      end


      // Now in potential write burst. Exit this sate immediately if we are only doing a single beat write.
      // Can exit this state in several ways:
      // At EOP and on a USB packet boundery (1K for USB3, 512B for USB2) must pad packet for 1 clock cycle in
      // addition to simply asserting pktend.
      // Otherwise at EOP just send a short packet.
      // If local FIFO goes empty then we terminatethe burst without asserting pktend.
      STATE_WRITE: begin
        if (wr_fifo_eop && wr_fifo_xfer && (transfer_size[7:0] == 0)) begin

          // If an exact multiple of the native USB packet size (1K USB3, 512B USB2) has been transfered
          // and TLAST is asserted (but the transfer is less than a full FX3 DMA buffer - this is
          // indicated when the watermark will terminate the transfer in this case) then we will pad the packet
          // for one more cycle to ensure it does not get stuck in the FX3.
          pktend_n = 1'b1; // Active low - De-asserted,
          slwr_n = 1'b0; // Active low - Asserted, write to FX3
          transfer_size_n = transfer_size + 1; // Increment transfer_size.
          pad_n = 1;
       end else if ((wr_fifo_eop && wr_fifo_xfer) | pad) begin
          // Its the end of a CHDR packet and we are not on a FX3 corner case size.
          // Go IDLE with pktend and slwr asserted to write the last data.
          pktend_n = 1'b0; // Active low - Asserted,
          state_n = STATE_WRITE_FLUSH;
          idle_cycles_n = 3'd5; // Stay in flush 3 cycles
          slwr_n = 1'b0; // Active low - Asserted, write to FX3
          transfer_size_n = 1; // End of packet will release FX3 DMA buffer, reset transfer size count.
          pad_n = 0; //Reset pad
       end else if (wr_fifo_xfer) begin
          // Regular write beat as part of a burst.
          pktend_n = 1'b1; // Active low - De-asserted,
          slwr_n = 1'b0; // Active low - Asserted, write to FX3
          transfer_size_n = transfer_size + 1; // Account for current cycles transfer
       end else begin // Implicit if (~wr_fifo_xfer)
          // This was either a single beat write (watermark was never asserted)
          // or the water mark just deasserted or we ran out of local data to send.
          // slwr will be deasserted and we transition to the flush state.
          state_n = STATE_WRITE_FLUSH;
          idle_cycles_n = 3'd6; // Stay in flush 2 cycles.
          pktend_n = 1'b1; // Active low - De-asserted,
          slwr_n = 1'b1; // Active low - Deasserted, don't write to FX3
       end

        gpif_data_out_n = wr_fifo_data; // Always latch data from FIFO's into output register

       end // case: STATE_WRITE

      // Some FX3 timing diagrams seem to imply address should be held stable after transaction
      STATE_WRITE_FLUSH: begin
        slrd_n = 1;
        slwr_n = 1;
        pktend_n = 1;
        gpif_data_out_n = 32'b0;
        idle_cycles_n = idle_cycles + 1'b1;
        if (idle_cycles == 3'b111) begin
          state_n = STATE_IDLE;
        end
      end


        default: state_n = STATE_IDLE;
        endcase
    end
    end

    always @(posedge gpif_clk) begin
        state <= state_n;
        sloe_r <= sloe_n;
        slrd_r <= slrd_n;
        slwr_r <= slwr_n;
        pktend_r <= pktend_n;
        gpif_data_out <= gpif_data_out_n;
        idle_cycles <= idle_cycles_n;
        fifoadr_r <= fifoadr_n;
        first_read <= first_read_n;
        last_addr <= last_addr_n;
        rx_eop <= rx_eop_n;
        transfer_size <= transfer_size_n;
        pad <= pad_n;
    end

   // ///////////////////////////////////////////////////////////////////
   // fifo signal assignments and enables

    //output from fifos - ready to xfer
    wire data_tx_tready, ctrl_tx_tready;
    wire ctrl_rx_tvalid, data_rx_tvalid;

    //Priority encoding for the the next address to service:
    //The next address to service is based on the readiness
    //of the internal fifos and last serviced fairness metric.

   //always @(posedge gpif_clk) next_addr <= (fifoadr + 2'b1);

   // Sequence addresses 0->2->1->3->0......
   always @(posedge gpif_clk) {next_addr[0],next_addr[1]} <= ({fifoadr_r[0],fifoadr_r[1]} + 2'b1);

    //Help the FPGA search to only look for addrs that the FPGA is ready for
    assign local_fifo_ready =
        (ctrl_rx_tvalid && (fifoadr_r == ADDR_CTRL_RX)) ||
        (ctrl_tx_fifo_has_space && (fifoadr_r == ADDR_CTRL_TX)) ||
        (data_rx_tvalid && (fifoadr_r == ADDR_DATA_RX)) ||
        (data_tx_fifo_has_space && (fifoadr_r == ADDR_DATA_TX));

    // Local TX FIFO imminantly about to fill.
    always @(posedge gpif_clk) fifo_nearly_full <=
        (ctrl_tx_fifo_nearly_full && (fifoadr_r == ADDR_CTRL_TX)) ||
        (data_tx_fifo_nearly_full && (fifoadr_r == ADDR_DATA_TX));

    // There is enough space in local FIFO to RX an entire CHDR packet (sized for channel type)
    always @(posedge gpif_clk) read_ready_go <=
        (ctrl_tx_fifo_has_space && (fifoadr_r == ADDR_CTRL_TX)) ||
        (data_tx_fifo_has_space && (fifoadr_r == ADDR_DATA_TX));

    // The is data waiting to be sent to FX3 in local FIFO's
    always @(posedge gpif_clk) write_ready_go <=
        (ctrl_rx_tvalid && (fifoadr_r == ADDR_CTRL_RX)) ||
        (data_rx_tvalid && (fifoadr_r == ADDR_DATA_RX));

    //fifo xfer enable
    wire data_rx_tready = (
               ((state == STATE_WRITE) && fx3_wmark1 && ~pad) || // Sustain burst
               ((state == STATE_THINK) && fx3_ready1)    // First beat
               ) && (fifoadr_r == ADDR_DATA_RX) ;

    wire ctrl_rx_tready = (
               ((state == STATE_WRITE) && fx3_wmark1) || // Sustain burst
               ((state == STATE_THINK) && fx3_ready1)    // First beat
               ) && (fifoadr_r == ADDR_CTRL_RX) ;

    // Burst reads tap the read strobe pipeline at stage3, single beat reads at stage5.
    wire data_tx_tvalid = (
               (((state == STATE_READ) || (state == STATE_READ_FLUSH)) && ~slrd3) |
               ((state == STATE_READ_SINGLE) && ~slrd5)
               ) && (fifoadr_r == ADDR_DATA_TX);
    wire ctrl_tx_tvalid = (
               (((state == STATE_READ) || (state == STATE_READ_FLUSH)) && ~slrd3) |
               ((state == STATE_READ_SINGLE) && ~slrd5)
               ) && (fifoadr_r == ADDR_CTRL_TX);

    // The position of RX TLAST is known well in advance for bursts by monitoring the watermark. However for
    // single beat reads it can only be deduced after a read that causes the ready flag to go inactive.
    wire  data_ctrl_tx_tlast = ((state == STATE_READ_FLUSH) && rx_eop2) || ((state == STATE_READ_SINGLE) && ~fx3_ready1);


    //outputs from rx fifo paths
    wire ctrl_rx_tlast, data_rx_tlast;
    wire [31:0] ctrl_rx_tdata, data_rx_tdata;

    // There will be a RX FIFO transaction this cycle
    assign wr_fifo_xfer = (fifoadr_r == ADDR_CTRL_RX)? (ctrl_rx_tvalid && ctrl_rx_tready) : (data_rx_tvalid && data_rx_tready);
    // The RX FIFO transaction this cycle has TLAST set
    assign wr_fifo_eop =  (fifoadr_r == ADDR_CTRL_RX)? ctrl_rx_tlast : data_rx_tlast;
    // Route data from addressed RX FIFO towards FX3
    assign wr_fifo_data = (fifoadr_r == ADDR_CTRL_RX)? ctrl_rx_tdata : data_rx_tdata;

    wire ctrl_bus_error, tx_bus_error;

   // ////////////////////////////////////////////////////////////////////
   // TX Data Path
   wire [31:0] debug_data_fifo;

    gpif2_to_fifo64 #(.FIFO_SIZE(DATA_TX_FIFO_SIZE)) gpif2_to_fifo64_tx(
        .gpif_clk(gpif_clk), .gpif_rst(gpif_rst),
        .i_tdata(gpif_data_in), .i_tlast(data_ctrl_tx_tlast), .i_tvalid(data_tx_tvalid), .i_tready(data_tx_tready), // IJB. NOTE data_tx_tready currently unused.
        .fifo_clk(fifo_clk), .fifo_rst(fifo_rst),
        .fifo_nearly_full(data_tx_fifo_nearly_full), .fifo_has_space(data_tx_fifo_has_space),
        .o_tdata(tx_tdata), .o_tlast(tx_tlast), .o_tvalid(tx_tvalid), .o_tready(tx_tready),
        .bus_error(tx_bus_error), .debug(debug_data_fifo)
    );

   // ////////////////////////////////////////////
   // RX Data Path

    fifo64_to_gpif2 #(.FIFO_SIZE(DATA_RX_FIFO_SIZE)) fifo64_to_gpif2_rx(
        .fifo_clk(fifo_clk), .fifo_rst(fifo_rst),
        .i_tdata(rx_tdata), .i_tlast(rx_tlast), .i_tvalid(rx_tvalid), .i_tready(rx_tready),
        .gpif_clk(gpif_clk), .gpif_rst(gpif_rst),
        .o_tdata(data_rx_tdata), .o_tlast(data_rx_tlast), .o_tvalid(data_rx_tvalid), .o_tready(data_rx_tready)
    );

    // ////////////////////////////////////////////////////////////////////
    // CTRL path
    wire [31:0] debug_ctrl_fifo;

    gpif2_to_fifo64 #(.FIFO_SIZE(CTRL_TX_FIFO_SIZE)) gpif2_to_fifo64_ctrl(
        .gpif_clk(gpif_clk), .gpif_rst(gpif_rst),
        .i_tdata(gpif_data_in), .i_tlast(data_ctrl_tx_tlast), .i_tvalid(ctrl_tx_tvalid), .i_tready(ctrl_tx_tready), // IJB. NOTE data_tx_tready currently unused.
        .fifo_clk(fifo_clk), .fifo_rst(fifo_rst),
        .fifo_nearly_full(ctrl_tx_fifo_nearly_full), .fifo_has_space(ctrl_tx_fifo_has_space),
        .o_tdata(ctrl_tdata), .o_tlast(ctrl_tlast), .o_tvalid(ctrl_tvalid), .o_tready(ctrl_tready),
        .bus_error(ctrl_bus_error), .debug(debug_ctrl_fifo)
    );

   // ////////////////////////////////////////////////////////////////////
   // RESP path

    fifo64_to_gpif2 #(.FIFO_SIZE(CTRL_RX_FIFO_SIZE)) fifo64_to_gpif2_resp(
        .fifo_clk(fifo_clk), .fifo_rst(fifo_rst),
        .i_tdata(resp_tdata), .i_tlast(resp_tlast), .i_tvalid(resp_tvalid), .i_tready(resp_tready),
        .gpif_clk(gpif_clk), .gpif_rst(gpif_rst),
        .o_tdata(ctrl_rx_tdata), .o_tlast(ctrl_rx_tlast), .o_tvalid(ctrl_rx_tvalid), .o_tready(ctrl_rx_tready)
    );




endmodule // gpif2_slave_fifo32
