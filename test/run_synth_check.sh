#!/bin/bash
# Synthesis check without the PDK: Yosys synthesises the design with the
# sky130 cells as black boxes, then the functional test bench runs on the
# resulting netlist (generic gates + stand-in sky130 cells).
#
# Checks that the RTL elaborates the way the hardening flow will see it, that
# every hand-instantiated cell survives, and that the netlist still works.
# It does not replace the Tiny Tapeout GDS action (no place and route, no
# real cell timing).
#
# Needs yosys and iverilog.   ./run_synth_check.sh
set -e
cd "$(dirname "$0")"
HERE=$(pwd)
W=$(mktemp -d)
cp ../src/*.v sky130_stubs.v "$W"
cd "$W"
cat > syn.ys <<'EOF'
read_verilog -lib sky130_stubs.v
read_verilog ffm_cells.v ffm_core.v ffm_counter.v project.v
hierarchy -check -top tt_um_mertrassa_ffmeta
synth -top tt_um_mertrassa_ffmeta -flatten
opt_clean -purge
check -assert
stat
write_verilog -noattr syn.v
EOF
yosys -q -l syn.log syn.ys
if grep -qi "warning" syn.log; then grep -i "warning" syn.log | sort | uniq -c; fi

# expected number of hand-instantiated cells, per type
expect() {
    got=$(grep -E "^ +sky130_fd_sc_hd__$1 " syn.log | tail -1 | awk '{print $2}')
    if [ "$got" != "$2" ]; then echo "FAIL: $1: expected $2, found ${got:-0}"; exit 1; fi
}
expect inv_1 210;  expect inv_4 7;    expect nand2_1 2;  expect mux2_1 4;  expect mux4_1 17
expect clkbuf_1 2; expect clkbuf_4 3; expect clkbuf_8 1; expect clkinv_4 1
expect dfxtp_1 30; expect dfxtp_2 1;  expect dfxtp_4 1;  expect dfrtp_1 1
expect dfstp_1 1;  expect dfbbp_1 1;  expect sdfxtp_1 1
echo "cell counts ok"

iverilog -g2005 -o gl.vvp sky130_stubs.v /usr/share/yosys/simcells.v syn.v "$HERE/tb_ffmeta.v"
vvp -n gl.vvp +GATE=400 +NK=2 +DUTS=0 | grep -E "^#" | tee gl.log
grep -q "RESULT: PASS" gl.log
rm -rf "$W"
