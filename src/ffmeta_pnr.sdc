# Place-and-route constraints for tt_um_mertrassa_ffmeta.
#
# Only the reference clock exists here.  The source multiplexers of the
# experiment core are held, by case analysis, in the setting where no clock
# reaches the core (clock root = constant, data = ui_in[6]).  The core is
# therefore not part of any clock network during place and route, and clock
# tree synthesis and clock-inverter repair leave its hand-built delay lines,
# ring oscillators and clock drivers alone.  (Those steps do not honour
# RSZ_DONT_TOUCH_RX; in the first attempt CTS tried to buffer the delay lines
# and crashed on the calibration ring.)
#
# The real clocking of the core is described in ffmeta.sdc, which is used for
# sign-off timing analysis only.

create_clock -name clk -period 20.0 [get_ports clk]

# clk_sel = 3: clock root off
set_case_analysis 1 [get_pins {*u_clk_mux.mx_cell/S0}]
set_case_analysis 1 [get_pins {*u_clk_mux.mx_cell/S1}]
# dat_sel = 0: data from ui_in[6]
set_case_analysis 0 [get_pins {*u_dat_mux.mx_cell/S0}]
set_case_analysis 0 [get_pins {*u_dat_mux.mx_cell/S1}]

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
