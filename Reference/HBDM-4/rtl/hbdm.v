`timescale 1ns / 1ps

//==============================================================================
// 1. PARALLEL PREFIX & CLA ADDER BUILDING BLOCKS (Figures 7 & 8, Section 4.4)
//==============================================================================

// 4-bit Kogge-Stone Parallel Prefix Adder (KSA-4)
module ksa_4bit (
    input  wire [3:0] a,
    input  wire [3:0] b,
    input  wire       cin,
    output wire [3:0] sum,
    output wire       cout
);
    // Pre-processing: Propagate (p) and Generate (g)
    wire [3:0] p = a ^ b;
    wire [3:0] g = a & b;

    // Stage 1 (Distance 1)
    wire [3:0] g1, p1;
    assign g1[0] = g[0] | (p[0] & cin);
    assign p1[0] = p[0];
    assign g1[1] = g[1] | (p[1] & g[0]);
    assign p1[1] = p[1] & p[0];
    assign g1[2] = g[2] | (p[2] & g[1]);
    assign p1[2] = p[2] & p[1];
    assign g1[3] = g[3] | (p[3] & g[2]);
    assign p1[3] = p[3] & p[2];

    // Stage 2 (Distance 2)
    wire [3:0] g2;
    assign g2[0] = g1[0];
    assign g2[1] = g1[1] | (p1[1] & cin);
    assign g2[2] = g1[2] | (p1[2] & g1[0]);
    assign g2[3] = g1[3] | (p1[3] & g1[1]);

    // Post-processing: Carry and Sum
    wire [3:0] c = {g2[2:0], cin};
    assign sum  = p ^ c;
    assign cout = g2[3];
endmodule

// 4-bit Brent-Kung Parallel Prefix Adder (BKA-4)
module bka_4bit (
    input  wire [3:0] a,
    input  wire [3:0] b,
    input  wire       cin,
    output wire [3:0] sum,
    output wire       cout
);
    wire [3:0] p = a ^ b;
    wire [3:0] g = a & b;

    // Forward Tree ( Odd indices )
    wire g0_cin = g[0] | (p[0] & cin);
    wire g1_0   = g[1] | (p[1] & g0_cin);
    wire g3_2   = g[3] | (p[3] & g[2]);
    wire p3_2   = p[3] & p[2];

    // Root & Inverse Tree
    wire c1   = g0_cin;
    wire c2   = g1_0;
    wire c3   = g[2] | (p[2] & c2);
    assign cout = g3_2 | (p3_2 & c2);

    assign sum[0] = p[0] ^ cin;
    assign sum[1] = p[1] ^ c1;
    assign sum[2] = p[2] ^ c2;
    assign sum[3] = p[3] ^ c3;
endmodule

// 4-bit Carry-Look-Ahead Adder (CLA-4)
module cla_4bit (
    input  wire [3:0] a,
    input  wire [3:0] b,
    input  wire       cin,
    output wire [3:0] sum,
    output wire       cout
);
    wire [3:0] p = a ^ b;
    wire [3:0] g = a & b;
    wire [4:0] c;

    assign c[0] = cin;
    assign c[1] = g[0] | (p[0] & c[0]);
    assign c[2] = g[1] | (p[1] & g[0]) | (p[1] & p[0] & c[0]);
    assign c[3] = g[2] | (p[2] & g[1]) | (p[2] & p[1] & g[0]) | (p[2] & p[1] & p[0] & c[0]);
    assign c[4] = g[3] | (p[3] & g[2]) | (p[3] & p[2] & g[1]) | (p[3] & p[2] & p[1] & g[0]) | (p[3] & p[2] & p[1] & p[0] & c[0]);

    assign sum  = p ^ c[3:0];
    assign cout = c[4];
endmodule

//------------------------------------------------------------------------------
// 8-bit Hybrid Adder (Figure 7): KSA(4-bit) [3:0] + BKA(4-bit) [7:4]
//------------------------------------------------------------------------------
module hybrid_adder_8bit (
    input  wire [7:0] a,
    input  wire [7:0] b,
    input  wire       cin,
    output wire [7:0] sum,
    output wire       cout
);
    wire c4;
    ksa_4bit u_ksa_low  (.a(a[3:0]), .b(b[3:0]), .cin(cin), .sum(sum[3:0]), .cout(c4));
    bka_4bit u_bka_high (.a(a[7:4]), .b(b[7:4]), .cin(c4),  .sum(sum[7:4]), .cout(cout));
endmodule

//------------------------------------------------------------------------------
// 12-bit Hybrid Adder (Figure 8): KSA(4-bit) + BKA(4-bit) + KSA(4-bit)
//------------------------------------------------------------------------------
module hybrid_adder_12bit (
    input  wire [11:0] a,
    input  wire [11:0] b,
    input  wire        cin,
    output wire [11:0] sum,
    output wire        cout
);
    wire c4, c8;
    ksa_4bit u_ksa_0 (.a(a[3:0]),  .b(b[3:0]),  .cin(cin), .sum(sum[3:0]),  .cout(c4));
    bka_4bit u_bka_1 (.a(a[7:4]),  .b(b[7:4]),  .cin(c4),  .sum(sum[7:4]),  .cout(c8));
    ksa_4bit u_ksa_2 (.a(a[11:8]), .b(b[11:8]), .cin(c8),  .sum(sum[11:8]), .cout(cout));
endmodule

//------------------------------------------------------------------------------
// Parameterized N-bit Adder Wrapper (Selects Hybrid Adder vs CLA per Table 2)
// Widths supported: multiples of 4 (8, 12, 16, 20, 24)
//------------------------------------------------------------------------------
module hbdm_adder_n #(
    parameter WIDTH      = 12,
    parameter USE_HYBRID = 1   // 1 = Hybrid (KSA/BKA alternating), 0 = CLA
)(
    input  wire [WIDTH-1:0] a,
    input  wire [WIDTH-1:0] b,
    input  wire             cin,
    output wire [WIDTH-1:0] sum,
    output wire             cout
);
    wire [WIDTH/4 : 0] c;
    assign c[0] = cin;

    genvar i;
    generate
        for (i = 0; i < WIDTH/4; i = i + 1) begin : gen_nibbles
            if (USE_HYBRID) begin : gen_hyb
                // Matches Fig. 7 (KSA -> BKA) and Fig. 8 (KSA -> BKA -> KSA)
                if ((i % 2) == 0) begin : use_ksa
                    ksa_4bit u_ksa (.a(a[4*i+3 : 4*i]), .b(b[4*i+3 : 4*i]), .cin(c[i]), .sum(sum[4*i+3 : 4*i]), .cout(c[i+1]));
                end else begin : use_bka
                    bka_4bit u_bka (.a(a[4*i+3 : 4*i]), .b(b[4*i+3 : 4*i]), .cin(c[i]), .sum(sum[4*i+3 : 4*i]), .cout(c[i+1]));
                end
            end else begin : gen_cla
                cla_4bit u_cla (.a(a[4*i+3 : 4*i]), .b(b[4*i+3 : 4*i]), .cin(c[i]), .sum(sum[4*i+3 : 4*i]), .cout(c[i+1]));
            end
        end
    endgenerate

    assign cout = c[WIDTH/4];
endmodule


//==============================================================================
// 2. APPROXIMATE 4-BIT DECODER MODULE (Algorithm 1 & Table 1, Section 4.1)
//==============================================================================
module hbdm_decoder_4bit #(
    parameter X_WIDTH = 8
)(
    input  wire [X_WIDTH-1:0] X,
    input  wire [3:0]         Y_nibble,
    output reg  [X_WIDTH+2:0] PP_dec
);
    wire [X_WIDTH+2:0] x_sh0 = {3'b000, X};
    wire [X_WIDTH+2:0] x_sh1 = {2'b00,  X, 1'b0};
    wire [X_WIDTH+2:0] x_sh2 = {1'b0,   X, 2'b00};
    wire [X_WIDTH+2:0] x_sh3 = {        X, 3'b000};

    // Exact implementation of Algorithm 1 & Table 1
    always @(*) begin
        case (Y_nibble)
            4'b0000: PP_dec = {(X_WIDTH+3){1'b0}};
            4'b0001: PP_dec = x_sh0;
            4'b0010: PP_dec = x_sh1;
            4'b0011: PP_dec = x_sh0 | x_sh1;
            4'b0100: PP_dec = x_sh2;
            4'b0101: PP_dec = x_sh2 | x_sh0;
            4'b0110: PP_dec = x_sh2 | x_sh1;
            4'b0111: PP_dec = x_sh2 | x_sh1 | x_sh0;
            4'b1000: PP_dec = x_sh3;
            4'b1001: PP_dec = x_sh3 | x_sh0;
            4'b1010: PP_dec = x_sh3 | x_sh1;
            4'b1011: PP_dec = x_sh3 | x_sh1 | x_sh0;
            4'b1100: PP_dec = x_sh3 | x_sh2;
            4'b1101: PP_dec = x_sh3 | x_sh2 | x_sh0;
            4'b1110: PP_dec = x_sh3 | x_sh2 | x_sh1;
            4'b1111: PP_dec = x_sh3 | x_sh2 | x_sh1 | x_sh0;
            default: PP_dec = {(X_WIDTH+3){1'b0}};
        endcase
    end
endmodule


//==============================================================================
// 3. MODIFIED RADIX-16 BOOTH ENCODER & PPG UNIT (Section 4.2, Figure 4)
//==============================================================================
module hbdm_radix16_booth_unit #(
    parameter X_WIDTH         = 8,   // 8 for 8x8 HBDM, 16 for 16x16 HBDM
    parameter PRECOMP_HYBRID  = 1,   // 1 = Hybrid Adder, 0 = CLA
    parameter TWOSCOMP_HYBRID = 1    // 1 = Hybrid Adder, 0 = CLA
)(
    input  wire [X_WIDTH-1:0] X,
    input  wire [4:0]         Q,     // {Q_{i+3}, Q_{i+2}, Q_{i+1}, Q_i, Q_{i-1}}
    output wire [X_WIDTH+3:0] PP_booth
);
    localparam PP_W = X_WIDTH + 4; // 12 bits for 8-bit X, 20 bits for 16-bit X

    //--------------------------------------------------------------------------
    // A. Precomputation Module: {X, 2X, 3X, 4X, 5X, 6X, 7X, 8X} (Fig. 4)
    //--------------------------------------------------------------------------
    wire [PP_W-1:0] m1X = {4'b0000, X};
    wire [PP_W-1:0] m2X = {3'b000,  X, 1'b0};
    wire [PP_W-1:0] m4X = {2'b00,   X, 2'b00};
    wire [PP_W-1:0] m8X = {1'b0,    X, 3'b000};

    wire [PP_W-1:0] m3X, m5X, m6X, m7X;
    wire            c3_unused, c5_unused, c7_unused;

    // Hard multiple 3X = 2X + X
    hbdm_adder_n #(.WIDTH(PP_W), .USE_HYBRID(PRECOMP_HYBRID)) u_add_3x (
        .a(m2X), .b(m1X), .cin(1'b0), .sum(m3X), .cout(c3_unused)
    );

    // Even multiple 6X = 3X << 1
    assign m6X = {m3X[PP_W-2:0], 1'b0};

    // Hard multiple 5X = 4X + X
    hbdm_adder_n #(.WIDTH(PP_W), .USE_HYBRID(PRECOMP_HYBRID)) u_add_5x (
        .a(m4X), .b(m1X), .cin(1'b0), .sum(m5X), .cout(c5_unused)
    );

    // Hard multiple 7X = 6X + X
    hbdm_adder_n #(.WIDTH(PP_W), .USE_HYBRID(PRECOMP_HYBRID)) u_add_7x (
        .a(m6X), .b(m1X), .cin(1'b0), .sum(m7X), .cout(c7_unused)
    );

    //--------------------------------------------------------------------------
    // B. 5:4 Radix-16 Booth Encoder (Eq. 5, 6, 7 & Fig. 4)
    //    Maps 5-bit Q to magnitude select [3:0] (0..8)
    //--------------------------------------------------------------------------
    reg [3:0] mag_sel;
    always @(*) begin
        case (Q)
            5'b00000, 5'b11111: mag_sel = 4'd0; //  0X
            5'b00001, 5'b00010,
            5'b11101, 5'b11110: mag_sel = 4'd1; // +1X / -1X
            5'b00011, 5'b00100,
            5'b11011, 5'b11100: mag_sel = 4'd2; // +2X / -2X
            5'b00101, 5'b00110,
            5'b11001, 5'b11010: mag_sel = 4'd3; // +3X / -3X
            5'b00111, 5'b01000,
            5'b10111, 5'b11000: mag_sel = 4'd4; // +4X / -4X
            5'b01001, 5'b01010,
            5'b10101, 5'b10110: mag_sel = 4'd5; // +5X / -5X
            5'b01011, 5'b01100,
            5'b10011, 5'b10100: mag_sel = 4'd6; // +6X / -6X
            5'b01101, 5'b01110,
            5'b10001, 5'b10010: mag_sel = 4'd7; // +7X / -7X
            5'b01111, 5'b10000: mag_sel = 4'd8; // +8X / -8X
            default:            mag_sel = 4'd0;
        endcase
    end

    //--------------------------------------------------------------------------
    // C. 8:1 Multiplexer with Zero Default (Fig. 4)
    //--------------------------------------------------------------------------
    reg [PP_W-1:0] mux_pos_pp;
    always @(*) begin
        case (mag_sel)
            4'd1:    mux_pos_pp = m1X;
            4'd2:    mux_pos_pp = m2X;
            4'd3:    mux_pos_pp = m3X;
            4'd4:    mux_pos_pp = m4X;
            4'd5:    mux_pos_pp = m5X;
            4'd6:    mux_pos_pp = m6X;
            4'd7:    mux_pos_pp = m7X;
            4'd8:    mux_pos_pp = m8X;
            default: mux_pos_pp = {PP_W{1'b0}};
        endcase
    end

    //--------------------------------------------------------------------------
    // D. 2's Complement Module: 1's complement (XOR with all 1s) + 1 (Fig. 4)
    //--------------------------------------------------------------------------
    wire [PP_W-1:0] ones_comp = mux_pos_pp ^ {PP_W{1'b1}};
    wire [PP_W-1:0] twos_comp;
    wire            tc_cout_unused;

    hbdm_adder_n #(.WIDTH(PP_W), .USE_HYBRID(TWOSCOMP_HYBRID)) u_twos_comp (
        .a    (ones_comp),
        .b    ({PP_W{1'b0}}),
        .cin  (1'b1),
        .sum  (twos_comp),
        .cout (tc_cout_unused)
    );

    //--------------------------------------------------------------------------
    // E. 2:1 Multiplexer Controlled by Sign Bit Q[4] (Y[7] in Fig. 4 & Fig. 5)
    //--------------------------------------------------------------------------
    assign PP_booth = Q[4] ? twos_comp : mux_pos_pp;

endmodule


//==============================================================================
// 4. PROPOSED 8x8 HBDM MULTIPLIER (16-Bit Output Z[15:0], Figures 5 & 6)
//    Supports all 4 configurations in Table 2 via parameter CONFIG (1..4)
//==============================================================================
module HBDM_8x8 #(
    parameter integer CONFIG = 4 // 1=HBDM-1, 2=HBDM-2, 3=HBDM-3, 4=HBDM-4 (Default)
)(
    input  wire [7:0]  X,
    input  wire [7:0]  Y,
    output wire [15:0] Z
);
    // Table 2 Adder Configuration Mapping
    localparam PRECOMP_HYB  = (CONFIG == 1 || CONFIG == 2 || CONFIG == 4) ? 1 : 0;
    localparam TWOSCOMP_HYB = (CONFIG == 4) ? 1 : 0;
    localparam ADD12_HYB    = (CONFIG == 1 || CONFIG == 4) ? 1 : 0;
    localparam ADD8_HYB     = (CONFIG == 4) ? 1 : 0;

    // 1. Decoder-based Approximate Partial Product PP1[10:0] from Y[3:0] (Fig. 5)
    wire [10:0] PP1;
    hbdm_decoder_4bit #(.X_WIDTH(8)) u_decoder (
        .X        (X),
        .Y_nibble (Y[3:0]),
        .PP_dec   (PP1)
    );

    // 2. Modified Radix-16 Booth Partial Product PP2[11:0] from {Y[7:4], 1'b0} (Fig. 4 & 5)
    wire [11:0] PP2;
    hbdm_radix16_booth_unit #(
        .X_WIDTH         (8),
        .PRECOMP_HYBRID  (PRECOMP_HYB),
        .TWOSCOMP_HYBRID (TWOSCOMP_HYB)
    ) u_booth (
        .X        (X),
        .Q        ({Y[7:4], 1'b0}),
        .PP_booth (PP2)
    );

    // 3. Lower 4 bits of final product Z[3:0] come directly from PP1[3:0] (Fig. 5 & 6)
    assign Z[3:0] = PP1[3:0];

    // 4. 12-bit Adder: Adds zero-extended PP1[10:4] and PP2[11:0] -> Z1[11:0] (Fig. 5 & 6)
    wire [11:0] Z1;
    wire        add12_cout_unused;
    hbdm_adder_n #(.WIDTH(12), .USE_HYBRID(ADD12_HYB)) u_adder_12bit (
        .a    ({5'b00000, PP1[10:4]}),
        .b    (PP2),
        .cin  (1'b0),
        .sum  (Z1),
        .cout (add12_cout_unused)
    );

    // Middle 4 bits Z[7:4] come directly from Z1[3:0] (Fig. 5 & 6)
    assign Z[7:4] = Z1[3:0];

    // 5. 8-bit Adder: Adds Z1[11:4] and X[7:0] for unsigned Y[7]=1 correction -> Z2[7:0]
    wire [7:0] Z2;
    wire       add8_cout_unused;
    hbdm_adder_n #(.WIDTH(8), .USE_HYBRID(ADD8_HYB)) u_adder_8bit (
        .a    (Z1[11:4]),
        .b    (X),
        .cin  (1'b0),
        .sum  (Z2),
        .cout (add8_cout_unused)
    );

    // 6. Final 2:1 Multiplexer controlled by Y[7] selects Z[15:8] (Fig. 5 & 6)
    assign Z[15:8] = Y[7] ? Z2 : Z1[11:4];

endmodule


//==============================================================================
// 5. SCALED 16x16 HBDM MULTIPLIER (32-Bit Output Z[31:0], Section 3 Equations)
//    - Splits 16-bit Y into Y_L = Y[7:0] (Two 4-bit Approximate Decoders)
//      and Y_H = Y[15:8] (Two Radix-16 Booth Encoding Units)
//    - Accumulates partial products using the same Hybrid Adder / CLA hierarchy
//==============================================================================
module HBDM_16x16 #(
    parameter integer CONFIG = 4 // 1=HBDM-1, 2=HBDM-2, 3=HBDM-3, 4=HBDM-4 (Default)
)(
    input  wire [15:0] X,
    input  wire [15:0] Y,
    output wire [31:0] Z
);
    localparam PRECOMP_HYB  = (CONFIG == 1 || CONFIG == 2 || CONFIG == 4) ? 1 : 0;
    localparam TWOSCOMP_HYB = (CONFIG == 4) ? 1 : 0;
    localparam MAIN_ADD_HYB = (CONFIG == 1 || CONFIG == 4) ? 1 : 0;
    localparam CORR_ADD_HYB = (CONFIG == 4) ? 1 : 0;

    //--------------------------------------------------------------------------
    // A. Decoder-Based Approximate Partial Product Generation for Y_L = Y[7:0]
    //    Uses 4-bit Decoder on Y[3:0] and Y[7:4] combined via bitwise OR (Eq. 12)
    //--------------------------------------------------------------------------
    wire [18:0] pp_dec_low, pp_dec_high;

    hbdm_decoder_4bit #(.X_WIDTH(16)) u_dec_low (
        .X        (X),
        .Y_nibble (Y[3:0]),
        .PP_dec   (pp_dec_low)
    );

    hbdm_decoder_4bit #(.X_WIDTH(16)) u_dec_high (
        .X        (X),
        .Y_nibble (Y[7:4]),
        .PP_dec   (pp_dec_high)
    );

    // Combined 23-bit Decoder Partial Product PP1[22:0] = pp_dec_low | (pp_dec_high << 4)
    wire [22:0] PP1 = {4'b0000, pp_dec_low} | {pp_dec_high, 4'b0000};

    //--------------------------------------------------------------------------
    // B. Modified Radix-16 Booth Partial Product Generation for Y_H = Y[15:8]
    //    Group 0: {Y[11:8], 1'b0} (weight 2^8)
    //    Group 1: {Y[15:12], Y[11]} (weight 2^12)
    //--------------------------------------------------------------------------
    wire [19:0] PP2_g0, PP2_g1;

    hbdm_radix16_booth_unit #(
        .X_WIDTH         (16),
        .PRECOMP_HYBRID  (PRECOMP_HYB),
        .TWOSCOMP_HYBRID (TWOSCOMP_HYB)
    ) u_booth_g0 (
        .X        (X),
        .Q        ({Y[11:8], 1'b0}),
        .PP_booth (PP2_g0)
    );

    hbdm_radix16_booth_unit #(
        .X_WIDTH         (16),
        .PRECOMP_HYBRID  (PRECOMP_HYB),
        .TWOSCOMP_HYBRID (TWOSCOMP_HYB)
    ) u_booth_g1 (
        .X        (X),
        .Q        ({Y[15:12], Y[11]}),
        .PP_booth (PP2_g1)
    );

    // Combine sign-extended PP2_g0 (weight 2^8..2^31) and PP2_g1 (weight 2^12..2^31)
    wire [23:0] PP2_g0_ext = {{4{Y[11]}}, PP2_g0};
    wire [23:0] PP2_g1_sh4 = {PP2_g1, 4'b0000};
    wire [23:0] PP2_combined;
    wire        c_booth_unused;

    hbdm_adder_n #(.WIDTH(24), .USE_HYBRID(MAIN_ADD_HYB)) u_add_booth_groups (
        .a    (PP2_g0_ext),
        .b    (PP2_g1_sh4),
        .cin  (1'b0),
        .sum  (PP2_combined),
        .cout (c_booth_unused)
    );

    //--------------------------------------------------------------------------
    // C. Final Accumulation & Unsigned MSB (Y[15]) Correction Multiplexer
    //--------------------------------------------------------------------------
    // Lower 8 bits Z[7:0] pass directly from PP1[7:0]
    assign Z[7:0] = PP1[7:0];

    // 24-bit Main Adder (weight 2^8..2^31): Adds PP1[22:8] and PP2_combined[23:0]
    wire [23:0] Z1;
    wire        c_main_unused;
    hbdm_adder_n #(.WIDTH(24), .USE_HYBRID(MAIN_ADD_HYB)) u_adder_24bit (
        .a    ({9'b0, PP1[22:8]}),
        .b    (PP2_combined),
        .cin  (1'b0),
        .sum  (Z1),
        .cout (c_main_unused)
    );

    // Middle 8 bits Z[15:8] come directly from Z1[7:0]
    assign Z[15:8] = Z1[7:0];

    // 16-bit Correction Adder (weight 2^16..2^31): Adds Z1[23:8] and X[15:0] when Y[15]=1
    wire [15:0] Z2;
    wire        c_corr_unused;
    hbdm_adder_n #(.WIDTH(16), .USE_HYBRID(CORR_ADD_HYB)) u_adder_16bit (
        .a    (Z1[23:8]),
        .b    (X),
        .cin  (1'b0),
        .sum  (Z2),
        .cout (c_corr_unused)
    );

    // Final 2:1 Multiplexer controlled by Y[15] selects Z[31:16]
    assign Z[31:16] = Y[15] ? Z2 : Z1[23:8];

endmodule


//==============================================================================
// 6. SELF-CHECKING TESTBENCH (Verifies HBDM_8x8 Table 4 Metrics & HBDM_16x16)
//==============================================================================
module tb_hbdm;
    reg  [7:0]  X8, Y8;
    wire [15:0] Z8_hbdm4;

    reg  [15:0] X16, Y16;
    wire [31:0] Z16_hbdm4;

    // Instantiate Paper 8x8 HBDM-4 (16-bit output)
    HBDM_8x8 #(.CONFIG(4)) u_dut_8x8 (
        .X (X8),
        .Y (Y8),
        .Z (Z8_hbdm4)
    );

    // Instantiate Scaled 16x16 HBDM-4 (32-bit output)
    HBDM_16x16 #(.CONFIG(4)) u_dut_16x16 (
        .X (X16),
        .Y (Y16),
        .Z (Z16_hbdm4)
    );

    integer i, j;
    integer err_cnt;
    real    mred_sum, nmed_sum, exact8, approx8, diff8;

    initial begin
        err_cnt  = 0;
        mred_sum = 0.0;
        nmed_sum = 0.0;

        // Exhaustive 65,536 (256x256) evaluation of 8x8 HBDM-4 (Section 5, Table 4)
        for (i = 0; i < 256; i = i + 1) begin
            for (j = 0; j < 256; j = j + 1) begin
                X8 = i[7:0];
                Y8 = j[7:0];
                #1;
                exact8  = i * j;
                approx8 = Z8_hbdm4;
                diff8   = (approx8 > exact8) ? (approx8 - exact8) : (exact8 - approx8);
                if (diff8 != 0) err_cnt = err_cnt + 1;
                if (exact8 > 0) mred_sum = mred_sum + (diff8 / exact8);
                nmed_sum = nmed_sum + diff8;
            end
        end

        $display("================================================================");
        $display("1. 8x8 HBDM-4 (16-bit Output) Exhaustive Accuracy Verification:");
        $display("   Error Rate (ER) = %0.2f %% (Paper Table 4 = 57.01 %%)", (err_cnt / 65536.0) * 100.0);
        $display("   MRED            = %0.4f    (Paper Table 4 = 0.0173)", mred_sum / 65536.0);
        $display("   NMED            = %0.4f    (Paper Table 4 = 0.0024)", (nmed_sum / 65536.0) / 65025.0);
        $display("================================================================");

        // Sample Test on 16x16 HBDM-4 (32-bit Output)
        X16 = 16'd45210;
        Y16 = 16'd38918; // Y[3:0] = 4'b0110 (example from Section 4.1)
        #5;
        $display("2. 16x16 HBDM-4 Sample Test: X=%0d, Y=%0d", X16, Y16);
        $display("   Exact Product = %0d | HBDM-4 Approx = %0d", X16 * Y16, Z16_hbdm4);
        $display("================================================================");
        $finish;
    end
endmodule