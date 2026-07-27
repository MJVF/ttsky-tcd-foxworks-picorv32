/*
 * tt_virtual_demoboard.v
 *
 * The ZU3-side stand-in for everything that surrounds the chip on the
 * Tiny Tapeout demo board: the RP2040 acting as SPI flash, the UART
 * link, and the (pulled-up / undriven) state of released pins.
 *
 * Sits next to tt_um_foxworks_picorv32 in the block design and closes the
 * loop on its uio bus:
 *
 *      PS --AXI-Lite--> [firmware loader] --> 64 KB flash store
 *      tt uio_out/oe --> [pad resolution] --> SPI flash model --> uio_in
 *      axi_uartlite TX -> uart_rx_i ------------------------- --> uio_in[7]
 *      uio_out[6] (SoC TX) ----------------------------------> uart_tx_o
 *
 * The whole module runs on one clock (AXI + oversampling domain),
 * nominally 200 MHz; anything >= ~150 MHz oversamples the 25 MHz SCK
 * with margin (the ZU+ PS PLL may actually deliver e.g. 177.776 MHz -
 * fine). The tt_um module runs at 50 MHz; the uio nets between the
 * two blocks are treated as asynchronous by construction (the flash
 * model double-synchronizes them), so the related-clock timing Vivado
 * applies to these paths is stricter than necessary, not looser.
 *
 * AXI-Lite slave: single-beat, 64 KB window, word-aligned accesses
 * (exactly what PYNQ MMIO produces). Reads are 2-cycle and share the
 * BRAM read port with the SPI prefetcher (SPI wins); do firmware
 * readback/verify only while the SoC is held in reset - which is the
 * only sensible time to do it anyway.
 */

