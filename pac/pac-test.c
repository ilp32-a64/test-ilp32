// SPDX-License-Identifier: GPL-2.0
/*
 * Pointer authentication (PAC) checks for an ILP32 or LP64 task. Built with
 * -mbranch-protection=pac-ret where the compiler supports it, so that the calls, signal handlers
 * and longjmp below also run with signed return addresses.
 *   - AT_HWCAP has PACA and PACG
 *   - the instruction keys are enabled: signing changes a pointer, authenticating gives it back,
 *     a wrong modifier fails (SIGILL with FEAT_FPAC, or a corrupted pointer)
 *   - fork keeps the keys, exec gives new ones
 *   - prctl: PR_PAC_GET_ENABLED_KEYS, PR_PAC_RESET_KEYS, PR_PAC_SET_ENABLED_KEYS
 *   - ptrace: NT_ARM_PAC_MASK and NT_ARM_PAC_ENABLED_KEYS of a stopped child
 * Exit status 0 if all checks pass.
 */
#include <elf.h>
#include <errno.h>
#include <setjmp.h>
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
#include <unistd.h>

#ifndef PR_PAC_RESET_KEYS
#define PR_PAC_RESET_KEYS 54
#endif
#ifndef PR_PAC_SET_ENABLED_KEYS
#define PR_PAC_SET_ENABLED_KEYS 60
#define PR_PAC_GET_ENABLED_KEYS 61
#endif
#define KEY_APIA (1UL << 0)
#define KEY_ALL 0xfUL		/* APIA, APIB, APDA, APDB */
#ifndef NT_ARM_PAC_ENABLED_KEYS
#define NT_ARM_PAC_ENABLED_KEYS 0x40a
#endif
#define BIT_PACA (1UL << 30)
#define BIT_PACG (1UL << 31)

static int failed;

#define CHECK(cond, ...)						\
	do {								\
		if (cond) {						\
			printf("ok   ");				\
		} else {						\
			printf("FAIL ");				\
			failed++;					\
		}							\
		printf(__VA_ARGS__);					\
		printf("\n");						\
	} while (0)

/* PACIA1716 / AUTIA1716 (HINT space): sign / authenticate x17 with key IA and modifier x16 */
static uint64_t pacia(uint64_t p, uint64_t mod)
{
	register uint64_t x17 __asm__("x17") = p;
	register uint64_t x16 __asm__("x16") = mod;

	__asm__ volatile("hint #8" : "+r"(x17) : "r"(x16));
	return x17;
}

static uint64_t autia(uint64_t p, uint64_t mod)
{
	register uint64_t x17 __asm__("x17") = p;
	register uint64_t x16 __asm__("x16") = mod;

	__asm__ volatile("hint #12" : "+r"(x17) : "r"(x16));
	return x17;
}

static int anchor;
#define PTR ((uint64_t)(uintptr_t)&anchor)
#define MOD 0x1234

/*
 * The PAC field is only a few bits wide with 52-bit virtual addresses (3 bits on QEMU -cpu max), so
 * one signature equals the plain pointer quite often: sign with NMOD modifiers and compare all.
 */
#define NMOD 16

struct sigs {
	uint64_t v[NMOD];
};

static struct sigs sign_all(void)
{
	struct sigs s;

	for (int i = 0; i < NMOD; i++)
		s.v[i] = pacia(PTR, MOD + i);
	return s;
}

static int all_plain(const struct sigs *s)
{
	for (int i = 0; i < NMOD; i++)
		if (s->v[i] != PTR)
			return 0;
	return 1;
}

static int same_sigs(const struct sigs *a, const struct sigs *b)
{
	return !memcmp(a, b, sizeof(*a));
}

/* FNV-1a over the signatures, to pass them through a pipe */
static uint64_t sigs_hash(const struct sigs *s)
{
	const unsigned char *p = (const unsigned char *)s;
	uint64_t h = 0xcbf29ce484222325ULL;

	for (size_t i = 0; i < sizeof(*s); i++)
		h = (h ^ p[i]) * 0x100000001b3ULL;
	return h;
}

static sigjmp_buf trap_env;

static void on_sigill(int sig)
{
	(void)sig;
	siglongjmp(trap_env, 1);
}

/*
 * autia of the signature for modifier i with modifier j, where the two signatures differ: 1 if it
 * trapped (FEAT_FPAC) or returned a corrupted pointer
 */
