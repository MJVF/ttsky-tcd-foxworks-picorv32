# =============================================================================
# pmods.xdc - AUP-ZU3 PMOD pin constraints for the tt_foxworks_picorv32 harness
# =============================================================================

# ---- ui_in[7:0]  <= PMOD A (GPIO inputs: switches / gamepad / etc...) ----
set_property PACKAGE_PIN J12 [get_ports {ui_in[0]}]
set_property PACKAGE_PIN H12 [get_ports {ui_in[1]}]
set_property PACKAGE_PIN H11 [get_ports {ui_in[2]}]
set_property PACKAGE_PIN G10 [get_ports {ui_in[3]}]
set_property PACKAGE_PIN K13 [get_ports {ui_in[4]}]
set_property PACKAGE_PIN K12 [get_ports {ui_in[5]}]
set_property PACKAGE_PIN J11 [get_ports {ui_in[6]}]
set_property PACKAGE_PIN J10 [get_ports {ui_in[7]}]
set_property IOSTANDARD LVCMOS33 [get_ports ui_in*]

# ---- uo_out[7:0] => PMOD B (GPIO outputs: LEDs / etc...) ----
set_property PACKAGE_PIN E12 [get_ports {uo_out[0]}]
set_property PACKAGE_PIN D11 [get_ports {uo_out[1]}]
set_property PACKAGE_PIN B11 [get_ports {uo_out[2]}]
set_property PACKAGE_PIN A10 [get_ports {uo_out[3]}]
set_property PACKAGE_PIN C11 [get_ports {uo_out[4]}]
set_property PACKAGE_PIN B10 [get_ports {uo_out[5]}]
set_property PACKAGE_PIN A12 [get_ports {uo_out[6]}]
set_property PACKAGE_PIN A11 [get_ports {uo_out[7]}]
set_property IOSTANDARD LVCMOS33 [get_ports uo_out*]


# =============================================================================
# CDC between pl_clk0 (50 MHz, tt_um) and pl_clk1 (200 MHz, harness):
# the uio nets between the two blocks are handled as asynchronous by
# construction (2FF synchronizers in spi_flash_model; MISO is quasi-
# static per half-bit for spimemio). The two PL clocks come from
# separate PS PLL outputs, so declaring them async is the honest
# constraint.
#
set_clock_groups -asynchronous \
     -group [get_clocks -include_generated_clocks *pl_clk0*] \
     -group [get_clocks -include_generated_clocks *pl_clk1*]
# =============================================================================
