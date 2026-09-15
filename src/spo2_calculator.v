// spo2_calculator.v
// Synthesizable ASIC hardware SpO2 computing block (Method 2).
// Sequentially calculates the Ratio-of-Ratios (R) and maps it to SpO2%.
// Multiplier-free sequential shift-subtract division to optimize PPA cell area.
// Formula:
//   R_scaled = (AC_Red_pp * DC_IR * 1024) / (AC_IR_pp * DC_Red)
//   SpO2 = 110 - (25 * R_scaled / 1024)

module spo2_calculator (
    input wire clk,                    // 10 MHz system clock
    input wire rst_n,                  // Active-low reset
    input wire start,                  // Pulsed high to trigger calculation
    input wire [15:0] red_ac_pp,       // Red AC peak-to-peak amplitude
    input wire [15:0] red_dc,          // Red DC baseline component
    input wire [15:0] ir_ac_pp,        // IR AC peak-to-peak amplitude
    input wire [15:0] ir_dc,           // IR DC baseline component
    output reg [7:0] spo2_out,         // Latching SpO2 output (value 0 to 100)
    output reg done                    // Pulsed high when calculation finishes
);

    // FSM States
    localparam S_IDLE      = 3'd0;
    localparam S_MULTIPLY  = 3'd1;
    localparam S_DIV_PREP  = 3'd2;
    localparam S_DIVIDE    = 3'd3;
    localparam S_CALC_SPO2 = 3'd4;
    localparam S_DONE      = 3'd5;

    reg [2:0] state;
    reg [5:0] bit_counter;

    // Internal 48-bit arithmetic registers
    reg [47:0] numerator;
    reg [31:0] denominator;
    reg [47:0] temp_num;
    reg [31:0] temp_denom;
    reg [47:0] quotient;
    reg [47:0] remainder;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            bit_counter <= 6'd0;
            numerator <= 48'd0;
            denominator <= 32'd0;
            temp_num <= 48'd0;
            temp_denom <= 32'd0;
            quotient <= 48'd0;
            remainder <= 48'd0;
            spo2_out <= 8'd98;         // Safe nominal startup value (98% SpO2)
            done <= 1'b0;
        end else begin
            case (state)
                S_IDLE: begin
                    done <= 1'b0;
                    if (start) begin
                        state <= S_MULTIPLY;
                    end
                end

                S_MULTIPLY: begin
                    // Compute Numerator: (Red_AC_pp * IR_DC) << 10
                    // Compute Denominator: IR_AC_pp * Red_DC
                    // Guard against division-by-zero by clamping denominators to 1
                    temp_num <= (red_ac_pp * ir_dc) << 10;
                    temp_denom <= (ir_ac_pp * red_dc == 0) ? 32'd1 : (ir_ac_pp * red_dc);
                    state <= S_DIV_PREP;
                end

                S_DIV_PREP: begin
                    numerator <= temp_num;
                    denominator <= temp_denom;
                    quotient <= 48'd0;
                    remainder <= 48'd0;
                    bit_counter <= 6'd47; // Begin 48-bit sequential division
                    state <= S_DIVIDE;
                end

                S_DIVIDE: begin
                    // Sequential shift-subtract division step
                    remainder <= (remainder << 1) | numerator[bit_counter];
                    
                    if ((remainder << 1) >= denominator) begin
                        remainder <= ((remainder << 1) | numerator[bit_counter]) - denominator;
                        quotient[bit_counter] <= 1'b1;
                    end else begin
                        remainder <= (remainder << 1) | numerator[bit_counter];
                        quotient[bit_counter] <= 1'b0;
                    end

                    if (bit_counter == 0) begin
                        state <= S_CALC_SPO2;
                    end else begin
                        bit_counter <= bit_counter - 1'b1;
                    end
                end

                S_CALC_SPO2: begin
                    // Apply linear equation: SpO2 = 110 - (25 * R_scaled / 1024)
                    // quotient represents R_scaled
                    reg [15:0] r_scaled;
                    reg [23:0] spo2_temp;
                    
                    r_scaled = (quotient > 48'hFFFF) ? 16'hFFFF : quotient[15:0];
                    spo2_temp = 110 - ((25 * r_scaled) >> 10);

                    // Clamp final SpO2 to standard physiological bounds [50, 100]
                    if (spo2_temp > 100) begin
                        spo2_out <= 8'd100;
                    end else if (spo2_temp < 50) begin
                        spo2_out <= 8'd50;
                    end else begin
                        spo2_out <= spo2_temp[7:0];
                    end
                    
                    state <= S_DONE;
                end

                S_DONE: begin
                    done <= 1'b1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
