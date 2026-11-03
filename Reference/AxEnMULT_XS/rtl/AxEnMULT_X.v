`timescale 1ns / 1ps

//==============================================================================
// 1. Shared Building Blocks (Half Adder, Full Adder, Parameterized RCA, Encoder)
//==============================================================================

module half_adder (
    input  wire a,
    input  wire b,
    output wire sum,
    output wire cout
);
    assign sum  = a ^ b;
    assign cout = a & b;
endmodule

module full_adder (
    input  wire a,
    input  wire b,
    input  wire cin,
    output wire sum,
    output wire cout
);
    assign sum  = a ^ b ^ cin;
    assign cout = (a & b) | (b & cin) | (a & cin);
endmodule

module rca_n #(
    parameter WIDTH = 18
)(
    input  wire [WIDTH-1:0] a,
    input  wire [WIDTH-1:0] b,
    input  wire             cin,
    output wire [WIDTH-1:0] sum,
    output wire             cout
);
    wire [WIDTH:0] c;
    assign c[0] = cin;

    genvar i;
    generate
        for (i = 0; i < WIDTH; i = i + 1) begin : gen_fa
            full_adder fa_inst (
                .a    (a[i]),
                .b    (b[i]),
                .cin  (c[i]),
                .sum  (sum[i]),
                .cout (c[i+1])
            );
        end
    endgenerate

    assign cout = c[WIDTH];
endmodule

module encoder_pair (
    input  wire x_low,   // X_i
    input  wire x_high,  // X_{i+1}
    output wire sel_1x,  // ~X_{i+1} & X_i
    output wire sel_2x,  //  X_{i+1} & ~X_i
    output wire sel_3x   //  X_{i+1} & X_i
);
    assign sel_1x = (~x_high) & x_low;
    assign sel_2x = x_high & (~x_low);
    assign sel_3x = x_high & x_low;
endmodule


//==============================================================================
// 2. Proposed Unsigned 16x16 Approximate Multiplier: AxEnMULT_X_16x16
//==============================================================================

module AxEnMULT_X_16x16 (
    input  wire [15:0] X,
    input  wire [15:0] Y,
    output wire [31:0] P
);
    //--------------------------------------------------------------------------
    // Multiples of Operand Y: 1Y (16-bit), 2Y (17-bit), 3Y (18-bit via 16-bit RCA)
    //--------------------------------------------------------------------------
    wire [15:0] y1 = Y;
    wire [16:0] y2 = {Y, 1'b0};

    wire [17:0] y3;
    assign y3[0] = y1[0];
    rca_n #(.WIDTH(16)) u_rca_3y (
        .a    ({1'b0, y1[15:1]}),
        .b    (y2[16:1]),
        .cin  (1'b0),
        .sum  (y3[16:1]),
        .cout (y3[17])
    );

    //--------------------------------------------------------------------------
    // Eight Pair-wise Encoders for Operand X[15:0]
    //--------------------------------------------------------------------------
    wire [7:0] sel_1x, sel_2x, sel_3x;
    genvar k;
    generate
        for (k = 0; k < 8; k = k + 1) begin : gen_enc
            encoder_pair u_enc (
                .x_low  (X[2*k]),
                .x_high (X[2*k+1]),
                .sel_1x (sel_1x[k]),
                .sel_2x (sel_2x[k]),
                .sel_3x (sel_3x[k])
            );
        end
    endgenerate

    //--------------------------------------------------------------------------
    // Partial Products Generation (PPG-1 to PPG-8)
    //--------------------------------------------------------------------------
    wire [17:0] ppg1;
    wire [17:2] ppg2;
    wire [17:0] ppg [2:7]; // PPG-3 (idx 2) through PPG-8 (idx 7)

    genvar m, p;
    generate
        // PPG-1: First 4 LSBs of 2Y and 3Y are truncated
        for (m = 0; m <= 3; m = m + 1) begin : gen_ppg1_lsb
            assign ppg1[m] = sel_1x[0] & y1[m];
        end
        for (m = 4; m <= 15; m = m + 1) begin : gen_ppg1_mid
            assign ppg1[m] = (sel_1x[0] & y1[m]) | (sel_2x[0] & y2[m]) | (sel_3x[0] & y3[m]);
        end
        assign ppg1[16] = (sel_2x[0] & y2[16]) | (sel_3x[0] & y3[16]);
        assign ppg1[17] = (sel_3x[0] & y3[17]);

        // PPG-2: First 2 LSB columns [1:0] are truncated
        for (m = 2; m <= 15; m = m + 1) begin : gen_ppg2_mid
            assign ppg2[m] = (sel_1x[1] & y1[m]) | (sel_2x[1] & y2[m]) | (sel_3x[1] & y3[m]);
        end
        assign ppg2[16] = (sel_2x[1] & y2[16]) | (sel_3x[1] & y3[16]);
        assign ppg2[17] = (sel_3x[1] & y3[17]);

        // PPG-3 through PPG-8: Full 18-bit partial products
        for (p = 2; p <= 7; p = p + 1) begin : gen_ppg_rest
            assign ppg[p][0] = (sel_1x[p] & y1[0]) | (sel_3x[p] & y3[0]);
            for (m = 1; m <= 15; m = m + 1) begin : gen_ppg_rest_mid
                assign ppg[p][m] = (sel_1x[p] & y1[m]) | (sel_2x[p] & y2[m]) | (sel_3x[p] & y3[m]);
            end
            assign ppg[p][16] = (sel_2x[p] & y2[16]) | (sel_3x[p] & y3[16]);
            assign ppg[p][17] = (sel_3x[p] & y3[17]);
        end
    endgenerate

    //--------------------------------------------------------------------------
    // Stage 1 Adder Tree: Four 18-bit RCAs
    //--------------------------------------------------------------------------
    assign P[1:0] = ppg1[1:0];

    // RCA 1_1: Combines PPG-1[17:2] and {PPG-2[17:2], 2'b00} (weight 2^2..2^19)
    wire [17:0] s1_1_sum;
    wire        s1_1_cout;
    rca_n #(.WIDTH(18)) u_rca_s1_1 (
        .a    ({2'b00, ppg1[17:2]}),
        .b    ({ppg2[17:2], 2'b00}),
        .cin  (1'b0),
        .sum  (s1_1_sum),
        .cout (s1_1_cout)
    );
    assign P[3:2] = s1_1_sum[1:0];

    // RCA 1_2: Combines PPG-3[17:2] and PPG-4[17:0] (weight 2^6..2^23)
    wire [17:0] s1_2_sum;
    wire        s1_2_cout;
    rca_n #(.WIDTH(18)) u_rca_s1_2 (
        .a    ({2'b00, ppg[2][17:2]}),
        .b    (ppg[3][17:0]),
        .cin  (1'b0),
        .sum  (s1_2_sum),
        .cout (s1_2_cout)
    );

    // RCA 1_3: Combines PPG-5[17:2] and PPG-6[17:0] (weight 2^10..2^27)
    wire [17:0] s1_3_sum;
    wire        s1_3_cout;
    rca_n #(.WIDTH(18)) u_rca_s1_3 (
        .a    ({2'b00, ppg[4][17:2]}),
        .b    (ppg[5][17:0]),
        .cin  (1'b0),
        .sum  (s1_3_sum),
        .cout (s1_3_cout)
    );

    // RCA 1_4: Combines PPG-7[17:2] and PPG-8[17:0] (weight 2^14..2^31)
    wire [17:0] s1_4_sum;
    wire        s1_4_cout;
    rca_n #(.WIDTH(18)) u_rca_s1_4 (
        .a    ({2'b00, ppg[6][17:2]}),
        .b    (ppg[7][17:0]),
        .cin  (1'b0),
        .sum  (s1_4_sum),
        .cout (s1_4_cout)
    );

    //--------------------------------------------------------------------------
    // Stage 2 Adder Tree: Two 20-bit RCAs
    //--------------------------------------------------------------------------
    // RCA 2_1 (weight 2^4..2^23): combines upper 17 bits of RCA 1_1 with PPG-3[1:0] and RCA 1_2
    wire [19:0] s2_1_a = {3'b000, s1_1_cout, s1_1_sum[17:2]};
    wire [19:0] s2_1_b = {s1_2_sum[17:0], ppg[2][1:0]};
    wire [19:0] s2_1_sum;
    wire        s2_1_cout_ raw;
    rca_n #(.WIDTH(20)) u_rca_s2_1 (
        .a    (s2_1_a),
        .b    (s2_1_b),
        .cin  (1'b0),
        .sum  (s2_1_sum),
        .cout (s2_1_cout_raw)
    );
    wire s2_1_cout = s2_1_cout_raw | s1_2_cout;
    assign P[7:4] = s2_1_sum[3:0];

    // RCA 2_2 (weight 2^12..2^31): combines upper 17 bits of RCA 1_3 with PPG-7[1:0] and RCA 1_4
    wire [19:0] s2_2_a = {3'b000, s1_3_cout, s1_3_sum[17:2]};
    wire [19:0] s2_2_b = {s1_4_sum[17:0], ppg[6][1:0]};
    wire [19:0] s2_2_sum;
    wire        s2_2_cout_unused;
    rca_n #(.WIDTH(20)) u_rca_s2_2 (
        .a    (s2_2_a),
        .b    (s2_2_b),
        .cin  (1'b0),
        .sum  (s2_2_sum),
        .cout (s2_2_cout_unused)
    );

    //--------------------------------------------------------------------------
    // Stage 3 Final Adder: One 24-bit RCA (weight 2^8..2^31)
    //--------------------------------------------------------------------------
    // Combines upper 17 bits of RCA 2_1 ({s2_1_cout, s2_1_sum[19:4]})
    // with PPG-5[1:0] (weight 2^8..2^9), s1_3_sum[1:0] (weight 2^10..2^11), and s2_2_sum[19:0] (weight 2^12..2^31)
    wire [23:0] s3_a = {7'b0000000, s2_1_cout, s2_1_sum[19:4]};
    wire [23:0] s3_b = {s2_2_sum[19:0], s1_3_sum[1:0], ppg[4][1:0]};
    wire        s3_cout_unused;

    rca_n #(.WIDTH(24)) u_rca_s3_final (
        .a    (s3_a),
        .b    (s3_b),
        .cin  (1'b0),
        .sum  (P[31:8]),
        .cout (s3_cout_unused)
    );

endmodule


//==============================================================================
// 3. Proposed Signed 16x16 Approximate Multiplier: AxEnMULT_XS_16x16
//==============================================================================

module AxEnMULT_XS_16x16 (
    input  wire signed [15:0] X,
    input  wire signed [15:0] Y,
    output wire signed [31:0] P
);
    //--------------------------------------------------------------------------
    // Baugh-Wooley Sign-Extended Multiples of Y for 16x16
    //--------------------------------------------------------------------------
    wire [15:0] y1_base = {~Y[15], Y[14:0]};
    wire [16:0] y2_base = {~Y[15], Y[14:0], 1'b0};

    // Shared 15-bit core adder for 3Y: adds y1_base[15:1] and ~Y[14:0]
    wire [14:0] y3_core_sum;
    wire        y3_core_cout;
    rca_n #(.WIDTH(15)) u_rca_3y_signed_core (
        .a    (y1_base[15:1]),
        .b    (~Y[14:0]),
        .cin  (1'b0),
        .sum  (y3_core_sum),
        .cout (y3_core_cout)
    );

    wire [16:0] y3_base = {y3_core_cout, y3_core_sum, y1_base[0]};

    // Sign-extended 18-bit multiples for PPG-1
    wire [17:0] y1_ppg1 = {2'b10, y1_base};
    wire [17:0] y2_ppg1 = {2'b01, y2_base[15:0]};
    wire [17:0] y3_ppg1 = {2'b01, y3_base[15:0]};

    // Sign-extended 18-bit multiples for PPG-2 through PPG-7
    wire [17:0] y1_ppg_mid = {2'b01, y1_base};
    wire [17:0] y2_ppg_mid = {2'b00, y2_base[15:0]};
    wire [17:0] y3_ppg_mid = {2'b00, y3_base[15:0]};

    // Sign-extended 18-bit 3Y multiple for PPG-8 (selected only by 3X of Encoder-8)
    wire [17:0] y3_ppg8;
    assign y3_ppg8[0]    = y1_base[0];
    assign y3_ppg8[15:1] = y3_core_sum;
    wire ha_c;
    half_adder u_ha_ppg8 (
        .a    (Y[15]),
        .b    (y3_core_cout),
        .sum  (y3_ppg8[16]),
        .cout (ha_c)
    );
    assign y3_ppg8[17] = 1'b1 ^ ha_c;

    //--------------------------------------------------------------------------
    // Eight Pair-wise Encoders for Operand X[15:0] (Encoder-8 only uses 3X)
    //--------------------------------------------------------------------------
    wire [6:0] sel_1x, sel_2x, sel_3x;
    wire       sel8_3x;

    genvar k;
    generate
        for (k = 0; k < 7; k = k + 1) begin : gen_s_enc
            encoder_pair u_enc (
                .x_low  (X[2*k]),
                .x_high (X[2*k+1]),
                .sel_1x (sel_1x[k]),
                .sel_2x (sel_2x[k]),
                .sel_3x (sel_3x[k])
            );
        end
    endgenerate
    assign sel8_3x = X[15] & X[14];

    //--------------------------------------------------------------------------
    // Partial Products Generation (PPG-1 to PPG-8)
    //--------------------------------------------------------------------------
    wire [17:0] ppg1;
    wire [17:2] ppg2;
    wire [17:0] ppg [2:7];

    genvar m, p;
    generate
        // PPG-1: First 4 LSBs of 2Y and 3Y truncated
        for (m = 0; m <= 3; m = m + 1) begin : gen_s_ppg1_lsb
            assign ppg1[m] = sel_1x[0] & y1_ppg1[m];
        end
        for (m = 4; m <= 17; m = m + 1) begin : gen_s_ppg1_msb
            assign ppg1[m] = (sel_1x[0] & y1_ppg1[m]) | (sel_2x[0] & y2_ppg1[m]) | (sel_3x[0] & y3_ppg1[m]);
        end

        // PPG-2: First 2 LSBs [1:0] truncated
        for (m = 2; m <= 17; m = m + 1) begin : gen_s_ppg2
            assign ppg2[m] = (sel_1x[1] & y1_ppg_mid[m]) | (sel_2x[1] & y2_ppg_mid[m]) | (sel_3x[1] & y3_ppg_mid[m]);
        end

        // PPG-3 through PPG-7: Full 18-bit sign-extended partial products
        for (p = 2; p <= 6; p = p + 1) begin : gen_s_ppg_mid
            for (m = 0; m <= 17; m = m + 1) begin : gen_s_ppg_bits
                assign ppg[p][m] = (sel_1x[p] & y1_ppg_mid[m]) | (sel_2x[p] & y2_ppg_mid[m]) | (sel_3x[p] & y3_ppg_mid[m]);
            end
        end

        // PPG-8: Selected by sel8_3x only
        for (m = 0; m <= 17; m = m + 1) begin : gen_s_ppg8
            assign ppg[7][m] = sel8_3x & y3_ppg8[m];
        end
    endgenerate

    //--------------------------------------------------------------------------
    // 3-Stage RCA Compression Tree (Identical topology to Unsigned 16x16)
    //--------------------------------------------------------------------------
    assign P[1:0] = ppg1[1:0];

    wire [17:0] s1_1_sum, s1_2_sum, s1_3_sum, s1_4_sum;
    wire        s1_1_cout, s1_2_cout, s1_3_cout, s1_4_cout;

    rca_n #(.WIDTH(18)) u_s_rca_s1_1 (.a({2'b00, ppg1[17:2]}),   .b({ppg2[17:2], 2'b00}), .cin(1'b0), .sum(s1_1_sum), .cout(s1_1_cout));
    rca_n #(.WIDTH(18)) u_s_rca_s1_2 (.a({2'b00, ppg[2][17:2]}), .b(ppg[3][17:0]),        .cin(1'b0), .sum(s1_2_sum), .cout(s1_2_cout));
    rca_n #(.WIDTH(18)) u_s_rca_s1_3 (.a({2'b00, ppg[4][17:2]}), .b(ppg[5][17:0]),        .cin(1'b0), .sum(s1_3_sum), .cout(s1_3_cout));
    rca_n #(.WIDTH(18)) u_s_rca_s1_4 (.a({2'b00, ppg[6][17:2]}), .b(ppg[7][17:0]),        .cin(1'b0), .sum(s1_4_sum), .cout(s1_4_cout));

    assign P[3:2] = s1_1_sum[1:0];

    wire [19:0] s2_1_sum, s2_2_sum;
    wire        s2_1_cout_raw, s2_2_cout_unused;

    rca_n #(.WIDTH(20)) u_s_rca_s2_1 (
        .a    ({3'b000, s1_1_cout, s1_1_sum[17:2]}),
        .b    ({s1_2_sum[17:0], ppg[2][1:0]}),
        .cin  (1'b0),
        .sum  (s2_1_sum),
        .cout (s2_1_cout_raw)
    );
    wire s2_1_cout = s2_1_cout_raw | s1_2_cout;
    assign P[7:4] = s2_1_sum[3:0];

    rca_n #(.WIDTH(20)) u_s_rca_s2_2 (
        .a    ({3'b000, s1_3_cout, s1_3_sum[17:2]}),
        .b    ({s1_4_sum[17:0], ppg[6][1:0]}),
        .cin  (1'b0),
        .sum  (s2_2_sum),
        .cout (s2_2_cout_unused)
    );

    wire s3_cout_unused;
    rca_n #(.WIDTH(24)) u_s_rca_s3_final (
        .a    ({7'b0000000, s2_1_cout, s2_1_sum[19:4]}),
        .b    ({s2_2_sum[19:0], s1_3_sum[1:0], ppg[4][1:0]}),
        .cin  (1'b0),
        .sum  (P[31:8]),
        .cout (s3_cout_unused)
    );

endmodule


//==============================================================================
// 4. Basys 3 Hardware Wrapper for 16x16 Multiplier (Time-Multiplexed I/O)
//    - Uses 16 Slide Switches (sw[15:0]) to load X[15:0] (btnL) and Y[15:0] (btnR)
//    - Uses btnU to toggle between P[15:0] (Lower 16 bits) and P[31:16] (Upper 16 bits)
//==============================================================================

module basys3_top_16x16 (
    input  wire        clk,
    input  wire [15:0] sw,
    input  wire        btnL,  // Press to latch sw[15:0] into X[15:0]
    input  wire        btnR,  // Press to latch sw[15:0] into Y[15:0]
    input  wire        btnU,  // Hold to view upper product bits P[31:16] on LEDs
    output wire [15:0] led
);
    reg [15:0] reg_X = 16'd0;
    reg [15:0] reg_Y = 16'd0;
    wire [31:0] prod_P;

    always @(posedge clk) begin
        if (btnL) reg_X <= sw;
        if (btnR) reg_Y <= sw;
    end

    // Instantiate Unsigned 16x16 (or swap with AxEnMULT_XS_16x16 for Signed)
    AxEnMULT_X_16x16 u_mult16 (
        .X (reg_X),
        .Y (reg_Y),
        .P (prod_P)
    );

    assign led = btnU ? prod_P[31:16] : prod_P[15:0];

endmodule


