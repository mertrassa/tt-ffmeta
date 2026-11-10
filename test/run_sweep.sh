#!/bin/bash
# Run the behavioural metastability sweep for several DUTs in parallel
# (one simulator process per DUT) and concatenate the records.
#   ./run_sweep.sh [GATE] [NK] [DUT ...]   -> sim_build/sweep.log
set -e
cd "$(dirname "$0")"
GATE=${1:-6000}
NK=${2:-8}
shift 2 2>/dev/null || true
DUTS=${*:-0 3 5}
mkdir -p sim_build
iverilog -g2005 -DFFM_BEHAV -o sim_build/ffmeta.vvp \
    ../src/ffm_cells.v ../src/ffm_core.v ../src/ffm_counter.v ../src/project.v tb_ffmeta.v
for d in $DUTS; do
    stdbuf -oL vvp -n sim_build/ffmeta.vvp +GATE="$GATE" +NK="$NK" +DUTS=$((1 << d)) \
        > "sim_build/sweep_dut$d.log" &
done
wait
cat sim_build/sweep_dut*.log > sim_build/sweep.log
grep -c "^M," sim_build/sweep.log
