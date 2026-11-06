`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2025/07/03 01:29:39
// Design Name: 
// Module Name: edge_detect
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


// 边沿检测子模块
    module edge_detect (
        input  wire clk,
        input  wire rst_n,
        input  wire din,
        output wire  dout
    );
        reg din_d1, din_d2;
        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                din_d1 <= 1'b0;
                din_d2 <= 1'b0;
            end else begin
                din_d1 <= din;
                din_d2 <= din_d1;
            end
        end
        assign dout = din_d1 & ~din_d2; // 上升沿
    endmodule


