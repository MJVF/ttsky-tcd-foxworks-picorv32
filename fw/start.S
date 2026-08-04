/*
 * start.S - TT-Foxworks-PicoRV32 reset entry (rv32i, no compressed, no IRQ)
 *
 * Placed at flash offset 0x400 = PROGADDR_RESET. Sets up the stack at
 * the top of the 128 B SRAM, copies .data from flash, zeroes .bss and
 * calls main(). No gp is set up, so the firmware Makefile links with
 * --no-relax.
 */

.section .init
.globl _start
_start:
	li   sp, 0x80           /* stack top = end of SRAM (128 B) */

	/* Zero ALL of SRAM (0x00..0x7F) */
	li   a1, 0x00
	li   a2, 0x80
0:	bgeu a1, a2, 1f
	sw   zero, 0(a1)
	addi a1, a1, 4
	j    0b

1:	/* copy .data (LMA in flash -> VMA in RAM) */
	la   a0, _sidata
	la   a1, _sdata
	la   a2, _edata
6:	bgeu a1, a2, 2f
	lw   a3, 0(a0)
	sw   a3, 0(a1)
	addi a0, a0, 4
	addi a1, a1, 4
	j    6b

2:	/* zero .bss */
	la   a1, _sbss
	la   a2, _ebss
3:	bgeu a1, a2, 4f
	sw   zero, 0(a1)
	addi a1, a1, 4
	j    3b

4:	call main

	/* main() must not return; spin if it does */
5:	j    5b