static int wrong_modifier_fails(const struct sigs *s)
{
	struct sigaction sa = { .sa_handler = on_sigill }, old;
	volatile uint64_t r = 0;
	int i, j = -1, trapped;

	for (i = 1; i < NMOD && j < 0; i++)
		if (s->v[i] != s->v[0])
			j = i;
	if (j < 0)
		return 0;
	sigaction(SIGILL, &sa, &old);
	trapped = sigsetjmp(trap_env, 1);
	if (!trapped)
		r = autia(s->v[0], MOD + j);
	sigaction(SIGILL, &old, NULL);
	printf("     wrong modifier: %s\n", trapped ? "SIGILL (FEAT_FPAC)" : "corrupted pointer");
	return trapped || r != PTR;
}

/* --- return address signing through calls, signal handlers and longjmp --- */

static int (*volatile fp)(int);
static jmp_buf jmp_env;
static sigjmp_buf sig_env;
static volatile int handled;

static int recurse(int n)
{
	return n ? fp(n - 1) + 1 : 0;
}

/* the recursion ends in longjmp, which GCC counts as not returning */
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Winfinite-recursion"
static __attribute__((noinline)) void deep_longjmp(int n)
{
	if (n)
		deep_longjmp(n - 1);
	else
		longjmp(jmp_env, 7);
	__asm__ volatile("");
}
#pragma GCC diagnostic pop

static void on_usr1(int sig)
{
	(void)sig;
	handled = recurse(100);
}

static void on_usr2(int sig)
{
	(void)sig;
	siglongjmp(sig_env, 1);
}

static __attribute__((noinline)) void deep_raise(int n)
{
	if (n)
		deep_raise(n - 1);
	else
		raise(SIGUSR2);
	__asm__ volatile("");
}

static void calls(void)
{
	fp = recurse;
	CHECK(recurse(1000) == 1000, "1000 nested calls through a function pointer");
	CHECK(setjmp(jmp_env) ? 1 : (deep_longjmp(50), 0), "longjmp out of 50 frames");
	signal(SIGUSR1, on_usr1);
	raise(SIGUSR1);
	CHECK(handled == 100, "signal handler with 100 nested calls");
	signal(SIGUSR2, on_usr2);
	CHECK(sigsetjmp(sig_env, 1) ? 1 : (deep_raise(50), 0), "siglongjmp out of a signal handler, 50 frames");
}

/* --- keys --- */

static uint64_t child_signature(char *self, int do_exec)
{
	int p[2];
	char buf[32] = "";
	pid_t pid;

	if (pipe(p))
		return 0;
	pid = fork();
	if (pid == 0) {
		close(p[0]);
		if (do_exec) {
			char fd[16];
			char *argv[] = { self, "--sign", fd, NULL };

			snprintf(fd, sizeof(fd), "%d", p[1]);
			execv(self, argv);
			_exit(127);
		}
		struct sigs s = sign_all();

		dprintf(p[1], "%llx", (unsigned long long)sigs_hash(&s));
		_exit(0);
	}
	close(p[1]);
	if (read(p[0], buf, sizeof(buf) - 1) < 0)
		buf[0] = 0;
	close(p[0]);
	waitpid(pid, NULL, 0);
	return strtoull(buf, NULL, 16);
}

/* in a child: changing key IA invalidates the signed return addresses of the live frames, so the
 * child never returns from here */
static __attribute__((noreturn)) void key_changes(void)
{
	struct sigs s0 = sign_all(), s1, s2, s3;
	long r, en;
	int ok, bad = 0;

	r = prctl(PR_PAC_RESET_KEYS, KEY_APIA, 0, 0, 0);
	s1 = sign_all();
	ok = r == 0 && !same_sigs(&s0, &s1);
	printf("%s PR_PAC_RESET_KEYS(APIA) = %ld, signatures changed: %s\n", ok ? "ok  " : "FAIL", r,
	       same_sigs(&s0, &s1) ? "no" : "yes");
	bad += !ok;

	r = prctl(PR_PAC_SET_ENABLED_KEYS, KEY_APIA, 0, 0, 0);
	s2 = sign_all();
	en = prctl(PR_PAC_GET_ENABLED_KEYS, 0, 0, 0, 0);
	ok = r == 0 && all_plain(&s2) && en == (long)(KEY_ALL & ~KEY_APIA);
	printf("%s PR_PAC_SET_ENABLED_KEYS(APIA off) = %ld, enabled 0x%lx, signing is a NOP: %s\n",
	       ok ? "ok  " : "FAIL", r, en, all_plain(&s2) ? "yes" : "no");
	bad += !ok;

	r = prctl(PR_PAC_SET_ENABLED_KEYS, KEY_APIA, KEY_APIA, 0, 0);
	s3 = sign_all();
	ok = r == 0 && same_sigs(&s1, &s3);
	printf("%s PR_PAC_SET_ENABLED_KEYS(APIA on) = %ld, signatures as before: %s\n", ok ? "ok  " : "FAIL",
	       r, same_sigs(&s1, &s3) ? "yes" : "no");
	bad += !ok;
	fflush(stdout);
	_exit(bad);
}

