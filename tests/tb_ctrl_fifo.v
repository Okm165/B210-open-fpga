// tb_ctrl_fifo.v - the CONTROL path through the FX3 slave-FIFO interface.
//
// Every other GPIF bench either ties ctrl_tvalid to 0 (tb_usb_rate,
// tb_e2e_rx) or benches the ABI above the FIFO (tb_ctrl_abi).  This bench
// closes exactly that gap: a control packet enters through the GPIF
// waveforms (thread CTRL_TX), crosses to the fifo domain, and a response
// packet leaves through the resp stream and the GPIF waveforms (thread
// CTRL_RX, with PKTEND).  gpif_clk and fifo_clk run at different phases,
// so the CDC in both directions is under test too.
//
// Conventions under test (read from the RTL, not assumed):
//   axi_fifo32_to_fifo64:  first 32-bit word -> HIGH half of the 64-bit beat
//   fifo64_to_gpif2:       HIGH half out first, then low half
//   watermark drop         marks end of packet on burst reads (tlast)
//   PKTEND (active low)    ends an FPGA->FX3 transfer

`timescale 1ns/1ps

module tb_ctrl_fifo;

   localparam ADDR_DATA_TX = 2'b00, ADDR_DATA_RX = 2'b01,
              ADDR_CTRL_TX = 2'b10, ADDR_CTRL_RX = 2'b11;

   reg clk = 0, clk2 = 0, rst = 1;
   always #5   clk  = ~clk;     // 100 MHz gpif_clk
   always #5.3 clk2 = ~clk2;    // 100 MHz fifo_clk, different phase

   wire [31:0] gpif_d;
   reg  [3:0]  gpif_ctl = 4'b0000;   // bit0 = ready flag, bit1 = watermark (b200.v maps CTL4,5)
   wire        slwr, sloe, slcs, slrd, pktend;
   wire [1:0]  fifoadr;

   // ---- control packet the FX3 delivers to the FPGA (peek32-shaped) ----
   localparam NW = 4;
   reg [31:0] cpkt [0:NW-1];
   integer ci;

   // ---- response packet the FPGA returns ----
   localparam RW = 4;                       // 2 beats of 64 bits
   reg [63:0] rbeat [0:RW/2-1];

   wire [63:0] tx_tdata, rx_tdata, ctrl_tdata;
   wire tx_tlast, rx_tlast, ctrl_tlast;
   wire tx_tvalid, rx_tvalid, ctrl_tvalid;
   // resp stream is an input: driven from regs
   reg  [63:0] resp_tdata = 0;
   reg         resp_tlast = 0, resp_tvalid = 0;
   reg  tx_tready = 1'b1, ctrl_tready = 1'b1;   // DUT inputs
   wire rx_tready, resp_tready;                 // DUT outputs (FIFO flow control)

   gpif2_slave_fifo32 #(.DATA_RX_FIFO_SIZE(13), .DATA_TX_FIFO_SIZE(13))
     dut (.gpif_clk(clk), .gpif_rst(rst), .gpif_enb(1'b1),
          .gpif_d(gpif_d), .gpif_ctl(gpif_ctl), .fifoadr(fifoadr),
          .slwr(slwr), .sloe(sloe), .slcs(slcs), .slrd(slrd), .pktend(pktend),
          .fifo_clk(clk2), .fifo_rst(rst),
          .tx_tdata(tx_tdata), .tx_tlast(tx_tlast), .tx_tvalid(tx_tvalid), .tx_tready(tx_tready),
          .rx_tdata(rx_tdata), .rx_tlast(rx_tlast), .rx_tvalid(rx_tvalid), .rx_tready(rx_tready),
          .ctrl_tdata(ctrl_tdata), .ctrl_tlast(ctrl_tlast), .ctrl_tvalid(ctrl_tvalid), .ctrl_tready(ctrl_tready),
          .resp_tdata(resp_tdata), .resp_tlast(resp_tlast), .resp_tvalid(resp_tvalid), .resp_tready(resp_tready),
          .debug());

   // ---------------- FX3 model ------------------------------------------
   // The FX3 multiplexes its flags by the thread address the FPGA presents.
   reg [31:0] fx3_word;
   reg        fx3_drive = 0;
   integer    ridx = 0;                     // resp words captured
   reg [31:0] rwords [0:15];
   integer    rpktend = 0;

   // flags per thread
   always @(posedge clk) if (!rst) begin
      case (fifoadr)
        ADDR_CTRL_TX: begin
           gpif_ctl[0] <= 1'b1;                       // ready: ctrl packet waiting
           gpif_ctl[1] <= (ci < NW-1);                // watermark: drops on last word
        end
        ADDR_CTRL_RX: begin gpif_ctl[0] <= 1'b1; gpif_ctl[1] <= 1'b1; end
        default:      begin gpif_ctl[0] <= 1'b0; gpif_ctl[1] <= 1'b0; end
      endcase
   end

   // FX3 drives the bus only while the FPGA is reading (sloe low)
   always @(negedge clk) fx3_drive <= (sloe === 1'b0);
   assign gpif_d = fx3_drive ? fx3_word : 32'bz;

   reg slrd_d1 = 1, slrd_d2 = 1;
   always @(posedge clk) begin slrd_d1 <= slrd; slrd_d2 <= slrd_d1; end
   // present next ctrl word on each read the DUT actually captures (~slrd2);
   // capture resp words on write strobe
   always @(posedge clk) if (!rst) begin
      if (fifoadr == ADDR_CTRL_TX && !slrd_d2) begin
         fx3_word <= (ci+1 < NW) ? cpkt[ci+1] : fx3_word;
         ci <= (ci < NW) ? ci + 1 : ci;
      end
      if (fifoadr == ADDR_CTRL_RX && slwr === 1'b0) begin
         rwords[ridx] <= gpif_d;
         ridx <= ridx + 1;
      end
      if (fifoadr == ADDR_CTRL_RX && pktend === 1'b0) rpktend <= rpktend + 1;
   end

   // resp source: 2 beats, then hold
   // AXI-proper source: data/tlast update in the SAME edge as the handshake,
   // so a consumed beat is never re-offered with tvalid high.
   integer rbi = 0;
   always @(posedge clk2) if (!rst) begin
      if (rbi < RW/2) begin
         resp_tvalid <= 1'b1;
         resp_tlast  <= (rbi == RW/2-1);
         if (resp_tvalid && resp_tready) begin
            rbi        <= rbi + 1;
            resp_tdata <= (rbi+1 < RW/2) ? rbeat[rbi+1] : resp_tdata;
         end else if (!resp_tvalid || resp_tdata !== rbeat[rbi]) begin
            resp_tdata <= rbeat[rbi];
         end
      end else if (rbi == RW/2) begin
         resp_tvalid <= 1'b0;
         resp_tlast  <= 1'b0;
         rbi         <= rbi + 1;
      end
   end

   // ---------------- ctrl sink ------------------------------------------
   integer cidx = 0, cerrors = 0;
   reg [63:0] cbeats [0:NW/2-1];
   reg        cdone = 0;
   always @(posedge clk2) if (!rst) begin
      if (ctrl_tvalid && ctrl_tready && !cdone) begin
         cbeats[cidx] <= ctrl_tdata;
         if (ctrl_tlast && cidx != NW/2-1) begin
            cerrors <= cerrors + 1;
            $display("CTRL-FIFO: FAIL tlast after beat %0d", cidx);
         end
         if (!ctrl_tlast && cidx == NW/2-1) begin
            cerrors <= cerrors + 1;
            $display("CTRL-FIFO: FAIL missing tlast");
         end
         cidx <= cidx + 1;
         if (ctrl_tlast) cdone <= 1'b1;
      end
   end

   wire ctrl_bus_error = dut.gpif2_to_fifo64_ctrl.bus_error;

`ifdef TRACE
   always @(posedge clk) if (!rst && fifoadr == ADDR_CTRL_RX)
     if (slwr === 1'b0 || dut.ctrl_rx_tvalid)
       $display("%0t gpif: slwr=%b pktend=%b state=%0d bus=%h wdata=%h tv=%b tt=%b xfer=%b",
                $time, slwr, pktend, dut.state, gpif_d, dut.ctrl_rx_tdata,
                dut.ctrl_rx_tvalid, dut.ctrl_rx_tlast, dut.wr_fifo_xfer);
   always @(posedge clk2) if (!rst && (resp_tvalid || rbi > 0))
     $display("%0t fifo: tv=%b tt=%b td=%h rdy=%b rbi=%0d",
              $time, resp_tvalid, resp_tlast, resp_tdata, resp_tready, rbi);
   always @(posedge clk) if (!rst && fifoadr == ADDR_CTRL_TX)
     $display("%0t tx: st=%0d slrd=%b wmark=%b ready=%b word=%h cin=%h tv=%b tr=%b ci=%0d",
              $time, dut.state, slrd, dut.fx3_wmark1, dut.fx3_ready1, fx3_word,
              dut.gpif_data_in, dut.ctrl_tx_tvalid, dut.gpif2_to_fifo64_ctrl.i_tready, ci);
   always @(posedge clk2) if (!rst && dut.gpif2_to_fifo64_ctrl.chk_tvalid)
     $display("%0t chk: td=%h tt=%b rdy=%b err=%b",
              $time, dut.gpif2_to_fifo64_ctrl.chk_tdata, dut.gpif2_to_fifo64_ctrl.chk_tlast,
              dut.gpif2_to_fifo64_ctrl.chk_tready, dut.ctrl_bus_error);
   reg [31:0] seqw [0:63]; integer nwr = 0, nrd = 0;
   always @(posedge clk2) if (!rst && dut.fifo64_to_gpif2_resp.i32_tvalid && dut.fifo64_to_gpif2_resp.i32_tready) begin
      seqw[nwr] <= dut.fifo64_to_gpif2_resp.i32_tdata; nwr <= nwr + 1;
      $display("%0t SPLIT-W %0d = %h tt=%b", $time, nwr, dut.fifo64_to_gpif2_resp.i32_tdata, dut.fifo64_to_gpif2_resp.i32_tlast);
   end
   always @(posedge clk) if (!rst && dut.fifo64_to_gpif2_resp.gate_tvalid && dut.fifo64_to_gpif2_resp.gate_tready) begin
      if (nrd < nwr + 8) begin
         if (nrd >= nwr || seqw[nrd] !== dut.fifo64_to_gpif2_resp.gate_tdata)
           $display("%0t MISMATCH read%0d=%h written%0d=%h (nwr=%0d)",
                    $time, nrd, dut.fifo64_to_gpif2_resp.gate_tdata,
                    (nrd<nwr)?nrd:0, (nrd<nwr)?seqw[nrd]:32'hx, nwr);
      end
      $display("%0t GATE-R  %0d = %h", $time, nrd, dut.fifo64_to_gpif2_resp.gate_tdata);
      nrd <= nrd + 1;
   end
`endif

   integer errors = 0, i;
   reg [31:0] exp;
   // the control packet is a REAL untimed write, exactly as tb_ctrl_abi
   // drives it (request header + addr/data payload), split into GPIF words
   // high half first.
   localparam [63:0] REQ_HDR = {1'b1, 1'b0, 1'b0, 1'b0, 12'h5A5, 16'h0010, 32'h40};
   localparam [63:0] REQ_PAY = {16'h0, 8'd24, 32'hDEADBEEF};
   // the response is the real response header + a readback word
   localparam [63:0] RSP_HDR = {4'hA, 12'h5A5, 16'd24, 32'h40};
   localparam [63:0] RSP_PAY = 64'hDEADBEEFCAFEBABE;

   initial begin
      cpkt[0] = REQ_HDR[63:32]; cpkt[1] = REQ_HDR[31:0];
      cpkt[2] = REQ_PAY[63:32]; cpkt[3] = REQ_PAY[31:0];
      for (i = 0; i < NW/2; i = i + 1) cbeats[i] = 64'hx;
      rbeat[0] = RSP_HDR; rbeat[1] = RSP_PAY;
      ci = 0;
      fx3_word = cpkt[0];
      repeat (20) @(posedge clk);
      rst <= 0;
      // release the resp packet once the machine is running
      repeat (200) @(posedge clk);
      // wait for both directions to complete
      repeat (5000) @(posedge clk);

      // ---- checks ----
      for (i = 0; i < NW/2; i = i + 1) begin
         if (cbeats[i] !== {cpkt[2*i], cpkt[2*i+1]}) begin
            cerrors <= cerrors + 1;
            $display("CTRL-FIFO: FAIL ctrl beat %0d = %h, expected %h",
                     i, cbeats[i], {cpkt[2*i], cpkt[2*i+1]});
         end
      end
      if (cidx < NW/2) begin
         errors = errors + 1;
         $display("CTRL-FIFO: FAIL only %0d ctrl beats arrived", cidx);
      end
      errors = errors + cerrors;
      // high half of each beat goes on the GPIF first (read from the RTL:
      // axi_fifo64_to_fifo32 emits i_tdata[63:32] in state 0)
      for (i = 0; i < RW; i = i + 1) begin
         if (ridx > i) begin
            exp = (i % 2 == 0) ? rbeat[i/2][63:32] : rbeat[i/2][31:0];
            if (rwords[i] !== exp) begin
               errors = errors + 1;
               $display("CTRL-FIFO: FAIL resp word %0d = %h, expected %h", i, rwords[i], exp);
            end
         end
      end
      if (ridx != RW) begin
         errors = errors + 1;
         $display("CTRL-FIFO: FAIL %0d resp words captured, expected %0d", ridx, RW);
      end
      if (rpktend != 1) begin
         errors = errors + 1;
         $display("CTRL-FIFO: FAIL %0d PKTEND pulses, expected exactly 1", rpktend);
      end
      if (ctrl_bus_error !== 1'b0) begin
         errors = errors + 1;
         $display("CTRL-FIFO: FAIL ctrl bus_error asserted");
      end

      if (errors == 0)
        $display("PASS: ctrl path through the FX3 interface (%0d ctrl words in, %0d resp words out, 1 PKTEND, no bus error)", NW, ridx);
      else
        $display("FAIL: ctrl path, %0d errors", errors);
      $finish;
   end
endmodule
