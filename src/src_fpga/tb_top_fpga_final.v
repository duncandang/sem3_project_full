// ============================================================================
// Module Name: tb_top_fpga
// Description: Vivado Testbench for top_fpga / top_module_v5
//              Simulates Basys 3 U18 button reset, MAX30102 I2C sensor model,
//              and 115200 Baud full-duplex UART frame transmitter & monitor.
// ============================================================================

`timescale 1ns / 1ps

module tb_top_fpga;

    // ------------------------------------------------------------------------
    // Testbench Signals
    // ------------------------------------------------------------------------
    reg         clk_100m;
    reg         rst_n; // Simulates Basys 3 U18 btnC (1 = Pressed, 0 = Unpressed)
    
    // I2C Tri-state lines with pull-ups
    wire        i2c_scl;
    wire        i2c_sda;
    tri1        i2c_scl;
    tri1        i2c_sda;
    
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
    // UART Transmitter Task (TB -> FPGA uart_rx @ 115200 Baud)
    // ------------------------------------------------------------------------
    parameter BIT_PERIOD_NS = 8680; // 1/115200 baud ≈ 8.68 us

    task send_uart_byte;
        input [7:0] tx_data;
        integer k;
        begin
            $display("[TB UART TX @ %0t ns] Transmitting byte 0x%02X to FPGA uart_rx...", $time, tx_data);
            uart_rx = 1'b0; // Start Bit
            #(BIT_PERIOD_NS);
            
            for (k = 0; k < 8; k = k + 1) begin
                uart_rx = tx_data[k]; // 8 Data Bits
                #(BIT_PERIOD_NS);
            end
            
            uart_rx = 1'b1; // Stop Bit
            #(BIT_PERIOD_NS);
            $display("[TB UART TX @ %0t ns] Byte 0x%02X successfully sent.", $time, tx_data);
        end
    endtask

    // ------------------------------------------------------------------------
    // Reset and Simulation Control
    // ------------------------------------------------------------------------
    initial begin
        $display("=========================================================");
        $display(" STARTING VIVADO SIMULATION: top_fpga (MAX30102 Oximeter)");
        $display("=========================================================");
        
        // Simulate pressing button U18 at startup (rst_n = 1)
        rst_n   = 1'b1;
        uart_rx = 1'b1;
        
        #100;
        // Release button U18 (rst_n = 0) -> Core runs
        rst_n   = 1'b0;
        $display("[TB %0t ns] Reset button released. System running...", $time);
        
        #50_000;
        send_uart_byte(8'hA5);
        #(BIT_PERIOD_NS * 5);
        send_uart_byte(8'h55);
        
        #2_000_000;
        $finish;
    end

    // ------------------------------------------------------------------------
    // Behavioral MAX30102 I2C Slave Model
    // ------------------------------------------------------------------------
    reg [7:0] i2c_shift_reg = 8'h00;
    reg       sda_drive     = 1'b1;
    assign i2c_sda = sda_drive ? 1'bz : 1'b0;

    reg [7:0] mock_fifo_bytes [0:5];
    initial begin
        mock_fifo_bytes[0] = 8'h01;
        mock_fifo_bytes[1] = 8'h80;
        mock_fifo_bytes[2] = 8'hA0;
        mock_fifo_bytes[3] = 8'h02;
        mock_fifo_bytes[4] = 8'h10;
        mock_fifo_bytes[5] = 8'hB0;
    end

    integer bit_idx = 0;
    wire tb_core_rst_n = ~rst_n;

    always @(negedge i2c_scl or negedge tb_core_rst_n) begin
        if (!tb_core_rst_n) begin
            sda_drive <= 1'b1;
            bit_idx   <= 0;
        end else begin
            if (bit_idx == 8) begin
                sda_drive <= 1'b0; // ACK
                bit_idx   <= 0;
            end else begin
                sda_drive <= 1'b1;
                bit_idx   <= bit_idx + 1;
            end
        end
    end

    // ------------------------------------------------------------------------
    // Behavioral UART Receiver Monitor (FPGA -> PC)
    // ------------------------------------------------------------------------
    reg [7:0] rx_byte;
    reg [7:0] rx_frame [0:7];
    integer   frame_idx = 0;
    integer   i;

    initial begin
        forever begin
            @(negedge uart_tx);
            #(BIT_PERIOD_NS / 2);
            
            if (uart_tx == 1'b0) begin
                for (i = 0; i < 8; i = i + 1) begin
                    #(BIT_PERIOD_NS);
                    rx_byte[i] = uart_tx;
                end
                #(BIT_PERIOD_NS);
                
                rx_frame[frame_idx] = rx_byte;
                if (rx_byte == 8'hAA && frame_idx != 0) begin
                    frame_idx = 0;
                    rx_frame[0] = 8'hAA;
                end
                
                frame_idx = frame_idx + 1;
                if (frame_idx == 8) begin
                    if (rx_frame[0] == 8'hAA && rx_frame[7] == 8'h55) begin
                        $display("[UART RX @ %0t ns] FRAME MATCH! Header: 0xAA | Red_AC: 0x%02X%02X | IR_AC: 0x%02X%02X | BPM: %0d | SpO2: %0d%% | Footer: 0x55", 
                                 $time, rx_frame[1], rx_frame[2], rx_frame[3], rx_frame[4], rx_frame[5], rx_frame[6]);
                    end
                    frame_idx = 0;
                end
            end
        end
    end

    // ------------------------------------------------------------------------
    // Diagnostic LED Monitor
    // ------------------------------------------------------------------------
    always @(led) begin
        $display("[LED UPDATE @ %0t ns] Sample_Blink=%b | UART_Busy=%b | I2C_Error=%b | FIFO_Full=%b | FIFO_Empty=%b | SpO2_LEDs=8'd%0d",
                 $time, led[0], led[1], led[2], led[3], led[4], led[15:8]);
    end

endmodule
