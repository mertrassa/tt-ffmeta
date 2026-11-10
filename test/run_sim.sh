#!/bin/bash
# Simulation of the whole chip with Icarus Verilog.
#   ./run_sim.sh [GATE] [NK] [DUTS] [struct]   -> sim_build/sim.log
# GATE = reference cycles per sweep point, NK = coarse taps per vernier
# setting, DUTS = decimal bit mask of devices under test to sweep (0 = only
# the functional checks).
# With "struct" the cell wrappers instantiate (stand-in) sky130 cells exactly
# as in synthesis, instead of the behavioural models.
set -e
cd "$(dirname "$0")"
GATE=${1:-4000}
NK=${2:-8}
DUTS=${3:-41}
mkdir -p sim_build
if [ "$4" = "struct" ]; then
    OUT=sim_build/ffmeta_struct.vvp
    iverilog -g2005 -o $OUT sky130_stubs.v \
        ../src/ffm_cells.v ../src/ffm_core.v ../src/ffm_counter.v ../src/project.v tb_ffmeta.v
else
    OUT=sim_build/ffmeta.vvp
    iverilog -g2005 -DFFM_BEHAV -o $OUT \
        ../src/ffm_cells.v ../src/ffm_core.v ../src/ffm_counter.v ../src/project.v tb_ffmeta.v
fi
vvp -n $OUT +GATE="$GATE" +NK="$NK" +DUTS="$DUTS" | tee sim_build/sim.log
grep -q "RESULT: PASS" sim_build/sim.log
