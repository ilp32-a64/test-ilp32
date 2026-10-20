/*
 * glibc-level test for the ILP32 user space (also builds as LP64 to check the test itself under QEMU).
 *
 * Checks: type sizes, printf, large malloc, threads, clock_gettime through the vDSO (compared with the
 * raw system call), signal handler and return (sigreturn trampoline in the vDSO), fork/wait, file size
 * through stat, dlopen of libm.
 * Exit code: number of failed checks.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/auxv.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static int fails;
static void check(const char *what, int ok)
{
	printf("  %-6s%s\n", ok ? "ok" : "FAIL", what);
	if (!ok)
		fails++;
}

static void *thread_fn(void *arg)
{
	long *v = arg;
	for (int i = 0; i < 1000000; i++)
		__atomic_add_fetch(v, 1, __ATOMIC_RELAXED);
	return NULL;
}

static volatile sig_atomic_t got_signal;
static void on_usr1(int sig) { got_signal = sig; }

static double now(void)
{
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec + t.tv_nsec / 1e9;
}

int main(void)
{
#ifdef __ILP32__
	const char *abi = "ILP32";
#else
	const char *abi = "LP64";
#endif
	/* unbuffered: the output must survive a crash (stdout is a pipe under systemd) */
	setvbuf(stdout, NULL, _IONBF, 0);
	printf("glibc test, built as %s\n", abi);
	printf("  sizeof: long=%zu void*=%zu time_t=%zu off_t=%zu size_t=%zu long double=%zu\n",
	       sizeof(long), sizeof(void *), sizeof(time_t), sizeof(off_t), sizeof(size_t), sizeof(long double));
#ifdef __ILP32__
	check("long and pointers are 32-bit", sizeof(long) == 4 && sizeof(void *) == 4);
#endif
	check("off_t is 64-bit", sizeof(off_t) == 8);

	size_t big = 64u << 20;
	char *m = malloc(big);
	check("malloc 64 MB", m != NULL);
	if (m) {
		memset(m, 0x5a, big);
		check("malloc'd memory usable", m[0] == 0x5a && m[big - 1] == 0x5a);
		free(m);
	}

	long counter = 0;
	pthread_t th[4];
	int ok = 1;
	for (int i = 0; i < 4; i++)
		ok &= pthread_create(&th[i], NULL, thread_fn, &counter) == 0;
	for (int i = 0; i < 4; i++)
		ok &= pthread_join(th[i], NULL) == 0;
	check("4 threads, atomic counter", ok && counter == 4000000);

	/* vDSO: libc's clock_gettime should be much faster than the raw system call */
	unsigned long vdso = getauxval(AT_SYSINFO_EHDR);
	printf("  AT_SYSINFO_EHDR=%#lx\n", vdso);
	check("vDSO mapped", vdso != 0);
	printf("  (step: clock_gettime via libc)\n");
	struct timespec ts;
	const int n = 200000;
	double t0 = now();
	for (int i = 0; i < n; i++)
		clock_gettime(CLOCK_MONOTONIC, &ts);
	double t1 = now();
	for (int i = 0; i < n; i++)
		syscall(SYS_clock_gettime, CLOCK_MONOTONIC, &ts);
	double t2 = now();
	double libc_ns = (t1 - t0) / n * 1e9, sys_ns = (t2 - t1) / n * 1e9;
	printf("  clock_gettime: libc %.0f ns/call, raw syscall %.0f ns/call (ratio %.1f)\n",
	       libc_ns, sys_ns, sys_ns / libc_ns);
	check("libc clock_gettime uses the vDSO (at least 3x faster than the syscall)", sys_ns > 3 * libc_ns);
	/* the vDSO time must advance like the kernel's: compare both over a 200 ms sleep */
	struct timespec v0, v1, s0, s1;
	clock_gettime(CLOCK_MONOTONIC, &v0);
	syscall(SYS_clock_gettime, CLOCK_MONOTONIC, &s0);
	usleep(200000);
	clock_gettime(CLOCK_MONOTONIC, &v1);
	syscall(SYS_clock_gettime, CLOCK_MONOTONIC, &s1);
	double dv = (v1.tv_sec - v0.tv_sec) + (v1.tv_nsec - v0.tv_nsec) / 1e9;
	double ds = (s1.tv_sec - s0.tv_sec) + (s1.tv_nsec - s0.tv_nsec) / 1e9;
	printf("  200 ms sleep: vDSO %.6f s, syscall %.6f s\n", dv, ds);
	check("vDSO time advances like the kernel time (within 5%)", ds > 0.15 && dv > 0.95 * ds && dv < 1.05 * ds);
	double vs = v1.tv_sec + v1.tv_nsec / 1e9, ss = s1.tv_sec + s1.tv_nsec / 1e9;
	check("vDSO time equals the kernel time (within 10 ms)", vs - ss < 0.01 && ss - vs < 0.01);
	time_t wall = time(NULL);
	check("time() is after 2025", wall > 1735689600);

	printf("  (step: signal)\n");
	struct sigaction sa;
	memset(&sa, 0, sizeof(sa));
	sa.sa_handler = on_usr1;
	sigaction(SIGUSR1, &sa, NULL);
	raise(SIGUSR1);
	check("signal handler ran and returned", got_signal == SIGUSR1);

	printf("  (step: fork)\n");
	pid_t pid = fork();
	if (pid == 0)
		_exit(42);
	int st = 0;
	check("fork + waitpid", pid > 0 && waitpid(pid, &st, 0) == pid && WIFEXITED(st) && WEXITSTATUS(st) == 42);

	char path[] = "/tmp/ilp32-test-XXXXXX";
	int fd = mkstemp(path);
	char buf[12345];
	memset(buf, 1, sizeof(buf));
	ok = fd >= 0 && write(fd, buf, sizeof(buf)) == (ssize_t)sizeof(buf);
	struct stat sb;
	ok = ok && fstat(fd, &sb) == 0 && sb.st_size == (off_t)sizeof(buf);
	printf("  stat: st_size=%lld st_blksize=%ld\n", (long long)sb.st_size, (long)sb.st_blksize);
	check("write + fstat size", ok);
	if (fd >= 0) {
		close(fd);
		unlink(path);
	}

	void *h = dlopen("libm.so.6", RTLD_NOW);
	double (*fcos)(double) = h ? (double (*)(double))dlsym(h, "cos") : NULL;
	check("dlopen libm.so.6 + dlsym cos", fcos && fcos(0.0) == 1.0);

	printf("RESULT: %s (%d failed)\n", fails ? "FAIL" : "PASS", fails);
	return fails;
}
