# Research plan: measured metastability parameters of sky130 flip-flops

Working title: **"An open, reproducible metastability characterisation of sky130 flip-flops
with an in-situ absolute time base"**

## 1. Position and claims

This is a replication-plus-extension paper. The measurement architecture is not new, and
the paper must say so. A literature check on 9 November 2026 (open web only, not IEEE
Xplore) found:

| Prior work | What it already did |
|------------|---------------------|
| Beer, Ginosar et al., ISCAS 2011 | The same late-transition circuit (sample on a delayed clock and on the falling edge, XOR, count), fully digital, about 100 x 75 um in 65 nm, delay line calibrated by closing it into a ring oscillator. Compared several flip-flop types. |
| Beer & Ginosar, IEEE Israel 2012 | tau and T_w over 0.95-1.25 V and -20 to 100 C, measured against simulation, tau within 5 %. States that T_w is unreliable because the ring calibration misses the clock insertion delay, and that the method sees the master latch only. |
| Zhou, Kinniment et al., JSSC 2008; Kinniment et al., TVLSI 2007 | On-chip deep-metastability measurement in 0.18 um; back-edge (slave latch) effects. |
| Das, Amrutur et al., TVLSI 2011; US patent 9116204 | Delay and skew measured from the statistics of asynchronous sub-sampling: the principle behind our twin samplers. |
| Polzer & Steininger (FPGA) | Characterisation with calibrated on-chip phase shifting; observes slave metastability. |
| Tiny Tapeout TT04/215, TT05/719, TTIHP26a/655 | Metastability demonstrators. No calibrated time base, no published tau. |

What is left to claim, strongest first:

1. **Absolute time axis.** The twin samplers measure the interval between the DUT clock
   edge and the sampling clock edge directly, insertion delay included, traceable to a
   crystal. This addresses the T_w limitation stated in the 2012 paper. The ring
   calibration is kept as a cross-check of the increments. It combines two known ideas,
   so it is an increment; the check found nobody applying it to metastability.
2. **Open, reproducible dataset.** tau and T_w for seven `sky130_fd_sc_hd` flip-flop
   cells (one of them twice) against supply voltage and temperature, compared with
   ngspice on the open PDK models. No measured or simulated values were found for
   sky130, gf180mcu or sg13g2, and the 65 nm work cannot be reproduced by outsiders.
   The value is reproducibility and usefulness to open-silicon designers.
3. **Stretch results.** tau drift under stress (E7) and chip-to-chip spread (E6).

Do not claim a new measurement architecture, new theory, or that a digital-output
measurement needing only two frequency sources is new.

Before submitting, repeat the check with full-text access (IEEE Xplore, Google Scholar):
"metastability measurement" with "sub-sampling" or "asynchronous sampling" or "statistical
calibration"; "sky130" or "open-source PDK" with "synchronizer" or "metastability";
everything citing Beer 2011 and Zhou 2008; "aging" or "BTI" with "synchronizer tau".

## 2. Method in one paragraph

A DUT flip-flop samples asynchronous data. An early sampler looks at the DUT output a
delay `t` after the DUT clock edge; a late sampler looks half a period later. They differ
when the DUT resolved later than `t`. With data slower than half the clock rate,

    n_meta / n_cyc = (T_w / H) * exp(-t / tau),        H = data half period.

`t(k, j)` is set by a 32-tap coarse line in the sampling clock and an 8-tap vernier line
in the DUT clock, and measured by twin samplers of the same data on both clocks:
`n_cal / n_cyc = |t| / H`. tau is the slope of a Poisson regression; T_w is quoted at the
knee (start of the exponential tail) and extrapolated to `t = 0`.

## 3. Experiments

| # | Experiment | Purpose | Needs |
|---|------------|---------|-------|
| E1 | All 8 DUTs, 1.8 V, room temperature, 10 s gates | headline tau, T_w table | demo board |
| E2 | Supply sweep, about 1.2 V to 1.95 V in 0.1 V steps | tau(V); low-voltage design rules | bench supply on the 1.8 V core rail |
| E3 | Temperature sweep, about 0 to 85 C | tau(T) | chamber or hot plate + thermocouple |
| E4a | Statistical time base vs ring calibration | validates uniform-arrival assumption and the time axis | - |
| E4b | Change RO_C and RO_D lengths | event rate must scale as f_clk * f_data, tau must not move | - |
| E4c | Data from external generator on `ui_in[6]` instead of RO_D | rules out injection locking between the two on-chip oscillators | signal generator |
| E4d | DUT 0 vs DUT 7 (same cell, two instances) | placement / routing repeatability, sets the resolution for cell-to-cell differences | - |
| E4e | Static data | noise floor (must be zero events) | - |
| E4f | Fit-window scan (already printed by `ffmeta_fit.py`) | tau must be stable against where the fit starts | - |
| E5 | SPICE tau of each cell (ngspice, sky130 models, extracted cell netlists, tt/ss/ff) | model-to-hardware correlation | PC |
| E6 | Several chips | chip-to-chip spread | more chips; other owners of the same shuttle also have the design |
| E7 | Stress: clock root off, static data, raised supply and temperature; repeat E1 at nominal conditions before, between and after stress intervals, then during recovery | tau and knee drift under BTI-type stress; the in-situ time base separates DUT drift from delay-line drift | bench supply, heater. Risks the chip, so do it last. A null result (an upper bound) is likely at 130 nm |

