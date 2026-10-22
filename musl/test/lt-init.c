/*
 * /init for running libc-test in QEMU (static musl ILP32): mount /dev, /dev/shm, /proc and /tmp, bring
 * the loopback interface up, run every test
 * listed in /libc-test/list through runtest.exe (from /libc-test, as libc-test's Makefile does from its
 * tree), print the runtest output and a summary, power off.
 * Summary: "LIBC-TEST-RESULT: <failed> of <total> test(s) failed"
 */
#define _GNU_SOURCE
#include <fcntl.h>
#include <net/if.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <sys/socket.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

int main(void)
{
	char line[512], out[4096];
	int total = 0, failed = 0;

	mkdir("/dev", 0755);
	mkdir("/proc", 0555);
	mkdir("/tmp", 01777);
	mount("devtmpfs", "/dev", "devtmpfs", 0, NULL);
	mount("proc", "/proc", "proc", 0, NULL);
	mount("tmpfs", "/tmp", "tmpfs", 0, NULL);
	/* sem_open and shm_open use /dev/shm */
	mkdir("/dev/shm", 01777);
	mount("tmpfs", "/dev/shm", "tmpfs", 0, NULL);
	/* the socket test uses the loopback interface */
	int s = socket(AF_INET, SOCK_DGRAM, 0);
	if (s >= 0) {
		struct ifreq ifr = { .ifr_name = "lo" };
		if (ioctl(s, SIOCGIFFLAGS, &ifr) == 0) {
			ifr.ifr_flags |= IFF_UP;
			ioctl(s, SIOCSIFFLAGS, &ifr);
		}
		close(s);
	}
	int con = open("/dev/console", O_RDWR);
	if (con >= 0) {
		dup2(con, 0);
		dup2(con, 1);
		dup2(con, 2);
		if (con > 2)
			close(con);
	}
	setvbuf(stdout, NULL, _IONBF, 0);
	if (chdir("/libc-test") != 0) {
		perror("chdir /libc-test");
		goto done;
	}
	FILE *list = fopen("list", "r");
	if (!list) {
		perror("list");
		goto done;
	}
	printf("LIBC-TEST: start\n");
	while (fgets(line, sizeof line, list)) {
		line[strcspn(line, "\n")] = 0;
		if (!line[0])
			continue;
		int p[2];
		if (pipe(p) != 0)
			break;
		pid_t pid = fork();
		if (pid == 0) {
			close(p[0]);
			dup2(p[1], 1);
			dup2(p[1], 2);
			char *argv[] = { "common/runtest.exe", "-t", "30", line, NULL };
			char *envp[] = { "PATH=/bin:/libc-test", "TMPDIR=/tmp", NULL };
			execve(argv[0], argv, envp);
			_exit(127);
		}
		close(p[1]);
		/* keep the first 4 KB of the output, drain the rest so the test cannot block */
		size_t n = 0;
		ssize_t r;
		char drain[256];
		while ((r = read(p[0], n < sizeof out - 1 ? out + n : drain,
				 n < sizeof out - 1 ? sizeof out - 1 - n : sizeof drain)) > 0)
			if (n < sizeof out - 1)
				n += r;
		close(p[0]);
		out[n] = 0;
		int st;
		waitpid(pid, &st, 0);
		total++;
		/* runtest prints nothing for a passing test, "FAIL ..." lines otherwise */
		if (n || !WIFEXITED(st) || WEXITSTATUS(st) != 0) {
			failed++;
			printf("%s", n ? out : "");
			if (!n)
				printf("FAIL %s [runtest status 0x%x]\n", line, st);
			else if (out[n - 1] != '\n')
				printf("\n");
		}
	}
	fclose(list);
	printf("LIBC-TEST-RESULT: %d of %d test(s) failed\n", failed, total);
done:
	sync();
	reboot(RB_POWER_OFF);
	return 0;
}
