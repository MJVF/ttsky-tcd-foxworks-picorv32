![](../../workflows/gds/badge.svg) ![](../../workflows/docs/badge.svg) ![](../../workflows/test/badge.svg) ![](../../workflows/fpga/badge.svg)

# TCD Foxworks PicoRV32
<img src="docs/assets/gds_render_w_badge.png" alt="Second Image" width="1557" height="256">

A small RISC-V microcontroller: a PicoRV32 core (RV32I) that executes
in place from an external SPI flash, with 128 bytes of on-chip SRAM for
stack and data, a UART, and an 8-in/8-out GPIO port. There is no on-chip
program memory — every instruction is fetched over SPI as it runs, so
the design fits in a small area at the cost of speed.

- [Read the documentation for project](docs/info.md)
- [Read the firmware compilation guide](fw/compiling-c-for-rv32i.md)

## Harden locally

NOTE: Tiny Tapeout's [GitHub Actions](https://github.com/mjvf/ttsky-tcd-foxworks-picorv32/actions) will *automatically* harden the design and prepare GDS every time the new changes are committed to the repository.

To harden locally read about the setup:
https://www.tinytapeout.com/guides/local-hardening/

  
### What is Tiny Tapeout?

Tiny Tapeout is an educational project that aims to make it easier and cheaper than ever to get your digital and analog designs manufactured on a real chip.
To learn more and get started, visit https://tinytapeout.com.
- [FAQ](https://tinytapeout.com/faq/)
- [Join the community](https://tinytapeout.com/discord)
