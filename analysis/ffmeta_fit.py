#!/usr/bin/env python3
"""Extract the metastability parameters tau and T_w from ffmeta records.

Input: a text file of records produced by the host firmware
(host/ffmeta_host.py), by the behavioural simulation (test/run_sweep.sh) or
by the Monte Carlo model (analysis/ffmeta_mc.py):

    # key=value                                         metadata (f_ref_hz is required)
    F,<what>,<p1>,<p2>,<n_a>,<n_ref>                    frequency of <what>
    M,<dut>,<k>,<j>,<n_meta>,<n_cal>,<n_cyc>,<n_ref>    one gate at delay setting (k, j)

Method
------
1. Time base.  The twin samplers disagree when a data edge falls between the
   DUT clock edge and the early sampling edge, so for |t| < H
       n_cal / n_cyc = |t(k, j)| / H,     H = 1 / (2 f_data).
   f_data comes from the most recent "F,data" record, counted against the
   crystal reference.  Estimates of the same (k, j) are pooled.
2. Model.  For t beyond the normal clock-to-output delay,
       n_meta / n_cyc = (T_w / H) * exp(-t / tau).
   tau and T_w follow from a Poisson regression of n_meta on t (exact for
   small and zero counts).  T_w is quoted twice: extrapolated to t = 0
   ("T_w0", the textbook convention, which absorbs exp(t_cq / tau)) and at
   the knee where the tail begins ("T_w_knee").
3. Uncertainty.  Parametric bootstrap over the counting statistics of both
   n_meta and the time base.  T_w uncertainties are multiplicative and are
   printed as factors ("*/ f": f times larger or smaller):
     T_w0      depends on the absolute time axis, so a residual offset between
               the twin samplers and the DUT / early sampler (clock and data
               skew, aperture difference; --skew-ps) enters as exp(skew / tau).
     T_w_knee  is a ratio taken on one axis, so that offset cancels; it is
               limited instead by how finely the delay settings bracket the knee.
4. Time-base check.  If "F,ring" records are present, the twin-sampler delays
   are regressed on the ring-oscillator calibration of the same coarse line.
   The slope tests the increments; the intercept is the insertion-delay
   offset that a ring calibration cannot see.

SPDX-License-Identifier: Apache-2.0
"""

import argparse
import math
import sys
from collections import defaultdict

import numpy as np

DUT_NAMES = {
    0: "dfxtp_1", 1: "dfxtp_2", 2: "dfxtp_4", 3: "dfrtp_1",
    4: "dfstp_1", 5: "dfbbp_1", 6: "sdfxtp_1", 7: "dfxtp_1 (b)",
}


# ------------------------------------------------------------------ parsing
def parse(path):
    """Return (meta, ring, points).  Each point carries the data half period
    H [s] that was in force when it was taken."""
    meta, ring, points = {}, {}, []
    f_data = None
    with open(path, encoding="utf-8", errors="replace") as fh:
        for raw in fh:
            line = raw.strip()
            if line.startswith("#"):
                if "=" in line:
                    key, val = line[1:].split("=", 1)
                    meta[key.strip()] = val.strip()
                continue
            f = line.split(",")
            if f[0] == "F" and len(f) == 6:
                if "f_ref_hz" not in meta:
                    sys.exit("f_ref_hz metadata must precede the records")
                freq = int(f[4]) / int(f[5]) * float(meta["f_ref_hz"])
                if f[1] == "data":
                    f_data = freq
                elif f[1] == "ring":
                    ring[int(f[2])] = freq
            elif f[0] == "M" and len(f) == 8:
                if f_data is None:
                    sys.exit("an 'F,data' record must precede the M records")
                dut, k, j, n_meta, n_cal, n_cyc, n_ref = (int(x) for x in f[1:])
                if n_cyc == 0:
                    continue
                points.append(dict(
                    dut=dut, k=k, j=j, n_meta=n_meta, n_cal=n_cal, n_cyc=n_cyc,
                    H=1.0 / (2.0 * f_data),
                    T=n_ref / (n_cyc * float(meta["f_ref_hz"])),
                ))
    if not points:
        sys.exit("no M records found in " + path)
    return meta, ring, points


