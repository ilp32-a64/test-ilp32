/*
 * AArch32 (armhf) test program, static glibc: runs on an ILP32 kernel with AARCH32_EL0=y to check that the
 * AArch32 ELF loader and the AArch32 system call, signal and time paths still work next to ILP32.
 * On a kernel without AArch32 (AARCH32_EL0=n) it must be refused by execve with ENOEXEC (see qemu/init.c).
 *
 * Checks: data model, uname machine (with and without PER_LINUX32), getpid, clock_gettime advancing over a
 * sleep, signal handler and return, fork/wait, anonymous mmap.
 * Exit code: number of failed checks.
 */
#define _GNU_SOURCE
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/personality.h>
#include <sys/utsname.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static int fails;
static void check(const char *what, int ok)
{
	printf("  %s  %s\n", ok ? "ok  " : "FAIL", what);
	if (!ok)
		fails++;
}

static volatile sig_atomic_t got_signal;
static void on_usr1(int sig) { got_signal = sig; }

int main(void)
{
	struct utsname u;
	struct timespec a, b, d = { 0, 50 * 1000 * 1000 };

	setvbuf(stdout, NULL, _IONBF, 0);
	printf("AArch32 test, sizeof(long)=%zu sizeof(void*)=%zu\n", sizeof(long), sizeof(void *));
	check("long and pointers are 32-bit", sizeof(long) == 4 && sizeof(void *) == 4);

	/* arm64 reports "aarch64" to AArch32 tasks too, "armv8l" only with the PER_LINUX32 personality */
	check("uname", uname(&u) == 0);
	printf("  uname: %s %s %s\n", u.sysname, u.release, u.machine);
	check("uname machine is aarch64", strcmp(u.machine, "aarch64") == 0);
	int old = personality(0xffffffff);
	check("personality(PER_LINUX32)", personality(PER_LINUX32) != -1);
	uname(&u);
	printf("  uname with PER_LINUX32: %s\n", u.machine);
	check("uname machine with PER_LINUX32 is armv8l", strcmp(u.machine, "armv8l") == 0);
	personality(old);

	check("getpid > 0", getpid() > 0);

	clock_gettime(CLOCK_MONOTONIC, &a);
	nanosleep(&d, NULL);
	clock_gettime(CLOCK_MONOTONIC, &b);
	double dt = (b.tv_sec - a.tv_sec) + (b.tv_nsec - a.tv_nsec) / 1e9;
	printf("  50 ms sleep measured %.6f s\n", dt);
	check("clock_gettime advances over a 50 ms sleep", dt >= 0.045 && dt < 5.0);

	signal(SIGUSR1, on_usr1);
	raise(SIGUSR1);
	check("signal handler ran and returned", got_signal == SIGUSR1);

	pid_t pid = fork();
	if (pid == 0)
		_exit(42);
	int st = 0;
	check("fork + waitpid", pid > 0 && waitpid(pid, &st, 0) == pid && WIFEXITED(st) && WEXITSTATUS(st) == 42);

	char *m = mmap(NULL, 65536, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	check("mmap 64 KB", m != MAP_FAILED);
	if (m != MAP_FAILED) {
		m[0] = 1;
		m[65535] = 2;
		check("mmap memory writable", m[0] == 1 && m[65535] == 2);
	}

	printf("RESULT: %s (%d failed)\n", fails ? "FAIL" : "PASS", fails);
	return fails;
}
