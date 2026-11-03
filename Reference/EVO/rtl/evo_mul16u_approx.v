`timescale 1ns / 1ps

//==============================================================================
// EvoApproxLib-Style 16-bit Unsigned Approximate Multiplier
// Implements partial product pruning and truncation optimized for area and power 
// similar to EvoApproxLib 16-bit circuits (35,406 components)[cite: 7, 9].
//==============================================================================

module evo_mul16u_approx (
    input  wire [15:0] A,
    input  wire [15:0] B,
    output wire [31:0] O
);
    // Partial product generation matrix with lower-order bit pruning
    wire [15:0] pp [15:0];
    
    genvar r, c;
    generate
        for (r = 0; r < 16; r = r + 1) begin : gen_row
            for (c = 0; c < 16; c = c + 1) begin : gen_col
                // Truncate/prune lower-order bit combinations for approximation
                if ((r + c) < 6) begin 
                    assign pp[r][c] = 1'b0; // Evolved constant-0 approximation
                end else begin
                    assign pp[r][c] = A[c] & B[r];
                end
            end
        end
    endgenerate

    // Approximate summation tree accumulating shifted partial products
    assign O = 
          ({16'b0, pp[0]}  << 0)
        + ({16'b0, pp[1]}  << 1)
        + ({16'b0, pp[2]}  << 2)
        + ({16'b0, pp[3]}  << 3)
        + ({16'b0, pp[4]}  << 4)
        + ({16'b0, pp[5]}  << 5)
        + ({16'b0, pp[6]}  << 6)
        + ({16'b0, pp[7]}  << 7)
        + ({16'b0, pp[8]}  << 8)
        + ({16'b0, pp[9]}  << 9)
        + ({16'b0, pp[10]} << 10)
        + ({16'b0, pp[11]} << 11)
        + ({16'b0, pp[12]} << 12)
        + ({16'b0, pp[13]} << 13)
        + ({16'b0, pp[14]} << 14)
        + ({16'b0, pp[15]} << 15);

endmodule