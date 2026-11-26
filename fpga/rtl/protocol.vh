// SPDX-License-Identifier: GPL-3.0-or-later
//
// protocol.vh - the packet constants of docs/PROTOCOL.md 2, shared by every
// block that builds or checks a packet header (command, events, rx_framer,
// tx_deframer). Included inside a module body: `include "protocol.vh".
//
// Header word 0: version [31:28], channels [27:24], format [23:20],
// type [19:16], length [15:0]. Header word 1: flags [19:16], sequence [15:0].

// protocol version, header word 0 bits 31:28
localparam [3:0] VERSION   = 4'd1;
// packet types, header word 0 bits 19:16
localparam [3:0] T_RX      = 4'd0;
localparam [3:0] T_TX      = 4'd1;
localparam [3:0] T_COMMAND = 4'd2;
localparam [3:0] T_RESULT  = 4'd3;
localparam [3:0] T_EVENT   = 4'd4;
// flag bit positions in header word 1
localparam integer HAS_TIME       = 16;   // words 2-3 are valid
localparam integer START_OF_BURST = 17;
localparam integer END_OF_BURST   = 18;
localparam integer OVERFLOW       = 19;   // rx samples were dropped before this packet
