# SPDX-License-Identifier: Apache-2.0
#
# Tiny Tapeout cocotb test for tt_um_mertrassa_ffmeta.
#
# Functional test only: registers, counters and event detection with the core
# clocked from the reference clock, so it also runs on the gate-level netlist
# (unit delays, ring oscillators left disabled).  The timing experiment itself
# is exercised by tb_ffmeta.v / run_sweep.sh with the behavioural cell models.

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, Timer

WR = 1 << 4
GATE = 1 << 5
EXT = 1 << 6
CLEAR = 1 << 7


class Host:
    """Same pin protocol as host/ffmeta_host.py."""

    def __init__(self, dut):
        self.dut = dut
        self.ctrl = 0  # GATE / EXT / CLEAR bits currently driven

    def _drive(self, addr=0, wr=False):
        self.dut.ui_in.value = self.ctrl | (addr & 0xF) | (WR if wr else 0)

    async def write(self, idx, value):
        await FallingEdge(self.dut.clk)
        self.dut.uio_in.value = value & 0xFF
        self._drive(12 + idx, wr=True)
        await FallingEdge(self.dut.clk)
        self._drive(12 + idx)

    async def read(self, addr):
        self._drive(addr)
        await Timer(2, unit="us")
        return int(self.dut.uo_out.value)

    async def read24(self, base):
        return (await self.read(base)) | (await self.read(base + 1)) << 8 | (await self.read(base + 2)) << 16

    async def config(self, k=0, j=0, dut=0, ev0=0, ev1=0, ring=0, clk_sel=0, roc_len=0,
                     dat_sel=0, rod_len=0, roc_en=0, rod_en=0, a_sel=0):
        await self.write(0, (j << 5) | k)
        await self.write(1, (ring << 7) | (ev1 << 5) | (ev0 << 3) | dut)
        await self.write(2, (rod_len << 6) | (dat_sel << 4) | (roc_len << 2) | clk_sel)
        await self.write(3, (a_sel << 2) | (rod_en << 1) | roc_en)

    async def set_ctrl(self, bit, on):
        await FallingEdge(self.dut.clk)
        self.ctrl = (self.ctrl | bit) if on else (self.ctrl & ~bit)
        self._drive()

    async def measure(self, cycles, toggle_every=0):
        """Clear, open the gate for `cycles` reference cycles, return the
        four counters.  Optionally toggle EXT_ASYNC every `toggle_every`
        cycles (on the falling clock edge, far from the sampling edge)."""
        await self.set_ctrl(CLEAR, True)
        await self.set_ctrl(CLEAR, False)
        await ClockCycles(self.dut.clk, 4)
        await self.set_ctrl(GATE, True)
        for n in range(cycles):
            if toggle_every and n % toggle_every == 0:
                await self.set_ctrl(EXT, not (self.ctrl & EXT))
            else:
                await FallingEdge(self.dut.clk)
        await self.set_ctrl(GATE, False)
        await ClockCycles(self.dut.clk, 6)
        return [await self.read24(base) for base in (0, 3, 6, 9)]


@cocotb.test()
async def test_project(dut):
    dut._log.info("Start")
    clock = Clock(dut.clk, 10, unit="us")
    cocotb.start_soon(clock.start())

    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 2)
    host = Host(dut)

    dut._log.info("Configuration registers")
    for addr in range(12, 16):
        assert await host.read(addr) == 0
    for idx, value in enumerate((0xA5, 0x5A, 0x3C, 0x0C)):
        await host.write(idx, value)
    for idx, value in enumerate((0xA5, 0x5A, 0x3C, 0x0C)):
        assert await host.read(12 + idx) == value
    assert int(dut.uio_oe.value) == 0

    dut._log.info("Counters count reference cycles")
    await host.config(ev0=3, ev1=3, a_sel=0)
    ev0, ev1, a, ref = await host.measure(200)
    dut._log.info(f"ev0={ev0} ev1={ev1} a={a} ref={ref}")
    assert 197 <= ref <= 203
    assert 196 <= ev0 <= 204 and ev1 == ev0
    assert 196 <= a <= 204

    dut._log.info("Event detection with slow, well-timed data")
    # EV0 = output transitions of DUT 3, EV1 = twin-sampler disagreements.
    await host.config(dut=3, ev0=2, ev1=1, a_sel=0)
    tr, cal, a, ref = await host.measure(300, toggle_every=3)
    dut._log.info(f"transitions={tr} cal={cal} cycles={a}")
    assert 90 <= tr <= 110     # one output change per data edge
    assert cal == 0            # no data edge between the two sampling clocks

    # EV0 = late transitions.  With the longest sampling delay (k = 31) the
    # DUT output has long settled when the early sampler looks: no events.
    await host.config(dut=3, k=31, ev0=0, ev1=3, a_sel=0)
    meta, cyc, a, ref = await host.measure(300, toggle_every=3)
    dut._log.info(f"k=31: meta={meta} cycles={cyc}")
    assert meta == 0
    assert 296 <= cyc <= 304

    # With the DUT clock delayed instead (k = 0, j = 7) the early sampler
    # looks before the DUT has switched: every output change is "late".
    await host.config(dut=3, k=0, j=7, ev0=0, ev1=3, a_sel=0)
    meta, cyc, a, ref = await host.measure(300, toggle_every=3)
    dut._log.info(f"k=0 j=7: meta={meta} cycles={cyc}")
    assert 90 <= meta <= 110

    dut._log.info("Clear")
    await host.set_ctrl(CLEAR, True)
    await host.set_ctrl(CLEAR, False)
    assert await host.read24(9) == 0
