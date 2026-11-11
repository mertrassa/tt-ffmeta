# ffmeta: flip-flop metastability characterisation on Tiny Tapeout (sky130)

A one-tile Tiny Tapeout design that measures the metastability resolution time constant
(tau) and window (T_w) of eight `sky130_fd_sc_hd` flip-flop cells, with a time base the
chip calibrates itself. It is the hardware for a measurement paper; see
[paper/research-plan.md](paper/research-plan.md).

- [docs/info.md](docs/info.md): how it works, register map, how to test
- [src/ffm_core.v](src/ffm_core.v): the experiment (delay lines, DUTs, samplers)
- [src/project.v](src/project.v): Tiny Tapeout top level, registers, counters

## Layout

| Path | Contents |
|------|----------|
| `src/` | RTL, LibreLane `config.json`, timing constraints `ffmeta.sdc` |
| `test/tb_ffmeta.v`, `run_sim.sh`, `run_sweep.sh` | behavioural simulation of the whole chip (Icarus Verilog) |
| `test/run_synth_check.sh`, `sky130_stubs.v` | Yosys synthesis check with stand-in sky130 cells (no PDK needed) |
| `test/test.py`, `tb.v`, `Makefile` | Tiny Tapeout cocotb test (RTL and gate level) |
| `host/ffmeta_host.py` | MicroPython measurement firmware for the demo board |
| `analysis/ffmeta_fit.py` | records -> tau, T_w, figure |
| `analysis/ffmeta_mc.py` | Monte Carlo model for planning gate times |
| `paper/research-plan.md` | claims, experiments, error budget, venues, next steps |

## Simulate

Needs Icarus Verilog and Python with numpy and matplotlib.

```bash
bash test/run_sim.sh 400 2 0
```

runs the functional checks (registers, counters, oscillators, ring calibration).

```bash
bash test/run_sweep.sh 5000 8 0 3 5
```

runs the metastability sweep for DUTs 0, 3 and 5 in parallel (slow: the behavioural
models simulate every inverter edge), then

```bash
python analysis/ffmeta_fit.py test/sim_build/sweep.log --expect 0:45,3:60,5:75 --plot build/sim.png
```

checks that the extraction recovers the tau values built into the behavioural flip-flop
models (45, 60 and 75 ps; these are test values, not predictions for silicon).

The cell wrappers in `src/ffm_cells.v` instantiate real `sky130_fd_sc_hd` cells for
synthesis and switch to behavioural models when `FFM_BEHAV` is defined.

```bash
bash test/run_synth_check.sh
```

synthesises the design with Yosys (sky130 cells as black boxes), checks that every
hand-instantiated cell survives, and runs the functional checks on the netlist.

The cocotb test (`cd test && make`) needs a checkout path without spaces: `make` cannot
handle them.

## Submit to Tiny Tapeout

The repository [mertrassa/tt-ffmeta](https://github.com/mertrassa/tt-ffmeta) was created
from [TinyTapeout/ttsky-verilog-template](https://github.com/TinyTapeout/ttsky-verilog-template)
(workflows pinned to the `ttsky26d` shuttle); the `gds`, `test` and `docs` actions run on
every push, and GitHub Pages (source: GitHub Actions) serves the layout viewer. Submit the
repository at [app.tinytapeout.com](https://app.tinytapeout.com) once all actions are green.

## Hardening notes

The experiment core (`mx_core`) is built from hand-instantiated cells that the tools must
leave alone. Three things make that work; all three were found the hard way:

- `RSZ_DONT_TOUCH_RX` keeps the resizer out of `mx_core` and off `clk_core`.
- Clock tree synthesis ignores that list, so place and route uses `src/ffmeta_pnr.sdc`,
  which declares only the reference clock. `src/ffmeta.sdc`, with the four real clocks, is
  used for sign-off timing only.
- CTS also follows the `clk` net through every combinational cell regardless of
  constraints (and does not terminate in the calibration ring), so the reference clock
  enters the core only through a divide-by-two flip-flop.

After every hardening run, check the result:

```bash
python analysis/check_netlist.py <runs/wokwi/final/nl/...nl.v>
```

confirms that no cell inside the core was resized or buffered, and

```bash
python analysis/layout_delays.py <...stapostpnr/nom_tt_025C_1v80/...sdf>
```

prints the post-layout oscillator periods and tap delays. Both files are in the `GDS_logs`
artifact of the `gds` action.

## Status

Verified in simulation:

- the RTL, the measurement protocol and the tau extraction (behavioural sweep recovers
  45.9, 60.6 and 73.5 ps for injected 45, 60 and 75 ps);
- `test/test.py` (cocotb) and the functional part of `test/tb_ffmeta.v` on the RTL and on
  a Yosys netlist.

Verified by the Tiny Tapeout flow (GitHub Actions, LibreLane, sky130A):

- hardening, DRC, LVS, antenna check and the Tiny Tapeout precheck pass; utilisation 68 %;
- the gate-level test with the PDK cell models passes;
- the routed netlist has all 319 hand-instantiated core cells, unmodified, and no
  tool-inserted cell on any net inside the core;
- sign-off timing: no hold violations in any corner; setup met at the typical corner for
  a 4 ns core clock (0.39 ns slack). At the slow corner the synchronous logic needs
  5.4 ns, while the fastest ring-oscillator setting slows to about 8.4 ns there.

Post-layout static-timing predictions (typical corner): RO_C 8.9 / 7.5 / 6.3 / 4.8 ns,
RO_D 4.9 / 3.5 ns before division, coarse tap 93 ps (77 to 108), vernier tap 114 ps,
coarse line 2.9 ns in total.

Not yet verified:

- `host/ffmeta_host.py` (MicroPython) has not been run on a board.
- Nothing has been measured: every number above is simulation or static timing.
