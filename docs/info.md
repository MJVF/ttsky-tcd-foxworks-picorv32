<!---

This file is used to generate your project datasheet. Please fill in the information below and delete any unused
sections.

You can also include images in this folder and reference them in the markdown. Each image must be less than
512 kb in size, and the combined size of all images must be less than 1 MB.
-->

## How it works

A small RISC-V microcontroller: a PicoRV32 core (RV32I) that executes
in place from an external SPI flash, with 128 bytes of on-chip SRAM for
stack and data, a UART, and an 8-in/8-out GPIO port. There is no on-chip
program memory — every instruction is fetched over SPI as it runs, so
the design fits in a small area at the cost of speed.

Memory map: SRAM at 0x0000_0000; flash execute-in-place window from
0x80 (reset vector 0x400); UART at 0x0200_0004/8; GPIO at 0x0300_0000.

## How to test

Attach an SPI flash (or an RP2040 emulating one) holding a RISC-V
program, hold rst_n low while it powers up, raise ena, then release
rst_n. The chip boots and runs. A UART console at 115200 8N1 reports
what it's doing; the sample firmware prints a banner and bounces a lit
bit across the 8 output pins, with speed set by the input pins.

## External hardware

An SPI flash on uio[3:0], or an RP2040 running the Tiny Tapeout
spi-ram-emu firmware to emulate one. A USB-serial adapter on the UART
pins (uio[6]/uio[7]) for the console. Optionally switches on the input
PMOD and LEDs on the output PMOD.