// top_module-v5.v
// Top-level module for Project Sem3 MAX30102 fully integrated BPM & SpO2 ASIC.
// Implements Method 2: Dual filter processing, peak-to-peak tracking, 
// sequential BPM, and sequential Ratio-of-Ratios SpO2% arithmetic on-chip.
// Packages measurements into a standardized 8-byte framing protocol over 115200 Baud UART.

module top_module (
    input wire clk,             // 10 MHz system clock
    input wire rst_n,           // Active-low reset
    
    // I2C Interface (tristate at boundary pads)
    output wire scl,
    inout sda,
    
    // UART Output Interface
    output wire uart_txd

    // Conditional LED Ports for FPGA Board Demo
`ifdef FPGA
    ,
    output wire [2:0] led       // led[0]: sample_blink, led[1]: uart_busy, led[2]: i2c_err
`endif
);

    // --- Tristate Buffer logic for I2C SDA line ---
    wire sda_in;
    wire sda_out;
    wire sda_oe;
    
    assign sda = sda_oe ? sda_out : 1'bz;
    assign sda_in = sda;

    // --- Internal Wires ---
    wire cmd_start;
    wire cmd_stop;
    wire cmd_write;
    wire cmd_read;
    wire cmd_ack;
    wire [7:0] i2c_data_in;
    wire [7:0] i2c_data_out;
    wire i2c_done;
    wire i2c_ack_err;
    
    wire [23:0] raw_red;
    wire [23:0] raw_ir;
    wire sample_valid;
    wire init_done;
    wire i2c_err_flag;
    wire sample_blink_flag;
    
    // Filter Outputs
    wire [15:0] red_ac;
    wire [15:0] red_dc;
    wire [15:0] red_ac_pp;
    
    wire [15:0] ir_ac;
    wire [15:0] ir_dc;
    wire [15:0] ir_ac_pp;

    // Computed Metrics
    wire [7:0] bpm_val;
    wire [7:0] spo2_val;
    wire spo2_done;

    // FIFO Wires
    wire [7:0] fifo_data_in;
    wire [7:0] fifo_data_out;
    reg fifo_write_en;
    reg fifo_read_en;
    wire fifo_full;
    wire fifo_empty;
    
    reg tx_start;
    reg [7:0] tx_byte;
    wire tx_active;
    wire tx_done;

    // --- Instantiate I2C Master ---
    i2c_master i2c_inst (
        .clk(clk),
        .rst_n(rst_n),
        .cmd_start(cmd_start),
        .cmd_stop(cmd_stop),
        .cmd_write(cmd_write),
        .cmd_read(cmd_read),
        .cmd_ack(cmd_ack),
        .data_in(i2c_data_in),
        .data_out(i2c_data_out),
        .cmd_done(i2c_done),
        .ack_err(i2c_ack_err),
        .scl(scl),
        .sda_in(sda_in),
        .sda_out(sda_out),
        .sda_oe(sda_oe)
    );

    // --- Instantiate MAX30102 Controller ---
    max30102_controller ctrl_inst (
        .clk(clk),
        .rst_n(rst_n),
        .cmd_start(cmd_start),
        .cmd_stop(cmd_stop),
        .cmd_write(cmd_write),
        .cmd_read(cmd_read),
        .cmd_ack(cmd_ack),
        .i2c_data_in(i2c_data_in),
        .i2c_data_out(i2c_data_out),
        .i2c_done(i2c_done),
        .i2c_ack_err(i2c_ack_err),
        .sample_data({raw_red, raw_ir}), // Split raw red and raw ir signals in FSM
        .sample_valid(sample_valid),
        .init_done(init_done),
        .i2c_err(i2c_err_flag),
        .led_blink(sample_blink_flag)
    );

    // --- Instantiate Dual PPG Filters ---
    ppg_filter_v4 filter_red_inst (
        .clk(clk),
        .rst_n(rst_n),
        .sample_valid(sample_valid),
        .raw_in(raw_red),
        .ac_out(red_ac),
        .dc_out(red_dc),
        .ac_pp(red_ac_pp)
    );

    ppg_filter_v4 filter_ir_inst (
        .clk(clk),
        .rst_n(rst_n),
        .sample_valid(sample_valid),
        .raw_in(raw_ir),
        .ac_out(ir_ac),
        .dc_out(ir_dc),
        .ac_pp(ir_ac_pp)
    );

    // --- Instantiate Peak Detector / BPM Calculator (On Red AC Channel) ---
    peak_detector bpm_calc_inst (
        .clk(clk),
        .rst_n(rst_n),
        .sample_valid(sample_valid),
        .ppg_in(red_ac),
        .bpm(bpm_val),
        .beat_detected() // Explicitly map to empty to avoid PINMISSING linter warnings
    );

    // --- Instantiate SpO2 Calculator (On Red and IR Channels) ---
    spo2_calculator spo2_calc_inst (
        .clk(clk),
        .rst_n(rst_n),
        .start(sample_valid),
        .red_ac_pp(red_ac_pp),
        .red_dc(red_dc),
        .ir_ac_pp(ir_ac_pp),
        .ir_dc(ir_dc),
        .spo2_out(spo2_val),
        .done(spo2_done)
    );

    // --- Instantiate FIFO Buffer ---
    fifo_buffer # (
        .DATA_WIDTH(8),
        .FIFO_DEPTH(16)
    ) buffer_inst (
        .clk(clk),
        .rst_n(rst_n),
        .write_en(fifo_write_en),
        .read_en(fifo_read_en),
        .data_in(fifo_data_in),
        .data_out(fifo_data_out),
        .full(fifo_full),
        .empty(fifo_empty)
    );

    // --- Instantiate UART Transmitter ---
    uart_tx tx_inst (
        .clk(clk),
        .rst_n(rst_n),
        .tx_start(tx_start),
        .tx_byte(tx_byte),
        .tx_active(tx_active),
        .tx_serial(uart_txd),
        .tx_done(tx_done)
    );

    // --- Pack Processed data into 8-byte FIFO streams ---
    // Packet Structure: 
    //   0xAA (Header) -> Red_AC[15:8] -> Red_AC[7:0] -> IR_AC[15:8] -> IR_AC[7:0] -> BPM -> SpO2 -> 0x55 (Footer)
    localparam P_IDLE      = 4'd0;
    localparam P_HEADER    = 4'd1;
    localparam P_RED_MSB   = 4'd2;
    localparam P_RED_LSB   = 4'd3;
    localparam P_IR_MSB    = 4'd4;
    localparam P_IR_LSB    = 4'd5;
    localparam P_BPM       = 4'd6;
    localparam P_SPO2      = 4'd7;
    localparam P_FOOTER    = 4'd8;

    reg [3:0] p_state;
    reg [15:0] r_ac_buf;
    reg [15:0] i_ac_buf;
    reg [7:0] bpm_buf;
    reg [7:0] spo2_buf;
    reg [7:0] p_data;

    assign fifo_data_in = p_data;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            p_state <= P_IDLE;
            r_ac_buf <= 16'd0;
            i_ac_buf <= 16'd0;
            bpm_buf <= 8'd0;
            spo2_buf <= 8'd0;
            p_data <= 8'd0;
            fifo_write_en <= 1'b0;
        end else begin
            case (p_state)
                P_IDLE: begin
                    fifo_write_en <= 1'b0;
                    // Trigger packet generation when SpO2 calculation completes
                    if (spo2_done && !fifo_full) begin
                        r_ac_buf <= red_ac;
                        i_ac_buf <= ir_ac;
                        bpm_buf <= bpm_val;
                        spo2_buf <= spo2_val;
                        p_state <= P_HEADER;
                    end
                end

                P_HEADER: begin
                    p_data <= 8'hAA;
                    fifo_write_en <= 1'b1;
                    p_state <= P_RED_MSB;
                end

                P_RED_MSB: begin
                    p_data <= r_ac_buf[15:8];
                    fifo_write_en <= 1'b1;
                    p_state <= P_RED_LSB;
                end

                P_RED_LSB: begin
                    p_data <= r_ac_buf[7:0];
                    fifo_write_en <= 1'b1;
                    p_state <= P_IR_MSB;
                end

                P_IR_MSB: begin
                    p_data <= i_ac_buf[15:8];
                    fifo_write_en <= 1'b1;
                    p_state <= P_IR_LSB;
                end

                P_IR_LSB: begin
                    p_data <= i_ac_buf[7:0];
                    fifo_write_en <= 1'b1;
                    p_state <= P_BPM;
                end

                P_BPM: begin
                    p_data <= bpm_buf;
                    fifo_write_en <= 1'b1;
                    p_state <= P_SPO2;
                end

                P_SPO2: begin
                    p_data <= spo2_buf;
                    fifo_write_en <= 1'b1;
                    p_state <= P_FOOTER;
                end

                P_FOOTER: begin
                    p_data <= 8'h55;
                    fifo_write_en <= 1'b1;
                    p_state <= P_IDLE;
                end

                default: p_state <= P_IDLE;
            endcase
        end
    end

    // --- Unload FIFO and stream via UART Transmitter ---
    localparam U_IDLE      = 2'd0;
    localparam U_READ_FIFO = 2'd1;
    localparam U_START_TX  = 2'd2;
    localparam U_WAIT_TX   = 2'd3;

    reg [1:0] u_state;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            u_state <= U_IDLE;
            fifo_read_en <= 1'b0;
            tx_start <= 1'b0;
            tx_byte <= 8'd0;
        end else begin
            case (u_state)
                U_IDLE: begin
                    fifo_read_en <= 1'b0;
                    tx_start <= 1'b0;
                    if (!fifo_empty && !tx_active) begin
                        fifo_read_en <= 1'b1;
                        u_state <= U_READ_FIFO;
                    end
                end

                U_READ_FIFO: begin
                    fifo_read_en <= 1'b0; // Immediately drop to prevent double reads
                    u_state <= U_START_TX;
                end

                U_START_TX: begin
                    tx_byte <= fifo_data_out;
                    tx_start <= 1'b1;
                    u_state <= U_WAIT_TX;
                end

                U_WAIT_TX: begin
                    tx_start <= 1'b0;
                    if (tx_done) begin
                        u_state <= U_IDLE;
                    end
                end

                default: u_state <= U_IDLE;
            endcase
        end
    end

    // --- Optional FPGA LEDs Map ---
`ifdef FPGA
    assign led[0] = sample_blink_flag; // Blinks on sample acquisition
    assign led[1] = tx_active;         // ON when UART is transmitting
    assign led[2] = i2c_err_flag;      // ON if I2C fails
`endif

endmodule
