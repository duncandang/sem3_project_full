// ppg_filter_v4.v
// Upgraded synthesizable, multiplier-free PPG filter module.
// Integrates an active DC Blocker (HPF) and a Low-Pass EMA filter (LPF).
// Computes baseline DC offset and monitors Peak-to-Peak (AC_PP) values over a 256-sample epoch.

module ppg_filter_v4 (
    input wire clk,                  // 10 MHz system clock
    input wire rst_n,                // Active-low reset
    input wire sample_valid,         // Pulsed high when new sample is ready (100 Hz)
    input wire [23:0] raw_in,        // 24-bit raw ADC reading from MAX30102
    output reg [15:0] ac_out,        // 16-bit AC component (filtered)
    output reg [15:0] dc_out,        // 16-bit DC component (baseline)
    output reg [15:0] ac_pp          // 16-bit Peak-to-Peak amplitude
);

    // --- DC Blocker / High-Pass Filter (HPF) ---
    // Formula: y[n] = x[n] - x[n-1] + alpha * y[n-1]
    // Implemented multiplier-free using bit shifts: alpha = 255/256 (1 - 1/256)
    reg [31:0] hpf_accum;            // Expanded precision for fractional accumulation

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hpf_accum <= 32'd0;
            dc_out <= 16'd0;
        end else if (sample_valid) begin
            // Accumulate baseline DC: dc_accum = dc_accum + raw_in - (dc_accum / 256)
            hpf_accum <= hpf_accum + raw_in - (hpf_accum >> 8);
            dc_out <= hpf_accum[23:8]; // Latch DC baseline
        end
    end

    // Compute AC component: AC = Raw_In - DC
    wire [15:0] ac_hpf_raw = (raw_in > dc_out) ? (raw_in - dc_out) : 16'd0;

    // --- Low-Pass Filter (LPF) using EMA ---
    // Formula: y[n] = y[n-1] + beta * (x[n] - y[n-1]), where beta = 1/4 (2-bit shift)
    reg [17:0] lpf_accum;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lpf_accum <= 18'd0;
            ac_out <= 16'd0;
        end else if (sample_valid) begin
            lpf_accum <= lpf_accum + ac_hpf_raw - (lpf_accum >> 2);
            ac_out <= lpf_accum[17:2]; // Latch smoothed AC signal
        end
    end

    // --- Peak-to-Peak Amplitude Monitor ---
    // Tracks maximum and minimum values found in a 256-sample epoch (~2.56 seconds at 100 Hz).
    // Computes and latches the final ac_pp value at the end of each epoch, resetting the trackers.
    reg [7:0] sample_counter;
    reg [15:0] max_val;
    reg [15:0] min_val;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sample_counter <= 8'd0;
            max_val <= 16'd0;
            min_val <= 16'hFFFF;
            ac_pp <= 16'd100; // Initialize with a safe nominal value to avoid divide-by-zero
        end else if (sample_valid) begin
            sample_counter <= sample_counter + 1'b1;

            // Update max and min trackers for the current epoch
            if (ac_out > max_val) begin
                max_val <= ac_out;
            end
            if (ac_out < min_val) begin
                min_val <= ac_out;
            end

            // End of 256-sample epoch
            if (sample_counter == 8'hFF) begin
                ac_pp <= (max_val > min_val) ? (max_val - min_val) : 16'd100;
                
                // Reset local trackers for the next epoch
                max_val <= ac_out;
                min_val <= ac_out;
            end
        end
    end

endmodule
