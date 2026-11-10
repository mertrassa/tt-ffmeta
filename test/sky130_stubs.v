/*
 * sky130_stubs.v - simulation stand-ins for the sky130_fd_sc_hd cells that
 * src/ffm_cells.v instantiates.  Port names match the PDK; delays are rough.
 *
 * Purpose: simulate the *synthesis* branch of the cell wrappers (no
 * FFM_BEHAV) without the PDK installed, to check that the structural netlist
 * is wired like the behavioural one.  Not a timing model.
 *
 *   bash run_sim.sh 400 2 0 struct
 *
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none
`timescale 1ps / 1fs

module sky130_fd_sc_hd__inv_1 (output wire Y, input wire A);
    assign #55 Y = ~A;
endmodule
module sky130_fd_sc_hd__inv_2 (output wire Y, input wire A);
    assign #55 Y = ~A;
endmodule
module sky130_fd_sc_hd__inv_4 (output wire Y, input wire A);
    assign #50 Y = ~A;
endmodule
module sky130_fd_sc_hd__clkinv_4 (output wire Y, input wire A);
    assign #70 Y = ~A;
endmodule
module sky130_fd_sc_hd__clkbuf_1 (output wire X, input wire A);
    assign #110 X = A;
endmodule
module sky130_fd_sc_hd__clkbuf_4 (output wire X, input wire A);
    assign #110 X = A;
endmodule
module sky130_fd_sc_hd__clkbuf_8 (output wire X, input wire A);
    assign #110 X = A;
endmodule
module sky130_fd_sc_hd__nand2_1 (output wire Y, input wire A, input wire B);
    assign #60 Y = ~(A & B);
endmodule
module sky130_fd_sc_hd__mux2_1 (output wire X, input wire A0, input wire A1, input wire S);
    assign #130 X = S ? A1 : A0;
endmodule
module sky130_fd_sc_hd__mux4_1 (
    output wire X, input wire A0, input wire A1, input wire A2, input wire A3,
    input wire S0, input wire S1
);
    assign #170 X = S1 ? (S0 ? A3 : A2) : (S0 ? A1 : A0);
endmodule

module sky130_fd_sc_hd__dfxtp_1 (output reg Q, input wire CLK, input wire D);
    always @(posedge CLK) Q <= #300 D;
endmodule
module sky130_fd_sc_hd__dfxtp_2 (output reg Q, input wire CLK, input wire D);
    always @(posedge CLK) Q <= #300 D;
endmodule
module sky130_fd_sc_hd__dfxtp_4 (output reg Q, input wire CLK, input wire D);
    always @(posedge CLK) Q <= #300 D;
endmodule
module sky130_fd_sc_hd__dfrtp_1 (output reg Q, input wire CLK, input wire D, input wire RESET_B);
    always @(posedge CLK or negedge RESET_B)
        if (!RESET_B) Q <= #300 1'b0;
        else          Q <= #300 D;
endmodule
module sky130_fd_sc_hd__dfstp_1 (output reg Q, input wire CLK, input wire D, input wire SET_B);
    always @(posedge CLK or negedge SET_B)
        if (!SET_B) Q <= #300 1'b1;
        else        Q <= #300 D;
endmodule
module sky130_fd_sc_hd__dfbbp_1 (
    output reg Q, output wire Q_N, input wire D, input wire CLK,
    input wire SET_B, input wire RESET_B
);
    assign Q_N = ~Q;
    always @(posedge CLK or negedge SET_B or negedge RESET_B)
        if (!RESET_B)    Q <= #300 1'b0;
        else if (!SET_B) Q <= #300 1'b1;
        else             Q <= #300 D;
endmodule
module sky130_fd_sc_hd__sdfxtp_1 (
    output reg Q, input wire CLK, input wire D, input wire SCD, input wire SCE
);
    always @(posedge CLK) Q <= #300 (SCE ? SCD : D);
endmodule
