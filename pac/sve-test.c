// SPDX-License-Identifier: GPL-2.0
/*
 * SVE and SME checks for an ILP32 or LP64 task (build with -march=armv9-a+sve2+sme):
 *   - AT_HWCAP SVE, AT_HWCAP2 SME
 *   - PR_SVE_GET_VL / PR_SVE_SET_VL, and rdvl follows the vector length
 *   - signal frame: a synchronous SIGILL (udf) with live Z registers; the handler finds them in the SVE
 *     record of the frame, clobbers the registers, and they are back after sigreturn
 *   - ptrace NT_ARM_SVE of a stopped child
 *   - SME: PR_SME_GET_VL, smstart/rdsvl/smstop, the same signal check in streaming mode (SVE record with
 *     SVE_SIG_FLAG_SM, ZA record, streaming mode on again after sigreturn), TPIDR2 kept over sleeps
 * Exit status 0 if all checks pass; 2 if the CPU has no SVE.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/auxv.h>
#include <sys/prctl.h>
#include <sys/ptrace.h>
#include <sys/uio.h>
#include <sys/wait.h>
#include <time.h>
#include <ucontext.h>
#include <unistd.h>
#include <asm/sigcontext.h>

#define BIT_SVE (1UL << 22)	/* AT_HWCAP */
#define BIT_SME (1UL << 23)	/* AT_HWCAP2 */
#ifndef PR_SVE_SET_VL
#define PR_SVE_SET_VL 50
#define PR_SVE_GET_VL 51
#endif
#ifndef PR_SME_SET_VL
#define PR_SME_SET_VL 63
#define PR_SME_GET_VL 64
#endif
#define VL_LEN_MASK 0xffff
#ifndef NT_ARM_SVE
#define NT_ARM_SVE 0x405
#endif

struct sve_header {		/* struct user_sve_header */
	uint32_t size, max_size;
	uint16_t vl, max_vl, flags, reserved;
};

static int failed;

#define CHECK(cond, ...)						\
	do {								\
		printf((cond) ? "ok   " : "FAIL ");			\
		failed += !(cond);					\
		printf(__VA_ARGS__);					\
		printf("\n");						\
	} while (0)

static uint64_t rdvl(void)
{
	uint64_t v;

	__asm__ volatile("rdvl %0, #1" : "=r"(v));
	return v;
}

/* byte k of register zN is n - 16 + k */
static int z_pattern_ok(const unsigned char *z, int n, unsigned int vl)
{
	for (unsigned int k = 0; k < vl; k++)
		if (z[k] != (unsigned char)(n - 16 + (int)k))
			return 0;
	return 1;
}

static uint64_t zbuf_addr;	/* 32 * the vector length, set before each run */
static unsigned char zbuf[32 * 256] __attribute__((aligned(16)));

/* fill z0..z31 with the pattern, udf (SIGILL, the handler skips it), store z0..z31 */
#define Z_PATTERN_UDF_STORE						\
	".irp n,0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31\n" \
	"index z\\n\\().b, #(\\n - 16), #1\n"				\
	".endr\n"							\
	"udf #0\n"							\
	".irp n,0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31\n" \
	"str z\\n, [%[buf], #\\n, mul vl]\n"				\
	".endr\n"

#define V_CLOBBERS							\
	"v0", "v1", "v2", "v3", "v4", "v5", "v6", "v7", "v8", "v9", "v10", "v11", "v12", "v13", "v14", \
	"v15", "v16", "v17", "v18", "v19", "v20", "v21", "v22", "v23", "v24", "v25", "v26", "v27", "v28", \
	"v29", "v30", "v31"

/* what the SIGILL handler saw */
static volatile int h_called, h_sve_found, h_sve_regs, h_sve_sm, h_za_found, h_regs_ok;
static volatile unsigned int h_sve_vl, h_za_vl, h_expect_vl;

static struct _aarch64_ctx *find_ctx(void *reserved, uint32_t magic)
{
	struct _aarch64_ctx *h = reserved;

	for (int i = 0; i < 64 && h->magic; i++) {
		if (h->magic == magic)
			return h;
		if (h->magic == EXTRA_MAGIC)
			h = (struct _aarch64_ctx *)(uintptr_t)((struct extra_context *)h)->datap;
		else
			h = (struct _aarch64_ctx *)((char *)h + h->size);
	}
	return NULL;
}

