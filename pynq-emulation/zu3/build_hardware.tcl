#------------------------------------------------------------------------------
# Company: Trinity College Dublin
# Engineer: Michael John Flynn
#
# Create Date: 30/07/2026
# Module Name: tt_um_foxworks_picorv32
# Target Devices: Real Digital AUP-ZU3
# Tool Versions: Vivado 2024.2
# Description: Synthesis, Implements, and builds the emulated chip for TT
# Dependencies: - aup-zu3 board files and Ultrascale+ MPSoC dev tools
#               - A ready to go block design from previous steps
# 
# Revision 0.02 - Modification of original Build Script
#-------------------------------------------------------------------------------

# Generate HDL wrapper and set as top for synthesis and Implementation
make_wrapper -files [get_files ${PROJ_DIR}/${PROJ_NAME}.srcs/sources_1/bd/tt_bd/tt_bd.bd] -top
add_files -norecurse ${PROJ_DIR}/${PROJ_NAME}.gen/sources_1/bd/tt_bd/hdl/tt_bd_wrapper.v
set_property top tt_bd_wrapper [current_fileset]
update_compile_order -fileset sources_1

# call synth + implement
launch_runs synth_1 -jobs 16
wait_on_run synth_1
launch_runs impl_1 -to_step write_bitstream -jobs 16
wait_on_run impl_1

# ---------------------------------------------------------------------------
# Ship the overlay pair to the top level.
# ---------------------------------------------------------------------------
set bit_src ${PROJ_DIR}/${PROJ_NAME}.runs/impl_1/tt_bd_wrapper.bit
set hwh_src ${PROJ_DIR}/${PROJ_NAME}.gen/sources_1/bd/tt_bd/hw_handoff/tt_bd.hwh
file copy -force $bit_src ../${PROJ_NAME}.bit
file copy -force $hwh_src ../${PROJ_NAME}.hwh


# ---------------------------------------------------------------------------
# Reports:
# ---------------------------------------------------------------------------
open_run impl_1
file mkdir ./reports_${PROJ_NAME}

report_timing_summary -delay_type min_max -report_unconstrained \
    -check_timing_verbose -max_paths 10 \
    -file ./reports_${PROJ_NAME}/timing_summary.rpt

# The ten worst setup paths, with full logic detail.
report_timing -delay_type max -max_paths 10 -path_type full \
    -file ./reports_${PROJ_NAME}/worst_setup_paths.rpt

# Every clock-domain crossing Vivado can see, categorised. Your async FIFO
# and gray_sync paths should appear as safely structured.
report_cdc -details -file ./reports_${PROJ_NAME}/cdc.rpt

report_clock_interaction -file ./reports_${PROJ_NAME}/clock_interaction.rpt
report_utilization -hierarchical \
    -file ./reports_${PROJ_NAME}/utilization.rpt


set wns [get_property STATS.WNS [get_runs impl_1]]
puts "-----------------------------------------------------------------"
puts " Build complete: ${PROJ_NAME}"
puts " WNS = ${wns} ns"
if {$wns < 0} {
    puts " Timing FAILED "
}
puts " Overlay: ../${PROJ_NAME}.bit + ../${PROJ_NAME}.hwh"
puts " Reports: ./reports_${PROJ_NAME}/"
puts "-----------------------------------------------------------------"
