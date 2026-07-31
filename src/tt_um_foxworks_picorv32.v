/*
 * tt_um_foxworks_picorv32.v
 *
 * Tiny Tapeout top-level wrapper for PicoSoC (PicoRV32 + spimemio XIP +
 * simpleuart + 128 B SRAM + 8-in/8-out GPIO).
 *
 * THIS FILE IS THE TAPEOUT BOUNDARY. It is instantiated unchanged by:
 *   - the Tiny Tapeout LibreLane flow (tt_wrapper -> this module)
 *   - the ZU3 Vivado block design   (module reference -> this module)
 *   - the simulation testbench      (sim/tt_tb.v -> this module)
 * Anything platform-specific lives OUTSIDE this module.
 *
 * Pinout:
 *   ui_in[7:0]   GPIO inputs  (PMOD A on ZU3; Gamepad Pmod etc. on TT board)
 *   uo_out[7:0]  GPIO outputs (PMOD B on ZU3; Tiny VGA Pmod pinout reserved)
 *   uio[0]  out  FLASH_SCK    (SPI clock, clk/2 = 25 MHz @ 50 MHz clk)
 *   uio[1]  out  FLASH_CSB    (SPI chip select, active low)
 *   uio[2]  bid  FLASH_IO0    (MOSI in serial mode)
 *   uio[3]  bid  FLASH_IO1    (MISO in serial mode)
 *   uio[4]  bid  FLASH_IO2    (driven 1 in serial mode = /WP)
 *   uio[5]  bid  FLASH_IO3    (driven 1 in serial mode = /HOLD)
 *   uio[6]  out  SERIAL_TX    (115200 8N1 with reg_uart_clkdiv = 434 @ 50MHz)
 *   uio[7]  in   SERIAL_RX
 *
 * Memory map (as seen by the firmware):
 *   0x0000_0000 - 0x0000_007F  SRAM, 128 B (MEM_WORDS = 32); stack top 0x80
 *   0x0000_0100 - 0x01FF_FFFF  SPI flash XIP window (flash offset = addr[23:0])
 *                              reset vector 0x0000_0400 = flash offset 0x400
 *   0x0200_0000                spimemio config (DO NOT WRITE: the RP2040
 *                              emulator speaks serial 03h reads only; enabling
 *                              QSPI/DDR bits breaks the emulation contract)
 *   0x0200_0004                UART clock divisor
 *   0x0200_0008                UART data (write: TX, blocks in HW; read: RX,
 *                              0xFFFF_FFFF if empty)
 *   0x0300_0000                GPIO: write [7:0] -> uo_out; read
 *                              {8'h0, uio_in_sync, ui_in_sync, gpio_out}
 *                              - every pin of the chip is firmware-readable
 */

