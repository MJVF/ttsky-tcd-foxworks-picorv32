/*
 * spi_flash_model.v
 *
 * Synthesizable, oversampled SPI flash model for the ZU3 "virtual demo
 * board". Plays the role the (forked) spi-ram-emu firmware plays on the
 * real Tiny Tapeout demo board's RP2040, honouring the same contract:
 *
 *   - SPI mode 0, CS active low, MSB first
 *   - single supported command: 03h serial READ, 24-bit address,
 *     streaming sequential bytes for as long as CS stays low
 *   - every other command byte (spimemio's power-up sends FFh then ABh)
 *     is sunk until CS rises - exactly what the RP2040 firmware must do
 *   - 64 KB backing store; addresses wrap at 16 bits
 *
 * Single 200 MHz clock (8x oversampling of the 25 MHz SCK). SCK/CS/MOSI
 * are double-synchronized. Mode-0 discipline as implemented here:
 * a presented MISO bit is "consumed" by the master on an SCK rising
 * edge; the model advances to the next bit right after that rising edge
 * (~15 ns later through the synchronizers), leaving ~25 ns of setup to
 * the next rising edge at 25 MHz SCK.
 *
 * The 64 KB store is an inferred simple-dual-port BRAM: one write port
 * (AXI-Lite loader in tt_virtual_demoboard.v) and one read port shared
 * between the SPI prefetcher (priority) and loader readback.
 */

`default_nettype none

module spi_flash_model (
	input  wire        clk,        // 125 MHz
	input  wire        rst_n,

	// SPI slave pins (already pad/oe-resolved by the caller)
	input  wire        spi_sck,
	input  wire        spi_csb,
	input  wire        spi_mosi,   // IO0
	output wire        spi_miso,   // IO1

	// Loader port (synchronous to clk)
	input  wire        ld_wen,
	input  wire [13:0] ld_waddr,   // word address (64 KB / 4)
	input  wire [31:0] ld_wdata,
	input  wire [3:0]  ld_wstrb,
	input  wire [13:0] ld_raddr,
	output reg  [31:0] ld_rdata
);
	// ------------------------------------------------------------------
	// 64 KB backing store, word-organized little-endian:
	// flash byte address b lives in mem[b[15:2]][8*b[1:0] +: 8]
	// (matches spimemio's rdata assembly {b3,b2,b1,b0}).
	// ------------------------------------------------------------------
	reg [31:0] mem [0:16383];

`ifdef SIM
	// In simulation the image is preloaded instead of written over AXI:
	// one 32-bit hex word per line (fw/fw32.hex).
	integer i;
	reg [1023:0] firmware_file;
	initial begin
		for (i = 0; i < 16384; i = i + 1)
			mem[i] = 32'h0000_0000;
		if ($value$plusargs("firmware=%s", firmware_file))
			$readmemh(firmware_file, mem);
	end
