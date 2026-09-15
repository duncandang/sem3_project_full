`define FPGA
// ============================================================================
// Module Name: top_fpga
// Target Board: Digilent Basys 3 (Xilinx Artix-7 XC7A35T-1CPG236C)
// Description: FPGA Top Wrapper for MAX30102 PPG ASIC (top_module)
// ============================================================================

`timescale 1ns / 1ps

module top_fpga (
    input  wire        clk,        // 100 MHz onboard oscillator (Pin W5)
    input  wire        rst_n,      // Active-low reset button (Pin U18)
    
    // I2C Interface for MAX30102 Sensor (Pmod Header JA)
    inout  wire        i2c_sda,    // Serial Data Line (Pin J1)
    output wire        i2c_scl,    // Serial Clock Line (Pin J2)
    
    // USB-UART Interface (FT2232H)
    output wire        uart_tx,    // FPGA TX -> PC RX (Pin A18)
    
    // Onboard Status LEDs
    output wire [15:0] led         // 16 Onboard LEDs (U16 to L1)
);

    // ------------------------------------------------------------------------
    // Clock Divider: 100 MHz -> 10 MHz System Clock
    // ------------------------------------------------------------------------
    reg [2:0] cnt_10m = 3'd0;
    reg       clk_10m_reg = 1'b0;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt_10m     <= 3'd0;
            clk_10m_reg <= 1'b0;
        end else begin
            if (cnt_10m == 3'd4) begin
                cnt_10m     <= 3'd0;
                clk_10m_reg <= ~clk_10m_reg;
            end else begin
                cnt_10m <= cnt_10m + 3'd1;
            end
        end
    end
    
    wire clk_10mhz = clk_10m_reg;

    // ------------------------------------------------------------------------
    // ASIC Core Instantiation (top_module)
    // Matching exact port names in top_module-v5.v: clk, rst_n, scl, sda, uart_txd, led
    // ------------------------------------------------------------------------
    wire [2:0] diag_leds;

    top_module u_top_core (
        .clk      (clk_10mhz),
        .rst_n    (rst_n),
        .scl      (i2c_scl),
        .sda      (i2c_sda),
        .uart_txd (uart_tx)
`ifdef FPGA
        ,
        .led      (diag_leds)
`endif
    );

    // ------------------------------------------------------------------------
    // LED Status Mapping
    // ------------------------------------------------------------------------
    assign led[0]    = diag_leds[0]; // Blinks on sample acquisition
    assign led[1]    = diag_leds[1]; // Active during UART transmission
    assign led[2]    = diag_leds[2]; // Active on I2C error
    assign led[15:3] = 13'b0;

endmodule
