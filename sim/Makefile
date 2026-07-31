# tt_um_foxworks_picorv32 simulation
#
# `make sim`   - tt_um + tt_virtual_demoboard (the ZU3 BD topology)
# `make wave`  - sim with +vcd, then open in gtkwave/surfer yourself
#
# Firmware must be built first with the SIM_FAST delay so bounces fit in
# simulated time:
#     make -C ../fw clean && make -C ../fw FWDEFS=-DSIM_FAST

SIM_US   ?= 300000

IVERILOG ?= iverilog
VVP      ?= vvp

# Order matters: picosoc.v defines PICORV32_REGS and must be read
# before picorv32.v (see the `ifndef guard at the top of picosoc.v).
SOC_SRCS = ../src/picosoc.v \
           ../src/spimemio.v \
           ../src/simpleuart.v \
           ../src/picorv32.v

TT_SRCS  = ../src/tt_um_foxworks_picorv32.v

VDB_SRCS = ../test/tt_virtual_demoboard.v \
           ../test/spi_flash_model.v

tt_tb.vvp: tt_tb.v $(TT_SRCS) $(VDB_SRCS) $(SOC_SRCS)
	$(IVERILOG) -g2005 -DSIM -o $@ tt_tb.v $(TT_SRCS) $(VDB_SRCS) $(SOC_SRCS)

sim: tt_tb.vvp
	$(VVP) $< +firmware=../fw/fw32.hex +sim_us=$(SIM_US)

wave: tt_tb.vvp
	$(VVP) $< +firmware=../fw/fw32.hex +sim_us=$(SIM_US) +vcd


clean:
	rm -f tt_tb.vvp tt_tb.vcd

.PHONY: sim wave clean
