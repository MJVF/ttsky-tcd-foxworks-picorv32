# SPDX-License-Identifier: Apache-2.0
#
# cocotb test for tt_um_foxworks_picorv32 - a PicoRV32 SoC that boots
# from an emulated SPI flash (tt_virtual_demoboard, wired in tb.v).
#
# Everything is sampled on the DUT clock - no Edge/Timer waits that can
# starve the scheduler or hit sub-timestep rounding. A background task
# samples uio_out[6] every clock and decodes 8N1 by counting clocks per
# bit; the main task watches uo_out for the self-test verdict. Both read
# pins bit-by-bit so partial-X buses never break int() conversion, so
# the identical test runs on RTL and the gate netlist.

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge

CLK_HZ = 25_000_000          # DUT clock (matches firmware -DCLK_HZ)
CLK_NS = 1e9 / CLK_HZ
BAUD = 115200
CLKS_PER_BIT = round(CLK_HZ / BAUD)   # 217 at 25 MHz / 115200

VERDICT_PASS = 0xC3
VERDICT_FAIL = 0x3C


def bit(sig, i):
    """One bit of a possibly-partially-X bus as 0/1; x/z read 0."""
    try:
        return 1 if str(sig.value)[::-1][i] == "1" else 0
    except (IndexError, ValueError):
        return 0


def byte(sig, width=8):
    v = 0
    for i in range(width):
        v |= bit(sig, i) << i
    return v


async def uart_sampler(dut, out_chars):
    """Clock-sampled 8N1 receiver on uio_out[6] (idle high)."""
    while True:
        # wait for the line to be idle-high then go low (start bit)
        while bit(dut.uio_out, 6) == 0:
            await RisingEdge(dut.clk)
        while bit(dut.uio_out, 6) == 1:
            await RisingEdge(dut.clk)
        # we're at the start-bit edge; step to the middle of bit 0
        for _ in range(CLKS_PER_BIT + CLKS_PER_BIT // 2):
            await RisingEdge(dut.clk)
        val = 0
        for i in range(8):
            val |= bit(dut.uio_out, 6) << i
            for _ in range(CLKS_PER_BIT):
                await RisingEdge(dut.clk)
        # (we are now inside the stop bit; loop re-syncs on next start)
        if 32 <= val < 127 or val in (10, 13):
            out_chars.append(chr(val))


@cocotb.test()
async def test_selftest(dut):
    dut._log.info("start: PicoRV32 SoC self-test over emulated flash")
    cocotb.start_soon(Clock(dut.clk, round(CLK_NS), unit="ns").start())

    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 20)
    dut.rst_n.value = 1
    dut._log.info("reset released; booting from flash")

    # Diagnostic snapshot a few clocks after reset release.
    await ClockCycles(dut.clk, 5)
    oe   = byte(dut.uio_oe)
    uout = byte(dut.uio_out)
    uin  = byte(dut.uio_in)
    dut._log.info("post-reset: uio_oe=0x%02x uio_out=0x%02x uio_in=0x%02x",
                  oe, uout, uin)
    dut._log.info("  expect uio_oe bit0(SCK)=1 bit1(CSB)=1 bit2(MOSI)=1 "
                  "bit6(TX)=1  -> oe & 0x47 == 0x47 (original pinout)")
    if oe == 0x00:
        dut._log.info("  !! uio_oe all-zero: DUT still sees reset (rst_n "
                      "not reaching it) or ena is low. Check tb wiring.")
    elif (oe & 0x07) != 0x07:
        dut._log.info("  !! flash-control oe bits not set: wrapper pin map "
                      "or CATCH trap on the very first fetch.")

    rx = []
    cocotb.start_soon(uart_sampler(dut, rx))

    verdict = 0
    sck_edges = 0
    prev_sck = bit(dut.uio_out, 0)      # FLASH_SCK = uio[0] (original pinout)
    last_uo = -1
    # XIP boot is slow: every instruction is fetched bit-by-bit over
    # ~12.5 MHz SPI, so the full 11-test suite is ~15M DUT clocks.
    # Poll in small chunks so we exit promptly once the verdict lands.
    CHUNK = 200
    ROUNDS = 250000                      # 50M clk budget (GL is ~3x slower than RTL)
    for r in range(ROUNDS):
        await ClockCycles(dut.clk, CHUNK)

        cur_sck = bit(dut.uio_out, 0)
        if cur_sck != prev_sck:
            sck_edges += 1
            prev_sck = cur_sck

        v = byte(dut.uo_out)
        if v != last_uo:
            dut._log.info("uo_out -> 0x%02x (SCK edges: %d, chars: %d)",
                          v, sck_edges, len(rx))
            last_uo = v
        if v in (VERDICT_PASS, VERDICT_FAIL):
            verdict = v
            break

        if r == 100 and sck_edges == 0:
            raise AssertionError(
                "no SCK activity after 8000 clocks - the core never "
                "fetched. Check firmware at fw32.hex offset 0x400, the "
                "CSB/MOSI/MISO/SCK mapping in spi_flash_model vs the "
                "wrapper (uio[0..3]), and that rst_n reached the DUT "
                "(uio_oe should be non-zero out of reset).")
    else:
        raise AssertionError(
            f"no verdict after {ROUNDS*CHUNK} clocks; last uo_out=0x{last_uo:02x}, "
            f"SCK edges={sck_edges}, chars={len(rx)}. SCK climbing = alive but "
            f"slow: XIP boot is ~15M clk, so raise ROUNDS further. (SCK flat "
            f"would mean stalled mid-boot.)")

    # let the last UART bytes land
    await ClockCycles(dut.clk, CLKS_PER_BIT * 12)

    report = "".join(rx)
    for ln in report.splitlines():
        dut._log.info("UART: %s", ln)
    dut._log.info("uo_out verdict = 0x%02x", verdict)

    if 0x10 <= verdict <= 0x1C:
        raise AssertionError(
            f"core hung during T{verdict - 0x10:02d} (progress code frozen)")
    assert verdict == VERDICT_PASS, (
        f"verdict 0x{verdict:02x}, expected 0xC3. UART:\n{report}")
    assert "RESULT 11/11 PASS" in report, (
        f"UART did not report a clean pass:\n{report}")
    dut._log.info("PASS: pin verdict 0xC3 and UART RESULT agree")