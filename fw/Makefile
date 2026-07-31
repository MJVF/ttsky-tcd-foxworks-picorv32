# TCD Foxworks PicoRV32 firmware
#
# Toolchain resolution, in priority order:
#   1. TOOLCHAIN_PREFIX=... on the command line
#   2. /opt/riscv32i/bin/riscv32-unknown-elf-   (the pure-RV32I toolchain
#      from the picorv32 README / `make build-riscv32i-tools`: compiler
#      AND libraries built for rv32i
#   3. riscv32-unknown-elf- on PATH
#   4. riscv64-unknown-elf- on PATH (needs the rv32i/ilp32 multilib -
#      Ubuntu's gcc-riscv64-unknown-elf and xPack builds have it)
ifeq ($(origin TOOLCHAIN_PREFIX), undefined)
  ifneq ($(wildcard /opt/riscv32i/bin/riscv32-unknown-elf-gcc),)
    TOOLCHAIN_PREFIX := /opt/riscv32i/bin/riscv32-unknown-elf-
  else ifneq ($(shell command -v riscv32-unknown-elf-gcc 2>/dev/null),)
    TOOLCHAIN_PREFIX := riscv32-unknown-elf-
  else ifneq ($(shell command -v riscv64-unknown-elf-gcc 2>/dev/null),)
    TOOLCHAIN_PREFIX := riscv64-unknown-elf-
  else ifneq ($(filter-out clean,$(or $(MAKECMDGOALS),all)),)
    $(error No RISC-V gcc found. Quickest: `sudo apt install \
gcc-riscv64-unknown-elf` (Ubuntu/WSL; has the rv32i multilib). Proper: \
build the pure-RV32I toolchain into /opt/riscv32i per the picorv32 \
README (auto-detected here). Or pass \
TOOLCHAIN_PREFIX=/path/to/bin/riscv32-unknown-elf-)
  endif
endif

CC      = $(TOOLCHAIN_PREFIX)gcc
OBJCOPY = $(TOOLCHAIN_PREFIX)objcopy
OBJDUMP = $(TOOLCHAIN_PREFIX)objdump

MARCH ?= rv32i
MABI  ?= ilp32

# rv32i, no compressed (COMPRESSED_ISA=0), no mul/div (ENABLE_MUL/DIV=0).
# --no-relax because start.S sets no gp (see start.S).
CFLAGS  = $(FWDEFS) -march=$(MARCH) -mabi=$(MABI) -Os -Wall -Wextra \
          -ffreestanding -fno-builtin -fno-pic -fno-strict-aliasing

# Which program to build:  make PROG=bounce  (default) |  make PROG=selftest
PROG ?= bounce
SRCS = start.S $(PROG).c

LDFLAGS  = -nostdlib -Wl,--no-relax -Wl,-T,sections.lds -Wl,-Map,firmware.map
LIBS     = -lgcc

all: flash.bin

firmware.elf: $(SRCS) sections.lds
	@echo "building PROG=$(PROG)"
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $(SRCS) $(LIBS)

firmware.bin: firmware.elf
	$(OBJCOPY) -O binary $< $@

# flash.bin (padded 64K-space image) + fw32.hex ($readmemh)
flash.bin: firmware.bin
	python3 makehex.py $<

disasm: firmware.elf
	$(OBJDUMP) -d -M numeric,no-aliases $<

size: firmware.elf
	$(TOOLCHAIN_PREFIX)size $<

toolchain:
	@echo "TOOLCHAIN_PREFIX = $(TOOLCHAIN_PREFIX)"
	@$(CC) --version | head -1

clean:
	rm -f firmware.elf firmware.bin firmware.map flash.bin fw32.hex

.PHONY: all disasm size toolchain clean
