`timescale 1ns / 1ps

//==============================================================================
// 1. INTERFACE: Connects the SV Verification Environment to the HBDM DUT
//==============================================================================
interface hbdm_if #(
    parameter int WIDTH = 16
)(
    input logic clk
);
    logic [WIDTH-1:0]     X;
    logic [WIDTH-1:0]     Y;
    logic [(2*WIDTH)-1:0] Z;

    clocking drv_cb @(posedge clk);
        default input #1ns output #1ns;
        output X, Y;
        input  Z;
    endclocking

    clocking mon_cb @(posedge clk);
        default input #1ns output #1ns;
        input X, Y, Z;
    endclocking

    modport DRV (clocking drv_cb, input clk);
    modport MON (clocking mon_cb, input clk);
endinterface


//==============================================================================
// 2. TRANSACTION CLASS: Stimulus Generation & HBDM Error Calculation
//==============================================================================
class hbdm_transaction #(
    parameter int WIDTH = 16
);
    rand bit [WIDTH-1:0]     X;
    rand bit [WIDTH-1:0]     Y;
         bit [(2*WIDTH)-1:0] Z_approx;
         longint unsigned    Z_exact;
         longint unsigned    approx_val;
         real                ed;      // Error Distance |Z_approx - Z_exact|
         real                rel_ed;  // Relative Error Distance ED / Z_exact
         real                sq_ed;   // Squared Error Distance for PSNR

    // Constrained-random stimulus targeting Decoder & Radix-16 Booth corner cases
    constraint c_hbdm_stimulus {
        X dist {
            {WIDTH{1'b0}}      := 5,
            {WIDTH{1'b1}}      := 5,
            [1 : (1<<WIDTH)-2] :/ 90
        };
        // Ensure both Y_MSB=0 and Y_MSB=1 (unsigned correction mux in Fig. 5) are heavily tested
        Y[WIDTH-1] dist { 1'b0 := 50, 1'b1 := 50 };
        // Exercise all 4-bit Decoder patterns in Y[3:0] (Table 1)
        Y[3:0] dist {
            4'b0000 := 10,
            4'b0110 := 10, // Paper worked example in Section 4.1
            4'b1111 := 10, // Max OR compression in Table 1
            [1:14]  :/ 70
        };
    }

    function void evaluate();
        Z_exact    = longint'(X) * longint'(Y);
        approx_val = longint'(Z_approx);

        ed    = (approx_val > Z_exact) ? real'(approx_val - Z_exact)
                                       : real'(Z_exact - approx_val);
        sq_ed = ed * ed;

        // MRED definition per Liang et al. (2013) cited in Section 5
        if (Z_exact > 0)
            rel_ed = ed / real'(Z_exact);
        else
            rel_ed = 0.0;
    endfunction

    // Helper: Returns 1 if the lower half Y_L has at most one '1' bit per 4-bit decoder nibble
    // (When only one bit in a decoder nibble is '1', bitwise OR has zero overlap -> Exact!)
    function bit is_decoder_exact_case();
        if (WIDTH == 8) begin
            return ($onehot0(Y[3:0]));
        end else begin
            // In 16x16, exact when Y_L == 0 or only a single bit is set in Y[3:0] with Y[7:4]==0 (or vice versa)
            return ($onehot0(Y[7:0]));
        end
    endfunction

    function void display(string tag = "HBDM_TR");
        $display("[%s] X=%0d, Y=%0d (Y_H=%b, Y_L=%b) | Exact=%0d, Approx=%0d | ED=%0.0f, RelED=%0.4f",
                 tag, X, Y, Y[WIDTH-1 : WIDTH/2], Y[(WIDTH/2)-1 : 0],
                 Z_exact, approx_val, ed, rel_ed);
    endfunction
endclass


//==============================================================================
// 3. GENERATOR CLASS: Directed Paper Tests + Exhaustive/Random Stimulus
//==============================================================================
class hbdm_generator #(
    parameter int WIDTH = 16
);
    typedef hbdm_transaction #(WIDTH) tr_t;
    mailbox #(tr_t) gen2drv_mbx;
    event           drv_done;
    int             num_random_vectors;
    bit             run_exhaustive;

    function new(mailbox #(tr_t) mbx, event done_ev, int num_vec = 5000, bit exhaustive = 0);
        this.gen2drv_mbx        = mbx;
        this.drv_done           = done_ev;
        this.num_random_vectors = num_vec;
        this.run_exhaustive     = exhaustive;
    endfunction

    task send_directed(bit [WIDTH-1:0] dx, bit [WIDTH-1:0] dy);
        tr_t tr = new();
        tr.X = dx;
        tr.Y = dy;
        gen2drv_mbx.put(tr);
        @(drv_done);
    endtask

    task run();
        if (run_exhaustive && WIDTH == 8) begin
            // Full 65,536 (256x256) sweep as described in Section 5 of the paper
            for (int ix = 0; ix < 256; ix++) begin
                for (int iy = 0; iy < 256; iy++) begin
                    send_directed(ix[7:0], iy[7:0]);
                end
            end
        end else begin
            // 1. Directed Architectural Corner Cases:
            //    (a) Zero operands
            send_directed('0, '0);
            //    (b) Paper Section 4.1 Decoder example: Y[3:0] = 4'b0110 -> (X<<2)|(X<<1)
            send_directed(WIDTH'(8'd45), WIDTH'(8'b0000_0110));
            //    (c) Hard Booth Multiples (3X, 5X, 7X) with Y_L = 0 (Must be 100% Exact)
            send_directed(WIDTH'(8'd100), WIDTH'(8'b0011_0000)); // 3X in R16BA
            send_directed(WIDTH'(8'd100), WIDTH'(8'b0101_0000)); // 5X in R16BA
            send_directed(WIDTH'(8'd100), WIDTH'(8'b0111_0000)); // 7X in R16BA
            //    (d) Unsigned MSB Special Case Y[WIDTH-1] = 1 (Fig. 5 & Fig. 6 8-bit/16-bit Adder + Mux)
            send_directed({WIDTH{1'b1}}, {1'b1, {(WIDTH-1){1'b0}}});
            send_directed({WIDTH{1'b1}}, {WIDTH{1'b1}});

            // 2. Constrained-Random Campaign
            for (int i = 0; i < num_random_vectors; i++) begin
                tr_t tr = new();
                if (!tr.randomize()) $fatal(1, "HBDM Transaction Randomization Failed!");
                gen2drv_mbx.put(tr);
                @(drv_done);
            end
        end
    endtask
endclass


//==============================================================================
// 4. DRIVER CLASS: Drives X and Y onto the HBDM Virtual Interface
//==============================================================================
class hbdm_driver #(
    parameter int WIDTH = 16
);
    typedef hbdm_transaction #(WIDTH) tr_t;
    virtual hbdm_if #(WIDTH).DRV vif;
    mailbox #(tr_t) gen2drv_mbx;
    event           drv_done;

    function new(virtual hbdm_if #(WIDTH).DRV vif, mailbox #(tr_t) mbx, event done_ev);
        this.vif         = vif;
        this.gen2drv_mbx = mbx;
        this.drv_done    = done_ev;
    endfunction

    task run();
        vif.drv_cb.X <= '0;
        vif.drv_cb.Y <= '0;
        forever begin
            tr_t tr;
            gen2drv_mbx.get(tr);
            @(vif.drv_cb);
            vif.drv_cb.X <= tr.X;
            vif.drv_cb.Y <= tr.Y;
            ->drv_done;
        end
    endtask
endclass


//==============================================================================
// 5. MONITOR CLASS: Samples Interface & Covers Decoder + Radix-16 Booth States
//==============================================================================
class hbdm_monitor #(
    parameter int WIDTH = 16
);
    typedef hbdm_transaction #(WIDTH) tr_t;
    virtual hbdm_if #(WIDTH).MON vif;
    mailbox #(tr_t) mon2scb_mbx;

    bit [WIDTH-1:0] cov_X, cov_Y;

    // Functional Coverage for Table 1 (4-bit Decoder) & Fig. 4/5 (Radix-16 Booth)
    covergroup cg_hbdm;
        option.per_instance = 1;

        // Cover all 16 rows of Table 1 (Proposed 4-bit Decoder Truth Table)
        cp_decoder_y_low: coverpoint cov_Y[3:0] {
            bins tbl1_rows[] = {[4'b0000 : 4'b1111]};
        }

        // Cover Radix-16 Booth nibble in MSB half (0X..8X, -8X..-1X)
        cp_booth_y_high: coverpoint cov_Y[WIDTH-1 : WIDTH-4] {
            bins pos_multiples[] = {[4'b0000 : 4'b0111]}; // Y_MSB = 0 (+0X .. +7X)
            bins neg_multiples[] = {[4'b1000 : 4'b1111]}; // Y_MSB = 1 (-8X .. -1X + Unsigned X corr)
        }

        // Cover the special Y_MSB selection line (Fig. 5 2:1 Multiplexers)
        cp_y_msb_sel: coverpoint cov_Y[WIDTH-1] {
            bins pos_branch = {1'b0};
            bins neg_unsigned_corr_branch = {1'b1};
        }

        // Cross Decoder states with Booth MSB sign/correction select
        cx_dec_booth: cross cp_decoder_y_low, cp_y_msb_sel;
    endgroup

    function new(virtual hbdm_if #(WIDTH).MON vif, mailbox #(tr_t) mbx);
        this.vif         = vif;
        this.mon2scb_mbx = mbx;
        cg_hbdm          = new();
    endfunction

    task run();
        @(vif.mon_cb);
        forever begin
            tr_t tr = new();
            @(vif.mon_cb);
            tr.X        = vif.mon_cb.X;
            tr.Y        = vif.mon_cb.Y;
            tr.Z_approx = vif.mon_cb.Z;

            cov_X = tr.X;
            cov_Y = tr.Y;
            cg_hbdm.sample();

            mon2scb_mbx.put(tr);
        end
    endtask
endclass


//==============================================================================
// 6. SCOREBOARD CLASS: Verifies Exact Sub-Blocks & Computes ER, MRED, NMED, PSNR
//==============================================================================
class hbdm_scoreboard #(
    parameter int WIDTH       = 16,
    parameter int HBDM_CONFIG = 4
);
    typedef hbdm_transaction #(WIDTH) tr_t;
    mailbox #(tr_t) mon2scb_mbx;

    longint total_vectors       = 0;
    longint error_vectors       = 0;
    longint exact_booth_checks  = 0;
    longint exact_booth_fails   = 0;
    real    sum_ed              = 0.0;
    real    sum_rel_ed          = 0.0;
    real    sum_sq_ed           = 0.0;
    real    max_ed              = 0.0;

    function new(mailbox #(tr_t) mbx);
        this.mon2scb_mbx = mbx;
    endfunction

    task run();
        forever begin
            tr_t tr;
            mon2scb_mbx.get(tr);
            tr.evaluate();

            total_vectors++;
            if (tr.ed != 0.0) error_vectors++;

            sum_ed     += tr.ed;
            sum_rel_ed += tr.rel_ed;
            sum_sq_ed  += tr.sq_ed;
            if (tr.ed > max_ed) max_ed = tr.ed;

            // Golden Self-Check 1: Whenever Y_L is a single power-of-2 (or 0),
            // the 4-bit Decoder introduces 0 error, so the Radix-16 Booth + Hybrid/CLA
            // pipeline MUST produce the 100% exact product!
            if (tr.is_decoder_exact_case()) begin
                exact_booth_checks++;
                if (tr.ed != 0.0) begin
                    exact_booth_fails++;
                    tr.display("BOOTH_EXACT_FAIL");
                    $error("[FAIL] Radix-16 Booth/Adder mismatch on exact vector: X=%0d, Y=%0d",
                           tr.X, tr.Y);
                end
            end

            // Golden Self-Check 2: Paper Section 4.1 Decoder Example (Y[3:0] = 4'b0110, Y_H = 0)
            if (tr.Y == WIDTH'(4'b0110)) begin
                longint unsigned expected_pp1 = (longint'(tr.X) << 2) | (longint'(tr.X) << 1);
                if (tr.approx_val !== expected_pp1) begin
                    $error("[DEC_EXAMPLE_FAIL] X=%0d, Y=0110: Expected (X<<2)|(X<<1)=%0d, Got %0d",
                           tr.X, expected_pp1, tr.approx_val);
                end
            end
        end
    endtask

    function void report_metrics(real cov_pct);
        real n       = (total_vectors > 0) ? real'(total_vectors) : 1.0;
        real max_op  = real'((1ULL << WIDTH) - 1);
        real max_p   = max_op * max_op; // Normalization factor (2^n - 1)^2 for NMED & PSNR
        real med     = sum_ed / n;
        real nmed    = med / max_p;
        real mred    = sum_rel_ed / n;
        real mse     = sum_sq_ed / n;
        real psnr    = (mse > 0.0) ? (10.0 * $log10((max_p * max_p) / mse)) : 999.99;

        $display("\n======================================================================");
        $display("  HBDM SYSTEMVERILOG VERIFICATION & QUALITY REPORT (Table 4 / Sec. 5)");
        $display("  Multiplier Architecture : HBDM-%0d (%0dx%0d-bit, %0d-bit Output Z)",
                 HBDM_CONFIG, WIDTH, WIDTH, 2*WIDTH);
        $display("======================================================================");
        $display("  Total Vectors Simulated      : %0d", total_vectors);
        $display("  Functional Coverage          : %0.2f %%", cov_pct);
        $display("  Exact Booth/Adder Checks     : %0d Passed, %0d Failed",
                 exact_booth_checks - exact_booth_fails, exact_booth_fails);
        $display("----------------------------------------------------------------------");
        $display("  Error Rate (ER %%)            : %0.2f %%", (real'(error_vectors) / n) * 100.0);
        $display("  Mean Relative ED (MRED)      : %0.4f", mred);
        $display("  Normalized Mean ED (NMED)    : %0.4f", nmed);
        $display("  Mean Error Distance (MED)    : %0.4f", med);
        $display("  Worst-Case Error Dist. (WCE) : %0.1f", max_ed);
        $display("  Image Metric Proxy (PSNR)    : %0.2f dB", psnr);
        $display("======================================================================\n");
    endfunction
endclass


//==============================================================================
// 7. ENVIRONMENT CLASS: Instantiates & Connects All Testbench Components
//==============================================================================
class hbdm_env #(
    parameter int WIDTH       = 16,
    parameter int HBDM_CONFIG = 4
);
    typedef hbdm_transaction #(WIDTH) tr_t;

    hbdm_generator  #(WIDTH)              gen;
    hbdm_driver     #(WIDTH)              drv;
    hbdm_monitor    #(WIDTH)              mon;
    hbdm_scoreboard #(WIDTH, HBDM_CONFIG) scb;

    mailbox #(tr_t) gen2drv_mbx;
    mailbox #(tr_t) mon2scb_mbx;
    event           drv_done;

    virtual hbdm_if #(WIDTH) vif;

    function new(virtual hbdm_if #(WIDTH) vif, int num_vec = 5000, bit exhaustive = 0);
        this.vif    = vif;
        gen2drv_mbx = new(1);
        mon2scb_mbx = new();

        gen = new(gen2drv_mbx, drv_done, num_vec, exhaustive);
        drv = new(vif.DRV, gen2drv_mbx, drv_done);
        mon = new(vif.MON, mon2scb_mbx);
        scb = new(mon2scb_mbx);
    endfunction

    task run();
        fork
            gen.run();
            drv.run();
            mon.run();
            scb.run();
        join_any

        repeat (3) @(posedge vif.clk);
        scb.report_metrics(mon.cg_hbdm.get_inst_coverage());
    endtask
endclass


//==============================================================================
// 8. TOP-LEVEL TESTBENCH MODULE
//==============================================================================
module tb_hbdm_top;
    //--------------------------------------------------------------------------
    // USER CONFIGURATION PARAMETERS:
    //   WIDTH       = 16 (Tests 16x16 HBDM_16x16 with 32-bit output Z[31:0])
    //               = 8  (Tests 8x8 HBDM_8x8 with 16-bit output Z[15:0])
    //   HBDM_CONFIG = 1, 2, 3, or 4 (Selects HBDM-1/2/3/4 from Table 2)
    //   EXHAUSTIVE  = 1 (When WIDTH=8, runs all 65,536 vectors to match Table 4)
    //--------------------------------------------------------------------------
    localparam int WIDTH       = 16;
    localparam int HBDM_CONFIG = 4;    // Default: HBDM-4 (All Hybrid Adders)
    localparam int NUM_RANDOM  = 5000;
    localparam bit EXHAUSTIVE  = 0;    // Set to 1 with WIDTH=8 for full 65,536 sweep

    logic clk = 0;
    always #5 clk = ~clk; // 100 MHz simulation clock

    // Instantiate HBDM Interface
    hbdm_if #(WIDTH) intf (clk);

    //--------------------------------------------------------------------------
    // Conditionally Instantiate HBDM_8x8 or HBDM_16x16
    //--------------------------------------------------------------------------
    generate
        if (WIDTH == 8) begin : gen_hbdm_8bit
            HBDM_8x8 #(
                .CONFIG (HBDM_CONFIG)
            ) dut (
                .X (intf.X),
                .Y (intf.Y),
                .Z (intf.Z)
            );
        end else if (WIDTH == 16) begin : gen_hbdm_16bit
            HBDM_16x16 #(
                .CONFIG (HBDM_CONFIG)
            ) dut (
                .X (intf.X),
                .Y (intf.Y),
                .Z (intf.Z)
            );
        end
    endgenerate

    // Instantiate and Run Verification Environment
    hbdm_env #(WIDTH, HBDM_CONFIG) env;

    initial begin
        env = new(intf, NUM_RANDOM, EXHAUSTIVE);
        env.run();
        $finish;
    end
endmodule