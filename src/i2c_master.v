// i2c_master.v
// Robust byte-level I2C Master optimized for OpenLane 2 physical synthesis.
// Avoids internal tristates by separating SDA lines at the boundary.

module i2c_master (
    input wire clk,         // 10 MHz clock
    input wire rst_n,       // Active-low reset
    input wire cmd_start,   // Generate START or REPEATED START
    input wire cmd_stop,    // Generate STOP
    input wire cmd_write,   // Write a byte
    input wire cmd_read,    // Read a byte
    input wire cmd_ack,     // ACK to transmit on read (0: ACK, 1: NACK)
    input wire [7:0] data_in,
    output reg [7:0] data_out,
    output reg cmd_done,
    output reg ack_err,
    
    // Physical line interfaces
    output reg scl,
    input wire sda_in,
    output reg sda_out,
    output reg sda_oe
);

    // 100 kHz SCL clock divider from 10 MHz
    // 10 MHz clock / 100 = 100 kHz. 
    // We use a quarter-cycle divider (25 cycles of 10 MHz = 2.5 us) for fine-grained timing.
    reg [5:0] clk_div;
    reg scl_tick;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            clk_div <= 0;
            scl_tick <= 0;
        end else begin
            if (clk_div == 24) begin
                clk_div <= 0;
                scl_tick <= 1;
            end else begin
                clk_div <= clk_div + 1'b1;
                scl_tick <= 0;
            end
        end
    end

    // FSM States
    localparam STATE_IDLE      = 4'd0;
    localparam STATE_START_1   = 4'd1;
    localparam STATE_START_2   = 4'd2;
    localparam STATE_STOP_1    = 4'd3;
    localparam STATE_STOP_2    = 4'd4;
    localparam STATE_STOP_3    = 4'd5;
    localparam STATE_WRITE     = 4'd6;
    localparam STATE_WRITE_ACK = 4'd7;
    localparam STATE_READ      = 4'd8;
    localparam STATE_READ_ACK  = 4'd9;

    reg [3:0] state;
    reg [2:0] bit_cnt;
    reg [7:0] shift_reg;
    reg [1:0] sub_state; // 4 quarters of SCL cycle

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= STATE_IDLE;
            bit_cnt <= 0;
            shift_reg <= 0;
            data_out <= 0;
            cmd_done <= 0;
            ack_err <= 0;
            scl <= 1'b1;
            sda_out <= 1'b1;
            sda_oe <= 1'b0; // High-Z
            sub_state <= 0;
        end else if (scl_tick) begin
            case (state)
                STATE_IDLE: begin
                    cmd_done <= 0;
                    scl <= 1'b1;
                    if (cmd_start) begin
                        state <= STATE_START_1;
                        sub_state <= 0;
                        sda_oe <= 1'b1;
                        sda_out <= 1'b1;
                    end else if (cmd_stop) begin
                        state <= STATE_STOP_1;
                        sub_state <= 0;
                        sda_oe <= 1'b1;
                        sda_out <= 1'b0;
                    end else if (cmd_write) begin
                        state <= STATE_WRITE;
                        bit_cnt <= 3'd7;
                        shift_reg <= data_in;
                        sub_state <= 0;
                        ack_err <= 0;
                    end else if (cmd_read) begin
                        state <= STATE_READ;
                        bit_cnt <= 3'd7;
                        sub_state <= 0;
                    end
                end

                // --- START CONDITION ---
                STATE_START_1: begin
                    // SDA goes low while SCL is high
                    sda_out <= 1'b0;
                    sda_oe <= 1'b1;
                    scl <= 1'b1;
                    state <= STATE_START_2;
                end
                STATE_START_2: begin
                    scl <= 1'b0; // Pull SCL low to prepare for data
                    cmd_done <= 1'b1;
                    state <= STATE_IDLE;
                end

                // --- STOP CONDITION ---
                STATE_STOP_1: begin
                    sda_out <= 1'b0;
                    sda_oe <= 1'b1;
                    scl <= 1'b0;
                    state <= STATE_STOP_2;
                end
                STATE_STOP_2: begin
                    scl <= 1'b1; // SCL goes high
                    state <= STATE_STOP_3;
                end
                STATE_STOP_3: begin
                    sda_out <= 1'b1; // SDA goes high while SCL is high
                    sda_oe <= 1'b1;
                    cmd_done <= 1'b1;
                    state <= STATE_IDLE;
                end

                // --- WRITE BYTE ---
                STATE_WRITE: begin
                    case (sub_state)
                        2'b00: begin // Quarter 1: Set SDA data
                            scl <= 1'b0;
                            sda_out <= shift_reg[bit_cnt];
                            sda_oe <= 1'b1;
                            sub_state <= 2'b01;
                        end
                        2'b01: begin // Quarter 2: Pull SCL high
                            scl <= 1'b1;
                            sub_state <= 2'b10;
                        end
                        2'b10: begin // Quarter 3: Hold SCL high
                            scl <= 1'b1;
                            sub_state <= 2'b11;
                        end
                        2'b11: begin // Quarter 4: Pull SCL low, advance bit
                            scl <= 1'b0;
                            sub_state <= 2'b00;
                            if (bit_cnt == 0) begin
                                state <= STATE_WRITE_ACK;
                            end else begin
                                bit_cnt <= bit_cnt - 1'b1;
                            end
                        end
                    endcase
                end

                // --- WRITE ACK (WAIT FOR ACK FROM SLAVE) ---
                STATE_WRITE_ACK: begin
                    case (sub_state)
                        2'b00: begin
                            scl <= 1'b0;
                            sda_oe <= 1'b0; // Release SDA line to allow slave response
                            sub_state <= 2'b01;
                        end
                        2'b01: begin
                            scl <= 1'b1;
                            sub_state <= 2'b10;
                        end
                        2'b10: begin
                            // Sample ACK from slave
                            ack_err <= sda_in; // 0: ACK, 1: NACK
                            scl <= 1'b1;
                            sub_state <= 2'b11;
                        end
                        2'b11: begin
                            scl <= 1'b0;
                            cmd_done <= 1'b1;
                            state <= STATE_IDLE;
                        end
                    endcase
                end

                // --- READ BYTE ---
                STATE_READ: begin
                    case (sub_state)
                        2'b00: begin
                            scl <= 1'b0;
                            sda_oe <= 1'b0; // Release SDA line
                            sub_state <= 2'b01;
                        end
                        2'b01: begin
                            scl <= 1'b1;
                            sub_state <= 2'b10;
                        end
                        2'b10: begin
                            // Sample SDA data
                            shift_reg[bit_cnt] <= sda_in;
                            scl <= 1'b1;
                            sub_state <= 2'b11;
                        end
                        2'b11: begin
                            scl <= 1'b0;
                            sub_state <= 2'b00;
                            if (bit_cnt == 0) begin
                                state <= STATE_READ_ACK;
                            end else begin
                                bit_cnt <= bit_cnt - 1'b1;
                            end
                        end
                    endcase
                end

                // --- READ ACK (SEND ACK/NACK TO SLAVE) ---
                STATE_READ_ACK: begin
                    case (sub_state)
                        2'b00: begin
                            scl <= 1'b0;
                            sda_out <= cmd_ack; // Send ACK (0) or NACK (1)
                            sda_oe <= 1'b1;
                            sub_state <= 2'b01;
                        end
                        2'b01: begin
                            scl <= 1'b1;
                            sub_state <= 2'b10;
                        end
                        2'b10: begin
                            scl <= 1'b1;
                            sub_state <= 2'b11;
                        end
                        2'b11: begin
                            scl <= 1'b0;
                            sda_oe <= 1'b0;
                            data_out <= shift_reg;
                            cmd_done <= 1'b1;
                            state <= STATE_IDLE;
                        end
                    endcase
                end
                
                default: state <= STATE_IDLE;
            endcase
        end
    end

endmodule
