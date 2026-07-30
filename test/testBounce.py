# SPDX-License-Identifier: Apache-2.0
#
# cocotb test for tt_um_foxworks_picorv32 running bounce.c.
#
# bounce writes a single walking bit to uo_out: 0x01,0x02,0x04,...,0x80,
# then back. This is a whole-chip liveness test - it proves the core
# boots from emulated flash, executes, and drives GPIO - without the
# self-test's sub-word SRAM accesses that trip gate-level X-propagation.
# Everything is sampled on the DUT clock and read bit-by-bit, so the
# identical test runs on RTL and the gate netlist.
#
# Build the firmware first (SIM_FAST shrinks the frame delay so several
# bounce steps fit in a few ms of sim time):
#   make -C ../fw clean && make -C ../fw PROG=bounce FWDEFS="-DSIM_FAST"
#   cp ../fw/fw32.hex .

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles

CLK_NS = 40           # 25 MHz DUT clock

# A valid bounce frame is exactly one bit set, in 0x01..0x80.
WALKING = [1 << i for i in range(8)]


def bit(sig, i):
    """One bit of a possibly-partially-X bus as 0/1; x/z read 0."""
    try:
        return 1 if str(sig.value)[::-1][i] == "1" else 0
    except (IndexError, ValueError):
        return 0


def byte(sig):
    v = 0
    for i in range(8):
        v |= bit(sig, i) << i
    return v


@cocotb.test()
async def test_bounce(dut):
    dut._log.info("start: bounce.c walking-bit liveness test")
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())

    dut.ena.value = 1
    dut.ui_in.value = 0          # switches off = fastest bounce
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 20)
    dut.rst_n.value = 1
    dut._log.info("reset released; booting from flash")

    # Collect distinct non-zero uo_out frames the core drives. We want to
    # see a run of valid walking-bit values that actually moves (i.e. the
    # position changes), which only a live, executing core produces.
    seen = []
    last = -1
    sck_edges = 0
    prev_sck = bit(dut.uio_out, 0)     # FLASH_SCK = uio[0], original pinout

    # ~8M clocks is plenty for several SIM_FAST bounce steps over XIP.
    NEED = 6                            # distinct walking frames to accept
    for _ in range(40000):
        await ClockCycles(dut.clk, 200)

        cur_sck = bit(dut.uio_out, 0)
        if cur_sck != prev_sck:
            sck_edges += 1
            prev_sck = cur_sck

        v = byte(dut.uo_out)
        if v != last:
            last = v
            if v in WALKING:
                seen.append(v)
                dut._log.info("frame 0x%02x (SCK edges: %d, distinct: %d)",
                              v, sck_edges, len(seen))
                if len(seen) >= NEED:
                    break

        if sck_edges == 0 and _ == 60:
            raise AssertionError(
                "no SCK activity - core never fetched. Check fw32.hex is "
                "built from bounce.c and present at flash offset 0x400, and "
                "the flash pin mapping (SCK=uio[0]).")

    # Verdict: we must have seen enough valid walking frames, AND they must
    # not be all the same position (the bit has to actually move).
    assert len(seen) >= NEED, (
        f"only saw {len(seen)} walking frames after budget; SCK edges="
        f"{sck_edges}. Core alive but slow -> raise loop bound; SCK flat "
        f"-> stalled boot.")
    assert len(set(seen)) >= 3, (
        f"bit never moved across {seen} - core wrote GPIO but isn't running "
        f"the bounce loop (suspect a stuck delay or a hang after first frame).")

    positions = [v.bit_length() - 1 for v in seen]
    dut._log.info("PASS: walking bit moved through positions %s", positions)