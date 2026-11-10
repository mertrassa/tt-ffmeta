/*
 * ffm_core.v - hand-structured core of the flip-flop metastability experiment.
 *
 *                 +-- vernier line (8 taps) -- mux(j) -- vd --+-- CD  : DUT[0..7], XA
 *   clock root ---+                                           +-- CPn : L, E2, XA2, XB2 (falling edge)
 *                 |                                           +-- clk_core : synthesised logic
 *                 +-- coarse line (32 taps) -- mux(k) -- ve ----- CE  : E[0..7], XB
 *
 * Each device under test (DUT) samples an asynchronous data signal on CD.
 * Its output is sampled a programmable time t = t(k, j) later by the early
 * sampler E (clock CE) and again half a clock period later by L (clock CPn),
 * when it has certainly resolved.  E != L means the DUT output had not yet
 * reached its final value after t: a late (metastable) transition.
 *
 * t is measured in situ, with no external timing reference, by the twin
 * samplers XA (on CD) and XB (on CE), which sample the same asynchronous data:
 * they disagree exactly when a data edge falls between the two clock edges,
 * i.e. with probability t / (data half period).
 *
 * As an independent check the coarse line can be closed into a ring
 * (ring_en) and its period counted for every tap.
 *
 * Capturing L/E2 on the falling edge makes the pipeline immune to clock skew
 * between the hand-built clock nets (valid for -T/2 < t < T/2 - ~0.5 ns).
 *
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

/* verilator lint_off UNOPTFLAT */

// ------------------------------------------------------------------------
// Ring oscillator: NAND enable + (N-1) inverters, four selectable lengths.
// Every tap index must be odd so that the loop has an odd number of inversions.
module ffm_ro #(
    parameter integer N  = 75,
    parameter integer T0 = 75,
    parameter integer T1 = 55,
    parameter integer T2 = 41,
    parameter integer T3 = 31
) (
    input  wire       en,
    input  wire [1:0] len,
    output wire       out
);
    // Stage outputs are scalar nets local to each generate block (g_s[i].y):
    // one wide vector net would make event-driven simulators re-evaluate
    // every stage on every edge.
    wire fb;

    genvar i;
    generate
        for (i = 0; i < N; i = i + 1) begin : g_s
            wire y;
            if (i == 0) begin : g_first
                ffm_nand2 u_en (.A(en), .B(fb), .Y(y));
            end else begin : g_inv
                ffm_inv #(.DRIVE(1), .JIT_PPM(30000)) u_i (.A(g_s[i-1].y), .Y(y));
            end
        end
    endgenerate

    ffm_mux4 u_len (
        .A0(g_s[T0-1].y), .A1(g_s[T1-1].y), .A2(g_s[T2-1].y), .A3(g_s[T3-1].y),
        .S0(len[0]), .S1(len[1]), .X(fb)
    );

    assign out = fb;
endmodule

