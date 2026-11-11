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
// Chain of N inverters (N >= 0), built by halving so that instance names stay
// short.  Deliberately no vectors and no references into generate blocks:
// wide vector nets are slow in event-driven simulators, and hierarchical
// generate references are not accepted alike by all synthesis tools.
module ffm_invchain #(
    parameter integer N       = 1,
    parameter integer JIT_PPM = 0
) (
    input  wire a,
    output wire y
);
    generate
        if (N <= 0) begin : g_none
            assign y = a;
        end else if (N == 1) begin : g_one
            ffm_inv #(.DRIVE(1), .JIT_PPM(JIT_PPM)) u_i (.A(a), .Y(y));
        end else begin : g_split
            wire m;
            ffm_invchain #(.N(N / 2),     .JIT_PPM(JIT_PPM)) u_lo (.a(a), .y(m));
            ffm_invchain #(.N(N - N / 2), .JIT_PPM(JIT_PPM)) u_hi (.a(m), .y(y));
        end
    endgenerate
endmodule

// ------------------------------------------------------------------------
// Ring oscillator: NAND enable followed by four inverter segments of L0..L3
// stages; the feedback is taken after segment 4, 3, 2 or 1 (len = 0..3).
// 1 + L0, 1 + L0 + L1, ... must all be odd.
module ffm_ro #(
    parameter integer L0 = 30,
    parameter integer L1 = 10,
    parameter integer L2 = 14,
    parameter integer L3 = 20
) (
    input  wire       en,
    input  wire [1:0] len,
    output wire       out
);
    wire fb, n0, p1, p2, p3, p4;

    ffm_nand2 u_en (.A(en), .B(fb), .Y(n0));
    ffm_invchain #(.N(L0), .JIT_PPM(30000)) u_s0 (.a(n0), .y(p1));
    ffm_invchain #(.N(L1), .JIT_PPM(30000)) u_s1 (.a(p1), .y(p2));
    ffm_invchain #(.N(L2), .JIT_PPM(30000)) u_s2 (.a(p2), .y(p3));
    ffm_invchain #(.N(L3), .JIT_PPM(30000)) u_s3 (.a(p3), .y(p4));
    ffm_mux4 u_len (
        .A0(p4), .A1(p3), .A2(p2), .A3(p1),
        .S0(len[0]), .S1(len[1]), .X(fb)
    );

    assign out = fb;
endmodule

// ------------------------------------------------------------------------
// Four consecutive taps of a delay line with their multiplexer.  A tap is a
// pair of inverters.  Tap 0 is the input; nxt is the input of the next
// segment (one more pair after tap 3).
module ffm_seg4 #(
    parameter integer LAST    = 0,   // 1: last segment, no pair after tap 3
    parameter integer DRIVE_B = 1,   // drive strength of the second inverter
    parameter integer TA_PS   = 55,  // sim: delay of the first inverter
    parameter integer TB_PS   = 55   // sim: delay of the second inverter
) (
    input  wire in,
    input  wire s0,
    input  wire s1,
    output wire x,
    output wire nxt
);
    wire m1, t1, m2, t2, m3, t3;

    ffm_inv #(.DRIVE(1),       .T_PS(TA_PS)) u_a1 (.A(in), .Y(m1));
    ffm_inv #(.DRIVE(DRIVE_B), .T_PS(TB_PS)) u_b1 (.A(m1), .Y(t1));
    ffm_inv #(.DRIVE(1),       .T_PS(TA_PS)) u_a2 (.A(t1), .Y(m2));
    ffm_inv #(.DRIVE(DRIVE_B), .T_PS(TB_PS)) u_b2 (.A(m2), .Y(t2));
    ffm_inv #(.DRIVE(1),       .T_PS(TA_PS)) u_a3 (.A(t2), .Y(m3));
    ffm_inv #(.DRIVE(DRIVE_B), .T_PS(TB_PS)) u_b3 (.A(m3), .Y(t3));
    generate
        if (LAST != 0) begin : g_last
            assign nxt = 1'b0;
        end else begin : g_next
            wire m4;
            ffm_inv #(.DRIVE(1),       .T_PS(TA_PS)) u_a4 (.A(t3), .Y(m4));
            ffm_inv #(.DRIVE(DRIVE_B), .T_PS(TB_PS)) u_b4 (.A(m4), .Y(nxt));
        end
    endgenerate

    ffm_mux4 u_m (.A0(in), .A1(t1), .A2(t2), .A3(t3), .S0(s0), .S1(s1), .X(x));
endmodule

