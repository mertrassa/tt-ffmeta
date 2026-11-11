# SPDX-License-Identifier: Apache-2.0
"""Host firmware for tt_um_mertrassa_ffmeta (MicroPython, Tiny Tapeout demo board RP2040).

Copy this file to the board, then from the REPL:

    import ffmeta_host as fm
    chip = fm.Chip()                 # selects the project, starts a 10 MHz clock
    chip.selftest()                  # registers + counters
    fm.run(chip, duts=range(8), max_gate_s=10, vdd=1.80, temp_c=25)

or, from a PC, capture the records directly:

    mpremote run host/ffmeta_host.py > chip1_1v80_25c.txt
    python analysis/ffmeta_fit.py chip1_1v80_25c.txt --plot chip1.png

STATUS: written against the Tiny Tapeout MicroPython SDK 2.x pin names
(tt.ui_in / tt.uo_out / tt.uio_in / tt.uio_oe_pico).  It has NOT been run on
hardware.  The pin protocol in class Chip is the one verified in simulation
(test/tb_ffmeta.v); only class Board talks to the SDK and may need adapting.
"""

import time

PROJECT = "tt_um_mertrassa_ffmeta"
F_REF_HZ = 10_000_000

WR, GATE, EXT, CLEAR = 1 << 4, 1 << 5, 1 << 6, 1 << 7
EV_META, EV_CAL, EV_TR, EV_ONE = 0, 1, 2, 3
A_CORE, A_DATA, A_EARLY, A_REF = 0, 1, 2, 3
MASK = (1 << 24) - 1


class Board:
    """Everything that depends on the Tiny Tapeout SDK."""

    def __init__(self, project=PROJECT, f_ref_hz=F_REF_HZ):
        from ttboard.demoboard import DemoBoard
        from ttboard.mode import RPMode

        self.tt = DemoBoard.get()
        self.tt.mode = RPMode.ASIC_RP_CONTROL
        getattr(self.tt.shuttle, project).enable()
        self.tt.uio_oe_pico.value = 0xFF      # RP2040 drives uio[7:0] (write data)
        self.tt.ui_in.value = 0
        self.tt.clock_project_PWM(f_ref_hz)
        self.tt.reset_project(True)
        time.sleep_ms(2)
        self.tt.reset_project(False)

    def ui(self, value):
        self.tt.ui_in.value = value

    def uio(self, value):
        self.tt.uio_in.value = value

    def uo(self):
        return int(self.tt.uo_out.value)


