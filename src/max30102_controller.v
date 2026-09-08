// max30102_controller.v
// Standard state machine to initialize MAX30102 and poll its FIFO for 6 bytes (Red/IR)
// at a specified sample rate (e.g. 100 Hz).

module max30102_controller (
    input wire clk,             // 10 MHz system clock
    input wire rst_n,           // Active-low reset
    
    // Commands to I2C Master
    output reg cmd_start,
    output reg cmd_stop,
    output reg cmd_write,
    output reg cmd_read,
    output reg cmd_ack,
    output reg [7:0] i2c_data_in,
    input wire [7:0] i2c_data_out,
    input wire i2c_done,
    input wire i2c_ack_err,
    
    // Output interfaces to FIFO buffer
    output reg [47:0] sample_data, // 6 bytes: Red_MSB, Red_MID, Red_LSB, IR_MSB, IR_MID, IR_LSB
    output reg sample_valid,
    output reg init_done,
    output reg i2c_err,
    output reg led_blink          // Toggles with each successful sample read
);

    // MAX30102 Address
    localparam I2C_ADDR_W = 8'hAE; // 7'h57 << 1 + Write bit (0)
    localparam I2C_ADDR_R = 8'hAF; // 7'h57 << 1 + Read bit (1)

    // Configuration sequences
    // We will write 7 configuration registers sequentially
    reg [2:0] init_step;
    reg [7:0] reg_addr;
    reg [7:0] reg_data;

    // 100 Hz (10 ms) Sampling timer from 10 MHz clock
    // 10,000,000 / 100 = 100,000 clock cycles.
    reg [17:0] sample_timer;
    reg sample_trigger;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sample_timer <= 0;
            sample_trigger <= 0;
        end else begin
            if (init_done) begin
                if (sample_timer == 18'd99999) begin
                    sample_timer <= 0;
                    sample_trigger <= 1'b1;
                end else begin
                    sample_timer <= sample_timer + 1'b1;
                    sample_trigger <= 1'b0;
                end
            end else begin
                sample_timer <= 0;
                sample_trigger <= 1'b0;
            end
        end
    end

    // FSM States
    localparam S_RESET          = 4'd0;
    localparam S_INIT_START     = 4'd1;
    localparam S_INIT_WR_ADDR   = 4'd2;
    localparam S_INIT_WR_REG    = 4'd3;
    localparam S_INIT_WR_DATA   = 4'd4;
    localparam S_INIT_STOP      = 4'd5;
    localparam S_INIT_NEXT      = 4'd6;
    
    localparam S_IDLE           = 4'd7;
    
    localparam S_READ_START     = 4'd8;
    localparam S_READ_WR_ADDR   = 4'd9;
    localparam S_READ_WR_REG    = 4'd10;
    localparam S_READ_RESTART   = 4'd11;
    localparam S_READ_RD_ADDR   = 4'd12;
    localparam S_READ_BYTES     = 4'd13;
    localparam S_READ_STOP      = 4'd14;

    reg [3:0] state;
    reg [2:0] byte_cnt; // Tracks which of the 6 bytes we are reading

    // Map init steps to physical register addresses & configuration values
    always @(*) begin
        case (init_step)
            3'd0: begin reg_addr = 8'h09; reg_data = 8'h03; end // Mode Configuration: SpO2 Mode (Red + IR)
            3'd1: begin reg_addr = 8'h0A; reg_data = 8'h27; end // SpO2 Configuration: 100 Hz, 411 us, 18-bit ADC
            3'd2: begin reg_addr = 8'h0C; reg_data = 8'h24; end // LED1 Red Pulse Amplitude: ~7.2mA
            3'd3: begin reg_addr = 8'h0D; reg_data = 8'h24; end // LED2 IR Pulse Amplitude: ~7.2mA
            3'd4: begin reg_addr = 8'h04; reg_data = 8'h00; end // FIFO Write Pointer reset
            3'd5: begin reg_addr = 8'h05; reg_data = 8'h00; end // FIFO Overflow Counter reset
            3'd6: begin reg_addr = 8'h06; reg_data = 8'h00; end // FIFO Read Pointer reset
            default: begin reg_addr = 8'h09; reg_data = 8'h03; end
        endcase
    end

    // FSM Sequencer logic
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_RESET;
            init_step <= 0;
            cmd_start <= 0;
            cmd_stop <= 0;
            cmd_write <= 0;
            cmd_read <= 0;
            cmd_ack <= 0;
            i2c_data_in <= 0;
            sample_data <= 0;
            sample_valid <= 0;
            init_done <= 0;
            i2c_err <= 0;
            led_blink <= 0;
            byte_cnt <= 0;
        end else begin
            // Pulse sample_valid for exactly 1 cycle
            if (sample_valid) sample_valid <= 1'b0;

            case (state)
                S_RESET: begin
                    init_step <= 0;
                    init_done <= 0;
                    state <= S_INIT_START;
                end

                // --- INITIALIZATION PATTERN ---
                S_INIT_START: begin
                    cmd_start <= 1'b1;
                    state <= S_INIT_WR_ADDR;
                end

                S_INIT_WR_ADDR: begin
                    if (cmd_start) begin
                        cmd_start <= 1'b0;
                    end else if (i2c_done) begin
                        if (i2c_ack_err) begin
                            i2c_err <= 1'b1;
                            state <= S_RESET; // Retry initialization
                        end else begin
                            cmd_write <= 1'b1;
                            i2c_data_in <= I2C_ADDR_W;
                            state <= S_INIT_WR_REG;
                        end
                    end
                end

                S_INIT_WR_REG: begin
                    if (cmd_write) begin
                        cmd_write <= 1'b0;
                    end else if (i2c_done) begin
                        if (i2c_ack_err) begin
                            i2c_err <= 1'b1;
                            state <= S_RESET;
                        end else begin
                            cmd_write <= 1'b1;
                            i2c_data_in <= reg_addr;
                            state <= S_INIT_WR_DATA;
                        end
                    end
                end

                S_INIT_WR_DATA: begin
                    if (cmd_write) begin
                        cmd_write <= 1'b0;
                    end else if (i2c_done) begin
                        if (i2c_ack_err) begin
                            i2c_err <= 1'b1;
                            state <= S_RESET;
                        end else begin
                            cmd_write <= 1'b1;
                            i2c_data_in <= reg_data;
                            state <= S_INIT_STOP;
                        end
                    end
                end

                S_INIT_STOP: begin
                    if (cmd_write) begin
                        cmd_write <= 1'b0;
                    end else if (i2c_done) begin
                        if (i2c_ack_err) begin
                            i2c_err <= 1'b1;
                            state <= S_RESET;
                        end else begin
                            cmd_stop <= 1'b1;
                            state <= S_INIT_NEXT;
                        end
                    end
                end

                S_INIT_NEXT: begin
                    if (cmd_stop) begin
                        cmd_stop <= 1'b0;
                    end else if (i2c_done) begin
                        if (init_step == 3'd6) begin
                            init_done <= 1'b1;
                            state <= S_IDLE;
                        end else begin
                            init_step <= init_step + 1'b1;
                            state <= S_INIT_START;
                        end
                    end
                end

                // --- IDLE STATE (WAITING FOR TIMER TRIGGER) ---
                S_IDLE: begin
                    if (sample_trigger) begin
                        state <= S_READ_START;
                        byte_cnt <= 0;
                    end
                end

                // --- READ 6-BYTE PACKET FROM REGISTER 0x07 ---
                S_READ_START: begin
                    cmd_start <= 1'b1;
                    state <= S_READ_WR_ADDR;
                end

                S_READ_WR_ADDR: begin
                    if (cmd_start) begin
                        cmd_start <= 1'b0;
                    end else if (i2c_done) begin
                        if (i2c_ack_err) begin
                            i2c_err <= 1'b1;
                            state <= S_IDLE;
                        end else begin
                            cmd_write <= 1'b1;
                            i2c_data_in <= I2C_ADDR_W;
                            state <= S_READ_WR_REG;
                        end
                    end
                end

                S_READ_WR_REG: begin
                    if (cmd_write) begin
                        cmd_write <= 1'b0;
                    end else if (i2c_done) begin
                        if (i2c_ack_err) begin
                            i2c_err <= 1'b1;
                            state <= S_IDLE;
                        end else begin
                            cmd_write <= 1'b1;
                            i2c_data_in <= 8'h07; // Register 0x07: FIFO Data Register
                            state <= S_READ_RESTART;
                        end
                    end
                end

                S_READ_RESTART: begin
                    if (cmd_write) begin
                        cmd_write <= 1'b0;
                    end else if (i2c_done) begin
                        if (i2c_ack_err) begin
                            i2c_err <= 1'b1;
                            state <= S_IDLE;
                        end else begin
                            cmd_start <= 1'b1; // Generate Repeated Start
                            state <= S_READ_RD_ADDR;
                        end
                    end
                end

                S_READ_RD_ADDR: begin
                    if (cmd_start) begin
                        cmd_start <= 1'b0;
                    end else if (i2c_done) begin
                        if (i2c_ack_err) begin
                            i2c_err <= 1'b1;
                            state <= S_IDLE;
                        end else begin
                            cmd_write <= 1'b1;
                            i2c_data_in <= I2C_ADDR_R;
                            state <= S_READ_BYTES;
                        end
                    end
                end

                S_READ_BYTES: begin
                    if (cmd_write) begin
                        cmd_write <= 1'b0;
                        cmd_read <= 1'b1;
                        // For bytes 0-4 send ACK (0). For byte 5 (last) send NACK (1) to end read.
                        cmd_ack <= (byte_cnt == 3'd5) ? 1'b1 : 1'b0;
                    end else if (cmd_read) begin
                        cmd_read <= 1'b0;
                    end else if (i2c_done) begin
                        // Save the read byte to the correct position inside 48-bit sample_data
                        case (byte_cnt)
                            3'd0: sample_data[47:40] <= i2c_data_out; // Red MSB
                            3'd1: sample_data[39:32] <= i2c_data_out; // Red MID
                            3'd2: sample_data[31:24] <= i2c_data_out; // Red LSB
                            3'd3: sample_data[23:16] <= i2c_data_out; // IR MSB
                            3'd4: sample_data[15:8]  <= i2c_data_out; // IR MID
                            3'd5: sample_data[7:0]   <= i2c_data_out; // IR LSB
                        endcase
                        
                        if (byte_cnt == 3'd5) begin
                            cmd_stop <= 1'b1;
                            state <= S_READ_STOP;
                        end else begin
                            byte_cnt <= byte_cnt + 1'b1;
                            cmd_write <= 1'b1; // Trigger next read cycle
                        end
                    end
                end

                S_READ_STOP: begin
                    if (cmd_stop) begin
                        cmd_stop <= 1'b0;
                    end else if (i2c_done) begin
                        sample_valid <= 1'b1;
                        led_blink <= ~led_blink; // Toggle successful read LED indicator
                        state <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