// ------------------------------------------------------------------------
module ffm_core (
    input  wire       clk_ext,    // reference clock / 2 (from a flip-flop)
    input  wire       ext_async,  // external asynchronous input
    input  wire       rod_div2,   // RO_D / 2 (dividers live outside)
    input  wire       rod_div4,   // RO_D / 4
    input  wire [1:0] clk_sel,    // 0 clk / 2, 1 RO_C, 2 ext_async, 3 off
    input  wire [1:0] roc_len,    // RO_C stages: 0 = 111, 1 = 91, 2 = 75, 3 = 55
    input  wire       roc_en,
    input  wire [1:0] dat_sel,    // 0 ext_async, 1 RO_D/4, 2 RO_D/2, 3 clk / 2
    input  wire       rod_len,    // RO_D length: 0 = 67 stages, 1 = 47 stages
    input  wire       rod_en,
    input  wire       ring_en,    // close the coarse line into a ring
    input  wire [4:0] k,          // coarse tap (delays the early sampling clock)
    input  wire [2:0] j,          // vernier tap (delays the DUT clock)
    output wire       clk_core,   // clock for the synthesised logic
    output wire       clk_early,  // early sampling clock / calibration ring
    output wire       dat,        // asynchronous data, for frequency counting
    output wire       rod,        // raw RO_D output (clocks the dividers)
    output wire [7:0] l,          // final DUT values       (CPn domain)
    output wire [7:0] e2,         // early samples          (CPn domain)
    output wire       xa2,        // twin sampler, DUT side (CPn domain)
    output wire       xb2         // twin sampler, early side (CPn domain)
);
    genvar i;

    // ------------------------------------------------------------ sources
    wire roc;
    // Post-layout static timing (typical corner): about 36 ps per stage, so
    // 8.0 / 6.6 / 5.5 / 4.0 ns.  The slowest setting leaves half a period
    // (4 ns) for the full 2.9 ns range of the coarse line.
    ffm_ro #(.L0(54), .L1(20), .L2(16), .L3(20)) u_roc (   // 111 / 91 / 75 / 55 stages
        .en(roc_en), .len(roc_len), .out(roc)
    );
    ffm_ro #(.L0(46), .L1(0), .L2(0), .L3(20)) u_rod (     // 67 / 47 stages
        .en(rod_en), .len({1'b0, rod_len}), .out(rod)
    );

    wire root, dsrc, d;
    ffm_mux4 u_clk_mux (
        .A0(clk_ext), .A1(roc), .A2(ext_async), .A3(1'b0),
        .S0(clk_sel[0]), .S1(clk_sel[1]), .X(root)
    );
    ffm_mux4 u_dat_mux (
        .A0(ext_async), .A1(rod_div4), .A2(rod_div2), .A3(clk_ext),
        .S0(dat_sel[0]), .S1(dat_sel[1]), .X(dsrc)
    );
    ffm_clkbuf #(.DRIVE(4)) u_d_buf   (.A(dsrc), .X(d));    // 10 sampler D pins
    ffm_clkbuf #(.DRIVE(1)) u_dat_buf (.A(dsrc), .X(dat));  // to the counter

    // ------------------------------------- vernier line (DUT clock branch)
    // Structure mirrors the coarse branch (mux2 -> line -> mux4 -> mux4 ->
    // mux2) so that t(k = 0, j = 0) is close to zero.
    // Vernier pair: inv_1 driving inv_4, a different unit delay from the
    // coarse pair so that the (k, j) combinations interleave.
    wire v0, v4, v_nc, vm0, vm1, vm2, vd;

    ffm_mux2 u_v_in (.A0(root), .A1(1'b0), .S(1'b0), .X(v0));
    ffm_seg4 #(.DRIVE_B(4), .TA_PS(95), .TB_PS(50)) u_v_s0 (
        .in(v0), .s0(j[0]), .s1(j[1]), .x(vm0), .nxt(v4)
    );
    ffm_seg4 #(.LAST(1), .DRIVE_B(4), .TA_PS(95), .TB_PS(50)) u_v_s1 (
        .in(v4), .s0(j[0]), .s1(j[1]), .x(vm1), .nxt(v_nc)
    );
    ffm_mux4 u_v_m2 (.A0(vm0), .A1(vm1), .A2(vm0), .A3(vm1), .S0(j[2]), .S1(1'b0), .X(vm2));
    ffm_mux2 u_v_m3 (.A0(vm2), .A1(1'b0), .S(1'b0), .X(vd));

    // ------------------------------- coarse line (early sampling clock branch)
    // Eight segments of four taps; cl[m] is tap 4m.
    wire [8:0] cl;
    wire [7:0] cm;
    wire       cq0, cq1, ve, ring_fb;

    ffm_mux2 u_c_in (.A0(root), .A1(ring_fb), .S(ring_en), .X(cl[0]));
    generate
        for (i = 0; i < 8; i = i + 1) begin : g_c
            ffm_seg4 #(.LAST(i == 7 ? 1 : 0)) u_s (
                .in(cl[i]), .s0(k[0]), .s1(k[1]), .x(cm[i]), .nxt(cl[i+1])
            );
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

    wire _unused = &{v_nc, cl[8], 1'b0};

endmodule

/* verilator lint_on UNOPTFLAT */
