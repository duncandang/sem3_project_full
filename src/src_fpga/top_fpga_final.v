// ============================================================================
// Module Name: top_fpga
// Target Board: Digilent Basys 3 (Xilinx Artix-7 XC7A35T-1CPG236C)
// Project: MAX30102 Pulse Oximeter & PPG Filter System (Sem3 Project)
// ============================================================================

`timescale 1ns / 1ps

module top_fpga (
    input  wire        clk,        // 100 MHz onboard clock (Pin W5)
    input  wire        rst_n,      // Button U18 (High when pressed, Low when released)
    
    // I2C Interface for MAX30102 Sensor (Pmod Header JA)
    inout  wire        i2c_sda,    // Serial Data Line (Pin J1)
    inout  wire        i2c_scl,    // Serial Clock Line (Pin J2)
    
    // USB-UART Interface (FT2232H)
    output wire        uart_tx,    // FPGA TX -> PC RX (Pin A18)
    input  wire        uart_rx,    // PC TX -> FPGA RX (Pin B18)
    
    // Onboard Status LEDs (Basys 3)
    output wire [15:0] led         // 16 Onboard LEDs
);

    // ------------------------------------------------------------------------
    // Reset Inversion Logic for Basys 3 Button U18 (btnC)
    // Button U18 outputs 0 when released, 1 when pressed.
    // Invert rst_n to create core_rst_n (Active-LOW reset for ASIC core):
    //   - Button released (rst_n = 0) -> core_rst_n = 1 (System Running)
    //   - Button pressed  (rst_n = 1) -> core_rst_n = 0 (System Reset)
    // ------------------------------------------------------------------------
    wire core_rst_n = ~rst_n;

    // ------------------------------------------------------------------------
    // Clock Divider: 100 MHz Onboard Oscillator -> 10 MHz Core Clock
    // ------------------------------------------------------------------------
    reg [2:0] cnt_10m = 0;
    reg       clk_10m_reg = 0;

    always @(posedge clk or negedge core_rst_n) begin
        if (!core_rst_n) begin
            cnt_10m     <= 0;
            clk_10m_reg <= 0;
        end else begin
            if (cnt_10m == 4) begin
                cnt_10m     <= 0;
                clk_10m_reg <= ~clk_10m_reg;
            end else begin
                cnt_10m <= cnt_10m + 1;
            end
        end
    end

    wire clk_10mhz = clk_10m_reg;

    // ------------------------------------------------------------------------
    // ASIC Core Instantiation (top_module_v5)
    // ------------------------------------------------------------------------
    wire sample_valid;
    wire tx_busy;
    wire i2c_error;
    wire fifo_full;
    wire fifo_empty;
    wire [2:0] core_led;
    wire [7:0] spo2_val;
    wire [7:0] hr_val;

    top_module_v5 u_top_core (
        .clk        (clk_10mhz),
        .rst_n      (core_rst_n),
        .i2c_sda    (i2c_sda),
        .i2c_scl    (i2c_scl),
        .uart_tx    (uart_tx),
        .uart_rx    (uart_rx),
        .led        (core_led),        // Connected to fix Synth 8-7071 & Synth 8-7023
        .sample_tick(sample_valid),
        .tx_busy    (tx_busy),
        .i2c_err    (i2c_error),
        .fifo_full  (fifo_full),
        .fifo_empty (fifo_empty),
        .spo2_out   (spo2_val),
        .hr_out     (hr_val)
    );

    // ------------------------------------------------------------------------
    // LED Mapping for Basys 3
    // ------------------------------------------------------------------------
    assign led[0]    = sample_valid; // Blinks on each valid PPG sample read (200 Hz)
    assign led[1]    = tx_busy;      // High when UART TX is actively transmitting
    assign led[2]    = i2c_error;    // High if I2C NACK error occurs
    assign led[3]    = fifo_full;    // High if FIFO buffer is full
    assign led[4]    = fifo_empty;   // High if FIFO buffer is empty
    assign led[7:5]  = core_led;     // Core status LEDs (sample blink, uart busy, i2c err)
    assign led[15:8] = spo2_val;     // Displays calculated SpO2 percentage on LEDs [15:8]

endmodule
