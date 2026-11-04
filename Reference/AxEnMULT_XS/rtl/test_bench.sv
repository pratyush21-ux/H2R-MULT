`timescale 1ns / 1ps

//==============================================================================
// 1. INTERFACE: Connects the SV Testbench Classes to the Combinational DUT
//==============================================================================
interface axenmult_if #(
    parameter int WIDTH = 8
)(
    input logic clk
);
    logic [WIDTH-1:0]     X;
    logic [WIDTH-1:0]     Y;
    logic [(2*WIDTH)-1:0] P;

    // Clocking block for synchronous driving and sampling
    clocking drv_cb @(posedge clk);
        default input #1ns output #1ns;
        output X, Y;
        input  P;
    endclocking

    clocking mon_cb @(posedge clk);
        default input #1ns output #1ns;
        input X, Y, P;
    endclocking

    modport DRV (clocking drv_cb, input clk);
    modport MON (clocking mon_cb, input clk);
endinterface


//==============================================================================
// 2. TRANSACTION CLASS: Encapsulates Stimulus, Outputs, & Error Calculations
//==============================================================================
class axenmult_transaction #(
    parameter int WIDTH     = 8,
    parameter bit IS_SIGNED = 0
);
    rand bit [WIDTH-1:0]     X;
    rand bit [WIDTH-1:0]     Y;
         bit [(2*WIDTH)-1:0] P_approx;
         longint             exact_val;
         longint             approx_val;
         real                abs_err;
         real                rel_err;

    // Constraints for distribution testing (corner cases + uniform random)
    constraint c_dist {
        X dist {
            {WIDTH{1'b0}} := 5,
            {WIDTH{1'b1}} := 5,
            [1 : (1<<WIDTH)-2] :/ 90
        };
        Y dist {
            {WIDTH{1'b0}} := 5,
            {WIDTH{1'b1}} := 5,
            [1 : (1<<WIDTH)-2] :/ 90
        };
    }

    // Compute exact product and error distances (Equations 1-6)
    function void evaluate();
        real denom;
        if (IS_SIGNED) begin
            exact_val  = longint'(signed'(X)) * longint'(signed'(Y));
            approx_val = longint'(signed'(P_approx));
        end else begin
            exact_val  = longint'(unsigned'(X)) * longint'(unsigned'(Y));
            approx_val = longint'(unsigned'(P_approx));
        end

        abs_err = (approx_val > exact_val) ? real'(approx_val - exact_val)
                                           : real'(exact_val - approx_val);

        // Denominator max(1, |O_orig|) per Eq. (4) & Eq. (6)
        denom   = (exact_val < 0) ? real'(-exact_val) : real'(exact_val);
        if (denom < 1.0) denom = 1.0;

        rel_err = abs_err / denom;
    endfunction

    function axenmult_transaction #(WIDTH, IS_SIGNED) clone();
        clone = new();
        clone.X          = this.X;
        clone.Y          = this.Y;
        clone.P_approx   = this.P_approx;
        clone.exact_val  = this.exact_val;
        clone.approx_val = this.approx_val;
        clone.abs_err    = this.abs_err;
        clone.rel_err    = this.rel_err;
    endfunction

    function void display(string tag = "TR");
        if (IS_SIGNED)
            $display("[%s] X=%0d (%b), Y=%0d (%b) | Exact=%0d, Approx=%0d | AbsErr=%0.0f, RelErr=%0.4f",
                     tag, signed'(X), X, signed'(Y), Y, exact_val, approx_val, abs_err, rel_err);
        else
            $display("[%s] X=%0d (%b), Y=%0d (%b) | Exact=%0d, Approx=%0d | AbsErr=%0.0f, RelErr=%0.4f",
                     tag, X, X, Y, Y, exact_val, approx_val, abs_err, rel_err);
    endfunction
endclass


//==============================================================================
// 3. GENERATOR CLASS: Produces Directed Paper Vectors + Random/Exhaustive Tests
//==============================================================================
class axenmult_generator #(
    parameter int WIDTH     = 8,
    parameter bit IS_SIGNED = 0
);
    typedef axenmult_transaction #(WIDTH, IS_SIGNED) tr_t;
    mailbox #(tr_t) gen2drv_mbx;
    event           drv_done;
    int             num_random_vectors;
    bit             run_exhaustive; // Set to 1 for full 65,536 8x8 sweep

    function new(mailbox #(tr_t) mbx, event done_ev, int num_vec = 1000, bit exhaustive = 0);
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
        // 1. Inject Directed Vectors from Paper (Fig. 7 & Fig. 8)
        if (WIDTH == 8 && !IS_SIGNED) begin
            // Fig. 7: X = 237 (11101101), Y = 245 (11110101) -> Expected Approx = 58053
            send_directed(8'd237, 8'd245);
        end else if (WIDTH == 8 && IS_SIGNED) begin
            // Fig. 8: X = -19 (11101101), Y = -105 (10010111) -> Expected Approx = 1991
            send_directed(-8'sd19, -8'sd105);
        end

        // 2. Exhaustive 8x8 Sweep (65,536 vectors) OR Constrained-Random Run
        if (run_exhaustive && WIDTH == 8) begin
            for (int ix = 0; ix < 256; ix++) begin
                for (int iy = 0; iy < 256; iy++) begin
                    send_directed(ix[7:0], iy[7:0]);
                end
            end
        end else begin
            for (int i = 0; i < num_random_vectors; i++) begin
                tr_t tr = new();
                if (!tr.randomize()) $fatal(1, "Randomization failed!");
                gen2drv_mbx.put(tr);
                @(drv_done);
            end
        end
    endtask
endclass


//==============================================================================
// 4. DRIVER CLASS: Drives Transactions onto the Virtual Interface
//==============================================================================
class axenmult_driver #(
    parameter int WIDTH     = 8,
    parameter bit IS_SIGNED = 0
);
    typedef axenmult_transaction #(WIDTH, IS_SIGNED) tr_t;
    virtual axenmult_if #(WIDTH).DRV vif;
    mailbox #(tr_t) gen2drv_mbx;
    event           drv_done;

    function new(virtual axenmult_if #(WIDTH).DRV vif, mailbox #(tr_t) mbx, event done_ev);
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
// 5. MONITOR CLASS: Samples Interface Signals & Collects Functional Coverage
//==============================================================================
class axenmult_monitor #(
    parameter int WIDTH     = 8,
    parameter bit IS_SIGNED = 0
);
    typedef axenmult_transaction #(WIDTH, IS_SIGNED) tr_t;
    virtual axenmult_if #(WIDTH).MON vif;
    mailbox #(tr_t) mon2scb_mbx;

    bit [WIDTH-1:0] cov_X, cov_Y;

    // Functional Coverage for Pair-Wise Encoders (Table I: 00->0, 01->1X, 10->2X, 11->3X)
    covergroup cg_axenmult;
        option.per_instance = 1;
        cp_enc1: coverpoint cov_X[1:0] {
            bins zero = {2'b00};
            bins sel_1X = {2'b01};
            bins sel_2X = {2'b10};
            bins sel_3X = {2'b11};
        }
        cp_enc2: coverpoint cov_X[3:2];
        cp_enc3: coverpoint cov_X[5:4];
        cp_enc4: coverpoint cov_X[7:6];
        cp_y_corners: coverpoint cov_Y {
            bins min_val = {0};
            bins max_val = {{WIDTH{1'b1}}};
            bins others  = default;
        }
        cx_enc1_y: cross cp_enc1, cp_y_corners;
    endgroup

    function new(virtual axenmult_if #(WIDTH).MON vif, mailbox #(tr_t) mbx);
        this.vif         = vif;
        this.mon2scb_mbx = mbx;
        cg_axenmult      = new();
    endfunction

    task run();
        // Wait for first driven vector to settle
        @(vif.mon_cb);
        forever begin
            tr_t tr = new();
            @(vif.mon_cb);
            tr.X        = vif.mon_cb.X;
            tr.Y        = vif.mon_cb.Y;
            tr.P_approx = vif.mon_cb.P;

            cov_X = tr.X;
            cov_Y = tr.Y;
            cg_axenmult.sample();

            mon2scb_mbx.put(tr);
        end
    endtask
endclass


//==============================================================================
// 6. SCOREBOARD CLASS: Self-Checks Paper Examples & Computes MRED/MAE/WCE
//==============================================================================
class axenmult_scoreboard #(
    parameter int WIDTH     = 8,
    parameter bit IS_SIGNED = 0
);
    typedef axenmult_transaction #(WIDTH, IS_SIGNED) tr_t;
    mailbox #(tr_t) mon2scb_mbx;

    longint total_vectors = 0;
    longint error_vectors = 0;
    real    sum_abs_err   = 0.0;
    real    sum_sq_err    = 0.0;
    real    sum_rel_err   = 0.0;
    real    max_abs_err   = 0.0;
    real    max_rel_err   = 0.0;

    function new(mailbox #(tr_t) mbx);
        this.mon2scb_mbx = mbx;
    endfunction

    task run();
        forever begin
            tr_t tr;
            mon2scb_mbx.get(tr);
            tr.evaluate();

            total_vectors++;
            if (tr.abs_err != 0.0) error_vectors++;

            sum_abs_err += tr.abs_err;
            sum_sq_err  += (tr.abs_err * tr.abs_err);
            sum_rel_err += tr.rel_err;

            if (tr.abs_err > max_abs_err) max_abs_err = tr.abs_err;
            if (tr.rel_err > max_rel_err) max_rel_err = tr.rel_err;

            // Golden Check for Paper Worked Examples (Fig. 7 & Fig. 8)
            if (WIDTH == 8 && !IS_SIGNED && tr.X == 8'd237 && tr.Y == 8'd245) begin
                tr.display("FIG7_CHECK");
                if (tr.P_approx == 16'd58053)
                    $display("   --> [PASS] Matches Paper Fig. 7 (Exact=58065, Approx=58053, Diff=12)");
                else
                    $error("   --> [FAIL] Expected 58053, Got %0d", tr.P_approx);
            end

            if (WIDTH == 8 && IS_SIGNED && signed'(tr.X) == -8'sd19 && signed'(tr.Y) == -8'sd105) begin
                tr.display("FIG8_CHECK");
                if (signed'(tr.P_approx) == 16'sd1991)
                    $display("   --> [PASS] Matches Paper Fig. 8 (Exact=1995, Approx=1991, Diff=4)");
                else
                    $error("   --> [FAIL] Expected 1991, Got %0d", signed'(tr.P_approx));
            end
        end
    endtask

    function void report_metrics(real cov_pct);
        real n = (total_vectors > 0) ? real'(total_vectors) : 1.0;
        $display("\n======================================================================");
        $display("  AxEnMULT SYSTEMVERILOG VERIFICATION & ERROR METRIC SUMMARY");
        $display("  Configuration      : %0dx%0d %s Multiplier",
                 WIDTH, WIDTH, IS_SIGNED ? "SIGNED (AxEnMULT-XS)" : "UNSIGNED (AxEnMULT-X)");
        $display("======================================================================");
        $display("  Total Vectors Run  : %0d", total_vectors);
        $display("  Functional Cov.    : %0.2f %%", cov_pct);
        $display("----------------------------------------------------------------------");
        $display("  Eq.(1) ER   (Error Rate)                  : %0.4f (%0.2f %%)",
                 real'(error_vectors)/n, (real'(error_vectors)/n)*100.0);
        $display("  Eq.(2) MAE  (Mean Absolute Error)         : %0.4f", sum_abs_err / n);
        $display("  Eq.(3) MSE  (Mean Square Error)           : %0.4f", sum_sq_err / n);
        $display("  Eq.(4) MRED (Mean Relative Error Dist.)   : %0.4f (x 10^-2 = %0.2f)",
                 sum_rel_err / n, (sum_rel_err / n) * 100.0);
        $display("  Eq.(5) WCE  (Worst-Case Absolute Error)   : %0.1f", max_abs_err);
        $display("  Eq.(6) WCRE (Worst-Case Relative Error)   : %0.4f (%0.2f %%)",
                 max_rel_err, max_rel_err * 100.0);
        $display("======================================================================\n");
    endfunction
endclass


//==============================================================================
// 7. ENVIRONMENT CLASS: Instantiates & Connects All Verification Components
//==============================================================================
class axenmult_env #(
    parameter int WIDTH     = 8,
    parameter bit IS_SIGNED = 0
);
    typedef axenmult_transaction #(WIDTH, IS_SIGNED) tr_t;

    axenmult_generator  #(WIDTH, IS_SIGNED) gen;
    axenmult_driver     #(WIDTH, IS_SIGNED) drv;
    axenmult_monitor    #(WIDTH, IS_SIGNED) mon;
    axenmult_scoreboard #(WIDTH, IS_SIGNED) scb;

    mailbox #(tr_t) gen2drv_mbx;
    mailbox #(tr_t) mon2scb_mbx;
    event           drv_done;

    virtual axenmult_if #(WIDTH) vif;

    function new(virtual axenmult_if #(WIDTH) vif, int num_vec = 2000, bit exhaustive = 0);
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

        // Allow pipeline/monitor to drain final transaction
        repeat (3) @(posedge vif.clk);
        scb.report_metrics(mon.cg_axenmult.get_inst_coverage());
    endtask
endclass


//==============================================================================
// 8. TOP-LEVEL TESTBENCH MODULE
//==============================================================================
module tb_axenmult_top;
    //--------------------------------------------------------------------------
    // USER CONFIGURATION PARAMETERS:
    //   WIDTH      = 8  (for 8x8 AxEnMULT_X / AxEnMULT_XS)
    //              = 16 (for 16x16 AxEnMULT_X_16x16 / AxEnMULT_XS_16x16)
    //   IS_SIGNED  = 0  (Unsigned) or 1 (Signed)
    //   EXHAUSTIVE = 1  (Runs all 65,536 vectors for 8x8 to match Table III MRED)
    //--------------------------------------------------------------------------
    localparam int WIDTH      = 8;
    localparam bit IS_SIGNED  = 0;
    localparam int NUM_RANDOM = 5000;
    localparam bit EXHAUSTIVE = 0; // Set to 1 to run full 65,536 8x8 sweep

    logic clk = 0;
    always #5 clk = ~clk; // 100 MHz simulation clock

    // Instantiate SystemVerilog Interface
    axenmult_if #(WIDTH) intf (clk);

    //--------------------------------------------------------------------------
    // Conditionally Instantiate the Selected DUT
    //--------------------------------------------------------------------------
    generate
        if (WIDTH == 8 && !IS_SIGNED) begin : gen_dut_8u
            AxEnMULT_X dut (.X(intf.X), .Y(intf.Y), .P(intf.P));
        end else if (WIDTH == 8 && IS_SIGNED) begin : gen_dut_8s
            AxEnMULT_XS dut (.X(intf.X), .Y(intf.Y), .P(intf.P));
        end else if (WIDTH == 16 && !IS_SIGNED) begin : gen_dut_16u
            AxEnMULT_X_16x16 dut (.X(intf.X), .Y(intf.Y), .P(intf.P));
        end else if (WIDTH == 16 && IS_SIGNED) begin : gen_dut_16s
            AxEnMULT_XS_16x16 dut (.X(intf.X), .Y(intf.Y), .P(intf.P));
        end
    endgenerate

    // Instantiate Verification Environment
    axenmult_env #(WIDTH, IS_SIGNED) env;

    initial begin
        env = new(intf, NUM_RANDOM, EXHAUSTIVE);
        env.run();
        $finish;
    end
endmodule