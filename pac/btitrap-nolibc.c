// SPDX-License-Identifier: GPL-2.0
// BTI enforcement check without the C library: built with -mbranch-protection=bti (GNU property note
// with BTI), but the indirect call goes to a function without a BTI landing pad. With BTI enforced the
// call raises SIGILL; on a CPU without BTI the function returns and the program exits with 1.
static long sys(long nr, long a, long b, long c)
{
	register long x8 __asm__("x8") = nr;
	register long x0 __asm__("x0") = a;
	register long x1 __asm__("x1") = b;
	register long x2 __asm__("x2") = c;

	__asm__ volatile("svc #0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2) : "memory");
	return x0;
}

static const char msg[] = "btitrap-nolibc: returned from a function without a landing pad (BTI not enforced)\n";

static __attribute__((noinline, target("branch-protection=none"))) long no_pad(void)
{
	return sys(64, 1, (long)msg, sizeof(msg) - 1);	/* write */
}

static long (*volatile no_pad_ptr)(void) = no_pad;

void _start(void)
{
	no_pad_ptr();
	sys(93, 1, 0, 0);	/* exit */
	for (;;)
		;
}
