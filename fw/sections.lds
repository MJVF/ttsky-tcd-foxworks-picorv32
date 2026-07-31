/*
 * sections.lds - TT-PicoSoC firmware layout
 *
 * Memory map (see tt_um_foxworks_picorv32.v):
 *   0x0000_0000 .. 0x0000_00FF : 128 B SRAM (data/bss + stack, sp = 0x80)
 *   0x0000_0400 .. 0x0000_FFFF : XIP window into the 64 KB SPI flash
 *                                (flash offsets 0x000-0x3FF sit below the
 *                                 XIP window / behind SRAM, so code starts
 *                                 at flash offset 0x400 = PROGADDR_RESET)
 */

MEMORY
{
	FLASH (rx)  : ORIGIN = 0x00000400, LENGTH = 0x0000FC00
	RAM   (xrw) : ORIGIN = 0x00000000, LENGTH = 0x00000080
}

SECTIONS
{
	.text :
	{
		*(.init)
		*(.text*)
		*(.rodata*)
		. = ALIGN(4);
	} > FLASH

	.data :
	{
		_sdata = .;
		*(.data*)
		*(.sdata*)
		. = ALIGN(4);
		_edata = .;
	} > RAM AT > FLASH
	_sidata = LOADADDR(.data);

	.bss (NOLOAD) :
	{
		_sbss = .;
		*(.bss*)
		*(.sbss*)
		*(COMMON)
		. = ALIGN(4);
		_ebss = .;
	} > RAM

	/* Leave at least 128 B for the stack (sp starts at 0x100). */
	ASSERT(_ebss <= 0x40, "ERROR: .data+.bss leave less than 128 B of stack")
}