// ------------------------------------------------------------------------
module ffm_core (
    input  wire       clk_ext,    // external reference clock
    input  wire       ext_async,  // external asynchronous input
    input  wire       rod_div,    // RO_D divided by two (divider lives outside)
    input  wire [1:0] clk_sel,    // 0 clk_ext, 1 RO_C, 2 ext_async, 3 off
    input  wire [1:0] roc_len,    // RO_C length: 0 = 75 stages ... 3 = 31 stages
    input  wire       roc_en,
    input  wire [1:0] dat_sel,    // 0 ext_async, 1 RO_D, 2 RO_D/2, 3 clk_ext
    input  wire       rod_len,    // RO_D length: 0 = 67 stages, 1 = 47 stages
    input  wire       rod_en,
    input  wire       ring_en,    // close the coarse line into a ring
    input  wire [4:0] k,          // coarse tap (delays the early sampling clock)
    input  wire [2:0] j,          // vernier tap (delays the DUT clock)
    output wire       clk_core,   // clock for the synthesised logic
    output wire       clk_early,  // early sampling clock / calibration ring
    output wire       dat,        // asynchronous data, for frequency counting
    output wire       rod,        // raw RO_D output
    output wire [7:0] l,          // final DUT values       (CPn domain)
    output wire [7:0] e2,         // early samples          (CPn domain)
    output wire       xa2,        // twin sampler, DUT side (CPn domain)
    output wire       xb2         // twin sampler, early side (CPn domain)
);
    genvar i;

    // ------------------------------------------------------------ sources
    wire roc;
    ffm_ro #(.N(75), .T0(75), .T1(55), .T2(41), .T3(31)) u_roc (
        .en(roc_en), .len(roc_len), .out(roc)
    );
    ffm_ro #(.N(67), .T0(67), .T1(47), .T2(67), .T3(47)) u_rod (
        .en(rod_en), .len({1'b0, rod_len}), .out(rod)
    );

    wire root, dsrc, d;
    ffm_mux4 u_clk_mux (
        .A0(clk_ext), .A1(roc), .A2(ext_async), .A3(1'b0),
        .S0(clk_sel[0]), .S1(clk_sel[1]), .X(root)
    );
    ffm_mux4 u_dat_mux (
        .A0(ext_async), .A1(rod), .A2(rod_div), .A3(clk_ext),
        .S0(dat_sel[0]), .S1(dat_sel[1]), .X(dsrc)
    );
    ffm_clkbuf #(.DRIVE(4)) u_d_buf   (.A(dsrc), .X(d));    // 10 sampler D pins
    ffm_clkbuf #(.DRIVE(1)) u_dat_buf (.A(dsrc), .X(dat));  // to the counter

    // ------------------------------------- vernier line (DUT clock branch)
    // Structure mirrors the coarse branch (mux2 -> line -> mux4 -> mux4 ->
    // mux2) so that t(k = 0, j = 0) is close to zero.
    // Tap 0 is v0, tap n (n > 0) is g_v[n-1].y.
    wire v0, vm0, vm1, vm2, vd;

    ffm_mux2 u_v_in (.A0(root), .A1(1'b0), .S(1'b0), .X(v0));
    generate
        for (i = 0; i < 7; i = i + 1) begin : g_v
            wire mid, y;
            if (i == 0) begin : g_a
                ffm_inv #(.DRIVE(1), .T_PS(95)) u_a (.A(v0), .Y(mid));
            end else begin : g_a
                ffm_inv #(.DRIVE(1), .T_PS(95)) u_a (.A(g_v[i-1].y), .Y(mid));
            end
            ffm_inv #(.DRIVE(4), .T_PS(50)) u_b (.A(mid), .Y(y));
        end
    endgenerate
    ffm_mux4 u_v_m0 (
        .A0(v0), .A1(g_v[0].y), .A2(g_v[1].y), .A3(g_v[2].y),
        .S0(j[0]), .S1(j[1]), .X(vm0)
    );
    ffm_mux4 u_v_m1 (
        .A0(g_v[3].y), .A1(g_v[4].y), .A2(g_v[5].y), .A3(g_v[6].y),
        .S0(j[0]), .S1(j[1]), .X(vm1)
    );
    ffm_mux4 u_v_m2 (.A0(vm0), .A1(vm1), .A2(vm0), .A3(vm1), .S0(j[2]), .S1(1'b0), .X(vm2));
    ffm_mux2 u_v_m3 (.A0(vm2), .A1(1'b0), .S(1'b0), .X(vd));

    // ------------------------------- coarse line (early sampling clock branch)
    // Tap 0 is c0, tap n (n > 0) is g_c[n-1].y.
    wire       c0, cq0, cq1, ve, ring_fb;
    wire [7:0] cm;

    ffm_mux2 u_c_in (.A0(root), .A1(ring_fb), .S(ring_en), .X(c0));
    generate
        for (i = 0; i < 31; i = i + 1) begin : g_c
            wire mid, y;
            if (i == 0) begin : g_a
                ffm_inv #(.DRIVE(1)) u_a (.A(c0), .Y(mid));
            end else begin : g_a
                ffm_inv #(.DRIVE(1)) u_a (.A(g_c[i-1].y), .Y(mid));
            end
            ffm_inv #(.DRIVE(1)) u_b (.A(mid), .Y(y));
        end
        for (i = 0; i < 8; i = i + 1) begin : g_cm
            if (i == 0) begin : g_m
                ffm_mux4 u_m (
                    .A0(c0), .A1(g_c[0].y), .A2(g_c[1].y), .A3(g_c[2].y),
                    .S0(k[0]), .S1(k[1]), .X(cm[i])
                );
            end else begin : g_m
                ffm_mux4 u_m (
                    .A0(g_c[4*i-1].y), .A1(g_c[4*i].y), .A2(g_c[4*i+1].y), .A3(g_c[4*i+2].y),
                    .S0(k[0]), .S1(k[1]), .X(cm[i])
                );
            end
        end
    endgenerate
    ffm_mux4 u_c_q0 (.A0(cm[0]), .A1(cm[1]), .A2(cm[2]), .A3(cm[3]), .S0(k[2]), .S1(k[3]), .X(cq0));
    ffm_mux4 u_c_q1 (.A0(cm[4]), .A1(cm[5]), .A2(cm[6]), .A3(cm[7]), .S0(k[2]), .S1(k[3]), .X(cq1));
    ffm_mux2 u_c_m3 (.A0(cq0), .A1(cq1), .S(k[4]), .X(ve));
    ffm_inv #(.DRIVE(1)) u_ring_inv (.A(ve), .Y(ring_fb));

    // ------------------------------------------------------ clock drivers
    wire cd, ce, cpn;
    ffm_clkbuf #(.DRIVE(4)) u_cd_buf   (.A(vd), .X(cd));        // 9 clock pins
    ffm_clkbuf #(.DRIVE(4)) u_ce_buf   (.A(ve), .X(ce));        // 9 clock pins
    ffm_clkinv              u_cpn_inv  (.A(vd), .Y(cpn));       // 18 clock pins
    ffm_clkbuf #(.DRIVE(8)) u_core_buf (.A(vd), .X(clk_core));
    ffm_clkbuf #(.DRIVE(1)) u_early_buf(.A(ve), .X(clk_early));

    // ------------------------------------------------- devices under test
    wire [7:0] q, e;
    generate
        for (i = 0; i < 8; i = i + 1) begin : g_dut
            ffm_dff #(.KIND(i), .META(1)) u_dut (.CLK(cd),  .D(d),    .Q(q[i]));
            ffm_dff #(.KIND(0))           u_e   (.CLK(ce),  .D(q[i]), .Q(e[i]));
            ffm_dff #(.KIND(0))           u_l   (.CLK(cpn), .D(q[i]), .Q(l[i]));
            ffm_dff #(.KIND(0))           u_e2  (.CLK(cpn), .D(e[i]), .Q(e2[i]));
        end
    endgenerate

    // --------------------------------------------- twin samplers (timebase)
    wire xa, xb;
    ffm_dff #(.KIND(0)) u_xa  (.CLK(cd),  .D(d),  .Q(xa));
    ffm_dff #(.KIND(0)) u_xb  (.CLK(ce),  .D(d),  .Q(xb));
    ffm_dff #(.KIND(0)) u_xa2 (.CLK(cpn), .D(xa), .Q(xa2));
    ffm_dff #(.KIND(0)) u_xb2 (.CLK(cpn), .D(xb), .Q(xb2));

endmodule

/* verilator lint_on UNOPTFLAT */
