`default_nettype none
`timescale 1ns / 1ps

/*
 * tb.v - cocotb testbench for tt_um_foxworks_picorv32.
 *
 * Unlike the stock TT template (which instantiates only the DUT and
 * lets Python drive every pin), this design needs an SPI flash on its
 * uio bus before it can fetch a single instruction. So this shim wires
 * the DUT to tt_virtual_demoboard and Python's job shrinks
 * to: release reset, then watch uo_out and the UART for the verdict.
 *
 * The DUT is the real tt_um; under GL_TEST it is the hardened gate
 * netlist. The flash harness is behavioral testbench scaffolding in
 * BOTH modes (it is not part of the DUT), so it keeps its $readmemh
 * firmware preload after hardening - exactly what lets a GL run boot.
 *
 * Firmware image: +firmware=fw32.hex (consumed inside spi_flash_model
 * via `ifdef SIM). Build it first:  make -C ../fw PROG=selftest
 * and copy fw/fw32.hex next to this file (or pass a path).
 */
module tb ();

  initial begin
    $dumpfile("tb.fst");
    $dumpvars(0, tb);
    #1;
  end


  // DUT pins
  reg  clk;
  reg  rst_n;
  reg  ena;
  reg  [7:0] ui_in;
  wire [7:0] uo_out;
  wire [7:0] uio_in;
  wire [7:0] uio_out;
  wire [7:0] uio_oe;

  // Second clock for the flash harness (Python only drives `clk`).
  // 5x the DUT clock (50MHz): enough to oversample SCK = clk/2 with margin.
  reg hrn_clk = 0;
  always #2 hrn_clk = ~hrn_clk;   // 250 MHz sim harness clock

  // Harness reset: arm the flash a little before the DUT leaves reset.
  // Python drives rst_n; this just tracks it one step earlier so the
  // model is ready. (Held in reset until Python raises rst_n.)
  wire vdb_rst_n = rst_n;

`ifdef GL_TEST
  wire VPWR = 1'b1;
  wire VGND = 1'b0;
`endif

  tt_um_foxworks_picorv32 user_project (
`ifdef GL_TEST
      .VPWR(VPWR),
      .VGND(VGND),
`endif
      .ui_in  (ui_in),
      .uo_out (uo_out),
      .uio_in (uio_in),
      .uio_out(uio_out),
      .uio_oe (uio_oe),
      .ena    (ena),
      .clk    (clk),
      .rst_n  (rst_n)
  );

  // Flash + UART harness (behavioral; identical module to the ZU3 BD).
  tt_virtual_demoboard vdb (
      .clk          (hrn_clk),
      .rst_n        (vdb_rst_n),
      .uio_out      (uio_out),
      .uio_oe       (uio_oe),
      .uio_in       (uio_in),
      .uart_rx_i    (1'b1),      // UART RX idle; Python reads TX via uio_out[6]
      .uart_tx_o    (),
      .s_axi_awaddr (16'h0),
      .s_axi_awprot (3'h0),
      .s_axi_awvalid(1'b0),
      .s_axi_awready(),
      .s_axi_wdata  (32'h0),
      .s_axi_wstrb  (4'h0),
      .s_axi_wvalid (1'b0),
      .s_axi_wready (),
      .s_axi_bresp  (),
      .s_axi_bvalid (),
      .s_axi_bready (1'b0),
      .s_axi_araddr (16'h0),
      .s_axi_arprot (3'h0),
      .s_axi_arvalid(1'b0),
      .s_axi_arready(),
      .s_axi_rdata  (),
      .s_axi_rresp  (),
      .s_axi_rvalid (),
      .s_axi_rready (1'b0)
  );

  // ------------------------------------------------------------------
  // X-MONITOR
  //
  // Timestamps the FIRST X on each boundary signal, once each. With the
  // harness echo removed, the ORDER of these prints localizes the fault:
  //
  //   uio_in first   -> X arrived FROM the harness (flash model / RX)
  //   uio_oe first   -> spimemio's output-enable state went X
  //   uio_out first  -> flash datapath or UART TX went X
  //   uo_out first   -> core / GPIO register went X
  //
  // Whichever timestamp is EARLIEST is the source; everything after it
  // is spread. `^bus === 1'bx` is the standard "any bit is X" idiom:
  // XOR-reduction of a vector containing X yields X.
  // ------------------------------------------------------------------
  reg x_uo = 0, x_uio_out = 0, x_uio_oe = 0, x_uio_in = 0, x_miso = 0;

  always @(posedge clk) begin
    if (rst_n === 1'b1) begin           // only once out of reset
      if (!x_uio_in  && (^uio_in  === 1'bx)) begin
        x_uio_in  <= 1'b1;
        $display("[X-MON %0t ns] FIRST X on uio_in  = %b  <-- from HARNESS", $time, uio_in);
      end
      if (!x_uio_oe  && (^uio_oe  === 1'bx)) begin
        x_uio_oe  <= 1'b1;
        $display("[X-MON %0t ns] FIRST X on uio_oe  = %b  <-- spimemio OE state", $time, uio_oe);
      end
      if (!x_uio_out && (^uio_out === 1'bx)) begin
        x_uio_out <= 1'b1;
        $display("[X-MON %0t ns] FIRST X on uio_out = %b  <-- flash/UART datapath", $time, uio_out);
      end
      if (!x_uo      && (^uo_out  === 1'bx)) begin
        x_uo      <= 1'b1;
        $display("[X-MON %0t ns] FIRST X on uo_out  = %b  <-- core/GPIO", $time, uo_out);
      end
      // MISO is the one input the harness legitimately drives - if this
      // goes X the flash model is the culprit, not the DUT.
      if (!x_miso && (vdb.spi_miso === 1'bx)) begin
        x_miso <= 1'b1;
        $display("[X-MON %0t ns] FIRST X on spi_miso <-- FLASH MODEL output", $time);
      end
    end
  end

  // Confirm the inputs the DUT is fed are clean at reset release, so a
  // later X cannot be blamed on the stimulus.
  initial begin
    @(posedge rst_n);
    @(posedge clk);
    $display("[X-MON %0t ns] at reset release: ui_in=%b uio_in=%b ena=%b rst_n=%b",
             $time, ui_in, uio_in, ena, rst_n);
    if ((^uio_in === 1'bx) || (^ui_in === 1'bx))
      $display("[X-MON] WARNING: DUT inputs already contain X at reset release");
    else
      $display("[X-MON] DUT inputs are fully defined at reset release");
  end

endmodule