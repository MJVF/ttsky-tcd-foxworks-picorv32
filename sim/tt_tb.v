/*
 * tt_tb.v
 *
 * Deliberately shaped like the ZU3 block design minus the PS:
 *
 *     [ tt_um_foxworks_picorv32 @ 25 MHz ] <--uio--> [ tt_virtual_demoboard @ 125 MHz ]
 *
 * so what is verified here is the exact pair of modules the Vivado BD
 * instantiates. Firmware is preloaded via $readmemh (+firmware=...)
 * instead of AXI writes; everything else is identical.
 *
 * Plusargs:
 *   +firmware=../fw/fw32.hex    word-hex flash image
 *   +sim_us=5000                simulated microseconds before timeout
 *   +vcd                        dump tt_tb.vcd
 *
 * Console output: decoded 115200-baud UART from uio_out[6], plus a line
 * per uo_out (GPIO) change - the bounce, in ASCII.
 */

`timescale 1 ns / 1 ps

module tt_tb;

	// ---------------- clocks & reset ----------------
	// Chip clock and harness clock. Keep harness >= ~6x SCK (= 3x chip
	// clock); 25/125 MHz gives 10x oversampling of the 12.5 MHz SCK.
	reg chip_clk = 0;
	reg hrn_clk  = 0;
	always #20.0 chip_clk = ~chip_clk;  // 25 MHz project clock
	always #4.0  hrn_clk  = ~hrn_clk;   // 125 MHz harness clock

	// ---- X-monitor state (see the monitor block below) ----
	localparam integer MEM_WORDS_TB = 32;   // MUST match the wrapper

	reg x_uo = 0, x_uio_out = 0, x_uio_oe = 0, x_uio_in = 0, x_miso = 0;
	reg x_ramrd = 0, x_memrd = 0, x_memaddr = 0, oor_first = 0;
	integer oor_count = 0;


	reg rst_n     = 0;  // SoC reset (the "RP2040 GPIO" on the real board)
	reg vdb_rst_n = 0;  // harness reset

	initial begin
		#100      vdb_rst_n = 1;  // flash model armed first,
		#5000     rst_n     = 1;  // then the chip comes out of reset
	end

	// ---------------- DUT ----------------
	wire [7:0] ui_in = 8'h00;   // switches: all off (fastest bounce)
	wire [7:0] uo_out;
	wire [7:0] uio_in;
	wire [7:0] uio_out;
	wire [7:0] uio_oe;

	tt_um_foxworks_picorv32 dut (
		.ui_in  (ui_in),
		.uo_out (uo_out),
		.uio_in (uio_in),
		.uio_out(uio_out),
		.uio_oe (uio_oe),
		.ena    (1'b1),
		.clk    (chip_clk),
		.rst_n  (rst_n)
	);

	// ---------------- virtual demo board (same module as the ZU3 BD) --
	tt_virtual_demoboard vdb (
		.clk          (hrn_clk),
		.rst_n        (vdb_rst_n),
		.uio_out      (uio_out),
		.uio_oe       (uio_oe),
		.uio_in       (uio_in),
		.uart_rx_i    (1'b1),      // UART line idle
		.uart_tx_o    (),
		// AXI-Lite loader unused in sim (firmware via $readmemh)
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

	// ---------------- firmware note ----------------
	// (+firmware= is consumed inside spi_flash_model via `ifdef SIM)

	// ---------------- UART monitor: 115200 8N1 on uio_out[6] ----------
	localparam real BIT_NS = 8680.6;  // 1e9 / 115200
	reg [7:0] uart_byte;
	integer uart_i;
	initial begin : uart_mon
		forever begin
			@(negedge uio_out[6]);
			#(BIT_NS / 2);
			if (uio_out[6] == 1'b0) begin       // confirmed start bit
				uart_byte = 8'h00;
				for (uart_i = 0; uart_i < 8; uart_i = uart_i + 1) begin
					#(BIT_NS);
					uart_byte = {uio_out[6], uart_byte[7:1]};
				end
				#(BIT_NS);                       // stop bit
				$write("%c", uart_byte);
				$fflush;
			end
		end
	end

	// ---------------- GPIO monitor: the bounce, frame by frame -------
	always @(uo_out) begin
		if ($time > 0)
			$display("[%0t ns] uo_out = %b", $time, uo_out);
	end

	// ---------------- uo_out trace: one hex byte per chip clock -------
	// (+uo_trace=uo_out.trace) Feeds the logic-level VGA decoder in the
	// PYNQ notebook: 50 MHz sampling = exactly 2x the 25 MHz pixel
	// clock of the (future) VGA peripheral - the decoder derives the
	// ratio from the hsync period, so nothing here assumes it.
	integer uo_trace_fd = 0;
	reg [1023:0] uo_trace_file;
	initial begin
		if ($value$plusargs("uo_trace=%s", uo_trace_file))
			uo_trace_fd = $fopen(uo_trace_file, "w");
	end
	always @(posedge chip_clk) begin
		if (uo_trace_fd != 0)
			$fwrite(uo_trace_fd, "%02x\n", uo_out);
	end

	// ---------------- run control ----------------
	integer sim_us;
	initial begin
		if ($test$plusargs("vcd")) begin
			$dumpfile("tt_tb.vcd");
			$dumpvars(0, tt_tb);
		end
		if (!$value$plusargs("sim_us=%d", sim_us))
			sim_us = 5000;
		#(sim_us * 1000.0);
		$display("\n[tt_tb] %0d us simulated, done.", sim_us);
		$display("[X-MON] ---- summary ----");
		$display("[X-MON] out-of-range RAM reads: %0d", oor_count);
		$display("[X-MON] first-X on: uio_in=%b uio_oe=%b uio_out=%b uo_out=%b",
		         x_uio_in, x_uio_oe, x_uio_out, x_uo);
		$display("[X-MON] internal:  mem_addr=%b ram_rdata=%b mem_rdata_to_cpu=%b",
		         x_memaddr, x_ramrd, x_memrd);
		$finish;
	end

	// ==================================================================
	// X-MONITOR
	//
	// Two jobs. First, the same boundary first-X report as the cocotb
	// bench: whichever signal's timestamp is EARLIEST is the source,
	// everything after it is spread.
	//
	// Second - and this is what only the RTL bench can do - it probes
	// inside the SoC. Gate-level netlists have mangled instance names, so
	// there the fault can only be watched at the pins; here the RTL
	// hierarchy survives and we can test the out-of-range RAM read
	// directly.
	//
	// Keep MEM_WORDS_TB in sync with the wrapper's .MEM_WORDS().
	// ==================================================================
	always @(posedge chip_clk) begin
		if (rst_n === 1'b1) begin

			// ---- boundary ----
			if (!x_uio_in && (^uio_in === 1'bx)) begin
				x_uio_in <= 1'b1;
				$display("[X-MON %0t] FIRST X on uio_in  = %b  <-- from HARNESS", $time, uio_in);
			end
			if (!x_uio_oe && (^uio_oe === 1'bx)) begin
				x_uio_oe <= 1'b1;
				$display("[X-MON %0t] FIRST X on uio_oe  = %b  <-- spimemio OE state", $time, uio_oe);
			end
			if (!x_uio_out && (^uio_out === 1'bx)) begin
				x_uio_out <= 1'b1;
				$display("[X-MON %0t] FIRST X on uio_out = %b  <-- flash/UART datapath", $time, uio_out);
			end
			if (!x_uo && (^uo_out === 1'bx)) begin
				x_uo <= 1'b1;
				$display("[X-MON %0t] FIRST X on uo_out  = %b  <-- core/GPIO", $time, uo_out);
			end
			if (!x_miso && (vdb.spi_miso === 1'bx)) begin
				x_miso <= 1'b1;
				$display("[X-MON %0t] FIRST X on spi_miso  <-- FLASH MODEL output", $time);
			end

			// ---- inside the SoC (RTL only - no GL equivalent) ----
			if (!x_memaddr && (^dut.soc.mem_addr === 1'bx)) begin
				x_memaddr <= 1'b1;
				$display("[X-MON %0t] FIRST X on soc.mem_addr = %h  <-- CPU address bus!", $time, dut.soc.mem_addr);
			end
			if (!x_ramrd && (^dut.soc.ram_rdata === 1'bx)) begin
				x_ramrd <= 1'b1;
				$display("[X-MON %0t] FIRST X on soc.ram_rdata = %h (ram_ready=%b)",
				         $time, dut.soc.ram_rdata, dut.soc.ram_ready);
			end
			if (!x_memrd && dut.soc.mem_valid && dut.soc.ram_ready
			             && (^dut.soc.mem_rdata === 1'bx)) begin
				x_memrd <= 1'b1;
				$display("[X-MON %0t] FIRST X reaching CPU: soc.mem_rdata = %h  <-- X GOT THROUGH THE MUX",
				         $time, dut.soc.mem_rdata);
			end

			// ---- the out-of-range RAM index (tests the addr-width theory) ----
			// picosoc_mem declares mem[0:WORDS-1] but is addressed with 22
			// bits. Any index >= WORDS makes mem[addr] return 32'bx in RTL,
			// while synthesis has no out-of-range concept and aliases
			// instead - an RTL/gate divergence. Count how often it happens.
			if (dut.soc.memory.addr >= MEM_WORDS_TB) begin
				oor_count = oor_count + 1;
				if (!oor_first) begin
					oor_first <= 1'b1;
					$display("[X-MON %0t] out-of-range RAM index: memory.addr = %0d (WORDS = %0d)",
					         $time, dut.soc.memory.addr, MEM_WORDS_TB);
					$display("[X-MON]   -> mem[addr] returns X in RTL; the netlist aliases instead.");
					$display("[X-MON]   -> harmless only while ram_ready gates it out of mem_rdata.");
				end
			end
		end
	end

	// Inputs clean at reset release? Rules the stimulus in or out.
	initial begin
		@(posedge rst_n);
		@(posedge chip_clk);
		$display("[X-MON %0t] at reset release: ui_in=%b uio_in=%b uio_oe=%b",
		         $time, ui_in, uio_in, uio_oe);
		if ((^uio_in === 1'bx) || (^ui_in === 1'bx))
			$display("[X-MON] WARNING: DUT inputs contain X at reset release");
		else
			$display("[X-MON] DUT inputs fully defined at reset release");
	end


endmodule