`default_nettype none

module tt_um_foxworks_picorv32 (
	input  wire [7:0] ui_in,    // dedicated inputs
	output wire [7:0] uo_out,   // dedicated outputs
	input  wire [7:0] uio_in,   // bidirectional: input path
	output wire [7:0] uio_out,  // bidirectional: output path
	output wire [7:0] uio_oe,   // bidirectional: enable (1 = output)
	input  wire       ena,      // TT mux select; qualifies uio_oe below
	input  wire       clk,      // project clock
	input  wire       rst_n     // active-low reset
);
	// ------------------------------------------------------------------
	// Reset synchronizer. rst_n arrives async from the RP2040 / PS GPIO.
	// ------------------------------------------------------------------
	reg [1:0] rst_sync;
	always @(posedge clk or negedge rst_n) begin
		if (!rst_n)
			rst_sync <= 2'b00;
		else
			rst_sync <= {rst_sync[0], 1'b1};
	end
	wire resetn = rst_sync[1];

	// ------------------------------------------------------------------
	// Input synchronizers (PMOD/pad inputs are asynchronous).
	// ALL 24 pins are made firmware-visible: ui_sync and uio_sync feed
	// the GPIO read register, so this is a generic rv32i micro with
	// sight of its entire pinout,. Note the flash data-in pins
	// (uio_in[2..5]) ALSO go to spimemio directly and
	// unsynchronized - that path is protocol-synchronous and needs
	// same-cycle sampling; the synced copies here are observation only.
	// ------------------------------------------------------------------
	reg [7:0] ui_meta,  ui_sync;
	reg [7:0] uio_meta, uio_sync;
	always @(posedge clk) begin
		ui_meta  <= ui_in;
		ui_sync  <= ui_meta;
		uio_meta <= uio_in;
		uio_sync <= uio_meta;
	end

	// ------------------------------------------------------------------
	// PicoSoC core
	// ------------------------------------------------------------------
	wire        iomem_valid;
	reg         iomem_ready;
	wire [3:0]  iomem_wstrb;
	wire [31:0] iomem_addr;
	wire [31:0] iomem_wdata;
	reg  [31:0] iomem_rdata;

	wire        ser_tx;
	wire        ser_rx = uio_in[7];

	wire flash_csb, flash_clk;
	wire flash_io0_oe, flash_io1_oe, flash_io2_oe, flash_io3_oe;
	wire flash_io0_do, flash_io1_do, flash_io2_do, flash_io3_do;
	wire flash_io0_di = uio_in[2];
	wire flash_io1_di = uio_in[3];
	wire flash_io2_di = uio_in[4];
	wire flash_io3_di = uio_in[5];

	picosoc #(
		// ---- memory geometry ----
		.MEM_WORDS      (32),            // 128 B SRAM, stack top = 0x80
		.PROGADDR_RESET (32'h 0000_0400),// flash offset 0x400
		.PROGADDR_IRQ   (32'h 0000_0000),// unused (IRQ disabled)
		// ---- area configuration: everything off ----
		.BARREL_SHIFTER (0),
		.TWO_STAGE_SHIFT(0),
		.ENABLE_MUL     (0),
		.ENABLE_FAST_MUL(0),
		.ENABLE_DIV     (0),
		.ENABLE_COMPRESSED(0),
		.ENABLE_COUNTERS(0),
		.ENABLE_IRQ     (0),
		.ENABLE_IRQ_QREGS(0),
		.ENABLE_REGS_DUALPORT(0),
		.CATCH_ILLINSN  (1)
	) soc (
		.clk         (clk),
		.resetn      (resetn),

		.ser_tx      (ser_tx),
		.ser_rx      (ser_rx),

		.flash_csb   (flash_csb),
		.flash_clk   (flash_clk),
		.flash_io0_oe(flash_io0_oe),
		.flash_io1_oe(flash_io1_oe),
		.flash_io2_oe(flash_io2_oe),
		.flash_io3_oe(flash_io3_oe),
		.flash_io0_do(flash_io0_do),
		.flash_io1_do(flash_io1_do),
		.flash_io2_do(flash_io2_do),
		.flash_io3_do(flash_io3_do),
		.flash_io0_di(flash_io0_di),
		.flash_io1_di(flash_io1_di),
		.flash_io2_di(flash_io2_di),
		.flash_io3_di(flash_io3_di),

		// IRQs: with ENABLE_IRQ=0 picorv32 prunes all interrupt logic.
		// There is no interrupt fabric on Tiny Tapeout - an IRQ source
		// can only be one of this design's own 24 pins or an internal
		// peripheral.
		.irq_5       (1'b0),
		.irq_6       (1'b0),
		.irq_7       (1'b0),

		.iomem_valid (iomem_valid),
		.iomem_ready (iomem_ready),
		.iomem_wstrb (iomem_wstrb),
		.iomem_addr  (iomem_addr),
		.iomem_wdata (iomem_wdata),
		.iomem_rdata (iomem_rdata)
	);

	// ------------------------------------------------------------------
	// GPIO block: this IS the "controller" - one write register driving
	// uo_out and one synchronized read path from ui_in. Nothing more is
	// needed for plain parallel I/O.
	//
	// picosoc asserts iomem_valid for all addresses with addr[31:24] > 0x01,
	// which INCLUDES the internal peripherals at 0x0200_00xx (they win the
	// mem_ready mux by priority, but only if we don't ack). Therefore the
	// default-ack below must exclude 0x02xx_xxxx or GPIO would race the
	// UART/SPI-config registers. Firmware must not touch unmapped
	// 0x02xx_xxxx addresses (the bus hangs - same as upstream picosoc).
	// ------------------------------------------------------------------
	reg [7:0] gpio_out;

	always @(posedge clk) begin
		iomem_ready <= 1'b0;
		if (!resetn) begin
			gpio_out <= 8'h00;
		end else if (iomem_valid && !iomem_ready
				&& iomem_addr[31:24] != 8'h02) begin
			iomem_ready <= 1'b1;              // ack GPIO and any stray I/O
			iomem_rdata <= {8'h00, uio_sync, ui_sync, gpio_out};
			if (iomem_addr[31:24] == 8'h03 && iomem_wstrb[0])
				gpio_out <= iomem_wdata[7:0];
		end
	end

	assign uo_out = gpio_out;

	// ------------------------------------------------------------------
	// Bidirectional pin mapping. During reset every uio is an input.
	// ------------------------------------------------------------------
	assign uio_out = {1'b0,          // uio[7] SERIAL_RX (input)
	                  ser_tx,        // uio[6] SERIAL_TX
	                  flash_io3_do,  // uio[5]
	                  flash_io2_do,  // uio[4]
	                  flash_io1_do,  // uio[3]
	                  flash_io0_do,  // uio[2]
	                  flash_csb,     // uio[1]
	                  flash_clk};    // uio[0]

	// ena is high when the TT mux has selected this design (the mux
	// already disconnects unselected projects physically, so per the TT
	// template it may be ignored - but qualifying the output enables
	// with it costs eight AND gates.
	assign uio_oe = (resetn && ena)
	                       ? {1'b0,          // uio[7] SERIAL_RX
	                          1'b1,          // uio[6] SERIAL_TX
	                          flash_io3_oe,  // uio[5]
	                          flash_io2_oe,  // uio[4]
	                          flash_io1_oe,  // uio[3]
	                          flash_io0_oe,  // uio[2]
	                          1'b1,          // uio[1] FLASH_CSB
	                          1'b1}          // uio[0] FLASH_SCK
	                       : 8'h00;

endmodule

`default_nettype wire