`endif

	reg         spi_fetch;      // one-shot read request from the FSM
	reg  [13:0] spi_word_addr;
	reg  [31:0] spi_word;

	// One write port + one (shared, SPI-priority) read port.
	always @(posedge clk) begin
		if (ld_wen) begin
			if (ld_wstrb[0]) mem[ld_waddr][ 7: 0] <= ld_wdata[ 7: 0];
			if (ld_wstrb[1]) mem[ld_waddr][15: 8] <= ld_wdata[15: 8];
			if (ld_wstrb[2]) mem[ld_waddr][23:16] <= ld_wdata[23:16];
			if (ld_wstrb[3]) mem[ld_waddr][31:24] <= ld_wdata[31:24];
		end
		if (spi_fetch)
			spi_word <= mem[spi_word_addr];
		else
			ld_rdata <= mem[ld_raddr];
	end

	// ------------------------------------------------------------------
	// Input synchronizers and SCK edge detection
	// ------------------------------------------------------------------
	reg [2:0] sck_q, csb_q, mosi_q;
	always @(posedge clk) begin
		sck_q  <= {sck_q[1:0],  spi_sck};
		csb_q  <= {csb_q[1:0],  spi_csb};
		mosi_q <= {mosi_q[1:0], spi_mosi};
	end
	wire sck_rise  = (sck_q[1] && !sck_q[2]);
	wire cs_active = !csb_q[1];
	wire mosi_s    = mosi_q[1];

	// ------------------------------------------------------------------
	// Protocol FSM
	// ------------------------------------------------------------------
	localparam [1:0] ST_CMD  = 2'd0;  // shifting command byte in
	localparam [1:0] ST_ADDR = 2'd1;  // shifting 24 address bits in
	localparam [1:0] ST_DATA = 2'd2;  // streaming data bytes out
	localparam [1:0] ST_SINK = 2'd3;  // unknown command: ignore to CS high

	reg [1:0]  state;
	reg [7:0]  shreg_in;    // command shift register
	reg [4:0]  field_cnt;   // bit counter for CMD/ADDR fields
	reg [23:0] addr;        // byte address, incremented while streaming
	reg [7:0]  oshift;      // outgoing byte, MSB at [7]
	reg [2:0]  data_bit;    // bits of current byte consumed so far

	function [7:0] byte_lane(input [31:0] w, input [1:0] sel);
		case (sel)
			2'd0: byte_lane = w[ 7: 0];
			2'd1: byte_lane = w[15: 8];
			2'd2: byte_lane = w[23:16];
			2'd3: byte_lane = w[31:24];
		endcase
	endfunction

	assign spi_miso = (state == ST_DATA) ? oshift[7] : 1'b0;

	always @(posedge clk) begin
		spi_fetch <= 1'b0;

		if (!rst_n || !cs_active) begin
			// CS high aborts/completes the transaction - this is also how
			// FFh/ABh and any half-finished command are discarded.
			state     <= ST_CMD;
			field_cnt <= 5'd0;
			data_bit  <= 3'd0;
		end else begin
			case (state)
				ST_CMD: if (sck_rise) begin
					shreg_in  <= {shreg_in[6:0], mosi_s};
					field_cnt <= field_cnt + 5'd1;
					if (field_cnt == 5'd7) begin
						field_cnt <= 5'd0;
						state <= ({shreg_in[6:0], mosi_s} == 8'h03)
						         ? ST_ADDR : ST_SINK;
					end
				end

				ST_ADDR: if (sck_rise) begin
					addr      <= {addr[22:0], mosi_s};
					field_cnt <= field_cnt + 5'd1;
					if (field_cnt == 5'd21) begin
						// 22 address bits now known = final addr[23:2];
						// its low 14 bits are the 64 KB word address.
						// Fetch early: the word is in spi_word ~2 SCK
						// before the first data bit is needed.
						spi_word_addr <= {addr[12:0], mosi_s};
						spi_fetch     <= 1'b1;
					end
					if (field_cnt == 5'd23) begin
						// Full 24-bit address = {addr[22:0], mosi_s};
						// byte lane = its low two bits.
						oshift    <= byte_lane(spi_word, {addr[0], mosi_s});
						field_cnt <= 5'd0;
						data_bit  <= 3'd0;
						state     <= ST_DATA;
					end
				end

				ST_DATA: if (sck_rise) begin
					// The rising edge consumed oshift[7].
					if (data_bit == 3'd0 && addr[1:0] == 2'd3) begin
						// First bit of a lane-3 byte: prefetch the next
						// word now (7 SCK of margin; the current byte is
						// already latched in oshift, so clobbering
						// spi_word is safe).
						spi_word_addr <= addr[15:2] + 14'd1;
						spi_fetch     <= 1'b1;
					end
					if (data_bit == 3'd7) begin
						// Byte finished: load the next lane; a lane wrap
						// (3 -> 0) picks up the freshly prefetched word.
						oshift   <= byte_lane(spi_word, addr[1:0] + 2'd1);
						addr     <= addr + 24'd1;
						data_bit <= 3'd0;
					end else begin
						oshift   <= {oshift[6:0], 1'b0};
						data_bit <= data_bit + 3'd1;
					end
				end

				ST_SINK: ;  // swallow everything until CS rises

				default: state <= ST_CMD;
			endcase
		end
	end

endmodule

`default_nettype wire
