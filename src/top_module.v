// top_module.v
// Top-level module for Project Sem3 MAX30102-to-UART ASIC/FPGA processing pipeline.
// Bridges I2C sensor reads, packages packets, buffers them in a 16-deep FIFO,
// and streams them via 115200 Baud UART to a PC.

module top_module (
    input wire clk,             // 10 MHz system clock
    input wire rst_n,           // Active-low reset
    
    // I2C Interface (with SDA tristate buffer at top boundary for physical pads)
    output wire scl,
    inout sda,
    
    // UART Output Interface
    output wire uart_txd
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
    
    wire [47:0] sample_data;
    wire sample_valid;
    wire init_done;
    wire i2c_err_flag;
    wire sample_blink_flag;
    
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
        .sample_data(sample_data),
        .sample_valid(sample_valid),
        .init_done(init_done),
        .i2c_err(i2c_err_flag),
        .led_blink(sample_blink_flag)
    );

    // --- Instantiate FIFO Buffer ---
    fifo_buffer #(
        .DATA_WIDTH(8),
        .FIFO_DEPTH(16) // Baseline depth parameter
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

    // --- Pack 48-bit sensor data into 8-byte FIFO streams ---
    // State machine to sequentially write 8 bytes to the FIFO:
    // Packet: 0xAA -> Red_MSB -> Red_MID -> Red_LSB -> IR_MSB -> IR_MID -> IR_LSB -> 0x55
    localparam P_IDLE   = 4'd0;
    localparam P_HEADER = 4'd1;
    localparam P_R_MSB  = 4'd2;
    localparam P_R_MID  = 4'd3;
    localparam P_R_LSB  = 4'd4;
    localparam P_I_MSB  = 4'd5;
    localparam P_I_MID  = 4'd6;
    localparam P_I_LSB  = 4'd7;
    localparam P_FOOTER = 4'd8;

    reg [3:0] p_state;
    reg [47:0] sample_buf;
    reg [7:0] p_data;

    assign fifo_data_in = p_data;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            p_state <= P_IDLE;
            sample_buf <= 0;
            p_data <= 0;
            fifo_write_en <= 0;
        end else begin
            case (p_state)
                P_IDLE: begin
                    fifo_write_en <= 0;
                    if (sample_valid && !fifo_full) begin
                        sample_buf <= sample_data;
                        p_state <= P_HEADER;
                    end
                end

                P_HEADER: begin
                    p_data <= 8'hAA;
                    fifo_write_en <= 1'b1;
                    p_state <= P_R_MSB;
                end

                P_R_MSB: begin
                    p_data <= sample_buf[47:40];
                    fifo_write_en <= 1'b1;
                    p_state <= P_R_MID;
                end

                P_R_MID: begin
                    p_data <= sample_buf[39:32];
                    fifo_write_en <= 1'b1;
                    p_state <= P_R_LSB;
                end

                P_R_LSB: begin
                    p_data <= sample_buf[31:24];
                    fifo_write_en <= 1'b1;
                    p_state <= P_I_MSB;
                end

                P_I_MSB: begin
                    p_data <= sample_buf[23:16];
                    fifo_write_en <= 1'b1;
                    p_state <= P_I_MID;
                end

                P_I_MID: begin
                    p_data <= sample_buf[15:8];
                    fifo_write_en <= 1'b1;
                    p_state <= P_I_LSB;
                end

                P_I_LSB: begin
                    p_data <= sample_buf[7:0];
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

    // --- Unload FIFO and push to UART Transmitter ---
    localparam U_IDLE      = 2'd0;
    localparam U_READ_FIFO = 2'd1;
    localparam U_START_TX  = 2'd2;
    localparam U_WAIT_TX   = 2'd3;

    reg [1:0] u_state;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            u_state <= U_IDLE;
            fifo_read_en <= 0;
            tx_start <= 0;
            tx_byte <= 0;
        end else begin
            case (u_state)
                U_IDLE: begin
                    fifo_read_en <= 0;
                    tx_start <= 0;
                    // If FIFO has buffered bytes and UART is not active, pull out byte
                    if (!fifo_empty && !tx_active) begin
                        fifo_read_en <= 1'b1;
                        u_state <= U_READ_FIFO;
                    end
                end

                U_READ_FIFO: begin
                    fifo_read_en <= 0; // Turn off immediately to pull exactly 1 byte
                    u_state <= U_START_TX;
                end

                U_START_TX: begin
                    tx_byte <= fifo_data_out;
                    tx_start <= 1'b1;
                    u_state <= U_WAIT_TX;
                end

                U_WAIT_TX: begin
                    tx_start <= 0;
                    if (tx_done) begin
                        u_state <= U_IDLE;
                    end
                end

                default: u_state <= U_IDLE;
            endcase
        end
    end

endmodule
