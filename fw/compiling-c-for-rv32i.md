# Compiling C for the TCD Foxworks PicoRV32: what `make -C fw` actually does

This document walks the firmware build end to end, grounded in the real
files in `fw`: which decisions were forced by the silicon, what gets
linked and what deliberately doesn't, and why there are assembly and linker scripts required.
## 1. The pipeline

`make -C fw` runs, in essence, three commands:

    riscv64-unknown-elf-gcc -march=rv32i -mabi=ilp32 -Os ... \
        -nostdlib -Wl,--no-relax -Wl,-T,sections.lds \
        -o firmware.elf start.S MAIN_PROGRAM.c -lgcc
    riscv64-unknown-elf-objcopy -O binary firmware.elf firmware.bin
    python3 makehex.py firmware.bin          # -> flash.bin, fw32.hex

The first command is the compiler pipeline:
preprocess, compile to rv32i assembly, assemble, and link. The prefix
`riscv64-unknown-elf-` is a *target triple*: architecture (`riscv64`,
misleadingly - it's a multilib compiler that also targets rv32),
vendor (`unknown`), and OS (`elf`, meaning **no OS** - the compiler
promises nothing about an operating system existing). That last field
is the single biggest difference from `gcc` on your laptop, and most of
this document is its consequences.

## 2. Two flags define what is possible: `-march=rv32i -mabi=ilp32`

These are separate axes and both must match the hardware.

**`-march=rv32i`** is a contract about which instructions the compiler
may emit. Our picorv32 is configured with `ENABLE_MUL=0`, `ENABLE_DIV=0`,
`COMPRESSED_ISA=0` - so the march must exclude the M and C extensions.

- Write `a * b` in C and the compiler cannot emit `mul` (doesn't exist
  here). Iinstead it emits a **function call** to `__mulsi3` in libgcc, which
  multiplies with shifts and adds. Same for `/` and `%` via
  `__udivsi3`/`__umodsi3`. This is why selftest T07 is simultaneously a
  core test and a toolchain test.
- If you compiled with `-march=rv32im` by mistake, the binary would
  contain `mul` instructions and the core would take an
  illegal-instruction trap (`CATCH_ILLINSN=1`) the first time one
  executed - the chip would just stop.
- No C extension means every instruction is exactly 4 bytes. Simpler
  fetching in spimemio, slightly larger binaries..

**`-mabi=ilp32`** defines code conventions:
`int`, `long`, and pointers are all 32 bits, arguments pass in
registers `a0`-`a7`, results return in `a0`/`a1`, and floating point
(even without floating point silicon) passes in integer registers, and then managed within software.

## 3. Freestanding: what the compiler stops assuming

`-ffreestanding -fno-builtin -nostdlib` switch the compiler from the
hosted world to ours:

- **Hosted C** assumes an environment: an OS loader, C libraries
  exists, `main` called by startup code, `printf`, `exit`
  returns.
- **Freestanding C** is the opposite. `-fno-builtin` stops the
  compiler from pattern-matching your code into library calls; even so,
  GCC will still emit `memcpy`/`memset` for large struct
  copies or array initializations - one reason the written tests deliberately avoids those constructs.
- `main` is just a function here. Nothing calls it (until start.S
  does), and nothing catches its return (start.S loops indefinitely if it
  does). There is no `exit`.

## 4. What is in the Assembly (`start.S`)

C has preconditions that C cannot establish. The very first thing a
compiled C function does is use the stack pointer - so *something* must
set `sp` before the first C instruction runs. The C standard guarantees
initialized globals hold their values and uninitialized globals are
zero - on a hosted system the OS loader makes that true; herewe have to.

1. `li sp, 0x80` - stack at the top of the 128 B SRAM. Without initialisation every C program is undefined behaviour.
2. Copy `.data` from its flash address to its RAM address.
3. Zero `.bss` reserves space for the count of test failures within the test programs.
4. `call main`

It also deliberartely *omits* setting the global pointer
`gp`. RISC-V toolchains use gp-relative addressing as a linker
optimization ("relaxation") to reach globals in one instruction; that
only works if startup sets `gp = __global_pointer$`. We skip the setup
for simplicity - our globals round to zero - and therefore must pass
`-Wl,--no-relax`, or the linker would emit gp-relative accesses that
dereference random bits.

## 5. The linker script (`section.lds`)

A hosted link uses a default script that assumes virtual memory and a
loader. `sections.lds` instead states the physical design mapping of this chip:

    FLASH (rx)  : ORIGIN = 0x00000400, LENGTH = 0xFC00
    RAM  (xrw)  : ORIGIN = 0x00000000, LENGTH = 0x80

- `.text` and `.rodata` are placed in FLASH and **stay there**: the
  core executes in place over SPI (XIP). Code and string literals never
  occupy SRAM - which is why these programs can fit in only
  128 bytes, only mutable state lives in RAM.
- FLASH starts at 0x400, not 0: addresses 0x00-0x7F are decoded as
  SRAM by the SoC, so flash below 0x80 is unreachable for execution -
  the reset vector (`PROGADDR_RESET`) points at 0x400 and the image is
  padded to match.
- `.data` gets **two addresses**: `> RAM AT > FLASH` gives it a load
  address (LMA) in flash - where its initial values are stored - and a
  virtual address (VMA) in RAM - where the program reads and writes it.
- The `ASSERT(_ebss <= 0x40, ...)` is a build-time guardrail: it
  refuses to produce a binary whose globals leave less than 64 B of
  stack.


## 6. Hosted vs Freestanding

| Concern                | Hosted `gcc` on Linux           | Freestanding build                    |
|------------------------|---------------------------------|----------------------------------------|
| Sets up sp/.data/.bss | OS loader + crt0             | `start.S`           |
| `main`                 | called by runtime, may return   | called by start.S, must never return   |
| `printf`               | libc → kernel `write()`         | 9-line `print()` → MMIO register       |
| `a * b`                | one `mul` instruction           | call into libgcc `__mulsi3`            |
| Stack                  | MBs, guard pages fault on overflow | ~120 B, overflow silently corrupts  |
| Addresses              | virtual, relocated, ASLR        | physical, absolute, final at link time |
| Binary                 | ELF executed by loader          | raw bytes at flash offsets             |

## 7. Run Compiler breakdown

`make -C fw disasm` (annotated rv32i, watch for `__mulsi3` calls and
the absence of `mul`), `make -C fw size` (text vs data+bss - the
flash/SRAM split in three numbers), `fw/firmware.map` (every symbol's
final address), and the selftest's own MEMMAP + stack-peak telemetry,
which report the same facts from inside the running chip.
