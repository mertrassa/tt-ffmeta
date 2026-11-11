#!/usr/bin/env python3
"""Post-layout delay estimates for the experiment core, from the sign-off SDF.

    python analysis/layout_delays.py <design>__nom_tt_025C_1v80.sdf

Sums the cell (IOPATH) and wire (INTERCONNECT) delays written by sign-off STA
along the hand-built structures and prints what the measurement depends on:
ring-oscillator periods, delay per coarse and vernier tap, and the calibration
ring period.  These are static-timing numbers from the PDK's Liberty models
and extracted parasitics: a prediction to compare with silicon, not a result.

SPDX-License-Identifier: Apache-2.0
"""

import re
import sys
from collections import defaultdict

TRIPLE = re.compile(r"\(\s*(-?[\d.]+)?:?(-?[\d.]+)?:?(-?[\d.]+)?\s*\)")


def typ(text):
    """Mean of the rise and fall delay triples that follow an SDF keyword."""
    vals = []
    for m in TRIPLE.finditer(text):
        nums = [float(x) for x in m.groups() if x is not None]
        if nums:
            vals.append(nums[len(nums) // 2])
    return sum(vals[:2]) / max(len(vals[:2]), 1)


def unescape(name):
    return name.replace("\\", "")


def main():
    text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
    scale = 1.0
    m = re.search(r"\(TIMESCALE\s+([\d.]+)\s*(\w+)\)", text)
    if m:
        scale = float(m.group(1)) * {"ns": 1000.0, "ps": 1.0}.get(m.group(2), 1.0)

    cell_delay = defaultdict(dict)     # instance -> {in_pin: delay ps}
    for blk in re.finditer(r"\(CELL\s+\(CELLTYPE\s+\"(\S+)\"\)\s+\(INSTANCE\s+(\S*)\)(.*?)\n \)", text, re.S):
        inst = unescape(blk.group(2))
        for io in re.finditer(r"\(IOPATH\s+(\S+)\s+(\S+)\s+(.*?)\)\s*\n", blk.group(3)):
            pin = io.group(1).split()[-1].strip("()")
            cell_delay[inst][pin] = typ(io.group(3)) * scale
    wire = defaultdict(float)          # sink "inst/pin" -> delay ps
    for ic in re.finditer(r"\(INTERCONNECT\s+(\S+)\s+(\S+)\s+(.*?)\)\s*\n", text):
        wire[unescape(ic.group(2))] = typ(ic.group(3)) * scale

    def find(prefix):
        """Full name of the library cell instance below a wrapper instance
        (generate-block names in between depend on the drive strength)."""
        for inst in cell_delay:
            if inst.startswith(prefix + ".") and inst.endswith(".mx_cell"):
                return inst
        return None

    def stage(prefix, pin="A"):
        """Delay through one wrapped cell including the wire into its input."""
        inst = find(prefix)
        if inst is None or pin not in cell_delay[inst]:
            return None
        return cell_delay[inst][pin] + wire.get(f"{inst}/{pin}", 0.0)

    def total(prefix, pin="A"):
        ds = [cell_delay[i][pin] + wire.get(f"{i}/{pin}", 0.0)
              for i in cell_delay if i.startswith(prefix) and i.endswith(".mx_cell") and pin in cell_delay[i]]
        return sum(ds), len(ds)

    print("Static-timing estimates, typical corner (ps):")
    for name, segs in (("RO_C", ("u_s0", "u_s1", "u_s2", "u_s3")), ("RO_D", ("u_s0", "u_s3"))):
        ro = "mx_core.u_roc." if name == "RO_C" else "mx_core.u_rod."
        nand = stage(ro + "u_en", "B") or 0.0
        acc, n = nand, 1
        opts = []
        for seg in segs:
            d, k = total(ro + seg + ".")
            acc, n = acc + d, n + k
            opts.append((n, acc))
        for (n_st, half), a_pin in zip(reversed(opts), ("A0", "A1", "A2", "A3")):
            mux = stage(ro + "u_len", a_pin) or 0.0
            period = 2.0 * (half + mux)
            print(f"  {name} {n_st:2d} stages: period {period:7.0f} ps  ({1e6 / period:5.0f} MHz)")

    pair = []
    for m_ in range(8):
        for t in (1, 2, 3):
            a = stage(f"mx_core.g_c[{m_}].u_s.u_a{t}")
            b = stage(f"mx_core.g_c[{m_}].u_s.u_b{t}")
            if a is not None and b is not None:
                pair.append(a + b)
        a = stage(f"mx_core.g_c[{m_}].u_s.g_next.u_a4")
        b = stage(f"mx_core.g_c[{m_}].u_s.g_next.u_b4")
        if a is not None and b is not None:
            pair.append(a + b)
    if pair:
        print(f"  coarse tap (k): {len(pair)} pairs, mean {sum(pair) / len(pair):.0f} ps, "
              f"min {min(pair):.0f}, max {max(pair):.0f}, line total {sum(pair):.0f} ps")
    vpair = []
    for seg in ("u_v_s0", "u_v_s1"):
        for t in (1, 2, 3, 4):
            pre = f"mx_core.{seg}." + ("g_next." if t == 4 else "")
            a = stage(pre + f"u_a{t}")
            b = stage(pre + f"u_b{t}")
            if a is not None and b is not None:
                vpair.append(a + b)
    if vpair:
        print(f"  vernier tap (j): {len(vpair)} pairs, mean {sum(vpair) / len(vpair):.0f} ps, "
              f"min {min(vpair):.0f}, max {max(vpair):.0f}")
    if not pair and not vpair:
        print("  no delay-line instances found: instance naming differs from what this script expects")
        print("  sample instances:", [i for i in cell_delay if "mx_core" in i][:5])


if __name__ == "__main__":
    main()
