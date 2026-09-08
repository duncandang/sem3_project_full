// uart_tx.v
// UART Serial Transmitter running at 115200 baud under a 10 MHz system clock.
// Frame structure: 8N1 (1 start bit, 8 data bits, no parity, 1 stop bit).

module uart_tx (
    input wire clk,             // 10 MHz system clock
    input wire rst_n,           // Active-low reset
    input wire tx_start,        // Pull high for 1 cycle to transmit a byte
    input wire [7:0] tx_byte,   // 8-bit byte to transmit
    output reg tx_active,       // High while transmission is in progress
    output reg tx_serial,       // Serial transmit line out
    output reg tx_done          // Pulled high for 1 cycle upon completion
);

    // Clock cycles per bit calculation: 10,000,000 / 115,200 approx 87
    localparam CLKS_PER_BIT = 87;
    localparam CTR_WIDTH    = $clog2(CLKS_PER_BIT);

    // States
    localparam STATE_IDLE  = 2'b00;
    localparam STATE_START = 2'b01;
    localparam STATE_DATA  = 2'b10;
    localparam STATE_STOP  = 2'b11;

    reg [1:0] state;
    reg [CTR_WIDTH-1:0] clk_counter;
    reg [2:0] bit_index;
    reg [7:0] tx_data;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= STATE_IDLE;
            clk_counter <= 0;
            bit_index <= 0;
            tx_data <= 0;
            tx_active <= 0;
            tx_serial <= 1'b1; // Defaults high (idle state)
            tx_done <= 0;
        end else begin
            // Single-cycle done pulse reset
            if (tx_done) tx_done <= 1'b0;

            case (state)
                STATE_IDLE: begin
                    tx_serial <= 1'b1;
                    clk_counter <= 0;
                    bit_index <= 0;
                    if (tx_start) begin
                        tx_active <= 1'b1;
                        tx_data <= tx_byte;
                        state <= STATE_START;
                    end else begin
                        tx_active <= 1'b0;
                    end
                end

                STATE_START: begin
                    tx_serial <= 1'b0; // Start bit is low
                    if (clk_counter < CLKS_PER_BIT - 1) begin
                        clk_counter <= clk_counter + 1'b1;
                    end else begin
                        clk_counter <= 0;
                        state <= STATE_DATA;
                    end
                end

                STATE_DATA: begin
                    tx_serial <= tx_data[bit_index];
                    if (clk_counter < CLKS_PER_BIT - 1) begin
                        clk_counter <= clk_counter + 1'b1;
                    end else begin
                        clk_counter <= 0;
                        if (bit_index < 7) begin
                            bit_index <= bit_index + 1'b1;
                        end else begin
                            bit_index <= 0;
                            state <= STATE_STOP;
                        end
                    end
                end

                STATE_STOP: begin
                    tx_serial <= 1'b1; // Stop bit is high
                    if (clk_counter < CLKS_PER_BIT - 1) begin
                        clk_counter <= clk_counter + 1'b1;
                    end else begin
                        clk_counter <= 0;
                        tx_done <= 1'b1;
                        tx_active <= 1'b0;
                        state <= STATE_IDLE;
                    end
                end

                default: state <= STATE_IDLE;
            endcase
        end
    end

endmodule
