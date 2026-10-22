/*
 * /init wrapper for the ILP32 tests: forbid the time32 and stat64 system calls of the ILP32 kernel ABI
 * with a seccomp filter (SECCOMP_RET_TRAP: the caller gets SIGSYS), then exec the real init (/init.real).
 * The filter is inherited by every process and thread of the test run, so a C library that still uses
 * one of these calls fails visibly ("killed by signal 31"). Stricter than a kernel built with
 * CONFIG_COMPAT_32BIT_TIME=n, where the time32 calls return -ENOSYS and a fallback could hide them.
 */
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <stddef.h>
#include <stdio.h>
#include <sys/prctl.h>
#include <unistd.h>

/* AArch64 ILP32 numbers (generic table): the time32 entries and the stat64 entries */
static const unsigned short forbidden[] = {
	4,	/* io_getevents */
	72,	/* pselect6 */
	73,	/* ppoll */
	79,	/* fstatat64 */
	80,	/* fstat64 */
	86,	/* timerfd_settime */
	87,	/* timerfd_gettime */
	88,	/* utimensat */
	98,	/* futex */
	101,	/* nanosleep */
	108,	/* timer_gettime */
	110,	/* timer_settime */
	112,	/* clock_settime */
	113,	/* clock_gettime */
	114,	/* clock_getres */
	115,	/* clock_nanosleep */
	127,	/* sched_rr_get_interval */
	137,	/* rt_sigtimedwait */
	169,	/* gettimeofday */
	170,	/* settimeofday */
	171,	/* adjtimex */
	182,	/* mq_timedsend */
	183,	/* mq_timedreceive */
	192,	/* semtimedop */
	243,	/* recvmmsg */
	260,	/* wait4 */
	266,	/* clock_adjtime */
	292,	/* io_pgetevents */
};
#define N (sizeof forbidden / sizeof forbidden[0])

int main(int argc, char **argv)
{
	struct sock_filter f[2 + 2 * N + 1];
	int i = 0;
	f[i++] = (struct sock_filter)BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, nr));
	for (unsigned k = 0; k < N; k++) {
		f[i++] = (struct sock_filter)BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, forbidden[k], 0, 1);
		f[i++] = (struct sock_filter)BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_TRAP);
	}
	f[i++] = (struct sock_filter)BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW);
	struct sock_fprog prog = { .len = i, .filter = f };
	if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) || prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &prog)) {
		perror("notime32-init: seccomp");
		return 1;
	}
	argv[0] = "/init.real";
	execv(argv[0], argv);
	perror("notime32-init: exec /init.real");
	return 1;
}
