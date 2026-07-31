# =============================================================================
# build_tt_foxworks_picorv32.tcl - Vivado project + bd for the ZU3 harness
#
# Usage:   vivado -mode batch -source build_tt_foxworks_picorv32.tcl
#          (or `source` it from the Tcl console)
#
#
#   Zynq US+ PS ---LPD/HPM0---> smartconnect ---> tt_virtual_demoboard (s_axi)
#        |                            |---------> axi_gpio   (rst_n/ena out, uo in)
#        | pl_clk0 = 25 MHz           |---------> axi_uartlite (115200)
#        | pl_clk1 = 125 MHz
#        v
#   [ tt_um_foxworks_picorv32 ]  <---- uio bus ----> [ tt_virtual_demoboard ]
#     clk rst_n ena                                     clk200
#     ui_in[7:0]  <== PMOD A pins
#     uo_out[7:0] ==> PMOD B pins (and looped into axi_gpio ch2 for PYNQ)
#
# The tt_um block in this BD has exactly the ports it has on silicon:
# clk, rst_n, ena and the 24 user I/Os. Moving to the Tiny Tapeout flow
# is: take src/tt_um_foxworks_picorv32.v + the patched picosoc sources,
# drop them into the ttsky-verilog-template, done.
# =============================================================================

set PART      "xczu3eg-sfvc784-2-e"
set BOARD     "realdigital.org:aup-zu3-8gb:part0:1.0"
set PROJ_NAME "tt_foxworks_picorv32"
set PROJ_DIR  "./vivado_proj"


if {![info exists HERE]} {
    if {[info script] ne ""} {
        set HERE [file dirname [file normalize [info script]]]
    } else {
        set HERE [file normalize [pwd]]
        puts "WARNING: \[info script\] empty (pasted into console?); assuming HERE=$HERE"
    }
}

# Fail fast with a useful message instead of cryptic add_files errors.
if {![file exists "$HERE/pmods.xdc"]} {
    error "HERE=$HERE does not look like the zu3/ directory (pmods.xdc not found).\
 Set HERE manually before sourcing - see comment above."
}

create_project $PROJ_NAME $PROJ_DIR -part $PART -force
set_property board_part $BOARD [current_project]

# Global define instead of relying on compile order: picosoc.v's
# `ifndef PICORV32_REGS guard errors out if picorv32.v is read first.
# With the macro defined project-wide, read order is irrelevant.
set_property verilog_define {PICORV32_REGS=picosoc_regs} [current_fileset]

add_files [list \
    "$HERE/../../src/tt_um_foxworks_picorv32.v" \
    "$HERE/tt_virtual_demoboard.v" \
    "$HERE/spi_flash_model.v" \
    "$HERE/../../src/picosoc.v" \
    "$HERE/../../src/spimemio.v" \
    "$HERE/../../src/simpleuart.v" \
    "$HERE/../../src/picorv32.v" \
]
add_files -fileset constrs_1 "$HERE/pmods.xdc"
update_compile_order -fileset sources_1

# -----------------------------------------------------------------------------
# Block design
# -----------------------------------------------------------------------------
create_bd_design "tt_bd"

# ---- PS: 25 MHz + 125 MHz PL clocks, one LPD AXI master ----
set ps [create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e ps]
if {[catch {apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e \
        -config {apply_board_preset "1"} $ps} msg]} {
    puts "WARNING: board preset not applied ($msg); using minimal PS config"
}
set_property -dict [list \
    CONFIG.PSU__USE__M_AXI_GP0 {0} \
    CONFIG.PSU__USE__M_AXI_GP1 {0} \
    CONFIG.PSU__USE__M_AXI_GP2 {1} \
    CONFIG.PSU__MAXIGP2__DATA_WIDTH {32} \
    CONFIG.PSU__FPGA_PL0_ENABLE {1} \
    CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ {25} \
    CONFIG.PSU__FPGA_PL1_ENABLE {1} \
    CONFIG.PSU__CRL_APB__PL1_REF_CTRL__FREQMHZ {125} \
] $ps

set act0 [get_property CONFIG.PSU__CRL_APB__PL0_REF_CTRL__ACT_FREQMHZ $ps]
set act1 [get_property CONFIG.PSU__CRL_APB__PL1_REF_CTRL__ACT_FREQMHZ $ps]
puts "PL0 (tt_um clk):  actual $act0 MHz (requested 25)"
puts "PL1 (harness clk): actual $act1 MHz (requested 125)"

# ---- resets ----
set rst200 [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst200]
connect_bd_net [get_bd_pins ps/pl_clk1]    [get_bd_pins rst200/slowest_sync_clk]
connect_bd_net [get_bd_pins ps/pl_resetn0] [get_bd_pins rst200/ext_reset_in]

# ---- the chip ----
set tt [create_bd_cell -type module -reference tt_um_foxworks_picorv32 tt_um]
connect_bd_net [get_bd_pins ps/pl_clk0] [get_bd_pins tt_um/clk]

