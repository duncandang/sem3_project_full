// peak_detector.v
// Detects systolic peaks in the filtered PPG waveform and calculates BPM.
// Uses slope detection, a threshold filter, and a refractory period to prevent false triggers.
// Integrates an area-efficient sequential divider for precise BPM computation.

module peak_detector # (
    input wire clk,                     // System clock
    input wire rst_n,                   // Active-low asynchronous reset
    input wire sample_valid,            // Pulse on new sample (100 Hz)
    input wire signed [15:0] ppg_in,    // Filtered PPG AC signal from ppg_filter
    output reg [7:0] bpm,               // Calculated beats-per-minute (BPM)
    output reg beat_detected            // Single clock pulse when a beat/peak is registered
);

    // Configurable thresholds for 100 Hz sampling rate
    localparam signed [15:0] PEAK_MIN_THRESH = 16'sd300; // Minimum amplitude for peak validation
    localparam [7:0] REFRACTORY_LIMIT = 8'd30;          // 300ms refractory period (at 100 Hz) to avoid double triggers
    localparam [15:0] MAX_SAMPLE_COUNT = 16'd500;       // 5 seconds timeout (lowest measurable heart rate = 12 BPM)

    reg signed [15:0] prev_ppg;
    reg [15:0] sample_timer;            // Counts 100 Hz sample periods between peaks
    reg [7:0] refractory_counter;       // Counts refractory timeout
    reg prev_slope_positive;

    // --- Sequential Divider Control Signals ---
    reg start_div;
    wire div_done;
    wire [15:0] div_quotient;
    reg [15:0] dividend;
    reg [15:0] divisor;

    // --- Slope-Tracking & Peak Detection Logic ---
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prev_ppg            <= 16'sd0;
            sample_timer        <= 16'd0;
            refractory_counter  <= 8'd0;
            prev_slope_positive <= 1'b0;
            beat_detected       <= 1'b0;
            start_div           <= 1'b0;
            dividend            <= 16'd0;
            divisor             <= 16'd1;
        end else begin
            beat_detected <= 1'b0;
            start_div     <= 1'b0;

            if (sample_valid) begin
                // Increment timers
                if (sample_timer < MAX_SAMPLE_COUNT) begin
                    sample_timer <= sample_timer + 1'b1;
                end

                if (refractory_counter > 0) begin
                    refractory_counter <= refractory_counter - 1'b1;
                end

                // Peak & Slope Detection State Machine
                // Positive slope: signal is strictly increasing
                if (ppg_in > prev_ppg) begin
                    prev_slope_positive <= 1'b1;
                end 
                // Negative slope transition: signal drops, previous slope was positive
                else if (ppg_in < prev_ppg) begin
                    if (prev_slope_positive && (prev_ppg > PEAK_MIN_THRESH) && (refractory_counter == 0)) begin
                        // systolic peak found!
                        beat_detected      <= 1'b1;
                        refractory_counter <= REFRACTORY_LIMIT;
                        
                        // BPM = 6000 / sample_timer (60 seconds * 100 Hz = 6000 samples/min)
                        if (sample_timer > 16'd15 && sample_timer < MAX_SAMPLE_COUNT) begin
                            dividend   <= 16'd6000;
                            divisor    <= sample_timer;
                            start_div  <= 1'b1;
                        end
                        sample_timer <= 16'd0;
                    end
                    prev_slope_positive <= 1'b0;
                end

                prev_ppg <= ppg_in;
            end
        end
    end

    // --- Retrieve divider results ---
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bpm <= 8'd0;
        end else if (div_done) begin
            // Cap BPM at 250 to prevent overflow
            if (div_quotient > 16'd250) begin
                bpm <= 8'd250;
            end else if (div_quotient < 16'd30) begin
                bpm <= 8'd0; // Underflow filter
            end else begin
                bpm <= div_quotient[7:0];
            end
        end
    end

    // --- Instantiation of the Sequential Divider module ---
    sequential_divider div_inst (
        .clk(clk),
        .rst_n(rst_n),
        .start(start_div),
        .dividend(dividend),
        .divisor(divisor),
        .quotient(div_quotient),
        .done(div_done)
    );

endmodule


// Submodule: Area-Efficient, Synthesizable Shift-Subtract Serial Divider
// Uses a single non-overlapping driver process to compile cleanly in Yosys.
module sequential_divider (
    input wire clk,
    input wire rst_n,
    input wire start,
    input wire [15:0] dividend,
    input wire [15:0] divisor,
    output reg [15:0] quotient,
    output reg done
);

    reg [4:0] count;
    reg [15:0] reg_q;
    reg [15:0] reg_r;
    reg [15:0] reg_d;
    reg active;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            count    <= 5'd0;
            reg_q    <= 16'd0;
            reg_r    <= 16'd0;
            reg_d    <= 16'd0;
            active   <= 1'b0;
            quotient <= 16'd0;
            done     <= 1'b0;
        end else begin
            done <= 1'b0;
            if (start && !active) begin
                active  <= 1'b1;
                count   <= 5'd15;
                reg_q   <= dividend;
                reg_r   <= 16'd0;
                reg_d   <= divisor;
            end else if (active) begin
                // Traditional restoring shift-subtract algorithm
                // We shift the dividend bit into the remainder register
                wire [16:0] sub_res = {reg_r[14:0], reg_q[15]} - reg_d;
                
                if (sub_res[16] == 1'b0) begin // Fits (subtraction didn't underflow)
                    reg_r <= sub_res[15:0];
                    reg_q <= {reg_q[14:0], 1'b1};
                end else begin // Doesn't fit
                    reg_r <= {reg_r[14:0], reg_q[15]};
                    reg_q <= {reg_q[14:0], 1'b0};
                end

                if (count == 0) begin
                    active   <= 1'b0;
                    quotient <= {reg_q[14:0], ~sub_res[16]};
                    done     <= 1'b1;
                end else begin
                    count <= count - 1'b1;
                end
            end
        end
    end

endmodule
