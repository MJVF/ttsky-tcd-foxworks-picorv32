# Vivado runthrough

1. Simulate before Vivado:

       make -C fw FWDEFS=-DSIM_FAST     # needs riscv64-unknown-elf-gcc
       make -C sim sim                  # needs iverilog
       # expect: banner over decoded UART, then uo_out stepping 01->02->04...

2. Rebuild firmware at real speed, then build the project:

Ensure the clock speeds match then:

       make -C fw clean && make -C fw
       vivado -mode batch -source zu3/build_tt_picosoc.tcl

   (Or open Vivado and `source zu3/build_tt_foxworks_picorv32.tcl` in the Tcl
   console - same result, and you can inspect the BD: tt_um sits there
   as one block with clk/rst_n/ena and the 24 I/Os, wired to the
   virtual demo board.)

3. Bitstream Generation:

       vivado -mode batch -source zu3/build_hardware.tcl

   (Or open Vivado and `source zu3/build_hardware.tcl` in the Tcl
   console.)

4. Collect the three files:

       ./tt_foxworks_picorv32.bit
       ./tt_foxworks_picorv32.hwh
       ../fw/flash.bin

5. Copy those plus `pynq/tt_picosoc_bringup.ipynb` to one folder on the
   board, open the notebook, run top to bottom: it holds the chip in
   reset, programs and verifies the flash, raises ena then rst_n, prints
   the UART banner, and shows the bounce live from AXI GPIO ch2.
