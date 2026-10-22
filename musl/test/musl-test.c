/*
 * musl AArch64 ILP32 test: the parts of the port that differ from LP64 and AArch32.
 *   data model; system calls with 64-bit arguments as register pairs (pread/pwrite, ftruncate,
 *   fallocate, lseek, posix_fadvise, sync_file_range, readahead) at offsets above 4 GB; stat vs statx
 *   (st_ino of the AArch32 struct stat64); fcntl locks (F_GETLK64); mmap2 offsets; time64 and the vDSO;
 *   setjmp/longjmp, sigsetjmp/siglongjmp with the signal mask; signal handler and ucontext;
 *   threads and TLS; fork; SysV IPC with IPC_64; fenv; dlopen of a module with TLS (TLSDESC).
 * Prints "ok <what>" or "FAIL <what>" and exits with the number of failures.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <fenv.h>
#include <pthread.h>
#include <setjmp.h>
#include <signal.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ipc.h>
#include <sys/mman.h>
#include <sys/sem.h>
#include <sys/shm.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <time.h>
#include <ucontext.h>
#include <unistd.h>

static int fails;
static void check(const char *what, int ok)
{
	printf("%s %s\n", ok ? "ok  " : "FAIL", what);
	if (!ok)
		fails++;
}

#define BIG (5LL << 30) /* 5 GB: the high word of the register pair is used */

static void test_types(void)
{
	check("sizeof long/pointer/size_t == 4", sizeof(long) == 4 && sizeof(void *) == 4 && sizeof(size_t) == 4);
	check("sizeof off_t/time_t/ino_t == 8", sizeof(off_t) == 8 && sizeof(time_t) == 8 && sizeof(ino_t) == 8);
	check("sizeof jmp_buf >= 22*8, sigset_t == 128", sizeof(jmp_buf) >= 176 && sizeof(sigset_t) == 128);
	check("ucontext uc_mcontext at offset 160", offsetof(ucontext_t, uc_mcontext) == 160);
}

static void test_files(void)
{
	const char *f = "/tmp/musl-ilp32-file";
	char buf[16] = { 0 };
	struct stat st;
	int fd = open(f, O_RDWR | O_CREAT | O_TRUNC, 0644);
	check("open", fd >= 0);
	check("pwrite at 5 GB", pwrite(fd, "hello", 5, BIG) == 5);
	check("pread at 5 GB", pread(fd, buf, 5, BIG) == 5 && !memcmp(buf, "hello", 5));
	check("lseek SEEK_END above 4 GB", lseek(fd, 0, SEEK_END) == BIG + 5);
	check("fstat st_size above 4 GB", fstat(fd, &st) == 0 && st.st_size == BIG + 5);
	check("ftruncate to 6 GB", ftruncate(fd, 6LL << 30) == 0 && fstat(fd, &st) == 0 && st.st_size == 6LL << 30);
	check("fallocate above 4 GB", fallocate(fd, 0, BIG, 4096) == 0);
	check("posix_fadvise above 4 GB", posix_fadvise(fd, BIG, 4096, POSIX_FADV_DONTNEED) == 0);
	check("sync_file_range above 4 GB", sync_file_range(fd, BIG, 4096, SYNC_FILE_RANGE_WRITE) == 0);
	check("readahead above 4 GB", readahead(fd, BIG, 4096) == 0);
	check("truncate to 1 MB", truncate(f, 1 << 20) == 0 && stat(f, &st) == 0 && st.st_size == 1 << 20);

	/* st_ino: struct stat64 of the kernel has it at the end (AArch32 layout), statx is the reference */
	struct statx sx;
	check("statx", statx(AT_FDCWD, f, 0, STATX_INO, &sx) == 0);
	check("stat st_ino == statx stx_ino", stat(f, &st) == 0 && st.st_ino == sx.stx_ino);
#if defined SYS_fstatat64 && !defined NOTIME32
	/* only when the C library still names the stat64 calls (musl without them uses statx only), and
	 * not in a NOTIME32 run, where the call is forbidden */
	long kst[32];
	errno = 0;
	int r = syscall(SYS_fstatat64, AT_FDCWD, f, kst, 0);
	check("fstatat64 system call st_ino == statx stx_ino",
	      r == 0 && *(unsigned long long *)((char *)kst + 96) == sx.stx_ino);
#endif

	struct flock fl = { .l_type = F_WRLCK, .l_whence = SEEK_SET, .l_start = BIG, .l_len = 10 };
	check("fcntl F_SETLK above 4 GB", fcntl(fd, F_SETLK, &fl) == 0);
	struct flock gl = { .l_type = F_WRLCK, .l_whence = SEEK_SET, .l_start = 0, .l_len = 0 };
	check("fcntl F_GETLK (own lock: F_UNLCK)", fcntl(fd, F_GETLK, &gl) == 0 && gl.l_type == F_UNLCK);

	check("ftruncate 64 KB", ftruncate(fd, 65536) == 0 && pwrite(fd, "page2", 5, 8192) == 5);
	char *m = mmap(0, 4096, PROT_READ, MAP_SHARED, fd, 8192);
	check("mmap at offset 8192 (mmap2 units)", m != MAP_FAILED && !memcmp(m, "page2", 5));
	if (m != MAP_FAILED)
		munmap(m, 4096);
	close(fd);
	unlink(f);
}

