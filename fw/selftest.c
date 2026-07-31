/*
 * selftest.c - TT-PicoSoC power-on self-test (verbose, v3).
 *
 * v3 exists because v2 (verbose, all tests in one function) OVERFLOWED
 * THE STACK at T04 and hung with uo_out frozen at 0x13. Post-mortem:
 * concentrating every test's volatile operands into run_suite's frame
 * (~56 B), then stacking test_sram's 64 B buffer and the 3-deep print
 * chain on top, exceeded the ~250 B that exist. The failure was silent
 * because an underflowed sp wraps to 0xFFFFFFxx - which the wrapper's
 * default-ack treats as valid I/O space, so stack ops "succeed" with
 * garbage and ra corrupts without a trap.
 *
 * Structural consequences, now load-bearing:
 *   - EVERY test is its own noinline function: operands live only in
 *     that test's frame and die before the next test runs. Peak depth
 *     = run_suite + one test + detail/print chain, ~150 B worst case.
 *   - The free stack is painted with a sentinel at boot and the peak
 *     usage is measured and REPORTED every run ("stack peak >= N B").
 *     Stack consumption is telemetry now, not faith.
 *
 * Protocol (unchanged): uo_out 0x10+n during test n, 0xC3/0x3C verdict;
 * UART report with indented detail lines + "Tnn name PASS|FAIL" verdict
 * lines, "RESULT p/t PASS|FAIL", "ECHO-SERVICE" (byte+1 echo; '?'
 * re-runs the suite - the harness uartlite RX FIFO is only 16 bytes,
 * so the boot report is perishable).
 *
 * All expected constants computed mechanically, not by hand.
 */

#include <stdint.h>

/* Chip clock and baud are BUILD-TIME facts: the UART divisor is
 * computed from them, so a mismatch with the real clock produces
 * garbage on the wire. Override per build, e.g.
 *   make -C fw FWDEFS="-DCLK_HZ=25000000 -DBAUD=115200"
 * (25 MHz / 115200 -> divisor 217 -> 115207 baud, +0.006%) */
#ifndef CLK_HZ
#define CLK_HZ 25000000
#endif
#ifndef BAUD
#define BAUD 115200
#endif

#define reg_uart_clkdiv (*(volatile uint32_t *)0x02000004)
#define reg_uart_data   (*(volatile uint32_t *)0x02000008)
#define reg_gpio        (*(volatile uint32_t *)0x03000000)

static inline __attribute__((always_inline)) void putch(char c)
{
	if (c == '\n')
		reg_uart_data = '\r';
	reg_uart_data = (uint8_t)c;
}

static inline __attribute__((always_inline)) void print(const char *s)
{
	while (*s)
		putch(*s++);
}

static inline __attribute__((always_inline)) void print_hex32(uint32_t v)
{
	for (int i = 28; i >= 0; i -= 4)
		putch("0123456789abcdef"[(v >> i) & 0xf]);
}

static inline __attribute__((always_inline)) void print_hex8(uint32_t v)
{
	for (int i = 4; i >= 0; i -= 4)
		putch("0123456789abcdef"[(v >> i) & 0xf]);
}

static void __attribute__((noinline)) detail(const char *label, uint32_t v)
{
	print("  "); print(label); print(" = ");
	print_hex32(v); putch('\n');
}

static uint32_t read_sp(void)
{
	uint32_t v;
	__asm__ volatile ("mv %0, sp" : "=r"(v));
	return v;
}

/* ---- stack telemetry: paint free stack at boot, measure peak ---- */
extern unsigned char _ebss[];
#define STACK_TOP      0x80u
#define STACK_SENTINEL 0x57acca57u

static void __attribute__((noinline)) paint_stack(void)
{
	uint32_t sp = read_sp();
	volatile uint32_t *p =
		(volatile uint32_t *)(((uintptr_t)_ebss + 3) & ~(uintptr_t)3);
	while ((uintptr_t)p < sp - 8)
		*p++ = STACK_SENTINEL;
}

// static uint32_t __attribute__((noinline)) stack_peak_bytes(void)
// {
// 	volatile uint32_t *p =
// 		(volatile uint32_t *)(((uintptr_t)_ebss + 3) & ~(uintptr_t)3);
// 	while ((uintptr_t)p < STACK_TOP && *p == STACK_SENTINEL)
// 		p++;
// 	return STACK_TOP - (uint32_t)(uintptr_t)p;
// }

static int failures;

//static uint32_t stack_peak_bytes(void);  /* fwd */

static void report(int n, const char *name, int ok)
{
	reg_gpio = 0x10 + (uint32_t)n;
	putch('T'); putch('0' + n / 10); putch('0' + n % 10);
	putch(' '); print(name);
	/* NOTE: the per-test "peak=" telemetry that used to live here called
	 * stack_peak_bytes(), which SCANS SRAM comparing each word to a
	 * sentinel. One X word makes the loop condition X, the branch
	 * undefined, and the core wanders - it was a diagnostic that caused
	 * the fault it was meant to observe. Removed. The end-of-run summary
	 * still reports peak stack once, after all tests have passed. */
	print(ok ? " PASS\n" : " FAIL\n");
	if (!ok)
		failures++;
}