# ---------------------------------------------------------------- time base
def time_base(points):
    """Pooled t(k, j) [s] and its standard error, with the sign resolved."""
    acc = defaultdict(lambda: [0.0, 0.0])   # (k, j) -> [sum w*|t|, sum w]
    for p in points:
        frac = p["n_cal"] / p["n_cyc"]
        if frac > 0.9:
            print(f"warning: n_cal/n_cyc = {frac:.2f} at k={p['k']} j={p['j']}: "
                  "|t| is close to the data half period, use slower data", file=sys.stderr)
        t_abs = frac * p["H"]
        var = max(frac * (1.0 - frac), 1.0 / p["n_cyc"]) / p["n_cyc"] * p["H"] ** 2
        acc[(p["k"], p["j"])][0] += t_abs / var
        acc[(p["k"], p["j"])][1] += 1.0 / var
    keys = sorted(acc)
    t_abs = np.array([acc[q][0] / acc[q][1] for q in keys])
    sig = np.array([1.0 / math.sqrt(acc[q][1]) for q in keys])

    # The counters give |t|.  The sign follows from t being close to linear in
    # (k, j): fit a plane, flip the points the plane puts below zero, repeat.
    kk = np.array([q[0] for q in keys], dtype=float)
    jj = np.array([q[1] for q in keys], dtype=float)
    design = np.column_stack([np.ones_like(kk), kk, jj])
    sign = np.ones_like(t_abs)
    for _ in range(20):
        coef, *_ = np.linalg.lstsq(design, sign * t_abs, rcond=None)
        new = np.where(design @ coef < 0.0, -1.0, 1.0)
        if np.array_equal(new, sign):
            break
        sign = new
    t = sign * t_abs
    tmap = {q: (t[i], sig[i]) for i, q in enumerate(keys)}
    return tmap, coef


# --------------------------------------------------------------- regression
def poisson_fit(t, n, off):
    """Maximum likelihood fit of  E[n] = off * exp(a - b * t).
    Returns (a, b, covariance, deviance)."""
    t0 = t.mean()
    x = np.column_stack([np.ones_like(t), -(t - t0)])
    good = n > 0
    if good.sum() >= 2:
        beta, *_ = np.linalg.lstsq(x[good], np.log(n[good] / off[good]), rcond=None)
    else:
        beta = np.array([math.log(max(n.sum(), 0.5) / off.sum()), 0.0])
    for _ in range(100):
        mu = off * np.exp(np.clip(x @ beta, -700, 700))
        grad = x.T @ (n - mu)
        hess = x.T @ (x * mu[:, None])
        step = np.linalg.solve(hess, grad)
        beta = beta + step
        if np.max(np.abs(step)) < 1e-10 * (1.0 + np.max(np.abs(beta))):
            break
    mu = off * np.exp(x @ beta)
    cov = np.linalg.inv(x.T @ (x * mu[:, None]))
    with np.errstate(divide="ignore", invalid="ignore"):
        dev = 2.0 * np.sum(np.where(n > 0, n * np.log(n / mu), 0.0) - (n - mu))
    a = beta[0] + beta[1] * t0          # undo the centring
    return a, beta[1], cov, dev


def fit_dut(points, tmap, dut, margin, rng, n_boot):
    pts = [p for p in points if p["dut"] == dut]
    t = np.array([tmap[(p["k"], p["j"])][0] for p in pts])
    sig_t = np.array([tmap[(p["k"], p["j"])][1] for p in pts])
    n = np.array([p["n_meta"] for p in pts], dtype=float)
    cyc = np.array([p["n_cyc"] for p in pts], dtype=float)
    H = np.array([p["H"] for p in pts])
    T = np.array([p["T"] for p in pts])
    frac = n / cyc

    # Plateau: while t is shorter than the clock-to-output delay every captured
    # data edge is "late", so n_meta / n_cyc = min(1, T / H).  The knee is the
    # last delay at which the DUT still sits on that plateau.
    plateau = np.minimum(1.0, T / H)
    on_plateau = frac > 0.25 * plateau
    if on_plateau.any():
        last = t[on_plateau].max()
        above = t[t > last]
        # the knee lies between the last plateau point and the first tail point
        t_knee = 0.5 * (last + above.min()) if above.size else last
        knee_gap = above.min() - last if above.size else 0.0
        start = last + margin
    else:
        t_knee = float("nan")
        knee_gap = float("nan")
        start = t.min()
    tail = t > start
    res = dict(dut=dut, t=t, frac=frac, H=H, n=n, tail=tail, t_knee=t_knee,
               knee_gap=knee_gap, n_tail=int(tail.sum()), ok=False)
    if tail.sum() < 3 or n[tail].sum() < 20:
        return res

    off = cyc[tail] / H[tail]
    a, b, cov, dev = poisson_fit(t[tail], n[tail], off)
    res.update(ok=True, a=a, b=b, tau=1.0 / b, dev=dev, dof=int(tail.sum()) - 2,
               tw0=math.exp(a),
               tw_knee=math.exp(a - b * t_knee) if on_plateau.any() else float("nan"),
               tau_err_fit=math.sqrt(cov[1, 1]) / b ** 2)

    taus, tws, tw0s = [], [], []
    for _ in range(n_boot):
        tb = t[tail] + rng.normal(0.0, sig_t[tail])
        nb = rng.poisson(n[tail]).astype(float)
        if nb.sum() < 5:
            continue
        ab, bb, _, _ = poisson_fit(tb, nb, off)
        if bb > 0:
            taus.append(1.0 / bb)
            tws.append(ab - bb * t_knee)
            tw0s.append(ab)
    if len(taus) > 10:
        res["tau_err"] = float(np.std(taus))
        res["ln_tw_knee_err"] = float(np.std(tws))
        res["ln_tw0_err"] = float(np.std(tw0s))
    return res