static void test_time(void)
{
	struct timespec a, b;
	check("clock_gettime (vDSO)", clock_gettime(CLOCK_MONOTONIC, &a) == 0);
	check("clock_gettime64 system call", syscall(SYS_clock_gettime64, CLOCK_MONOTONIC, &b) == 0);
	long long d = (b.tv_sec - a.tv_sec) * 1000000000LL + (b.tv_nsec - a.tv_nsec);
	check("vDSO and system call agree (< 1 s)", d >= 0 && d < 1000000000LL);
	struct timespec s = { 0, 20000000 };
	clock_gettime(CLOCK_MONOTONIC, &a);
	check("nanosleep 20 ms", nanosleep(&s, 0) == 0);
	clock_gettime(CLOCK_MONOTONIC, &b);
	d = (b.tv_sec - a.tv_sec) * 1000000000LL + (b.tv_nsec - a.tv_nsec);
	check("slept >= 20 ms", d >= 20000000LL);
	time_t t = time(0);
	check("time() after 2020", t > 1577836800);
	struct timespec y2038 = { 0x80000000LL + 100, 0 };
	check("time_t is 64-bit at run time (2038)", y2038.tv_sec > 0x7fffffffLL);
}

static jmp_buf jb;
static sigjmp_buf sjb;
static volatile sig_atomic_t got;
static volatile unsigned long long fault_pc;

static void on_usr1(int sig, siginfo_t *si, void *uc)
{
	ucontext_t *u = uc;
	got = sig;
	fault_pc = u->uc_mcontext.pc;
	(void)si;
}

static void on_usr2(int sig)
{
	siglongjmp(sjb, sig);
}

static void test_signals(void)
{
	volatile int n = 0;
	if (setjmp(jb) == 0) {
		n = 1;
		longjmp(jb, 42);
	}
	check("setjmp/longjmp", n == 1);

	struct sigaction sa = { .sa_sigaction = on_usr1, .sa_flags = SA_SIGINFO };
	sigaction(SIGUSR1, &sa, 0);
	raise(SIGUSR1);
	check("SA_SIGINFO handler runs and returns", got == SIGUSR1);
	check("ucontext pc is set", fault_pc != 0 && fault_pc < (1ULL << 32));

	signal(SIGUSR2, on_usr2);
	sigset_t set, old;
	sigemptyset(&set);
	sigaddset(&set, SIGHUP);
	sigprocmask(SIG_BLOCK, &set, &old);
	int r = sigsetjmp(sjb, 1);
	if (r == 0) {
		sigset_t none;
		sigemptyset(&none);
		sigprocmask(SIG_SETMASK, &none, 0);
		raise(SIGUSR2);
	}
	sigset_t now;
	sigprocmask(SIG_SETMASK, 0, &now);
	check("sigsetjmp/siglongjmp from a handler", r == SIGUSR2);
	check("siglongjmp restores the signal mask", sigismember(&now, SIGHUP) == 1);
	sigprocmask(SIG_SETMASK, &old, 0);
}