E7 needs no RTL change: write `0x03` to register 14 (`clk_sel = 3`, data from
`ui_in[6]`) and `0x00` to register 15 (oscillators off), then hold `ui_in[6]` at a fixed
level. `Chip.stress_hold(level)` in `host/ffmeta_host.py` does this. How far the core rail
of the demo board may be raised has not been checked.

Record supply voltage (measured at the board), temperature and chip id in every run
(`fm.run(chip, vdd=..., temp_c=..., chip_id=...)`).

## 4. Expected numbers (planning only, not predictions)

`analysis/ffmeta_mc.py` with tau = 60 ps, T_w = 30 ps, 157 MHz clock, 65 MHz data: a 1 s
gate per point shows about 6 decades of the tail over about 175 delay settings and gives
a statistical error on tau near 0.2 %. The measurement will therefore be limited by
systematics, not by counting statistics. Budget them explicitly:

- **Delay-line jitter and supply noise.** Jitter grows with the delay, so it can bias the
  slope. Bound it from E4a residuals and from repeating E1 at two RO_C lengths.
- **Rise/fall asymmetry.** The ring calibration averages rising and falling delays; the
  twin samplers measure the rising edge actually used. Their ratio is a result, not an error.
- **Sampler aperture.** The twins and the early sampler are `dfxtp_1`; for other DUT types
  the absolute `t` has an offset of order 10 ps. It cancels in tau and enters T_w as
  `exp(offset / tau)`. Quote T_w with that uncertainty.
- **Clock skew inside the hand-built nets.** Read the per-pin arrival times from the
  post-layout STA and correct or bound.
- **Oscillator coupling.** RO_C and RO_D share a supply; E4c is the control.
- **One process corner per shuttle.** State it; E6 only samples within-wafer spread.
- **Master latch only.** The late sample is taken on the falling clock edge, so the
  measurement sees the master latch's tau, as in Beer 2012. A slower slave latch would
  make the real MTBF worse than the table in section 5 suggests. State it.

## 5. Figures and tables

1. Block diagram of the structure (from `src/ffm_core.v` header).
2. Layout / die photo of the tile with the DUT block marked.
3. Time base: `t(k, j)` from twin samplers with the ring calibration overlaid (left panel
   of the `ffmeta_fit.py` figure).
4. Late-transition probability vs `t` for all DUTs with fits (right panel).
5. tau vs supply voltage, measured and SPICE.
6. tau vs temperature.
7. Table: tau, T_w(knee), T_w0 per cell, with uncertainties and chip-to-chip spread.
8. Table: MTBF of a two-flop synchroniser built from each cell at representative
   frequencies, and the resolution time needed for a 1000-year MTBF.

## 6. Venue

| Venue | Realistic? |
|-------|-----------|
| IEEE ASYNC symposium | Best fit: the metastability community. Needs claim 1 validated (E4a) and E1-E3. |
| ISCAS, ICECS, NorCAS | Conference route with the same content. |
| IEEE Access, Microelectronics Journal, Integration | Journal route. Needs E1-E5 complete. |
| HardwareX, Journal of Open Hardware | If written as an open, reproducible instrument. |
| IEEE TCAS-II: Express Briefs | Long shot. Only if claim 1 survives the full-text check and E7 or a second PDK shows something new. |
| IEEE TVLSI, TCAS-I, JSSC | Not realistic for this content. |

A single chip supports claim 1 firmly and claim 2 with a caveat; try to measure at least
three chips before a journal submission.

## 7. Status and next steps

Done and verified here:
- RTL (`src/`), behavioural simulation of the whole chip (`test/tb_ffmeta.v`): registers,
  counters, both ring oscillators, ring calibration, full metastability sweep.
- Extraction (`analysis/ffmeta_fit.py`) recovers the tau injected into the behavioural
  model (45.9 / 60.6 / 73.5 ps for 45 / 60 / 75 ps) and into the Monte Carlo model; the
  twin-sampler and ring time bases agree to 0.9 % in that simulation.
- Yosys synthesis is clean and keeps every hand-instantiated cell; the cocotb test and
  the functional test bench pass on the RTL and on the Yosys netlist
  (`test/run_synth_check.sh`).

Not yet verified:
- LibreLane place and route: `src/config.json` additions and `src/ffmeta.sdc` have not
  been run. Check in the first GDS action run that (a) all four clocks are created,
  (b) no buffers were inserted inside `mx_core`, (c) utilisation and timing are clean,
  (d) the gate-level test with the real PDK models passes.
- `host/ffmeta_host.py` (MicroPython) has not been run on a board.

Then:
1. Create the repository from `TinyTapeout/ttsky-verilog-template`, copy this tree in,
   rename the top module to include the GitHub user name, fill in the author.
2. Iterate on the GDS action until clean; inspect the layout of the DUT block.
3. Post-layout: extract clock arrival times at the DUT, sampler and twin clock pins.
4. Run E5 (SPICE) while the chip is being fabricated, so predictions are on record
   before silicon arrives.
5. On silicon: self-test, E4 controls first, then E1-E3.
