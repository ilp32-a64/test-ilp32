// SPDX-License-Identifier: GPL-2.0
// A program without the C library, built with -mbranch-protection=bti so that the linker gives it a
// GNU property note (GNU_PROPERTY_AARCH64_FEATURE_1_BTI). The kernel parses that note at exec.
static long sys(long nr, long a, long b, long c)
{
	register long x8 __asm__("x8") = nr;
	register long x0 __asm__("x0") = a;
	register long x1 __asm__("x1") = b;
	register long x2 __asm__("x2") = c;

	__asm__ volatile("svc #0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2) : "memory");
	return x0;
}

static const char msg[] = "bti-nolibc: ok\n";

/* an indirect call: with BTI enforced (PROT_BTI pages) the callee needs its BTI landing pad */
static __attribute__((noinline)) long say(void)
{
	return sys(64, 1, (long)msg, sizeof(msg) - 1);	/* write */
}

static long (*volatile say_ptr)(void) = say;

void _start(void)
{
	sys(93, say_ptr() == sizeof(msg) - 1 ? 0 : 1, 0, 0);	/* exit */
	for (;;)
		;
}