static __thread int tls_var = 7;
static __thread char tls_big[1000];
static void *thread_fn(void *arg)
{
	tls_var += (int)(intptr_t)arg;
	tls_big[999] = 1;
	return (void *)(intptr_t)tls_var;
}

static void test_threads(void)
{
	pthread_t t[4];
	void *ret;
	int ok = 1;
	for (int i = 0; i < 4; i++)
		ok &= pthread_create(&t[i], 0, thread_fn, (void *)(intptr_t)(i + 1)) == 0;
	for (int i = 0; i < 4; i++)
		ok &= pthread_join(t[i], &ret) == 0 && (intptr_t)ret == 7 + i + 1;
	check("threads with their own TLS", ok);
	check("main thread TLS unchanged", tls_var == 7 && tls_big[999] == 0);

	pid_t p = fork();
	if (p == 0)
		_exit(tls_var == 7 ? 33 : 1);
	int st;
	check("fork and wait", p > 0 && waitpid(p, &st, 0) == p && WIFEXITED(st) && WEXITSTATUS(st) == 33);
}

static void test_ipc(void)
{
	int id = shmget(IPC_PRIVATE, 8192, IPC_CREAT | 0600);
	struct shmid_ds ds;
	time_t t0 = time(0);
	check("shmget", id >= 0);
	void *p = shmat(id, 0, 0);
	check("shmat", p != (void *)-1);
	check("shmctl IPC_STAT (IPC_64, time64)", shmctl(id, IPC_STAT, &ds) == 0 && ds.shm_segsz == 8192 &&
	      ds.shm_nattch == 1 && ds.shm_atime >= t0 - 5 && ds.shm_atime <= t0 + 5 &&
	      (ds.shm_perm.mode & 0777) == 0600);
	shmdt(p);
	shmctl(id, IPC_RMID, 0);

	int sid = semget(IPC_PRIVATE, 3, IPC_CREAT | 0600);
	struct semid_ds sd;
	check("semctl IPC_STAT", sid >= 0 && semctl(sid, 0, IPC_STAT, &sd) == 0 && sd.sem_nsems == 3);
	semctl(sid, 0, IPC_RMID);
}

static void test_fenv(void)
{
	fesetround(FE_UPWARD);
	check("fesetround/fegetround", fegetround() == FE_UPWARD);
	fenv_t e;
	fegetenv(&e);
	fesetenv(FE_DFL_ENV);
	check("fesetenv(FE_DFL_ENV)", fegetround() == FE_TONEAREST);
	fesetenv(&e);
	check("fesetenv(saved)", fegetround() == FE_UPWARD);
	fesetround(FE_TONEAREST);
	feclearexcept(FE_ALL_EXCEPT);
	volatile double x = 1.0, y = 0.0;
	x = x / y;
	check("division by zero raises FE_DIVBYZERO", fetestexcept(FE_DIVBYZERO) != 0);
}

static void test_dlopen(void)
{
	void *h = dlopen("/usr/lib/libtlsmod.so", RTLD_NOW);
	check("dlopen module with TLS", h != 0);
	if (!h) {
		printf("     %s\n", dlerror());
		return;
	}
	int (*get)(void) = (int (*)(void))dlsym(h, "tlsmod_get");
	int *(*addr)(void) = (int *(*)(void))dlsym(h, "tlsmod_addr");
	check("dlsym", get && addr);
	if (get && addr) {
		check("TLS of the module (TLSDESC dynamic): initial value", get() == 1234);
		*addr() = 99;
		check("TLS of the module: store and load", get() == 99);
	}
}

int main(int argc, char **argv)
{
	(void)argc;
	setvbuf(stdout, 0, _IONBF, 0);
	test_types();
	test_files();
	test_time();
	test_signals();
	test_threads();
	test_ipc();
	test_fenv();
	/* the dynamically linked build (name *-dynamic) also tests dlopen */
	if (strstr(argv[0], "dynamic"))
		test_dlopen();
	printf("%s: %d failure(s)\n", argv[0], fails);
	return fails;
}