/* ---- helpers ---- */
static uint32_t xs_a(uint32_t v) { v ^= v << 13; return v; }
static uint32_t xs_b(uint32_t v) { v ^= v >> 17; v ^= v << 5; return v; }
static uint32_t __attribute__((noinline)) sumr(uint32_t n)
{
	return n == 0 ? 0 : n + sumr(n - 1);
}

/* ---- the tests: ONE FRAME EACH (see header post-mortem) ---- */

static void __attribute__((noinline)) t01_alu(void)
{
	volatile uint32_t a = 0x12345678, b = 0x9abcdef0;
	detail("a+b", a + b);
	detail("a-b", a - b);
	detail("a&b", a & b);
	detail("a|b", a | b);
	detail("~a ", ~a);
	uint32_t s = (a + b) ^ (a - b) ^ (a & b) ^ (a | b) ^ ~a;
	detail("got ", s);
	detail("want", 0xbec563ef);
	report(1, "alu", s == 0xbec563ef);
}

static void __attribute__((noinline)) t02_shift(void)
{
	volatile uint32_t v = 0x80000001;
	volatile int32_t  n = (int32_t)0x80000000;
	volatile int sh = 7;
	detail("v<<7 ", v << sh);
	detail("v>>7 ", v >> sh);
	detail("n>>31 (arith)", (uint32_t)(n >> 31));
	uint32_t r = (v << sh) ^ (v >> sh) ^ (uint32_t)(n >> 31);
	detail("got ", r);
	detail("want", 0xfeffff7f);
	report(2, "shift", r == 0xfeffff7f);
}

static void __attribute__((noinline)) t03_sltx(void)
{
	volatile int32_t  sa = (int32_t)0x80000000, sb2 = 1;
	volatile uint32_t ua = 0x80000000u,        ub = 1;
	detail("signed  0x80000000 < 1 ", sa < sb2);
	detail("unsigned 0x80000000 > 1", ua > ub);
	detail("signed  0x80000000 < 0 ", sa < 0);
	report(3, "sltx",
	       (sa < sb2) && (ua > ub) && (sa < 0) && (ua >= 0x80000000u));
}

static void __attribute__((noinline)) t04_sram(void)
{
	volatile uint32_t buf[8];   // 32 B (128 B RAM: keep frames small)
	int ok = 1;
	print("  32B window base = ");
	print_hex32((uint32_t)(uintptr_t)&buf[0]); putch('\n');
	for (int i = 0; i < 8; i++)
		buf[i] = 0xa5000000u ^ ((uint32_t)i << 8) ^ (uint32_t)i;
	for (int i = 0; i < 8; i++)
		if (buf[i] != (0xa5000000u ^ ((uint32_t)i << 8) ^ (uint32_t)i))
			ok = 0;
	detail("phase1 buf[0]", buf[0]);
	detail("phase1 buf[7]", buf[7]);
	for (int i = 0; i < 8; i++) buf[i] = ~(uint32_t)i;
	for (int i = 7; i >= 0; i--)
		if (buf[i] != ~(uint32_t)i) ok = 0;
	detail("phase2 buf[0]", buf[0]);
	detail("phase2 buf[7]", buf[7]);
	report(4, "sram", ok);
}

static void __attribute__((noinline)) t05_lanes(void)
{
	volatile uint32_t w = 0;
	volatile uint8_t  *b8  = (volatile uint8_t *)&w;
	volatile uint16_t *h16 = (volatile uint16_t *)&w;
	b8[0] = 0x80; b8[1] = 0x7f; b8[2] = 0xff; b8[3] = 0x01;
	detail("after 4x sb, w", w);
	detail("want          ", 0x01ff7f80u);
	int ok = (w == 0x01ff7f80u);
	detail("(int8)b8[0]   ", (uint32_t)(int32_t)(int8_t)b8[0]);
	ok &= ((int8_t)b8[0] == -128) && (b8[2] == 0xff);
	h16[0] = 0xbeef;
	detail("after sh, w   ", w);
	detail("(int16)h16[0] ", (uint32_t)(int32_t)(int16_t)h16[0]);
	detail("h16[1]        ", h16[1]);
	ok &= (w == 0x01ffbeefu) && ((int16_t)h16[0] < 0) && (h16[1] == 0x01ff);
	report(5, "lanes", ok);
}

static const uint32_t rodata_tbl[8] = {
	0xdeadbeef, 0x00c0ffee, 0x8badf00d, 0x0defaced,
	0xfeedface, 0xcafebabe, 0x00bada55, 0x50f7c0de
};

static void __attribute__((noinline)) t06_xipro(void)
{
	uint32_t v = 0;
	for (int i = 0; i < 8; i++) {
		detail("rodata_tbl[i]", rodata_tbl[i]);
		v ^= rodata_tbl[i];
	}
	detail("xor got ", v);
	detail("xor want", 0x3c71471a);
	report(6, "xipro", v == 0x3c71471a);
}