struct pac_mask {
	uint64_t data_mask;
	uint64_t insn_mask;
};

static void ptrace_regsets(void)
{
	struct pac_mask m = { 0, 0 };
	uint64_t keys = 0;
	struct iovec iov;
	long r1, r2;
	pid_t pid = fork();

	if (pid == 0) {
		ptrace(PTRACE_TRACEME, 0, NULL, NULL);
		raise(SIGSTOP);
		_exit(0);
	}
	waitpid(pid, NULL, 0);
	iov.iov_base = &m;
	iov.iov_len = sizeof(m);
	r1 = ptrace(PTRACE_GETREGSET, pid, (void *)NT_ARM_PAC_MASK, &iov);
	iov.iov_base = &keys;
	iov.iov_len = sizeof(keys);
	r2 = ptrace(PTRACE_GETREGSET, pid, (void *)NT_ARM_PAC_ENABLED_KEYS, &iov);
	ptrace(PTRACE_CONT, pid, NULL, NULL);
	waitpid(pid, NULL, 0);
	CHECK(r1 == 0 && m.data_mask && m.data_mask == m.insn_mask,
	      "ptrace NT_ARM_PAC_MASK = %ld: data 0x%llx insn 0x%llx", r1,
	      (unsigned long long)m.data_mask, (unsigned long long)m.insn_mask);
	CHECK(r2 == 0 && keys == KEY_ALL, "ptrace NT_ARM_PAC_ENABLED_KEYS = %ld: 0x%llx", r2,
	      (unsigned long long)keys);
}

int main(int argc, char **argv)
{
	unsigned long hwcap = getauxval(AT_HWCAP);
	struct sigs s;
	int st, plain = 0, back = 1;

	if (argc == 3 && !strcmp(argv[1], "--sign")) {
		s = sign_all();
		dprintf(atoi(argv[2]), "%llx", (unsigned long long)sigs_hash(&s));
		return 0;
	}

	printf("pac-test: %u-bit pointers\n", (unsigned)sizeof(void *) * 8);
	CHECK((hwcap & BIT_PACA) && (hwcap & BIT_PACG), "AT_HWCAP 0x%lx: PACA %d PACG %d", hwcap,
	      !!(hwcap & BIT_PACA), !!(hwcap & BIT_PACG));
	if (!(hwcap & BIT_PACA))
		return 1;

	s = sign_all();
	for (int i = 0; i < NMOD; i++) {
		plain += s.v[i] == PTR;
		back &= autia(s.v[i], MOD + i) == PTR;
	}
	CHECK(plain < NMOD && back, "sign 0x%llx with %d modifiers: e.g. 0x%llx 0x%llx, %d unchanged, all authenticate",
	      (unsigned long long)PTR, NMOD, (unsigned long long)s.v[0], (unsigned long long)s.v[1], plain);
	CHECK(wrong_modifier_fails(&s), "authentication with a wrong modifier fails");

	long en = prctl(PR_PAC_GET_ENABLED_KEYS, 0, 0, 0, 0);
	CHECK(en == (long)KEY_ALL, "PR_PAC_GET_ENABLED_KEYS = 0x%lx (errno %d)", en, en < 0 ? errno : 0);

	CHECK(child_signature(argv[0], 0) == sigs_hash(&s), "fork keeps the keys");
	CHECK(child_signature(argv[0], 1) != sigs_hash(&s), "exec gives new keys");

	calls();

	fflush(stdout);
	if (fork() == 0)
		key_changes();
	wait(&st);
	CHECK(WIFEXITED(st) && WEXITSTATUS(st) == 0, "key changes in a child");

	ptrace_regsets();

	printf("pac-test: %d failed\n", failed);
	return failed != 0;
}
