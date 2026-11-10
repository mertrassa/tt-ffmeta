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

The repository was created from
[TinyTapeout/ttsky-verilog-template](https://github.com/TinyTapeout/ttsky-verilog-template);
the `gds`, `test` and `docs` GitHub actions run on every push. When they are green, submit
the repository at [app.tinytapeout.com](https://app.tinytapeout.com) (the repository must
be public at that point).

## Status

Verified in simulation:

- the RTL, the measurement protocol and the tau extraction (behavioural sweep recovers
  45.9, 60.6 and 73.5 ps for injected 45, 60 and 75 ps);
- Yosys 0.33 synthesis: no warnings, all 282 hand-instantiated cells kept, flattened
  instance names match the patterns in `src/ffmeta.sdc`;
- `test/test.py` (cocotb 2.1) and the functional part of `test/tb_ffmeta.v` pass on the
  RTL and on the Yosys netlist.

Not yet verified, check on the first GitHub Actions run:

- Place and route. `src/config.json` additions and `src/ffmeta.sdc` have never been
  through LibreLane. Confirm that the four clocks in the SDC are created, that nothing
  inside `mx_core` was buffered or resized, and that timing and utilisation are clean.
- The gate-level test with the real PDK cell models.
- `host/ffmeta_host.py` (MicroPython) has not been run on a board.
