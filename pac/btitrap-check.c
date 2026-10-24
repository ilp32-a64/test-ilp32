// SPDX-License-Identifier: GPL-2.0
/*
 * Run the btitrap-nolibc programs (ILP32 and LP64) and check how they end: killed by SIGILL on a CPU
 * with BTI (AT_HWCAP2 BTI), exit status 1 without BTI. Exit status 0 if both end as expected.
 */
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/auxv.h>
#include <sys/wait.h>
#include <unistd.h>

#ifndef HWCAP2_BTI
#define HWCAP2_BTI (1 << 17)
#endif

static int check(const char *path, int bti)
{
	char *argv[] = { (char *)path, NULL };
	char *envp[] = { NULL };
	int status;
	pid_t pid = fork();

	if (pid == 0) {
		execve(path, argv, envp);
		_exit(127);
	}
	if (pid < 0 || waitpid(pid, &status, 0) != pid) {
		printf("FAIL %s: fork/wait\n", path);
		return 1;
	}
	if (bti ? WIFSIGNALED(status) && WTERMSIG(status) == SIGILL
		: WIFEXITED(status) && WEXITSTATUS(status) == 1) {
		printf("ok   %s: %s\n", path, bti ? "SIGILL (BTI enforced)" : "exit 1 (no BTI)");
		return 0;
	}
	if (WIFSIGNALED(status))
		printf("FAIL %s: killed by signal %d (%s)\n", path, WTERMSIG(status), strsignal(WTERMSIG(status)));
	else
		printf("FAIL %s: exit status %d\n", path, WEXITSTATUS(status));
	return 1;
}

int main(void)
{
	int bti = !!(getauxval(AT_HWCAP2) & HWCAP2_BTI);

	printf("ok   AT_HWCAP2 BTI: %s\n", bti ? "yes" : "no");
	return check("/pac-data/btitrap-nolibc-ilp32", bti) | check("/pac-data/btitrap-nolibc-lp64", bti);
}