static void on_sigill(int sig, siginfo_t *si, void *ctx)
{
	ucontext_t *uc = ctx;
	struct sve_context *sve;
	struct _aarch64_ctx *za;

	(void)sig;
	(void)si;
	h_called++;
	sve = (struct sve_context *)find_ctx(uc->uc_mcontext.__reserved, SVE_MAGIC);
	za = find_ctx(uc->uc_mcontext.__reserved, ZA_MAGIC);
	h_sve_found = sve != NULL;
	h_za_found = za != NULL;
	if (za)
		h_za_vl = ((struct za_context *)za)->vl;
	if (sve) {
		unsigned int vq = sve_vq_from_vl(sve->vl);

		h_sve_vl = sve->vl;
		h_sve_sm = !!(sve->flags & SVE_SIG_FLAG_SM);
		h_sve_regs = sve->head.size >= SVE_SIG_CONTEXT_SIZE(vq);
		h_regs_ok = h_sve_regs && sve->vl == h_expect_vl;
		for (int n = 0; n < 32 && h_regs_ok; n++)
			h_regs_ok = z_pattern_ok((unsigned char *)sve + SVE_SIG_ZREG_OFFSET(vq, n), n, sve->vl);
	}
	/* clobber the (non-streaming) Z registers: sigreturn has to bring the frame's values back */
	__asm__ volatile(".irp n,0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31\n"
			 "dup z\\n\\().b, #0x5a\n"
			 ".endr\n" ::: V_CLOBBERS);
	uc->uc_mcontext.pc += 4;	/* skip the udf */
}

static int zbuf_ok(unsigned int vl)
{
	for (int n = 0; n < 32; n++)
		if (!z_pattern_ok(zbuf + (size_t)n * vl, n, vl))
			return 0;
	return 1;
}

static void reset_handler_state(unsigned int vl)
{
	h_called = h_sve_found = h_sve_regs = h_sve_sm = h_za_found = h_regs_ok = 0;
	h_sve_vl = h_za_vl = 0;
	h_expect_vl = vl;
	memset(zbuf, 0, sizeof(zbuf));
	zbuf_addr = (uint64_t)(uintptr_t)zbuf;
}

static void sve_signal(void)
{
	unsigned int vl = rdvl();

	reset_handler_state(vl);
	__asm__ volatile(Z_PATTERN_UDF_STORE : : [buf] "r"(zbuf_addr) : "memory", V_CLOBBERS);
	CHECK(h_called == 1 && h_sve_found && h_sve_regs && !h_sve_sm && h_regs_ok,
	      "signal frame: SVE record vl %u (want %u), Z registers in the frame: %s", h_sve_vl, vl,
	      h_regs_ok ? "match" : "wrong or missing");
	CHECK(zbuf_ok(vl), "Z registers restored by sigreturn");
}

static void sve_vl(void)
{
	long cur = prctl(PR_SVE_GET_VL, 0, 0, 0, 0);
	long r;

	CHECK(cur > 0 && (unsigned)(cur & VL_LEN_MASK) == rdvl(), "PR_SVE_GET_VL = 0x%lx, rdvl %llu", cur,
	      (unsigned long long)rdvl());
	if (cur <= 0)
		return;
	r = prctl(PR_SVE_SET_VL, 16, 0, 0, 0);
	CHECK(r >= 0 && rdvl() == 16, "PR_SVE_SET_VL(16) = 0x%lx, rdvl %llu", r, (unsigned long long)rdvl());
	sve_signal();		/* also with this vector length */
	r = prctl(PR_SVE_SET_VL, cur & VL_LEN_MASK, 0, 0, 0);
	CHECK(r >= 0 && rdvl() == (unsigned)(cur & VL_LEN_MASK), "PR_SVE_SET_VL back to %ld", cur & VL_LEN_MASK);
}