class Chip:
    def __init__(self, board=None, f_ref_hz=F_REF_HZ):
        self.b = board or Board(f_ref_hz=f_ref_hz)
        self.f_ref = f_ref_hz
        self.cfg = dict(k=0, j=0, dut=0, ev0=EV_META, ev1=EV_CAL, ring=0, clk_sel=0,
                        roc_len=0, dat_sel=0, rod_len=0, roc_en=0, rod_en=0, a_sel=A_CORE)

    # ------------------------------------------------------- pin protocol
    def write(self, idx, value):
        self.b.uio(value & 0xFF)
        self.b.ui(12 + idx)
        self.b.ui(12 + idx | WR)      # held for many reference clock edges
        time.sleep_us(50)
        self.b.ui(12 + idx)

    def read(self, addr):
        self.b.ui(addr)
        return self.b.uo()

    def read24(self, base):
        return self.read(base) | self.read(base + 1) << 8 | self.read(base + 2) << 16

    def apply(self, **changes):
        """Write the configuration.  The oscillators are stopped and the
        calibration ring is opened while taps and lengths change, so that
        every ring restarts from rest (a ring switched while an edge is
        circulating can run in a harmonic mode)."""
        c = self.cfg
        c.update(changes)
        cfg1 = c["ev1"] << 5 | c["ev0"] << 3 | c["dut"]
        self.write(3, c["a_sel"] << 2)
        self.write(1, cfg1)
        self.write(2, c["rod_len"] << 6 | c["dat_sel"] << 4 | c["roc_len"] << 2 | c["clk_sel"])
        self.write(0, c["j"] << 5 | c["k"])
        self.write(1, c["ring"] << 7 | cfg1)
        self.write(3, c["a_sel"] << 2 | c["rod_en"] << 1 | c["roc_en"])
        time.sleep_ms(1)

    def gate(self, seconds):
        """Clear, count for about `seconds`, return raw (EV0, EV1, A, REF)."""
        self.b.ui(CLEAR)
        self.b.ui(0)
        time.sleep_us(100)
        self.b.ui(GATE)
        time.sleep_us(int(seconds * 1e6))
        self.b.ui(0)
        time.sleep_us(100)
        return self.read24(0), self.read24(3), self.read24(6), self.read24(9)

    # ------------------------------------------------------- measurements
    @staticmethod
    def _unwrap(raw, expected):
        """The counters are 24 bits wide; restore the bits above from an
        estimate that only has to be good to +-2^23 counts."""
        if expected <= MASK // 2:
            return raw
        return raw + (round((expected - raw) / (MASK + 1)) << 24)

    def measure(self, min_events=10000, max_gate_s=1.0):
        """Adaptive gate: 10 ms, then x10 until EV0 has collected
        `min_events` or the gate reaches `max_gate_s`.  Each gate's rates
        predict the counts of the next one, which resolves counter wrap."""
        g, rate = 0.01, None           # rate = (ev0, ev1, a) per reference cycle
        while True:
            raw = self.gate(g)
            n_ref = self._unwrap(raw[3], g * self.f_ref)
            if rate is None:
                n = list(raw[:3])      # 10 ms: nothing can wrap below 1.6 GHz
            else:
                n = [self._unwrap(raw[i], rate[i] * n_ref) for i in range(3)]
            if n[0] >= min_events or g >= max_gate_s:
                return n[0], n[1], n[2], n_ref
            rate = [x / n_ref for x in n]
            g = min(g * 10, max_gate_s)

    def frequency(self, a_sel):
        self.apply(a_sel=a_sel)
        return self.measure(min_events=1 << 30, max_gate_s=0.1)

    def stress_hold(self, level=0):
        """Static stress state for experiment E7: clock root off, both
        oscillators off, data taken from ui_in[6] and held at `level`.
        Nothing toggles inside the experiment core while this is held; the
        reference clock keeps running.  Any later register access drives
        ui_in again, so call this last before the stress interval and run
        apply() / run() afterwards to measure."""
        self.apply(ring=0, clk_sel=3, dat_sel=0, roc_en=0, rod_en=0)
        self.b.ui(EXT if level else 0)

    def selftest(self):
        for idx, value in enumerate((0xA5, 0x5A, 0x3C, 0x0C)):
            self.write(idx, value)
        got = [self.read(12 + i) for i in range(4)]
        assert got == [0xA5, 0x5A, 0x3C, 0x0C], "register readback failed: %r" % got
        self.apply(k=0, j=0, dut=0, ev0=EV_ONE, ev1=EV_ONE, ring=0, clk_sel=0, roc_len=0,
                   dat_sel=0, rod_len=0, roc_en=0, rod_en=0, a_sel=A_CORE)
        ev0, ev1, a, ref = self.gate(0.05)
        # with clk_sel = 0 the core runs at exactly half the reference frequency
        assert abs(2 * ev0 - ref) <= 6 and abs(2 * a - ref) <= 6 and ev1 == ev0, (ev0, ev1, a, ref)
        assert abs(ref - 0.05 * self.f_ref) < 0.02 * self.f_ref, ref
        print("# selftest ok: ev0=%d a=%d ref=%d" % (ev0, a, ref))


def run(chip, duts=range(8), max_gate_s=10.0, min_events=10000, roc_len=0, rod_len=0,
        dat_sel=1, vdd=None, temp_c=None, chip_id=None):
    """Full characterisation run; prints records for analysis/ffmeta_fit.py."""
    print("# ffmeta host")
    print("# f_ref_hz=%d" % chip.f_ref)
    for key, val in (("chip", chip_id), ("vdd", vdd), ("temp_c", temp_c)):
        if val is not None:
            print("# %s=%s" % (key, val))
    chip.selftest()

    # deterministic calibration: coarse line as a ring, clock root off
    # (the chip counts the ring through a divide-by-two prescaler)
    for k in range(32):
        chip.apply(k=k, j=0, ring=1, clk_sel=3, roc_en=0, rod_en=0, a_sel=A_EARLY)
        _, _, a, ref = chip.measure(min_events=1 << 30, max_gate_s=0.1)
        print("F,ring,%d,0,%d,%d" % (k, a, ref))

    # RO_C as DUT clock (default: 111 stages, about 8 ns, which leaves half a
    # period for the whole delay range); RO_D / 4 as data so that the data
    # half period (about 10 ns) is longer than the clock period and every
    # data edge is captured exactly once
    chip.apply(k=0, j=0, ring=0, clk_sel=1, roc_len=roc_len, dat_sel=dat_sel, rod_len=rod_len,
               roc_en=1, rod_en=1, ev0=EV_META, ev1=EV_CAL)
    for dut in duts:
        _, _, a, ref = chip.frequency(A_DATA)
        print("F,data,%d,%d,%d,%d" % (dat_sel, rod_len, a, ref))
        _, _, a, ref = chip.frequency(A_CORE)
        print("F,core,%d,0,%d,%d" % (roc_len, a, ref))
        for j in range(8):
            empty = 0
            for k in range(32):
                chip.apply(dut=dut, k=k, j=j, a_sel=A_CORE)
                n_meta, n_cal, n_cyc, n_ref = chip.measure(min_events, max_gate_s)
                print("M,%d,%d,%d,%d,%d,%d,%d" % (dut, k, j, n_meta, n_cal, n_cyc, n_ref))
                # two consecutive empty long gates: the tail has run out
                empty = empty + 1 if n_meta == 0 else 0
                if empty >= 2:
                    break
    chip.apply(roc_en=0, rod_en=0)
    print("# done")


if __name__ == "__main__":
    run(Chip())
