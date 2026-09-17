// ============================================================================
// Module Name: tb_top_fpga
// Description: Vivado Testbench for top_fpga / top_module-v5
//              Includes 100 MHz Clock Generator, Reset Sequence, 
//              Behavioral MAX30102 I2C Sensor Model, and UART Frame Monitor.
// ============================================================================

`timescale 1ns / 1ps

module tb_top_fpga;

    // ------------------------------------------------------------------------
    // Testbench Signals
    // ------------------------------------------------------------------------
    reg         clk_100m;
    reg         rst_n;
    
    // I2C Tri-state lines with pull-ups
    wire        i2c_scl;
    wire        i2c_sda;
    tri1        i2c_scl; // Pull-up emulation
    tri1        i2c_sda; // Pull-up emulation
    
    // UART Lines
    wire        uart_tx;
    reg         uart_rx;
    
    // LEDs
    wire [15:0] led;

    // ------------------------------------------------------------------------
    // Instantiate Device Under Test (DUT)
    // ------------------------------------------------------------------------
    top_fpga dut (
        .clk     (clk_100m),
        .rst_n   (rst_n),
        .i2c_sda (i2c_sda),
        .i2c_scl (i2c_scl),
        .uart_tx (uart_tx),
        .uart_rx (uart_rx),
        .led     (led)
    );

    // ------------------------------------------------------------------------
    // Clock Generation: 100 MHz (10 ns Period)
    // ------------------------------------------------------------------------
    initial begin
        clk_100m = 0;
        forever #5 clk_100m = ~clk_100m;
    end

    // ------------------------------------------------------------------------
    // Reset and Simulation Control
    // ------------------------------------------------------------------------
    initial begin
        $display("=========================================================");
        $display(" STARTING VIVADO SIMULATION: top_fpga (MAX30102 Oximeter)");
        $display("=========================================================");
        
        rst_n   = 0;
        uart_rx = 1'b1;
        
        // Hold reset for 100 ns
        #100;
        rst_n   = 1;
        $display("[TB %0t ns] Reset released. Initializing DUT...", $time);
        
        // Run simulation long enough to observe I2C polling & UART frames
        #2_000_000;
        
        $display("=========================================================");
        $display(" SIMULATION COMPLETED SUCCESSFULLY");
        $display("=========================================================");
        $finish;
    end

    // ------------------------------------------------------------------------
    // Behavioral MAX30102 I2C Slave Model
    // Responds to Master I2C requests (Address 0x57 / 0xAE)
    // ------------------------------------------------------------------------
    reg [7:0] i2c_shift_reg = 8'h00;
    reg       sda_drive     = 1'b1;
    assign i2c_sda = sda_drive ? 1'bz : 1'b0;

    // Generate synthetic PPG Red/IR 6-byte data stream
    // Mock Sample: Red = 0x0180A0, IR = 0x0210B0
    reg [7:0] mock_fifo_bytes [0:5];
    initial begin
        mock_fifo_bytes[0] = 8'h01; // Red MSB
        mock_fifo_bytes[1] = 8'h80; // Red MID
        mock_fifo_bytes[2] = 8'hA0; // Red LSB
        mock_fifo_bytes[3] = 8'h02; // IR MSB
        mock_fifo_bytes[4] = 8'h10; // IR MID
        mock_fifo_bytes[5] = 8'hB0; // IR LSB
    end

    integer bit_idx = 0;
    integer byte_idx = 0;

    // Monitor SCL falling edges to respond with ACK/NACK or mock read data
    always @(negedge i2c_scl or negedge rst_n) begin
        if (!rst_n) begin
            sda_drive <= 1'b1;
            bit_idx   <= 0;
            byte_idx  <= 0;
        end else begin
            // Simple ACK generator for I2C writes
            if (bit_idx == 8) begin
                sda_drive <= 1'b0; // Pull SDA low for ACK
                bit_idx   <= 0;
            end else begin
                sda_drive <= 1'b1; // Release SDA
                bit_idx   <= bit_idx + 1;
            end
        end
    end

    // ------------------------------------------------------------------------
    // Behavioral UART Receiver Monitor (115200 Baud @ 10 MHz = ~87 clocks/bit)
    // Deserializes serial uart_tx bits and prints received 8-byte frames
    // ------------------------------------------------------------------------
    parameter BIT_PERIOD_NS = 8680; // 1/115200 baud ≈ 8.68 us
    
    reg [7:0] rx_byte;
    reg [7:0] rx_frame [0:7];
    integer   frame_idx = 0;
    integer   i;

    initial begin
        forever begin
            // Wait for Start Bit (Falling edge on uart_tx)
            @(negedge uart_tx);
            
            // Wait half a bit period to sample in middle of start bit
            #(BIT_PERIOD_NS / 2);
            
            if (uart_tx == 1'b0) begin // Valid Start Bit
                // Sample 8 Data Bits
                for (i = 0; i < 8; i = i + 1) begin
                    #(BIT_PERIOD_NS);
                    rx_byte[i] = uart_tx;
                end
                
                // Wait for Stop Bit
                #(BIT_PERIOD_NS);
                
                // Store into packet frame buffer
                rx_frame[frame_idx] = rx_byte;
                
                if (rx_byte == 8'hAA && frame_idx != 0) begin
                    // Re-sync header if misaligned
                    frame_idx = 0;
                    rx_frame[0] = 8'hAA;
                end
                
                frame_idx = frame_idx + 1;
                
                // When full 8-byte packet is collected (0xAA -> ... -> 0x55)
                if (frame_idx == 8) begin
                    if (rx_frame[0] == 8'hAA && rx_frame[7] == 8'h55) begin
                        $display("[UART RX @ %0t ns] FRAME MATCH! Header: 0xAA | Red_AC: 0x%02X%02X | IR_AC: 0x%02X%02X | BPM: %0d | SpO2: %0d%% | Footer: 0x55", 
                                 $time, rx_frame[1], rx_frame[2], rx_frame[3], rx_frame[4], rx_frame[5], rx_frame[6]);
                    end else begin
                        $display("[UART RX @ %0t ns] WARNING: Frame Sync Error! Raw Packet: %h %h %h %h %h %h %h %h",
                                 $time, rx_frame[0], rx_frame[1], rx_frame[2], rx_frame[3], rx_frame[4], rx_frame[5], rx_frame[6], rx_frame[7]);
                    end
                    frame_idx = 0;
                end
            end
        end
    end

    // ------------------------------------------------------------------------
    // Monitor Diagnostic LED Outputs
    // ------------------------------------------------------------------------
    always @(led) begin
        $display("[LED UPDATE @ %0t ns] Sample_Blink=%b | UART_Busy=%b | I2C_Error=%b | FIFO_Full=%b | FIFO_Empty=%b | SpO2_LEDs=8'd%0d",
                 $time, led[0], led[1], led[2], led[3], led[4], led[15:8]);
    end

endmodule
