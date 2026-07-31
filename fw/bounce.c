/*
 * bounce.c - a square bouncing back and forth across the screen.
 *
 * The screen is the 8-bit GPIO output port (PMOD B on the ZU3 harness,
 * uo_out[7:0] on silicon). The square is one pixel. The pixel is an
 * LED. Art is about constraints.
 *
 * Why this is not driving an actual VGA cable: executing from serial
 * SPI flash, this core sustains roughly 0.3-1 MIPS. A 640x480@60 VGA
 * signal needs a new pixel every 40 ns and an hsync edge every 32 us -
 * three orders of magnitude out of reach of software timing. The
 * correct way to get real VGA out of this chip is a small hardware
 * timing generator (two counters + comparators, well under one tile)
 * with the square's X/Y in iomem registers that this loop would update
 * once per frame - that peripheral is the documented upgrade path, not
 * part of this build. The uo_out pinout is reserved to match the Tiny
 * VGA Pmod so it can be added without re-pinning.
 *
 * Build notes: rv32i only - no hardware multiply/divide (ENABLE_MUL/
 * ENABLE_DIV are 0), so keep arithmetic to adds and shifts, or libgcc
 * softmul gets linked in and eats flash.
 *
 * UART: 115200 8N1 on uio[6]/uio[7]. TX stores stall in hardware until
 * the byte is sent (simpleuart reg_dat_wait) - no polling needed.
 */

#include <stdint.h>

/* Chip clock and baud are BUILD-TIME: the UART divisor is
 * computed from them, so a mismatch with the real clock produces
 * random bits on the wire. Override per build, e.g.
 *   make -C fw FWDEFS="-DCLK_HZ=25000000 -DBAUD=115200"
 * (25 MHz / 115200 -> divisor 217 -> 115207 baud, +0.006%) */
#ifndef CLK_HZ
#define CLK_HZ 25000000
#endif
#ifndef BAUD
#define BAUD 115200
#endif

#define reg_spictrl     (*(volatile uint32_t *)0x02000000) /* DO NOT WRITE:
	enabling QSPI/DDR bits breaks the RP2040/ZU3 flash-emulation contract */
#define reg_uart_clkdiv (*(volatile uint32_t *)0x02000004)
#define reg_uart_data   (*(volatile uint32_t *)0x02000008)
#define reg_gpio        (*(volatile uint32_t *)0x03000000)
/* reg_gpio read: [7:0] gpio_out readback, [15:8] synchronized ui_in,
 * [23:16] synchronized uio_in (SERIAL_RX raw level, flash-pin loopback) */

static void putch(char c)
{
	if (c == '\n')
		reg_uart_data = '\r';
	reg_uart_data = (uint8_t)c;
}

static void print(const char *s)
{
	while (*s)
		putch(*s++);
}

/* Software delay. Executing from flash: one iteration costs a back-jump
 * (new SPI transaction incl. the CS-recovery pause, ~130 clocks) plus a
 * few sequentially streamed words - call it 5-10 us per iteration at
 * 50 MHz. The numbers below give a visible bounce; calibrate to taste. */
static void delay_loops(uint32_t n)
{
	for (volatile uint32_t i = 0; i < n; i++)
		;
}

void main(void)
{
	reg_uart_clkdiv = (CLK_HZ + BAUD / 2) / BAUD;  /* from build defines */

	print("\n=== Foxworks PicoRV32 ===\nbounce: 1x1 square, 8x1 screen\n");

	uint32_t pos = 0;
	int dir = 1;

	for (;;) {
		reg_gpio = (uint32_t)1 << pos;   /* draw the frame */

		if (pos == 7) {
			dir = -1;
			putch('<');              /* telemetry per wall hit */
		} else if (pos == 0 && dir < 0) {
			dir = 1;
			putch('>');
		}
		pos += (uint32_t)dir;

		/* frame delay; ui_in[3:0] (switches on PMOD A) slow it down:
		 * shift-only scaling - no multiply on rv32i, see header.
		 * SIM_FAST (make FWDEFS=-DSIM_FAST) shrinks the delay so a
		 * few bounces fit in a few ms of simulated time. */
		{
			uint32_t sw = (reg_gpio >> 8) & 0x0f;
#ifdef SIM_FAST
			delay_loops(2u + sw);
#else
			delay_loops(8000u + (sw << 12));
#endif
		}
	}
}