`timescale 1ns / 1ps

//==============================================================================
// 1. INTERFACE: Connects the SV Verification Environment to the EvoApproxLib DUT
//==============================================================================
interface evo_mult_if #(
    parameter int WIDTH = 16
)(
    input logic clk
);
    logic [WIDTH-1:0]     A;
    logic [WIDTH-1:0]     B;
    logic [(2*WIDTH)-1:0] O;

    clocking drv_cb @(posedge clk);
        default input #1ns output #1ns;
        output A, B;
        input  O;
    endclocking

    clocking mon_cb @(posedge clk);
        default input #1ns output #1ns;
        input A, B, O;
    endclocking

    modport DRV (clocking drv_cb, input clk);
    modport MON (clocking mon_cb, input clk);
endinterface


//==============================================================================
// 2. TRANSACTION CLASS: Encapsulates Input Vectors & Eq. (1)-(6) Error Distance
//==============================================================================
class evo_transaction #(
    parameter int WIDTH = 16
);
    rand bit [WIDTH-1:0]     A;
    rand bit [WIDTH-1:0]     B;
         bit [(2*WIDTH)-1:0] O_approx;
         longint             O_orig;
         longint             approx_val;
         real                abs_err;
         real                sq_err;
         real                rel_err;

    // Constraint to ensure corner cases (0, max, powers of 2) + uniform random
    constraint c_evo_stimulus {
        A dist {
            {WIDTH{1'b0}}      := 5,
            {WIDTH{1'b1}}      := 5,
            [1 : (1<<WIDTH)-2] :/ 90
        };
        B dist {
            {WIDTH{1'b0}}      := 5,
            {WIDTH{1'b1}}      := 5,
            [1 : (1<<WIDTH)-2] :/ 90
        };
    }

    // Evaluate candidate circuit output against accurate circuit O_orig
    // following Section II-A (Equations 1 to 6) of EVO.pdf
    function void evaluate();
        real denom;
        O_orig     = longint'(unsigned'(A)) * longint'(unsigned'(B));
        approx_val = longint'(unsigned'(O_approx));

        // |O_approx^(i) - O_orig^(i)|
        abs_err = (approx_val > O_orig) ? real'(approx_val - O_orig)
                                        : real'(O_orig - approx_val);

        // (O_approx^(i) - O_orig^(i))^2 for MSE (Eq. 3)
        sq_err  = abs_err * abs_err;

        // max(1, O_orig^(i)) denominator for MRE (Eq. 4) & WCRE (Eq. 6)
        denom   = (O_orig > 1) ? real'(O_orig) : 1.0;
        rel_err = abs_err / denom;
    endfunction

    function void display(string tag = "EVO_TR");
        $display("[%s] A=%0d, B=%0d | O_orig=%0d, O_approx=%0d | AbsErr=%0.0f, RelErr=%0.4f",
                 tag, A, B, O_orig, approx_val, abs_err, rel_err);
    endfunction
endclass


//==============================================================================
// 3. GENERATOR CLASS: Supports Exhaustive Enumeration (forall i in 2^ni) or Random
//==============================================================================
class evo_generator #(
    parameter int WIDTH = 16
);
    typedef evo_transaction #(WIDTH) tr_t;
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

    task send_directed(bit [WIDTH-1:0] da, bit [WIDTH-1:0] db);
        tr_t tr = new();
        tr.A = da;
        tr.B = db;
        gen2drv_mbx.put(tr);
        @(drv_done);
    endtask

    task run();
        // 1. Exhaustive enumeration of all 2^(ni) vectors for small circuits (WIDTH <= 8)
        if (run_exhaustive && WIDTH <= 8) begin
            int limit = (1 << WIDTH);
            for (int ia = 0; ia < limit; ia++) begin
                for (int ib = 0; ib < limit; ib++) begin
                    send_directed(ia[WIDTH-1:0], ib[WIDTH-1:0]);
                end
            end
        end else begin
            // 2. Directed Corner Cases (Accurate Multiplication by Zero & Max Values)
            send_directed('0, '0);
            send_directed({WIDTH{1'b1}}, '0);
            send_directed('0, {WIDTH{1'b1}});
            send_directed({WIDTH{1'b1}}, {WIDTH{1'b1}});

            // 3. Constrained-Random Simulation Campaign
            for (int i = 0; i < num_random_vectors; i++) begin
                tr_t tr = new();
                if (!tr.randomize()) $fatal(1, "Evo Transaction Randomization Failed!");
                gen2drv_mbx.put(tr);
                @(drv_done);
            end
        end
    endtask
endclass


//==============================================================================
// 4. DRIVER CLASS: Drives Primary Inputs A and B onto the Interface
//==============================================================================
class evo_driver #(
    parameter int WIDTH = 16
);
    typedef evo_transaction #(WIDTH) tr_t;
    virtual evo_mult_if #(WIDTH).DRV vif;
    mailbox #(tr_t) gen2drv_mbx;
    event           drv_done;

    function new(virtual evo_mult_if #(WIDTH).DRV vif, mailbox #(tr_t) mbx, event done_ev);
        this.vif         = vif;
        this.gen2drv_mbx = mbx;
        this.drv_done    = done_ev;
    endfunction

    task run();
        vif.drv_cb.A <= '0;
        vif.drv_cb.B <= '0;
        forever begin
            tr_t tr;
            gen2drv_mbx.get(tr);
            @(vif.drv_cb);
            vif.drv_cb.A <= tr.A;
            vif.drv_cb.B <= tr.B;
            ->drv_done;
        end
    endtask
endclass


//==============================================================================
// 5. MONITOR CLASS: Captures DUT Outputs & Samples Functional Coverage
//==============================================================================
class evo_monitor #(
    parameter int WIDTH = 16
);
    typedef evo_transaction #(WIDTH) tr_t;
    virtual evo_mult_if #(WIDTH).MON vif;
    mailbox #(tr_t) mon2scb_mbx;

    bit [WIDTH-1:0] cov_A, cov_B;

    covergroup cg_evo_inputs;
        option.per_instance = 1;
        cp_A: coverpoint cov_A {
            bins zero_val = {0};
            bins low_range = {[1 : (1<<(WIDTH/2))-1]};
            bins high_range = {[(1<<(WIDTH/2)) : (1<<WIDTH)-2]};
            bins max_val = {{WIDTH{1'b1}}};
        }
        cp_B: coverpoint cov_B {
            bins zero_val = {0};
            bins low_range = {[1 : (1<<(WIDTH/2))-1]};
            bins high_range = {[(1<<(WIDTH/2)) : (1<<WIDTH)-2]};
            bins max_val = {{WIDTH{1'b1}}};
        }
        cx_AB: cross cp_A, cp_B;
    endgroup

    function new(virtual evo_mult_if #(WIDTH).MON vif, mailbox #(tr_t) mbx);
        this.vif         = vif;
        this.mon2scb_mbx = mbx;
        cg_evo_inputs    = new();
    endfunction

    task run();
        @(vif.mon_cb);
        forever begin
            tr_t tr = new();
            @(vif.mon_cb);
            tr.A        = vif.mon_cb.A;
            tr.B        = vif.mon_cb.B;
            tr.O_approx = vif.mon_cb.O;

            cov_A = tr.A;
            cov_B = tr.B;
            cg_evo_inputs.sample();

            mon2scb_mbx.put(tr);
        end
    endtask
endclass


//==============================================================================
// 6. SCOREBOARD CLASS: Implements EvoApproxLib Quality Evaluation (Fig. 3)
//    Computes ER (Eq. 1), MAE (Eq. 2), MSE (Eq. 3), MRE (Eq. 4),
//    WCE (Eq. 5), and WCRE (Eq. 6) + Zero-Multiplication Check
//==============================================================================
class evo_scoreboard #(
    parameter int WIDTH = 16
);
    typedef evo_transaction #(WIDTH) tr_t;
    mailbox #(tr_t) mon2scb_mbx;

    longint total_vectors      = 0;
    longint mismatched_vectors = 0;
    longint zero_mult_errors   = 0;
    real    sum_abs_err        = 0.0;
    real    sum_sq_err         = 0.0;
    real    sum_rel_err        = 0.0;
    real    wce_max_abs        = 0.0;
    real    wcre_max_rel       = 0.0;

    function new(mailbox #(tr_t) mbx);
        this.mon2scb_mbx = mbx;
    endfunction

    task run();
        forever begin
            tr_t tr;
            mon2scb_mbx.get(tr);
            tr.evaluate();

            total_vectors++;
            if (tr.abs_err != 0.0) mismatched_vectors++;

            sum_abs_err += tr.abs_err;
            sum_sq_err  += tr.sq_err;
            sum_rel_err += tr.rel_err;

            if (tr.abs_err > wce_max_abs)  wce_max_abs  = tr.abs_err;
            if (tr.rel_err > wcre_max_rel) wcre_max_rel = tr.rel_err;

            // Check special requirement from Section II-C: "accurate multiplication by zero"
            if ((tr.A == '0 || tr.B == '0) && (tr.O_approx != '0)) begin
                zero_mult_errors++;
                $error("[ZERO_MULT_FAIL] A=%0d, B=%0d produced non-zero O_approx=%0d",
                       tr.A, tr.B, tr.O_approx);
            end
        end
    endtask

    function void report_quality_metrics(real cov_pct);
        real n       = (total_vectors > 0) ? real'(total_vectors) : 1.0;
        real max_out = real'((1ULL << (2*WIDTH)) - 1);
        real mae     = sum_abs_err / n;
        real mse     = sum_sq_err  / n;
        real psnr    = (mse > 0.0) ? (10.0 * $log10((max_out * max_out) / mse)) : 999.99;

        $display("\n======================================================================");
        $display("  EVOAPPROXLIB QUALITY EVALUATION REPORT (Section II-A, Eq. 1-6)");
        $display("  Circuit Configuration : %0d-bit Approximate Multiplier (ni = %0d)",
                 WIDTH, 2*WIDTH);
        $display("======================================================================");
        $display("  Total Vectors Evaluated      : %0d", total_vectors);
        $display("  Stimulus Functional Coverage : %0.2f %%", cov_pct);
        $display("  Zero-Multiplication Errors   : %0d (Constraint Check)", zero_mult_errors);
        $display("----------------------------------------------------------------------");
        $display("  Eq.(1) ER   (Error Rate)                 : %0.4f (%0.2f %%)",
                 real'(mismatched_vectors)/n, (real'(mismatched_vectors)/n)*100.0);
        $display("  Eq.(2) MAE  (Mean Absolute Error)        : %0.4f (%0.4f %%)",
                 mae, (mae / max_out) * 100.0);
        $display("  Eq.(3) MSE  (Mean Square Error)          : %0.4f (PSNR = %0.2f dB)",
                 mse, psnr);
        $display("  Eq.(4) MRE  (Mean Relative Error)        : %0.4f (%0.2f %%)",
                 sum_rel_err / n, (sum_rel_err / n) * 100.0);
        $display("  Eq.(5) WCE  (Worst-Case Error)           : %0.1f", wce_max_abs);
        $display("  Eq.(6) WCRE (Worst-Case Relative Error)  : %0.4f (%0.2f %%)",
                 wcre_max_rel, wcre_max_rel * 100.0);
        $display("======================================================================\n");
    endfunction
endclass


//==============================================================================
// 7. ENVIRONMENT CLASS: Connects Generator, Driver, Monitor, and Scoreboard
//==============================================================================
class evo_env #(
    parameter int WIDTH = 16
);
    typedef evo_transaction #(WIDTH) tr_t;

    evo_generator  #(WIDTH) gen;
    evo_driver     #(WIDTH) drv;
    evo_monitor    #(WIDTH) mon;
    evo_scoreboard #(WIDTH) scb;

    mailbox #(tr_t) gen2drv_mbx;
    mailbox #(tr_t) mon2scb_mbx;
    event           drv_done;

    virtual evo_mult_if #(WIDTH) vif;

    function new(virtual evo_mult_if #(WIDTH) vif, int num_vec = 5000, bit exhaustive = 0);
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
        scb.report_quality_metrics(mon.cg_evo_inputs.get_inst_coverage());
    endtask
endclass


//==============================================================================
// 8. TOP-LEVEL TESTBENCH MODULE
//==============================================================================
module tb_evo_top;
    //--------------------------------------------------------------------------
    // USER CONFIGURATION PARAMETERS:
    //   WIDTH = 2  -> Tests evo_fig1_multiplier_sv (Fig. 1 2-bit CGP Multiplier)
    //   WIDTH = 8  -> Tests evo_mul8u_cgp          (8-bit CGP Multiplier)
    //   WIDTH = 16 -> Tests evo_mul16u_approx_sv   (16-bit CGP Multiplier)
    //--------------------------------------------------------------------------
    localparam int WIDTH      = 16;
    localparam int NUM_RANDOM = 5000;
    localparam bit EXHAUSTIVE = 0; // Set to 1 when WIDTH=2 or WIDTH=8 for full 2^ni sweep

    logic clk = 0;
    always #5 clk = ~clk; // 100 MHz simulation clock

    // Instantiate Interface
    evo_mult_if #(WIDTH) intf (clk);

    //--------------------------------------------------------------------------
    // Conditionally Instantiate the Target EvoApproxLib Multiplier DUT
    //--------------------------------------------------------------------------
    generate
        if (WIDTH == 2) begin : gen_evo_2b
            evo_fig1_multiplier_sv dut (
                .a (intf.A),
                .b (intf.B),
                .O (intf.O)
            );
        end else if (WIDTH == 8) begin : gen_evo_8b
            evo_mul8u_cgp dut (
                .A (intf.A),
                .B (intf.B),
                .O (intf.O)
            );
        end else if (WIDTH == 16) begin : gen_evo_16b
            evo_mul16u_approx_sv dut (
                .A (intf.A),
                .B (intf.B),
                .O (intf.O)
            );
        end
    endgenerate

    // Instantiate & Run Verification Environment
    evo_env #(WIDTH) env;

    initial begin
        env = new(intf, NUM_RANDOM, EXHAUSTIVE);
        env.run();
        $finish;
    end
endmodule