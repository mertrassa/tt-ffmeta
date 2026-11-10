<!---

This file is used to generate your project datasheet. Please fill in the information below and delete any unused
sections.

You can also include images in this folder and reference them in the markdown. Each image must be less than
512 kb in size, and the combined size of all images must be less than 1 MB.
-->

## How it works

`ffmeta` measures how quickly sky130 flip-flops recover from metastability. For each of
eight flip-flop cells it yields the resolution time constant **tau** and the metastability
window **T_w**, the two numbers needed to compute the MTBF of a synchroniser
(`MTBF = exp(t / tau) / (T_w * f_clk * f_data)`).

Devices under test (DUT), all from `sky130_fd_sc_hd`:

| DUT | cell | DUT | cell |
|-----|------|-----|------|
| 0 | `dfxtp_1` | 4 | `dfstp_1` (async set) |
| 1 | `dfxtp_2` | 5 | `dfbbp_1` (set + reset) |
| 2 | `dfxtp_4` | 6 | `sdfxtp_1` (scan) |
| 3 | `dfrtp_1` (async reset) | 7 | `dfxtp_1` (second instance) |

**Experiment.** Every DUT samples an asynchronous data signal. Its output is sampled again
a programmable time `t` later by an "early" flip-flop, and once more half a clock period
later, when it has certainly settled. If the two samples differ, the DUT output had not
reached its final value after `t`: a late, metastable transition. The fraction of clock
cycles with such an event falls as `(T_w / H) * exp(-t / tau)`, where `H` is the data half
period, so a sweep of `t` gives tau from the slope and T_w from the intercept.

**Clock and data** come from two on-chip ring oscillators (lengths selectable), from the
reference clock divided by two, or from `ui_in[6]`.

**Sampling delay.** `t` is the difference of two tapped inverter lines: a 32-tap coarse
line in the early sampling clock (`k`, about 0.1 ns per tap) and an 8-tap vernier line
with a different unit delay in the DUT clock (`j`). Together they give up to 256 unevenly
spaced delays from about -1 ns to +3 ns.

**Self-calibration.** No external timing equipment is needed. Two twin flip-flops sample
the *same* asynchronous data on the DUT clock and on the early clock. They disagree
exactly when a data edge falls between the two clock edges, which happens with
probability `|t| / H`. Counting disagreements therefore measures `t` for every `(k, j)`
directly in units of the data period, and the data period is counted against the
reference clock. As an independent check the coarse line can be closed into a ring
oscillator and its period counted for every tap.

**Counters.** Four 24-bit gated counters run while `GATE` is high: `EV0` and `EV1`
(selectable event types), `A` (cycles of a selectable clock) and `REF` (cycles of `clk`).

### Register map

`ui_in[3:0]` selects the byte on `uo_out`. Counters are little endian and must be read
while `GATE` is low.

| addr | read |
|------|------|
| 0-2 | `EV0` |
| 3-5 | `EV1` |
| 6-8 | `A` |
| 9-11 | `REF` |
| 12 | `cfg0 = {j[2:0], k[4:0]}` |
| 13 | `cfg1 = {ring_en, ev1_sel[1:0], ev0_sel[1:0], dut[2:0]}` |
| 14 | `cfg2 = {0, rod_len, dat_sel[1:0], roc_len[1:0], clk_sel[1:0]}` |
| 15 | `cfg3 = {0000, a_sel[1:0], rod_en, roc_en}` |

Writing: put the address (12-15) on `ui_in[3:0]`, the data on `uio[7:0]`, and hold `WR`
high across one rising edge of `clk`.

| field | meaning |
|-------|---------|
| `ev0_sel`, `ev1_sel` | 0 late transition of the selected DUT, 1 twin samplers disagree, 2 DUT output changed, 3 every cycle |
| `clk_sel` | DUT clock: 0 `clk / 2`, 1 RO_C, 2 `ui_in[6]`, 3 off |
| `roc_len` | RO_C stages: 0 = 75, 1 = 55, 2 = 41, 3 = 31 |
| `dat_sel` | data: 0 `ui_in[6]`, 1 RO_D, 2 RO_D / 2, 3 `clk / 2` |
| `rod_len` | RO_D stages: 0 = 67, 1 = 47 |
| `a_sel` | clock counted by `A`: 0 DUT clock, 1 data, 2 early clock / calibration ring, 3 `clk / 2` |
| `ring_en` | close the coarse delay line into a ring |

Change oscillator lengths, taps and `ring_en` only while the oscillators are disabled
(and, for the calibration ring, with `clk_sel = 3`): switching a ring while an edge is
circulating can leave it running in a harmonic mode.

## How to test

1. Select the project, apply a 10 MHz clock and reset.
2. Write `0xA5` to address 12 and read it back.
3. Self-test: `cfg1 = 0x78` (both event counters count every cycle), pulse `CLEAR`, hold
   `GATE` high for a known time, then read `EV0`, `A` and `REF`: `REF` is the number of
   clock cycles in the gate, `EV0` and `A` are half of it (after reset the experiment
   runs from `clk / 2`).
4. Enable the oscillators (`cfg3 = 0x03`), select RO_C as DUT clock and RO_D / 2 as data
   (`cfg2 = 0x25`), select a DUT, `EV0` = late transitions and `EV1` = twin samplers
   (`cfg1 = 0x20 | dut`), then step `k` and `j` through `cfg0`, counting for 10 ms to 10 s
   per setting. `EV0 / A` falls exponentially with the delay obtained from `EV1 / A`.

`host/ffmeta_host.py` (MicroPython, runs on the demo board's RP2040) automates the sweep
and prints records that `analysis/ffmeta_fit.py` turns into tau and T_w.

## External hardware

None for a basic measurement: the Tiny Tapeout demo board is enough. For the full
characterisation an adjustable 1.8 V core supply and a way to heat or cool the chip are
useful, and an external signal generator on `ui_in[6]` gives a data source that is
independent of the on-chip oscillators.
