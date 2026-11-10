/*
 * ffm_cells.v - thin wrappers around the sky130_fd_sc_hd cells that form the
 * timing-critical part of the experiment.
 *
 * Synthesis (default): each wrapper instantiates exactly one PDK cell, so the
 * delay lines, ring oscillators, devices under test and samplers are built
 * from known cells and are never re-mapped by the tools.
 *
 * Simulation (`define FFM_BEHAV): behavioural models with picosecond delays,
 * per-instance mismatch, optional jitter and a metastability model for the
 * devices under test.  The *_PS / *_PPM parameters only affect these models.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none
`ifdef FFM_BEHAV
`timescale 1ps / 1fs
`endif

// ---------------------------------------------------------------- inverter
module ffm_inv #(
    parameter integer DRIVE   = 1,   // 1, 2 or 4
    parameter integer T_PS    = 55,  // sim: nominal delay
    parameter integer JIT_PPM = 0    // sim: rms edge jitter, ppm of T_PS
) (
    input  wire A,
    output wire Y
);
`ifdef FFM_BEHAV
    integer seed;
    real    t_i, d;
    reg     y;
    initial begin
        seed = $urandom;
        t_i  = T_PS * (1.0 + 0.03 * $dist_normal(seed, 0, 1000) / 1000.0);
    end
    always @(A) begin
        d = t_i;
        if (JIT_PPM > 0) d = d + T_PS * (JIT_PPM / 1.0e6) * $dist_normal(seed, 0, 1000) / 1000.0;
        if (d < 1.0) d = 1.0;
        y <= #(d) ~A;
    end
    assign Y = y;
`else
    generate
        if (DRIVE == 4) begin : g4
            (* keep *) sky130_fd_sc_hd__inv_4 mx_cell (.A(A), .Y(Y));
        end else if (DRIVE == 2) begin : g2
            (* keep *) sky130_fd_sc_hd__inv_2 mx_cell (.A(A), .Y(Y));
        end else begin : g1
            (* keep *) sky130_fd_sc_hd__inv_1 mx_cell (.A(A), .Y(Y));
        end
    endgenerate
`endif
endmodule

// ------------------------------------------------- inverting clock driver
module ffm_clkinv #(
    parameter integer T_PS = 70
) (
    input  wire A,
    output wire Y
);
`ifdef FFM_BEHAV
    reg y;
    always @(A) y <= #(T_PS) ~A;
    assign Y = y;
`else
    (* keep *) sky130_fd_sc_hd__clkinv_4 mx_cell (.A(A), .Y(Y));
`endif
endmodule

// --------------------------------------------- non-inverting clock driver
module ffm_clkbuf #(
    parameter integer DRIVE = 4,   // 1, 4 or 8
    parameter integer T_PS  = 110
) (
    input  wire A,
    output wire X
);
`ifdef FFM_BEHAV
    reg x;
    always @(A) x <= #(T_PS) A;
    assign X = x;
`else
    generate
        if (DRIVE == 8) begin : g8
            (* keep *) sky130_fd_sc_hd__clkbuf_8 mx_cell (.A(A), .X(X));
        end else if (DRIVE == 4) begin : g4
            (* keep *) sky130_fd_sc_hd__clkbuf_4 mx_cell (.A(A), .X(X));
        end else begin : g1
            (* keep *) sky130_fd_sc_hd__clkbuf_1 mx_cell (.A(A), .X(X));
        end
    endgenerate
`endif
endmodule

// ------------------------------------------------------------------ nand2
module ffm_nand2 #(
    parameter integer T_PS = 60
) (
    input  wire A,
    input  wire B,
    output wire Y
);
`ifdef FFM_BEHAV
    reg y;
    always @(A or B) y <= #(T_PS) ~(A & B);
    assign Y = y;
`else
    (* keep *) sky130_fd_sc_hd__nand2_1 mx_cell (.A(A), .B(B), .Y(Y));
`endif
endmodule

// ------------------------------------------------------------------- mux2
module ffm_mux2 #(
    parameter integer T_PS = 130
) (
    input  wire A0,
    input  wire A1,
    input  wire S,
    output wire X
);
`ifdef FFM_BEHAV
    integer seed;
    real    t_i;
    reg     x;
    initial begin
        seed = $urandom;
        t_i  = T_PS * (1.0 + 0.03 * $dist_normal(seed, 0, 1000) / 1000.0);
    end
    always @(A0 or A1 or S) x <= #(t_i) (S ? A1 : A0);
    assign X = x;
`else
    (* keep *) sky130_fd_sc_hd__mux2_1 mx_cell (.A0(A0), .A1(A1), .S(S), .X(X));
`endif
endmodule

// ------------------------------------------------------------------- mux4
module ffm_mux4 #(
    parameter integer T_PS = 170
) (
    input  wire A0,
    input  wire A1,
    input  wire A2,
    input  wire A3,
    input  wire S0,
    input  wire S1,
    output wire X
);
`ifdef FFM_BEHAV
    integer seed, n;
    real    t_i [0:3];   // each input pin has its own pin-to-output delay
    reg     x;
    wire [1:0] s = {S1, S0};
    initial begin
        seed = $urandom;
        for (n = 0; n < 4; n = n + 1)
            t_i[n] = T_PS * (1.0 + 0.05 * $dist_normal(seed, 0, 1000) / 1000.0);
    end
    always @(A0 or A1 or A2 or A3 or s)
        x <= #(t_i[s]) (S1 ? (S0 ? A3 : A2) : (S0 ? A1 : A0));
    assign X = x;
`else
    (* keep *) sky130_fd_sc_hd__mux4_1 mx_cell (
        .A0(A0), .A1(A1), .A2(A2), .A3(A3), .S0(S0), .S1(S1), .X(X)
    );
`endif
endmodule

// --------------------------------------------------------------- flip-flop
// KIND selects the library cell.  KIND 0 is used for every sampler; KIND 0..7
// are the devices under test:
//   0 dfxtp_1   1 dfxtp_2   2 dfxtp_4   3 dfrtp_1
//   4 dfstp_1   5 dfbbp_1   6 sdfxtp_1  7 dfxtp_1 (second instance)
module ffm_dff #(
    parameter integer KIND = 0,
    parameter integer META = 0     // sim: 1 = model metastable resolution delay
) (
    input  wire CLK,
    input  wire D,
    output wire Q
);
`ifdef FFM_BEHAV
    // Behavioural constants.  They are deliberately different per KIND so the
    // test bench can check that the extraction recovers the injected values;
    // they are NOT predictions of the silicon.
    real tau, tw, tcq;
    real t_d, dt, extra;
    reg  q;
    initial begin
        t_d = -1.0e9;
        tw  = 200.0;
        case (KIND)
            1:       begin tau = 45.0; tcq = 330.0; end
            2:       begin tau = 45.0; tcq = 380.0; end
            3:       begin tau = 60.0; tcq = 340.0; end
            4:       begin tau = 62.0; tcq = 345.0; end
            5:       begin tau = 75.0; tcq = 400.0; end
            6:       begin tau = 50.0; tcq = 320.0; end
            default: begin tau = 45.0; tcq = 300.0; end
        endcase
    end
    always @(D) t_d = $realtime;
    always @(posedge CLK) begin
        extra = 0.0;
        if (META != 0) begin
            // One-sided window of width tw: statistically equivalent, for
            // uniformly distributed data arrival, to the usual two-sided
            // aperture.  delay = tcq + tau * ln(tw / |dt|).
            dt = $realtime - t_d;
            if (dt < 0.001) dt = 0.001;
            if (dt < tw) extra = tau * $ln(tw / dt);
        end
        q <= #(tcq + extra) D;
    end
    assign Q = q;
`else
    generate
        if (KIND == 1) begin : g_dfxtp_2
            (* keep *) sky130_fd_sc_hd__dfxtp_2 mx_cell (.CLK(CLK), .D(D), .Q(Q));
        end else if (KIND == 2) begin : g_dfxtp_4
            (* keep *) sky130_fd_sc_hd__dfxtp_4 mx_cell (.CLK(CLK), .D(D), .Q(Q));
        end else if (KIND == 3) begin : g_dfrtp_1
            (* keep *) sky130_fd_sc_hd__dfrtp_1 mx_cell (.CLK(CLK), .D(D), .RESET_B(1'b1), .Q(Q));
        end else if (KIND == 4) begin : g_dfstp_1
            (* keep *) sky130_fd_sc_hd__dfstp_1 mx_cell (.CLK(CLK), .D(D), .SET_B(1'b1), .Q(Q));
        end else if (KIND == 5) begin : g_dfbbp_1
            /* verilator lint_off PINCONNECTEMPTY */
            (* keep *) sky130_fd_sc_hd__dfbbp_1 mx_cell (
                .CLK(CLK), .D(D), .SET_B(1'b1), .RESET_B(1'b1), .Q(Q), .Q_N()
            );
            /* verilator lint_on PINCONNECTEMPTY */
        end else if (KIND == 6) begin : g_sdfxtp_1
            (* keep *) sky130_fd_sc_hd__sdfxtp_1 mx_cell (
                .CLK(CLK), .D(D), .SCD(1'b0), .SCE(1'b0), .Q(Q)
            );
        end else begin : g_dfxtp_1
            (* keep *) sky130_fd_sc_hd__dfxtp_1 mx_cell (.CLK(CLK), .D(D), .Q(Q));
        end
    endgenerate
`endif
endmodule