# ---- the virtual demo board ----
set vdb [create_bd_cell -type module -reference tt_virtual_demoboard vdb]
connect_bd_net [get_bd_pins ps/pl_clk1] [get_bd_pins vdb/clk]
connect_bd_net [get_bd_pins rst200/peripheral_aresetn] [get_bd_pins vdb/rst_n]

connect_bd_net [get_bd_pins tt_um/uio_out] [get_bd_pins vdb/uio_out]
connect_bd_net [get_bd_pins tt_um/uio_oe]  [get_bd_pins vdb/uio_oe]
connect_bd_net [get_bd_pins vdb/uio_in]    [get_bd_pins tt_um/uio_in]

# ---- rst_n / ena for the chip, driven from PYNQ via AXI GPIO ch1;
#      uo_out readback into PYNQ via AXI GPIO ch2 ----
set gpio [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio ctrl_gpio]
set_property -dict [list \
    CONFIG.C_IS_DUAL {1} \
    CONFIG.C_GPIO_WIDTH {2} CONFIG.C_ALL_OUTPUTS {1} \
    CONFIG.C_GPIO2_WIDTH {8} CONFIG.C_ALL_INPUTS_2 {1} \
] $gpio

set slice_rst [create_bd_cell -type ip -vlnv xilinx.com:ip:xlslice slice_rst]
set_property -dict [list CONFIG.DIN_WIDTH {2} CONFIG.DIN_FROM {0} CONFIG.DIN_TO {0}] $slice_rst
set slice_ena [create_bd_cell -type ip -vlnv xilinx.com:ip:xlslice slice_ena]
set_property -dict [list CONFIG.DIN_WIDTH {2} CONFIG.DIN_FROM {1} CONFIG.DIN_TO {1}] $slice_ena

connect_bd_net [get_bd_pins ctrl_gpio/gpio_io_o] [get_bd_pins slice_rst/Din]
connect_bd_net [get_bd_pins ctrl_gpio/gpio_io_o] [get_bd_pins slice_ena/Din]
connect_bd_net [get_bd_pins slice_rst/Dout] [get_bd_pins tt_um/rst_n]
connect_bd_net [get_bd_pins slice_ena/Dout] [get_bd_pins tt_um/ena]
connect_bd_net [get_bd_pins tt_um/uo_out] [get_bd_pins ctrl_gpio/gpio2_io_i]

# ---- UART: uartlite <-> vdb passthrough <-> uio[6]/uio[7] ----
set uart [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_uartlite uartlite]
set_property -dict [list CONFIG.C_BAUDRATE {115200}] $uart
connect_bd_net [get_bd_pins uartlite/tx] [get_bd_pins vdb/uart_rx_i]
connect_bd_net [get_bd_pins vdb/uart_tx_o] [get_bd_pins uartlite/rx]

# ---- AXI interconnect: everything on the 200 MHz domain ----
set smc [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect smc]
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {3}] $smc
connect_bd_net [get_bd_pins ps/pl_clk1] [get_bd_pins smc/aclk]
connect_bd_net [get_bd_pins ps/pl_clk1] [get_bd_pins ps/maxihpm0_lpd_aclk]
connect_bd_net [get_bd_pins ps/pl_clk1] [get_bd_pins ctrl_gpio/s_axi_aclk]
connect_bd_net [get_bd_pins ps/pl_clk1] [get_bd_pins uartlite/s_axi_aclk]
connect_bd_net [get_bd_pins rst200/peripheral_aresetn] [get_bd_pins ctrl_gpio/s_axi_aresetn]
connect_bd_net [get_bd_pins rst200/peripheral_aresetn] [get_bd_pins uartlite/s_axi_aresetn]

connect_bd_intf_net [get_bd_intf_pins ps/M_AXI_HPM0_LPD] [get_bd_intf_pins smc/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins smc/M00_AXI] [get_bd_intf_pins vdb/s_axi]
connect_bd_intf_net [get_bd_intf_pins smc/M01_AXI] [get_bd_intf_pins ctrl_gpio/S_AXI]
connect_bd_intf_net [get_bd_intf_pins smc/M02_AXI] [get_bd_intf_pins uartlite/S_AXI]

# ---- PMOD-facing external ports ----
create_bd_port -dir I -from 7 -to 0 ui_in
create_bd_port -dir O -from 7 -to 0 uo_out
connect_bd_net [get_bd_ports ui_in]  [get_bd_pins tt_um/ui_in]
connect_bd_net [get_bd_ports uo_out] [get_bd_pins tt_um/uo_out]

# ---- addresses (vdb range = 64 KB, from its 16-bit awaddr) ----
assign_bd_address
validate_bd_design
save_bd_design

# ---- HDL wrapper + top ----
make_wrapper -files [get_files tt_bd.bd] -top
add_files -norecurse "$PROJ_DIR/$PROJ_NAME.gen/sources_1/bd/tt_bd/hdl/tt_bd_wrapper.v"
set_property top tt_bd_wrapper [current_fileset]
update_compile_order -fileset sources_1

puts "=============================================================="
puts " BD ready."
puts "=============================================================="
