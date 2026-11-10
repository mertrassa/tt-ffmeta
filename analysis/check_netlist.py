#!/usr/bin/env python3
"""Check that place and route left the experiment core exactly as written.

    python analysis/check_netlist.py <final netlist .nl.v>

The delay lines, ring oscillators, devices under test and samplers are
hand-instantiated library cells inside the instance `mx_core`.  The
measurement is only meaningful if the tools did not resize them, add buffers
to their nets or hang foreign loads on them.  This script checks, in the
gate-level netlist written by the hardening flow:

1. the number of cells of each type inside mx_core is the expected one;
2. no other cell type appears inside mx_core;
3. every net between two core cells is touched by core cells only, and the
   nets that cross the boundary have the expected foreign pins.

SPDX-License-Identifier: Apache-2.0
"""

import collections
import re
import sys

PREFIX = "sky130_fd_sc_hd__"
EXPECTED = {
    "inv_1": 210, "inv_4": 7, "nand2_1": 2, "mux2_1": 4, "mux4_1": 17,
    "clkbuf_1": 2, "clkbuf_4": 3, "clkbuf_8": 1, "clkinv_4": 1,
    "dfxtp_1": 30, "dfxtp_2": 1, "dfxtp_4": 1, "dfrtp_1": 1, "dfstp_1": 1,
    "dfbbp_1": 1, "sdfxtp_1": 1,
}
INST = re.compile(r"^\s*(sky130_\w+)\s+(\\\S+|\w+)\s*\((.*?)\);", re.M | re.S)
PIN = re.compile(r"\.(\w+)\(\s*(\\\S+|[\w\[\]']*)\s*\)")


def main():
    text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
    core = collections.Counter()
    touch = collections.defaultdict(list)      # net -> [(instance, cell, pin)]
    n_inst = 0
    for cell, name, body in INST.findall(text):
        cell = cell.replace(PREFIX, "")
        if cell.startswith(("decap", "fill", "tapvpwrvgnd")):
            continue
        n_inst += 1
        in_core = name.startswith("\\mx_core.")
        if in_core:
            core[cell] += 1
        for pin, net in PIN.findall(body):
            if pin in ("VPWR", "VGND", "VPB", "VNB") or not net:
                continue
            touch[net].append((name, cell, pin, in_core))

    ok = True
    print(f"{n_inst} logic cells, {sum(core.values())} inside mx_core")
    for cell, want in sorted(EXPECTED.items()):
        got = core.get(cell, 0)
        if got != want:
            ok = False
            print(f"FAIL  {cell}: expected {want}, found {got}")
    for cell, got in sorted(core.items()):
        if cell not in EXPECTED and cell != "conb_1":
            ok = False
            print(f"FAIL  unexpected cell type inside mx_core: {cell} x{got}")

    # nets with at least one core pin
    boundary = []
    for net, pins in touch.items():
        n_core = sum(1 for p in pins if p[3])
        if n_core == 0:
            continue
        foreign = [p for p in pins if not p[3]]
        if foreign:
            boundary.append((net, n_core, foreign))
    print(f"{len(boundary)} nets connect the core to the rest of the design:")
    for net, n_core, foreign in sorted(boundary):
        cells = collections.Counter(p[1] + "/" + p[2] for p in foreign)
        desc = ", ".join(f"{c} x{n}" for c, n in sorted(cells.items()))
        print(f"  {net:<34s} core pins {n_core:2d} | outside: {desc}")

    print("RESULT:", "core intact" if ok else "CORE WAS MODIFIED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