# ------------------------------------------------------------------- report
def ring_check(ring, tmap):
    """Compare the statistical time base with the ring calibration.
    Half the change of the ring period between taps 0 and k is the delay of k
    coarse taps (mean of rising and falling edge)."""
    ks = sorted(k for k in ring if (k, 0) in tmap and 0 in ring)
    if len(ks) < 3:
        return None
    d_ring = np.array([(1.0 / ring[k] - 1.0 / ring[0]) / 2.0 for k in ks])
    d_stat = np.array([tmap[(k, 0)][0] for k in ks])
    slope, icpt = np.polyfit(d_ring, d_stat, 1)
    resid = d_stat - (slope * d_ring + icpt)
    return dict(slope=slope, offset=icpt, rms=float(np.sqrt(np.mean(resid ** 2))), n=len(ks))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("records")
    ap.add_argument("--margin", type=float, default=30.0,
                    help="start the tail fit this many ps after the knee (default 30)")
    ap.add_argument("--boot", type=int, default=300, help="bootstrap replicas (default 300)")
    ap.add_argument("--skew-ps", type=float, default=15.0,
                    help="assumed residual offset of the absolute time axis between the twin "
                         "samplers and the DUT / early sampler, for the T_w0 uncertainty "
                         "(default 15; replace by the post-layout value)")
    ap.add_argument("--plot", metavar="PNG", help="write a figure")
    ap.add_argument("--expect", metavar="DUT:TAU_PS,...",
                    help="regression test: expected tau per DUT, e.g. 0:45,3:60")
    ap.add_argument("--tol", type=float, default=0.10,
                    help="relative tolerance for --expect (default 0.10)")
    args = ap.parse_args()

    meta, ring, points = parse(args.records)
    tmap, coef = time_base(points)
    rng = np.random.default_rng(1)

    print(f"records: {len(points)} gates, {len(tmap)} delay settings, "
          f"t = {min(v[0] for v in tmap.values()) * 1e12:.0f} .. "
          f"{max(v[0] for v in tmap.values()) * 1e12:.0f} ps")
    print(f"time base: t ~ {coef[0] * 1e12:+.1f} ps {coef[1] * 1e12:+.2f} ps*k "
          f"{coef[2] * 1e12:+.2f} ps*j, median s.e. "
          f"{np.median([v[1] for v in tmap.values()]) * 1e12:.2f} ps")
    rc = ring_check(ring, tmap)
    if rc:
        print(f"time-base check against the ring calibration ({rc['n']} coarse taps, j = 0):")
        print(f"  increments: twin-sampler delay / ring delay = {rc['slope']:.4f}, "
              f"rms residual {rc['rms'] * 1e12:.1f} ps")
        print(f"  offset:     t(k = 0, j = 0) = {rc['offset'] * 1e12:+.1f} ps "
              "(insertion delay, invisible to the ring calibration)")
    else:
        print("time-base check: no usable 'F,ring' records")

    results = []
    print()
    print("DUT  cell          tau [ps]        T_w(knee) [ps]   T_w0 [ps]   knee [ps]  pts  dev/dof")
    for dut in sorted({p["dut"] for p in points}):
        r = fit_dut(points, tmap, dut, args.margin * 1e-12, rng, args.boot)
        results.append(r)
        name = DUT_NAMES.get(dut, "?")
        if not r["ok"]:
            print(f"{dut:<4d} {name:<12s}  not enough tail data ({r['n_tail']} points)")
            continue
        err = r.get("tau_err", r["tau_err_fit"])
        print(f"{dut:<4d} {name:<12s} {r['tau'] * 1e12:7.2f} +- {err * 1e12:<5.2f} "
              f"{r['tw_knee'] * 1e12:10.2f}       {r['tw0'] * 1e12:10.3g}  "
              f"{r['t_knee'] * 1e12:8.0f}  {r['n_tail']:4d}  {r['dev'] / max(r['dof'], 1):6.2f}")

    print()
    print(f"T_w detail; '*/ f' means the value may be f times larger or smaller "
          f"(skew = {args.skew_ps:g} ps assumed):")
    print("DUT   T_w0 [ps]    stat      skew     |  T_w(knee) [ps]  stat      knee position")
    for r in results:
        if not r["ok"]:
            continue
        f_skew = math.exp(args.skew_ps * 1e-12 / r["tau"])
        f_knee = math.exp(0.5 * r["knee_gap"] / r["tau"]) if r["knee_gap"] == r["knee_gap"] else float("nan")
        f_s0 = math.exp(r["ln_tw0_err"]) if "ln_tw0_err" in r else float("nan")
        f_sk = math.exp(r["ln_tw_knee_err"]) if "ln_tw_knee_err" in r else float("nan")
        print(f"{r['dut']:<5d} {r['tw0'] * 1e12:9.3g}  */{f_s0:6.2f}  */{f_skew:6.2f}  |"
              f"  {r['tw_knee'] * 1e12:10.2f}    */{f_sk:6.2f}  */{f_knee:6.2f}")

    # sensitivity of tau to where the fit window starts
    print("\ntau [ps] versus fit start (margin after the knee):")
    margins = [0, 20, 40, 60, 80, 100, 150]
    print("DUT   " + "".join(f"{m:>8d}" for m in margins))
    for r in results:
        row = []
        for m in margins:
            rr = fit_dut(points, tmap, r["dut"], m * 1e-12, rng, 0)
            row.append(f"{rr['tau'] * 1e12:8.2f}" if rr["ok"] else "       -")
        print(f"{r['dut']:<6d}" + "".join(row))

    if args.plot:
        plot(args.plot, results, tmap, ring, meta)

    status = 0
    if args.expect:
        print()
        for item in args.expect.split(","):
            dut, tau = item.split(":")
            r = next((x for x in results if x["dut"] == int(dut)), None)
            good = bool(r and r["ok"] and abs(r["tau"] * 1e12 / float(tau) - 1.0) <= args.tol)
            got = f"{r['tau'] * 1e12:.2f}" if r and r["ok"] else "none"
            print(f"expect DUT {dut}: tau = {tau} ps, got {got} ps -> {'ok' if good else 'MISMATCH'}")
            status |= 0 if good else 1
    return status


