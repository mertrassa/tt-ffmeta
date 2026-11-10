# Sign-off timing constraints for tt_um_mertrassa_ffmeta.
#
# Used for sign-off static timing analysis only (SIGNOFF_SDC_FILE).  Place and
# route uses ffmeta_pnr.sdc, in which no clock enters the experiment core.
# The pin patterns rely on the flattened instance names produced by Yosys
# (mx_core.<instance>.mx_cell); the first hardening run confirmed that all
# four clocks are found.
#
# Clocks
#   clk    reference clock from the pad (crystal derived, <= 50 MHz)
#   core   root of the DUT clock: RO_C, clk / 2 or ui_in[6] behind a multiplexer
#   early  swept sampling clock (output of the coarse delay line), also the
#          calibration ring
#   data   asynchronous data source: RO_D, RO_D/2, ui_in[6] or clk / 2
#
# "early" is derived from "core" through the programmable delay line, but the
# delay between them is exactly what the experiment sweeps, so the two are
# declared asynchronous on purpose.  That removes the DUT -> early sampler and
# early sampler -> pipeline paths from analysis; the design keeps those safe
# by construction (falling-edge capture, see ffm_core.v).  Everything else in
# the core domain, including the half-cycle paths into the pipeline flops, is
# timed normally.

create_clock -name clk   -period 20.0 [get_ports clk]
create_clock -name core  -period 5.0  [get_pins {*u_clk_mux.mx_cell/X}]
create_clock -name early -period 5.0  [get_pins {*u_c_m3.mx_cell/X}]
create_clock -name data  -period 5.0  [get_pins {*u_dat_mux.mx_cell/X}]

set_clock_groups -asynchronous \
    -group [get_clocks clk] \
    -group [get_clocks core] \
    -group [get_clocks early] \
    -group [get_clocks data]

set_clock_uncertainty 0.25 [all_clocks]
set_clock_transition 0.15 [all_clocks]
set_propagated_clock [all_clocks]

# Host interface: static signals, sampled or read many reference cycles after
# they change.
set io_ports [get_ports {ui_in[*] uio_in[*] rst_n ena}]
set_input_delay  4.0 -clock [get_clocks clk] $io_ports
set_output_delay 4.0 -clock [get_clocks clk] [all_outputs]
set_false_path -from [get_ports {rst_n ena}]

set_driving_cell -lib_cell sky130_fd_sc_hd__inv_2 -pin Y [all_inputs]
set_load 0.033 [all_outputs]
set_timing_derate -early 0.95
set_timing_derate -late  1.05
