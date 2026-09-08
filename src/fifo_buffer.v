// fifo_buffer.v
// Highly optimized 8-bit wide, synchronous FIFO buffer to store sensor packet bytes
// for sequential transmission over UART. 

module fifo_buffer #(
    parameter DATA_WIDTH = 8,
    parameter FIFO_DEPTH = 16 // Recommended baseline depth of 16
)(
    input wire clk,
    input wire rst_n,
    input wire write_en,
    input wire read_en,
    input wire [DATA_WIDTH-1:0] data_in,
    output reg [DATA_WIDTH-1:0] data_out,
    output wire full,
    output wire empty
);

    // Address width calculation
    localparam ADDR_WIDTH = $clog2(FIFO_DEPTH);

    // Internal memory array
    reg [DATA_WIDTH-1:0] mem [0:FIFO_DEPTH-1];

    // Pointer registers (using +1 extra bit to easily distinguish full and empty states)
    reg [ADDR_WIDTH:0] write_ptr;
    reg [ADDR_WIDTH:0] read_ptr;

    // Status flags
    assign empty = (write_ptr == read_ptr);
    assign full  = (write_ptr[ADDR_WIDTH] != read_ptr[ADDR_WIDTH]) && 
                   (write_ptr[ADDR_WIDTH-1:0] == read_ptr[ADDR_WIDTH-1:0]);

    // Synchronous Write Logic
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            write_ptr <= 0;
        end else if (write_en && !full) begin
            mem[write_ptr[ADDR_WIDTH-1:0]] <= data_in;
            write_ptr <= write_ptr + 1'b1;
        end
    end

    // Synchronous Read Logic
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            read_ptr <= 0;
            data_out <= {DATA_WIDTH{1'b0}};
        end else if (read_en && !empty) begin
            data_out <= mem[read_ptr[ADDR_WIDTH-1:0]];
            read_ptr <= read_ptr + 1'b1;
        end
    end

endmodule
