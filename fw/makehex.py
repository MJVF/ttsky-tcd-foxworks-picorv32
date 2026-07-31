#!/usr/bin/env python3
"""makehex.py - build the flash artifacts from firmware.bin.

Produces:
  flash.bin  the 64 KB-space flash image: 0x400 zero bytes (the region
             precceded by SRAM / below PROGADDR_RESET) followed by the
             program.
  fw32.hex   the same image as one little-endian 32-bit hex word per
             line, for $readmemh into spi_flash_model.mem in simulation.
"""
import sys

RESET_OFFSET = 0x400
FLASH_SIZE = 64 * 1024

src = sys.argv[1] if len(sys.argv) > 1 else "firmware.bin"
prog = open(src, "rb").read()

img = b"\x00" * RESET_OFFSET + prog
if len(img) > FLASH_SIZE:
    sys.exit(f"ERROR: image is {len(img)} bytes, flash is {FLASH_SIZE}")
if len(img) % 4:
    img += b"\x00" * (4 - len(img) % 4)

open("flash.bin", "wb").write(img)

with open("fw32.hex", "w") as f:
    for i in range(0, len(img), 4):
        f.write(f"{int.from_bytes(img[i:i+4], 'little'):08x}\n")

print(f"flash.bin: {len(img)} bytes ({len(prog)} program bytes @ 0x{RESET_OFFSET:x})")
