`timescale 1ns / 1ps

// pps_switch.v
module pps_switch (
    input  wire        clk,          // 系统时钟（≥10 MHz 推荐）
    input  wire        rst_n,        // 低电平有效异步复位
    input  wire        gps_pps,      // GPS_PPS 输入
    input  wire        ext_pps,      // EXT_PPS 输入
    output reg         pps_out       // 最终输出的PPS脉冲
);

    // 跟踪当前激活的PPS源
    reg active_pps_source;  // 0=GPS, 1=EXT
    
    // 边沿检测：上升沿产生一个时钟周期的高脉冲
    wire gps_posedge;
    wire ext_posedge;

    edge_detect u_gps_edge (
        .clk(clk),
        .rst_n(rst_n),
        .din(gps_pps),
        .dout(gps_posedge)
    );

    edge_detect u_ext_edge (
        .clk(clk),
        .rst_n(rst_n),
        .din(ext_pps),
        .dout(ext_posedge)
    );

    // 状态机：0=等待GPS，1=等待EXT
    reg [1:0] state;
    localparam S_GPS = 2'b00;
    localparam S_EXT = 2'b01;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state   <= S_GPS;
            active_pps_source <= 1'b0;  // 默认GPS
        end 
        else begin
            case (state)
                S_GPS: begin
                    if (gps_posedge) begin
                        state   <= S_GPS; // 保持GPS优先
                        active_pps_source <= 1'b0;  // 激活GPS
                    end else if (ext_posedge) begin
                        state   <= S_GPS; // 仍保持GPS优先，但允许EXT临时补位
                        active_pps_source <= 1'b1;  // 激活EXT
                    end
                end
                default: begin  // 简化处理，实际应用中可扩展状态机
                    if (ext_posedge) begin
                        state   <= S_GPS; // 回到GPS等待
                        active_pps_source <= 1'b1;  // 激活EXT
                    end
                end
            endcase
        end
    end

    // 输出逻辑
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            pps_out <= 1'b0;
        else 
            pps_out <= active_pps_source ? ext_pps : gps_pps;
    end

endmodule