def plot(path, results, tmap, ring, meta):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    fig, (ax0, ax1) = plt.subplots(1, 2, figsize=(11, 4.4), constrained_layout=True)

    ks = sorted({q[0] for q in tmap})
    for j in sorted({q[1] for q in tmap}):
        sel = [k for k in ks if (k, j) in tmap]
        ax0.plot(sel, [tmap[(k, j)][0] * 1e12 for k in sel], ".-", ms=4, lw=0.8, label=f"j = {j}")
    if 0 in ring:
        rk = sorted(ring)
        ax0.plot(rk, [(1 / ring[k] - 1 / ring[0]) / 2 * 1e12 for k in rk], "k--", lw=1,
                 label="ring calibration")
    ax0.set_xlabel("coarse tap k")
    ax0.set_ylabel("sampling delay t [ps]")
    ax0.set_title("Self-measured time base")
    ax0.legend(fontsize=7, ncol=2)
    ax0.grid(alpha=0.3)

    for r in results:
        y = r["frac"] * r["H"] * 1e12
        pos = r["n"] > 0
        line, = ax1.semilogy(r["t"][pos] * 1e12, y[pos], ".", ms=5)
        if r["ok"]:
            seen = r["tail"] & pos
            tt = np.linspace(r["t"][r["tail"]].min(), r["t"][seen].max(), 50)
            ax1.semilogy(tt * 1e12, np.exp(r["a"] - r["b"] * tt) * 1e12, "-", lw=1,
                         color=line.get_color(),
                         label=f"{DUT_NAMES.get(r['dut'], r['dut'])}: "
                               f"$\\tau$ = {r['tau'] * 1e12:.1f} ps")
    ax1.set_xlabel("sampling delay t [ps]")
    ax1.set_ylabel(r"$H \cdot n_{meta} / n_{cyc}$ [ps]")
    ax1.set_title("Late-transition probability (scaled to a time window)")
    ax1.legend(fontsize=8)
    ax1.grid(alpha=0.3, which="both")
    fig.suptitle(meta.get("title", "ffmeta"), fontsize=10)
    fig.savefig(path, dpi=150)
    print(f"\nfigure written to {path}")


if __name__ == "__main__":
    sys.exit(main())
