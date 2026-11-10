# Place-and-route constraints for tt_um_mertrassa_ffmeta.
#
# Only the reference clock exists here, and in the netlist the clk net ends
# at register clock pins only: the experiment core receives the reference
# through a divide-by-two flip-flop (ref_div in project.v).  The core is
# therefore not part of any clock network during place and route, and clock
# tree synthesis leaves its hand-built delay lines, ring oscillators and
# clock drivers alone.
#
# Both halves of that are needed.  CTS does not honour RSZ_DONT_TOUCH_RX: with
# the core clocks declared it buffered the delay lines, and with clk wired
# straight into the source multiplexers its latency balancer followed the
# netlist through every combinational cell, whatever the constraints said,
# and never returned from the calibration ring.
#
# The real clocking of the core is described in ffmeta.sdc, which is used for
# sign-off timing analysis only.

create_clock -name clk -period 20.0 [get_ports clk]

set_clock_uncertainty 0.25 [get_clocks clk]
set_clock_transition 0.15 [get_clocks clk]

set io_ports [get_ports {ui_in[*] uio_in[*] rst_n ena}]
set_input_delay  4.0 -clock [get_clocks clk] $io_ports
set_output_delay 4.0 -clock [get_clocks clk] [all_outputs]
set_false_path -from [get_ports {rst_n ena}]

set_driving_cell -lib_cell sky130_fd_sc_hd__inv_2 -pin Y [all_inputs]
set_load 0.033 [all_outputs]
set_max_fanout 10 [current_design]
set_timing_derate -early 0.95
set_timing_derate -late  1.05