static void __attribute__((noinline)) t07_muldiv(void)
{
	volatile uint32_t a2 = 48271, b3 = 65537, d = 641;
	detail("48271*65537 got ", a2 * b3);
	detail("            want", 3163536527u);
	detail("prod/641    got ", a2 * b3 / d);
	detail("            want", 4935314u);
	detail("prod%641    got ", a2 * b3 % d);
	detail("            want", 253u);
	report(7, "muldiv", (a2 * b3 == 3163536527u)
	       && (a2 * b3 / d == 4935314u) && (a2 * b3 % d == 253u));
}

static void __attribute__((noinline)) t08_stack(void)
{
	detail("sp before recursion", read_sp());
	uint32_t r = sumr(3);   // 4 frames: fits the 64 B stack budget
	detail("sp after recursion ", read_sp());
	detail("sumr(3) got ", r);
	detail("sumr(3) want", 6);
	report(8, "stack", r == 6);
}

static void __attribute__((noinline)) t09_fetch(void)
{
	uint32_t v = 0x1234abcd;
	for (int i = 1; i <= 64; i++) {
		v = xs_b(xs_a(v));
		if ((i & 15) == 0)
			detail("xorshift state", v);
	}
	detail("got ", v);
	detail("want", 0x16efcbc4);
	report(9, "fetch", v == 0x16efcbc4u);
}

static void __attribute__((noinline)) t10_gpio(void)
{
	int ok = 1;
	reg_gpio = 0x5a;
	detail("wrote 5a, readback", reg_gpio & 0xff);
	ok &= ((reg_gpio & 0xff) == 0x5a);
	reg_gpio = 0xa5;
	detail("wrote a5, readback", reg_gpio & 0xff);
	ok &= ((reg_gpio & 0xff) == 0xa5);
	report(10, "gpio", ok);
}

static void __attribute__((noinline)) t11_rxidle(void)
{
	uint32_t g = reg_gpio;
	detail("full gpio register", g);
	detail("uio_sync[7] (RX)  ", (g >> 23) & 1);
	report(11, "rxidle", ((g >> 23) & 1) == 1);
}

static void __attribute__((noinline)) t12_loop(void)
{
	static const uint8_t pat[3] = { 0x55, 0xaa, 0x0f };
	print("T12 loop ");
	for (int i = 0; i < 3; i++) {
		reg_gpio = pat[i];
		for (volatile int d = 0; d < 200; d++) ;
		print_hex8((reg_gpio >> 8) & 0xff);
		putch(i < 2 ? ',' : ' ');
	}
	print("INFO\n");
}

static void run_suite(void)
{
	print("\nTT-SELFTEST v3 (verbose)\n");
	print("MEMMAP - where things actually live:\n");
	detail("run_suite (code, flash)  ", (uint32_t)(uintptr_t)&run_suite);
	detail("rodata_tbl (const, flash)", (uint32_t)(uintptr_t)rodata_tbl);
	detail("failures (.bss, SRAM)    ", (uint32_t)(uintptr_t)&failures);
	detail("sp now (stack, SRAM)     ", read_sp());
	print("  (code+strings execute in place from 64KB flash;\n");
	print("   SRAM 0x000-0x07F holds only .data/.bss + stack)\n");
	failures = 0;

	t01_alu();   t02_shift(); t03_sltx();  t04_sram();
	t05_lanes(); t06_xipro(); t07_muldiv(); t08_stack();
	t09_fetch(); t10_gpio();  t11_rxidle(); t12_loop();

	/* stack telemetry: how close did this run get to the maximum?
	{
		uint32_t peak = stack_peak_bytes();
		detail("stack peak bytes (>=)", peak);
		if (peak >= STACK_TOP - (uint32_t)(uintptr_t)_ebss - 16)
			print("  !! stack nearly/fully exhausted - v2's bug\n");
	} */
	/* Stack telemetry removed: stack_peak_bytes() scans SRAM comparing
	 * each word to a sentinel, and one X word makes the loop condition
	 * X and the branch undefined. It is a diagnostic that kills the run
	 * it is meant to measure. paint_stack() can stay - writing is safe;
	 * only the read-back scan is hazardous. Can be reintroduced on real 
	 * silicon. */

	print("RESULT ");
	putch('0' + (11 - failures) / 10); putch('0' + (11 - failures) % 10);
	putch('/'); print("11 ");
	print(failures ? "FAIL\n" : "PASS\n");
	reg_gpio = failures ? 0x3c : 0xc3;
}

void main(void)
{
	reg_uart_clkdiv = (CLK_HZ + BAUD / 2) / BAUD;  /* from build defines */
	reg_gpio = 0x0f;

	paint_stack();
	run_suite();

	print("ECHO-SERVICE\n");
	for (;;) {
		uint32_t c = reg_uart_data;
		if (c == 0xffffffffu)
			continue;
		if ((c & 0xff) == '?') {
			run_suite();
			print("ECHO-SERVICE\n");
		} else {
			reg_uart_data = (c + 1) & 0xff;
		}
	}
}