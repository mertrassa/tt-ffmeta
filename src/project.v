/*
 * tt_um_mertrassa_ffmeta - flip-flop metastability characterisation for sky130_fd_sc_hd
 *
 * Pins
 *   clk          reference clock (crystal derived), also clocks the registers.
 *                Where the experiment can use the reference as a source it
 *                uses clk / 2 from a flip-flop ("ref_div"): the clk net must
 *                end at register clock pins only, because clock tree
 *                synthesis follows it through every combinational cell and
 *                would otherwise rebuild (and loop in) the experiment core.
 *   ui_in[3:0]   address: selects the byte on uo_out; 12..15 = config regs
 *   ui_in[4]     write strobe: on a rising clk edge, cfg[addr] <= uio_in
 *                (only for addr 12..15)
 *   ui_in[5]     gate: counters run while high
 *   ui_in[6]     external asynchronous input (optional data / clock source)
 *   ui_in[7]     clear counters (asynchronous, active high)
 *   uio[7:0]     write data (always inputs)
 *   uo_out[7:0]  read data
 *
 * Read map (all counters 24 bit, little endian)
 *   0..2   EV0   events selected by ev0_sel
 *   3..5   EV1   events selected by ev1_sel
 *   6..8   A     cycles of the clock selected by a_sel
 *   9..11  REF   cycles of clk
 *   12     cfg0  {j[2:0], k[4:0]}
 *   13     cfg1  {ring_en, ev1_sel[1:0], ev0_sel[1:0], dut[2:0]}
 *   14     cfg2  {1'b0, rod_len, dat_sel[1:0], roc_len[1:0], clk_sel[1:0]}
 *   15     cfg3  {4'b0, a_sel[1:0], rod_en, roc_en}
 *
 * Event sources (ev0_sel / ev1_sel)
 *   0 meta   early sample != final value of the selected DUT
 *   1 cal    twin samplers disagree (a data edge fell inside the delay t)
 *   2 tr     selected DUT output changed since the previous cycle
 *   3 one    every cycle (counts core clock cycles)
 *
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

module tt_um_mertrassa_ffmeta (
    input  wire [7:0] ui_in,    // Dedicated inputs
    output wire [7:0] uo_out,   // Dedicated outputs
    input  wire [7:0] uio_in,   // IOs: Input path
    output wire [7:0] uio_out,  // IOs: Output path
    output wire [7:0] uio_oe,   // IOs: Enable path (active high: 0=input, 1=output)
    input  wire       ena,      // always 1 when the design is powered
    input  wire       clk,      // clock
    input  wire       rst_n     // reset_n - low to reset
);
    wire [3:0] addr      = ui_in[3:0];
    wire       wr        = ui_in[4];
    wire       gate      = ui_in[5];
    wire       ext_async = ui_in[6];
    wire       arst      = ~rst_n | ui_in[7];   // counter clear

    assign uio_out = 8'h00;
    assign uio_oe  = 8'h00;

    // ------------------------------------------------ configuration registers
    reg [7:0] cfg0, cfg1, cfg2, cfg3;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cfg0 <= 8'h00;
            cfg1 <= 8'h00;
            cfg2 <= 8'h00;
            cfg3 <= 8'h00;
        end else if (wr && addr[3:2] == 2'b11) begin
            case (addr[1:0])
                2'd0: cfg0 <= uio_in;
                2'd1: cfg1 <= uio_in;
                2'd2: cfg2 <= uio_in;
                2'd3: cfg3 <= uio_in;
            endcase
        end
    end

    wire [4:0] k        = cfg0[4:0];
    wire [2:0] j        = cfg0[7:5];
    wire [2:0] dut      = cfg1[2:0];
    wire [1:0] ev0_sel  = cfg1[4:3];
    wire [1:0] ev1_sel  = cfg1[6:5];
    wire       ring_en  = cfg1[7];
    wire [1:0] clk_sel  = cfg2[1:0];
    wire [1:0] roc_len  = cfg2[3:2];
    wire [1:0] dat_sel  = cfg2[5:4];
    wire       rod_len  = cfg2[6];
    wire       roc_en   = cfg3[0];
    wire       rod_en   = cfg3[1];
    wire [1:0] a_sel    = cfg3[3:2];

    // ------------------------------------------------------ experiment core
    wire       clk_core, clk_early, dat, rod;
    wire [7:0] l, e2;
    wire       xa2, xb2;
    reg        rod_div;
    reg        ref_div;

    // reference clock / 2: the only way the reference enters the experiment
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) ref_div <= 1'b0;
        else        ref_div <= ~ref_div;
    end

    ffm_core mx_core (
        .clk_ext  (ref_div),
        .ext_async(ext_async),
        .rod_div  (rod_div),
        .clk_sel  (clk_sel),
        .roc_len  (roc_len),
        .roc_en   (roc_en),
        .dat_sel  (dat_sel),
        .rod_len  (rod_len),
        .rod_en   (rod_en),
        .ring_en  (ring_en),
        .k        (k),
        .j        (j),
        .clk_core (clk_core),
        .clk_early(clk_early),
        .dat      (dat),
        .rod      (rod),
        .l        (l),
        .e2       (e2),
        .xa2      (xa2),
        .xb2      (xb2)
    );

    // RO_D / 2: slower data with an exact 50 % duty cycle
    always @(posedge rod or negedge rst_n) begin
        if (!rst_n) rod_div <= 1'b0;
        else        rod_div <= ~rod_div;
    end

    // -------------------------------------------------------- event detection
    // l, e2, xa2, xb2 change on the falling edge of clk_core.  They are first
    // re-registered on the rising edge, so that the only half-cycle paths are
    // flop to flop; the multiplexer and the XORs then have a full cycle.
    // (With the logic in the half-cycle path, sign-off timing limited the
    // DUT clock period to about 5.4 ns.)
    reg [7:0] l_q, e2_q;
    reg       xa_q, xb_q;
    always @(posedge clk_core) begin
        l_q  <= l;
        e2_q <= e2;
        xa_q <= xa2;
        xb_q <= xb2;
    end
    wire l_sel  = l_q[dut];
    wire e2_sel = e2_q[dut];
    reg  s_meta, s_cal, s_l, s_tr;
    always @(posedge clk_core) begin
        s_meta <= l_sel ^ e2_sel;
        s_cal  <= xa_q ^ xb_q;
        s_l    <= l_sel;
        s_tr   <= l_sel ^ s_l;
    end
    wire [3:0] ev   = {1'b1, s_tr, s_cal, s_meta};
    wire       inc0 = ev[ev0_sel];
    wire       inc1 = ev[ev1_sel];

    // ---------------------------------------------------------------- counters
    wire [23:0] cnt_ev0, cnt_ev1, cnt_a, cnt_ref;

    /* verilator lint_off UNOPTFLAT */
    wire a_clk = (a_sel == 2'd0) ? clk_core  :
                 (a_sel == 2'd1) ? dat       :
                 (a_sel == 2'd2) ? clk_early : ref_div;
    /* verilator lint_on UNOPTFLAT */

    ffm_counter #(.W(24)) u_ev0 (.clk(clk_core), .arst(arst), .gate(gate), .inc(inc0), .q(cnt_ev0));
    ffm_counter #(.W(24)) u_ev1 (.clk(clk_core), .arst(arst), .gate(gate), .inc(inc1), .q(cnt_ev1));
    ffm_counter #(.W(24)) u_a   (.clk(a_clk),    .arst(arst), .gate(gate), .inc(1'b1), .q(cnt_a));
    ffm_counter #(.W(24)) u_ref (.clk(clk),      .arst(arst), .gate(gate), .inc(1'b1), .q(cnt_ref));

    // ----------------------------------------------------------------- readback
    reg [7:0] rd;
    always @(*) begin
        case (addr)
            4'd0:  rd = cnt_ev0[7:0];
            4'd1:  rd = cnt_ev0[15:8];
            4'd2:  rd = cnt_ev0[23:16];
            4'd3:  rd = cnt_ev1[7:0];
            4'd4:  rd = cnt_ev1[15:8];
            4'd5:  rd = cnt_ev1[23:16];
            4'd6:  rd = cnt_a[7:0];
            4'd7:  rd = cnt_a[15:8];
            4'd8:  rd = cnt_a[23:16];
            4'd9:  rd = cnt_ref[7:0];
            4'd10: rd = cnt_ref[15:8];
            4'd11: rd = cnt_ref[23:16];
            4'd12: rd = cfg0;
            4'd13: rd = cfg1;
            4'd14: rd = cfg2;
            default: rd = cfg3;
        endcase
    end
    assign uo_out = rd;

    // unused
    wire _unused = &{ena, cfg2[7], cfg3[7:4], 1'b0};

endmodule
