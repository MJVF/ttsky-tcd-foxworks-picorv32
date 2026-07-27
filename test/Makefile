# Makefile - cocotb RTL + gate-level test for tt_um_foxworks_picorv32
# See https://docs.cocotb.org/en/stable/quickstart.html
#
# RTL:   make -B
# Gates: harden, copy runs/wokwi/results/final/verilog/gl/<module>.v to
#        gate_level_netlist.v, then:  make -B GATES=yes
#
# Firmware must exist first (the flash harness $readmemh's fw32.hex):
#   make -C ../fw PROG=selftest
#   cp ../fw/fw32.hex .        # or set FIRMWARE=/path below

SIM ?= icarus
FST ?= -fst
TOPLEVEL_LANG ?= verilog

SRC_DIR = $(PWD)/../src

# The DUT sources (RTL build) - your real design files.
PROJECT_SOURCES = picosoc.v \
                  spimemio.v \
                  simpleuart.v \
                  picorv32.v \
                  tt_um_foxworks_picorv32.v

# Behavioral flash + UART harness. NOT part of the DUT - included in
# BOTH RTL and gate-level builds so a GL run can still boot from flash.
HARNESS_SOURCES = $(PWD)/tt_virtual_demoboard.v \
                  $(PWD)/spi_flash_model.v

# Firmware image the harness preloads (fw/makehex.py output).
FIRMWARE ?= $(PWD)/fw32.hex

ifneq ($(GATES),yes)

# ---- RTL simulation ----
SIM_BUILD = sim_build/rtl
VERILOG_SOURCES += $(addprefix $(SRC_DIR)/,$(PROJECT_SOURCES))

else

# ---- Gate-level simulation ----
SIM_BUILD = sim_build/gl
COMPILE_ARGS += -DGL_TEST
COMPILE_ARGS += -DFUNCTIONAL
COMPILE_ARGS += -DUSE_POWER_PINS
COMPILE_ARGS += -DUNIT_DELAY=\#1
VERILOG_SOURCES += $(PDK_ROOT)/sky130A/libs.ref/sky130_fd_sc_hd/verilog/primitives.v
VERILOG_SOURCES += $(PDK_ROOT)/sky130A/libs.ref/sky130_fd_sc_hd/verilog/sky130_fd_sc_hd.v
# copied in by the GDS action workflow (the hardened DUT netlist):
VERILOG_SOURCES += $(PWD)/gate_level_netlist.v

endif

# The flash/UART harness is behavioral in both modes, and SIM enables
# its $readmemh firmware preload. Added AFTER the DUT sources.
COMPILE_ARGS    += -DSIM
VERILOG_SOURCES += $(HARNESS_SOURCES)

# Pass the firmware path through to $readmemh via a plusarg.
PLUSARGS += +firmware=$(FIRMWARE)

# Allow `include sharing between design and testbench.
COMPILE_ARGS += -I$(SRC_DIR)

# Testbench sources:
VERILOG_SOURCES += $(PWD)/tb.v
TOPLEVEL = tb

COCOTB_TEST_MODULES = test

include $(shell cocotb-config --makefiles)/Makefile.sim
