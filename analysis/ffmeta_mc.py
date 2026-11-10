#!/usr/bin/env python3
"""Monte Carlo model of the ffmeta experiment, for planning a measurement.

Draws the counter values the chip would report for assumed device parameters
and prints records in the format read by ffmeta_fit.py, e.g.

    python ffmeta_mc.py --tau 60 --tw 30 --gate 10 > mc.txt
    python ffmeta_fit.py mc.txt --plot mc.png

It answers "how long must the gate be", "how many decades will I see" and
"what statistical error on tau should I expect" before any silicon exists.
It models counting statistics only: no jitter, no supply noise, no locking
between the oscillators.

SPDX-License-Identifier: Apache-2.0
"""

import argparse

import numpy as np


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--tau", type=float, default=60.0, help="resolution time constant [ps]")
    ap.add_argument("--tw", type=float, default=30.0, help="window T_w referred to t_cq [ps]")
    ap.add_argument("--tcq", type=float, default=380.0, help="clock-to-output delay [ps]")
    ap.add_argument("--fc", type=float, default=157e6, help="DUT clock frequency [Hz]")
    ap.add_argument("--fd", type=float, default=64.6e6, help="data frequency [Hz]")
    ap.add_argument("--gate", type=float, default=1.0, help="longest gate per point [s]")
    ap.add_argument("--min-events", type=int, default=2000,
                    help="stop extending the gate once this many events are seen")
    ap.add_argument("--dk", type=float, default=105.0, help="coarse tap delay [ps]")
    ap.add_argument("--dj", type=float, default=140.0, help="vernier tap delay [ps]")
    ap.add_argument("--mismatch", type=float, default=8.0, help="rms tap irregularity [ps]")
    ap.add_argument("--dut", type=int, default=0)
    ap.add_argument("--f-ref", type=float, default=10e6)
    ap.add_argument("--seed", type=int, default=0)
    a = ap.parse_args()

    rng = np.random.default_rng(a.seed)
    H = 1.0 / (2.0 * a.fd) * 1e12          # data half period [ps]
    T = 1.0 / a.fc * 1e12                  # clock period [ps]
    if H <= T:
        raise SystemExit("choose fd < fc / 2 so that every data edge is captured once")

    print("# ffmeta Monte Carlo")
    print(f"# title=Monte Carlo: tau = {a.tau} ps, T_w = {a.tw} ps")
    print(f"# f_ref_hz={a.f_ref:.0f}")
    n_ref = int(a.f_ref * 0.1)
    print(f"F,data,2,0,{int(round(a.fd * 0.1))},{n_ref}")

    off_k = rng.normal(0.0, a.mismatch, 32)
    off_j = rng.normal(0.0, a.mismatch, 8)
    for j in range(8):
        for k in range(32):
            t = k * a.dk + off_k[k] - j * a.dj - off_j[j]
            if not -0.2 * T < t < 0.45 * T:
                continue                   # outside the valid range of the pipeline
            if t <= a.tcq:
                p = T / H                  # plateau: every captured edge is late
            else:
                p = a.tw / H * np.exp(-(t - a.tcq) / a.tau)
            # adaptive gate, as the host does: 10 ms, then x10 up to --gate
            gate = 0.01
            while True:
                n_cyc = int(a.fc * gate)
                n_meta = rng.binomial(n_cyc, min(p, 1.0))
                if n_meta >= a.min_events or gate >= a.gate:
                    break
                gate = min(gate * 10.0, a.gate)
            n_cal = rng.binomial(n_cyc, min(abs(t) / H, 1.0))
            print(f"M,{a.dut},{k},{j},{n_meta},{n_cal},{n_cyc},{int(a.f_ref * gate)}")


if __name__ == "__main__":
    main()
