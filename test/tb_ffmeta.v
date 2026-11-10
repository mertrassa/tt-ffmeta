/*
 * tb_ffmeta.v - self-checking behavioural test bench (Icarus Verilog).
 *
 * Drives the chip exactly as the host firmware does and prints the same
 * record format, so the output can be fed straight into analysis/fit_tau.py:
 *
 *   # key=value                                   metadata
 *   F,<what>,<p1>,<p2>,<n_a>,<n_ref>              frequency measurement
 *   M,<dut>,<k>,<j>,<n_meta>,<n_cal>,<n_cyc>,<n_ref>   sweep point
 *
 * Plusargs: +GATE=<ref cycles per sweep point>  (default 4000)
 *           +NK=<coarse taps per vernier setting> (default 8)
 *           +DUTS=<bit mask of DUTs to sweep>   (default 8'b00101001)
 *
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none
`timescale 1ps / 1fs

module tb_ffmeta;
    reg        clk = 1'b0;
    reg        rst_n = 1'b0;
    reg  [7:0] ui_in = 8'h00;
    reg  [7:0] uio_in = 8'h00;
    wire [7:0] uo_out, uio_out, uio_oe;

    tt_um_mertrassa_ffmeta dut (
        .ui_in(ui_in), .uo_out(uo_out), .uio_in(uio_in), .uio_out(uio_out),
        .uio_oe(uio_oe), .ena(1'b1), .clk(clk), .rst_n(rst_n)
    );

    // 20 MHz reference
    always #25000 clk = ~clk;

    integer errors = 0;
    integer gate_n, nk, duts;

    // ------------------------------------------------------------ helpers
    // configuration fields
    integer f_k = 0, f_j = 0, f_dut = 0, f_ev0 = 0, f_ev1 = 0, f_ring = 0;
    integer f_clk = 0, f_roclen = 0, f_dat = 0, f_rodlen = 0;
    integer f_rocen = 0, f_roden = 0, f_asel = 0;

    task wr_cfg(input [1:0] idx, input [7:0] val);
        begin
            @(negedge clk);
            ui_in[3:0] = {2'b11, idx};
            uio_in     = val;
            ui_in[4]   = 1'b1;
            @(negedge clk);
            ui_in[4]   = 1'b0;
        end
    endtask

    // Rings must always start from rest: changing a tap or a length while an
    // edge is circulating can inject extra edges, and a ring then runs in a
    // harmonic mode.  So: stop both oscillators and open the calibration
    // ring, change the static settings, then close / enable again.
    task apply_cfg;
        begin
            wr_cfg(2'd3, {4'b0000, f_asel[1:0], 2'b00});
            wr_cfg(2'd1, {1'b0, f_ev1[1:0], f_ev0[1:0], f_dut[2:0]});
            wr_cfg(2'd2, {1'b0, f_rodlen[0], f_dat[1:0], f_roclen[1:0], f_clk[1:0]});
            wr_cfg(2'd0, {f_j[2:0], f_k[4:0]});
            wr_cfg(2'd1, {f_ring[0], f_ev1[1:0], f_ev0[1:0], f_dut[2:0]});
            wr_cfg(2'd3, {4'b0000, f_asel[1:0], f_roden[0], f_rocen[0]});
        end
    endtask

    task rd8(input [3:0] a, output [7:0] v);
        begin
            ui_in[3:0] = a;
            #2000;
            v = uo_out;
        end
    endtask

    task rd24(input [3:0] base, output [23:0] v);
        begin
            rd8(base,        v[7:0]);
            rd8(base + 4'd1, v[15:8]);
            rd8(base + 4'd2, v[23:16]);
        end
    endtask

    reg [23:0] n_ev0, n_ev1, n_a, n_ref;

    // clear, count for n reference cycles, read all four counters
    task measure(input integer n);
        begin
            @(negedge clk);
            ui_in[7] = 1'b1;
            repeat (2) @(negedge clk);
            ui_in[7] = 1'b0;
            repeat (4) @(negedge clk);
            ui_in[5] = 1'b1;
            repeat (n) @(negedge clk);
            ui_in[5] = 1'b0;
            repeat (6) @(negedge clk);
            rd24(4'd0, n_ev0);
            rd24(4'd3, n_ev1);
            rd24(4'd6, n_a);
            rd24(4'd9, n_ref);
        end
    endtask

    task check(input cond, input [8*40-1:0] what);
        begin
            if (!cond) begin
                errors = errors + 1;
                $display("# CHECK FAILED: %0s", what);
            end
        end
    endtask

    // ---------------------------------------------------------------- tests
    integer i, kk, jj, dd, k_lo;
    reg [7:0] b;

    initial begin
        if (!$value$plusargs("GATE=%d", gate_n)) gate_n = 4000;
        if (!$value$plusargs("NK=%d", nk))       nk = 8;
        if (!$value$plusargs("DUTS=%d", duts))   duts = 8'b00101001;

        $display("# ffmeta behavioural simulation");
        $display("# f_ref_hz=20000000");

        repeat (5) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);

        // ---- 1. configuration registers
        for (i = 12; i < 16; i = i + 1) begin
            rd8(i[3:0], b);
            check(b === 8'h00, "config resets to zero");
        end
        wr_cfg(2'd0, 8'hA5); wr_cfg(2'd1, 8'h5A); wr_cfg(2'd2, 8'h3C); wr_cfg(2'd3, 8'h0C);
        rd8(4'd12, b); check(b === 8'hA5, "cfg0 readback");
        rd8(4'd13, b); check(b === 8'h5A, "cfg1 readback");
        rd8(4'd14, b); check(b === 8'h3C, "cfg2 readback");
        rd8(4'd15, b); check(b === 8'h0C, "cfg3 readback");
        // a write strobe at a non-config address must not change anything
        @(negedge clk); ui_in[3:0] = 4'd1; uio_in = 8'hFF; ui_in[4] = 1'b1;
        @(negedge clk); ui_in[4] = 1'b0;
        rd8(4'd13, b); check(b === 8'h5A, "write ignored outside 12..15");

        // ---- 2. counters, core clocked from the reference clock / 2
        f_clk = 0; f_ev0 = 3; f_ev1 = 3; f_asel = 0;
        apply_cfg;
        measure(1000);
        $display("# selftest ev0=%0d ev1=%0d a=%0d ref=%0d", n_ev0, n_ev1, n_a, n_ref);
        check(n_ref >= 998 && n_ref <= 1002, "REF counts reference cycles");
        check(n_ev0 >= 497 && n_ev0 <= 503,  "EV0 counts core cycles");
        check(n_ev1 == n_ev0,                "EV1 equals EV0");
        check(n_a   >= 497 && n_a   <= 503,  "A counts core cycles");
        // with a static data input nothing may be counted as an event
        f_ev0 = 0; f_ev1 = 1; f_k = 5;
        apply_cfg;
        measure(1000);
        check(n_ev0 == 0 && n_ev1 == 0, "no events without data activity");
        // clear really clears
        @(negedge clk); ui_in[7] = 1'b1; @(negedge clk); ui_in[7] = 1'b0;
        rd24(4'd9, n_ref);
        check(n_ref == 0, "clear zeroes the counters");

        // ---- 3. ring oscillator frequencies
        f_rocen = 1; f_roden = 1; f_clk = 1; f_k = 0; f_ev0 = 3; f_ev1 = 3;
        for (i = 0; i < 4; i = i + 1) begin
            f_roclen = i; f_asel = 0;
            apply_cfg;
            measure(1000);
            $display("F,core,%0d,0,%0d,%0d", i, n_a, n_ref);
            check(n_a > 3000 && n_a < 30000, "RO_C frequency plausible");
            check(n_ev0 >= n_a - 3 && n_ev0 <= n_a + 3, "EV0 tracks A on RO_C");
        end
        f_roclen = 0;
        for (i = 0; i < 4; i = i + 1) begin
            f_dat = 1 + i / 2; f_rodlen = i % 2; f_asel = 1;
            apply_cfg;
            measure(1000);
            $display("F,data,%0d,%0d,%0d,%0d", f_dat, f_rodlen, n_a, n_ref);
            check(n_a > 1500 && n_a < 30000, "RO_D frequency plausible");
        end

        // ---- 4. deterministic calibration: coarse line as a ring
        // (clock root switched off so the line is at rest when the ring closes)
        f_ring = 1; f_asel = 2; f_clk = 3; f_rocen = 0;
        for (i = 0; i < 32; i = i + 1) begin
            f_k = i;
            apply_cfg;
            measure(400);
            $display("F,ring,%0d,0,%0d,%0d", i, n_a, n_ref);
            check(n_a > 2000 && n_a < 40000, "calibration ring frequency plausible");
        end
        f_ring = 0; f_rocen = 1;

        // ---- 5. metastability sweep
        // Clock: RO_C, 55 stages.  Data: RO_D / 2, so that the data half
        // period exceeds the clock period: every data edge is then captured
        // exactly once and each capture changes the DUT output, which is the
        // condition under which  P(event) = T_w / H * exp(-t / tau)  holds.
        f_clk = 1; f_roclen = 1; f_dat = 2; f_rodlen = 0; f_ev0 = 0; f_ev1 = 1;
        f_asel = 1; f_k = 0; f_j = 0;
        apply_cfg;
        measure(4000);
        $display("F,data,%0d,%0d,%0d,%0d", f_dat, f_rodlen, n_a, n_ref);
        f_asel = 0;
        for (dd = 0; dd < 8; dd = dd + 1) if (duts[dd]) begin
            f_dut = dd;
            for (jj = 0; jj < 8; jj = jj + 1) begin
                // keep t(k, j) in the interesting 0.1 .. 1.0 ns range
                k_lo = 1 + (jj * 145) / 110;
                for (kk = k_lo; kk < k_lo + nk && kk < 32; kk = kk + 1) begin
                    f_k = kk; f_j = jj;
                    apply_cfg;
                    measure(gate_n);
                    $display("M,%0d,%0d,%0d,%0d,%0d,%0d,%0d",
                             dd, kk, jj, n_ev0, n_ev1, n_a, n_ref);
                end
            end
        end

        if (errors == 0) $display("# RESULT: PASS");
        else             $display("# RESULT: FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