static void sve_ptrace(void)
{
	struct { struct sve_header h; unsigned char regs[16384]; } buf;
	struct iovec iov = { &buf, sizeof(buf) };
	unsigned int vl = rdvl();
	long r;
	pid_t pid = fork();

	if (pid == 0) {
		__asm__ volatile("index z0.b, #1, #1" ::: "v0");
		ptrace(PTRACE_TRACEME, 0, NULL, NULL);
		raise(SIGSTOP);
		_exit(0);
	}
	waitpid(pid, NULL, 0);
	memset(&buf, 0, sizeof(buf));
	r = ptrace(PTRACE_GETREGSET, pid, (void *)NT_ARM_SVE, &iov);
	ptrace(PTRACE_CONT, pid, NULL, NULL);
	waitpid(pid, NULL, 0);
	CHECK(r == 0 && buf.h.vl == vl && buf.h.max_vl >= vl, "ptrace NT_ARM_SVE = %ld: vl %u max_vl %u flags 0x%x",
	      r, buf.h.vl, buf.h.max_vl, buf.h.flags);
}

/* --- SME --- */

static uint64_t rdsvl(void)
{
	uint64_t v;

	__asm__ volatile("smstart\n"
			 "rdsvl %0, #1\n"
			 "smstop\n" : "=r"(v) : : V_CLOBBERS);
	return v;
}

static void sme_signal(unsigned int svl)
{
	uint64_t svcr = 0;

	reset_handler_state(svl);
	__asm__ volatile("smstart\n"
			 Z_PATTERN_UDF_STORE
			 "mrs %[svcr], svcr\n"
			 "smstop\n"
			 : [svcr] "=r"(svcr) : [buf] "r"(zbuf_addr) : "memory", V_CLOBBERS);
	CHECK(h_called == 1 && h_sve_found && h_sve_sm && h_regs_ok,
	      "streaming mode signal frame: SVE record vl %u (want %u) flags SM %d, Z registers: %s", h_sve_vl, svl,
	      h_sve_sm, h_regs_ok ? "match" : "wrong or missing");
	CHECK(h_za_found && h_za_vl == svl, "streaming mode signal frame: ZA record vl %u", h_za_vl);
	CHECK((svcr & 3) == 3 && zbuf_ok(svl), "after sigreturn: SVCR 0x%llx (SM and ZA on), Z registers restored: %s",
	      (unsigned long long)svcr, zbuf_ok(svl) ? "yes" : "no");
}

static void sme_tpidr2(void)
{
	const uint64_t want = 0x1234567890abcdefULL;
	struct timespec ts = { 0, 5 * 1000 * 1000 };
	uint64_t got;

	__asm__ volatile("msr tpidr2_el0, %0" : : "r"(want));
	for (int i = 0; i < 10; i++)
		nanosleep(&ts, NULL);
	__asm__ volatile("mrs %0, tpidr2_el0" : "=r"(got));
	CHECK(got == want, "TPIDR2 after 10 sleeps: 0x%llx", (unsigned long long)got);
}

static void sme(void)
{
	long cur = prctl(PR_SME_GET_VL, 0, 0, 0, 0);
	unsigned int svl;

	CHECK(cur > 0, "PR_SME_GET_VL = 0x%lx (errno %d)", cur, cur < 0 ? errno : 0);
	if (cur <= 0)
		return;
	svl = rdsvl();
	CHECK(svl == (unsigned)(cur & VL_LEN_MASK), "smstart, rdsvl %u, smstop", svl);
	sme_signal(svl);
	sme_tpidr2();
}

int main(void)
{
	unsigned long hwcap = getauxval(AT_HWCAP), hwcap2 = getauxval(AT_HWCAP2);
	struct sigaction sa = { .sa_sigaction = on_sigill, .sa_flags = SA_SIGINFO };

	printf("sve-test: %u-bit pointers, AT_HWCAP 0x%lx AT_HWCAP2 0x%lx\n", (unsigned)sizeof(void *) * 8, hwcap,
	       hwcap2);
	if (!(hwcap & BIT_SVE)) {
		printf("sve-test: no SVE\n");
		return 2;
	}
	sigaction(SIGILL, &sa, NULL);
	printf("ok   SVE vector length %llu bytes\n", (unsigned long long)rdvl());
	sve_signal();
	sve_vl();
	sve_ptrace();
	if (hwcap2 & BIT_SME)
		sme();
	else
		printf("sve-test: no SME\n");
	printf("sve-test: %d failed\n", failed);
	return failed != 0;
}