`default_nettype none

module tt_virtual_demoboard (
	(* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk CLK" *)
	(* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axi, ASSOCIATED_RESET rst_n" *)
	input  wire        clk,        // nominally 200 MHz; >=150 MHz required
	                               // (no FREQ_HZ attribute on purpose: the
	                               // PS PLL delivers the closest achievable
	                               // frequency, e.g. 177.776 MHz, and the BD
	                               // propagates whatever that is)
	(* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 rst_n RST" *)
	(* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
	input  wire        rst_n,

	// ---- Tiny Tapeout uio bus (to/from tt_um_foxworks_picorv32) ----
	input  wire [7:0]  uio_out,
	input  wire [7:0]  uio_oe,
	output wire [7:0]  uio_in,

	// ---- UART link (to axi_uartlite in the BD) ----
	input  wire        uart_rx_i,  // uartlite tx -> SoC RX (uio_in[7])
	output wire        uart_tx_o,  // SoC TX (uio_out[6]) -> uartlite rx

	// ---- AXI4-Lite firmware loader (from PS via smartconnect) ----
	input  wire [15:0] s_axi_awaddr,
	input  wire [2:0]  s_axi_awprot,
	input  wire        s_axi_awvalid,
	output wire        s_axi_awready,
	input  wire [31:0] s_axi_wdata,
	input  wire [3:0]  s_axi_wstrb,
	input  wire        s_axi_wvalid,
	output wire        s_axi_wready,
	output wire [1:0]  s_axi_bresp,
	output reg         s_axi_bvalid,
	input  wire        s_axi_bready,
	input  wire [15:0] s_axi_araddr,
	input  wire [2:0]  s_axi_arprot,
	input  wire        s_axi_arvalid,
	output wire        s_axi_arready,
	output reg  [31:0] s_axi_rdata,
	output wire [1:0]  s_axi_rresp,
	output reg         s_axi_rvalid,
	input  wire        s_axi_rready
);
	// ------------------------------------------------------------------
	// Pad resolution: what a released (oe=0) pin looks like to the
	// outside world. CS has a pull-up (idle high); SCK/MOSI idle low.
	// ------------------------------------------------------------------
	wire spi_sck  = uio_oe[0] ? uio_out[0] : 1'b0;
	wire spi_csb  = uio_oe[1] ? uio_out[1] : 1'b1;
	wire spi_mosi = uio_oe[2] ? uio_out[2] : 1'b0;
	wire spi_miso;

	// Input bus back into the chip: flash MISO on IO1, UART RX on [7],
	// everything the SoC itself drives is simply echoed (it never reads
	// those lines in serial mode; the echo keeps waveforms honest).
	assign uio_in = {uart_rx_i,   // [7] SERIAL_RX
	                 uio_out[6],  // [6] echo TX
	                 uio_out[5],  // [5] echo IO3
	                 uio_out[4],  // [4] echo IO2
	                 spi_miso,    // [3] IO1 = MISO
	                 uio_out[2],  // [2] echo IO0/MOSI
	                 uio_out[1],  // [1] echo CSB
	                 uio_out[0]}; // [0] echo SCK

	assign uart_tx_o = uio_out[6];

	// ------------------------------------------------------------------
	// AXI4-Lite loader
	// ------------------------------------------------------------------
	reg         ld_wen;
	reg  [13:0] ld_waddr;
	reg  [31:0] ld_wdata;
	reg  [3:0]  ld_wstrb;
	reg  [13:0] ld_raddr;
	wire [31:0] ld_rdata;

	// Write channel: accept AW and W together, respond with B.
	assign s_axi_awready = s_axi_awvalid && s_axi_wvalid && !s_axi_bvalid;
	assign s_axi_wready  = s_axi_awready;
	assign s_axi_bresp   = 2'b00; // OKAY

	always @(posedge clk) begin
		ld_wen <= 1'b0;
		if (!rst_n) begin
			s_axi_bvalid <= 1'b0;
		end else begin
			if (s_axi_awready) begin        // AW+W handshake this cycle
				ld_wen   <= 1'b1;
				ld_waddr <= s_axi_awaddr[15:2];
				ld_wdata <= s_axi_wdata;
				ld_wstrb <= s_axi_wstrb;
				s_axi_bvalid <= 1'b1;
			end else if (s_axi_bvalid && s_axi_bready) begin
				s_axi_bvalid <= 1'b0;
			end
		end
	end

	// Read channel: 2-cycle pipeline through the shared BRAM port.
	reg rd_pend, rd_pend_d;
	assign s_axi_arready = !rd_pend && !rd_pend_d && !s_axi_rvalid;
	assign s_axi_rresp   = 2'b00; // OKAY

	always @(posedge clk) begin
		if (!rst_n) begin
			rd_pend   <= 1'b0;
			rd_pend_d <= 1'b0;
			s_axi_rvalid <= 1'b0;
		end else begin
			rd_pend   <= 1'b0;
			rd_pend_d <= rd_pend;
			if (s_axi_arready && s_axi_arvalid) begin
				ld_raddr <= s_axi_araddr[15:2];
				rd_pend  <= 1'b1;
			end
			if (rd_pend_d) begin
				s_axi_rdata  <= ld_rdata;
				s_axi_rvalid <= 1'b1;
			end else if (s_axi_rvalid && s_axi_rready) begin
				s_axi_rvalid <= 1'b0;
			end
		end
	end

	// ------------------------------------------------------------------
	// The flash itself
	// ------------------------------------------------------------------
	spi_flash_model flash (
		.clk      (clk),
		.rst_n    (rst_n),
		.spi_sck  (spi_sck),
		.spi_csb  (spi_csb),
		.spi_mosi (spi_mosi),
		.spi_miso (spi_miso),
		.ld_wen   (ld_wen),
		.ld_waddr (ld_waddr),
		.ld_wdata (ld_wdata),
		.ld_wstrb (ld_wstrb),
		.ld_raddr (ld_raddr),
		.ld_rdata (ld_rdata)
	);

	// Lint tie-off
	wire _unused = &{s_axi_awprot, s_axi_arprot, uio_out[7], uio_oe[7:3], 1'b0};

endmodule

`default_nettype wire