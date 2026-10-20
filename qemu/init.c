/*
 * /init of the QEMU test initramfs (static ILP32 program): mount /dev, /proc and /tmp, run every program in
 * /tests in name order, print a summary line and power off.
 * Summary: "ILP32-TEST-RESULT: <failed> of <total> program(s) failed"
 *
 * AArch32 programs (name aarch32-*): with "ilp32test.aarch32=0" on the kernel command line (kernel built
 * without AARCH32_EL0) they must be refused by execve with ENOEXEC; otherwise they must run and pass.
 */
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <sys/utsname.h>
#include <sys/wait.h>
#include <unistd.h>

static int by_name(const struct dirent **a, const struct dirent **b)
{
	return strcmp((*a)->d_name, (*b)->d_name);
}

int main(void)
{
	struct utsname u;
	struct dirent **ents;
	int n, total = 0, failed = 0;

	mkdir("/dev", 0755);
	mkdir("/proc", 0555);
	mkdir("/tmp", 01777);
	mount("devtmpfs", "/dev", "devtmpfs", 0, NULL);
	mount("proc", "/proc", "proc", 0, NULL);
	mount("tmpfs", "/tmp", "tmpfs", 0, NULL);
	/* the initramfs has no /dev/console node, so the kernel could not open one for us */
	int con = open("/dev/console", O_RDWR);
	if (con >= 0) {
		dup2(con, 0);
		dup2(con, 1);
		dup2(con, 2);
		if (con > 2)
			close(con);
	}
	setvbuf(stdout, NULL, _IONBF, 0);

	uname(&u);
	printf("ILP32-TEST: kernel %s %s, init sizeof(long)=%zu sizeof(void *)=%zu\n",
	       u.release, u.version, sizeof(long), sizeof(void *));

	char cmdline[1024] = "";
	FILE *f = fopen("/proc/cmdline", "r");
	if (f) {
		if (!fgets(cmdline, sizeof(cmdline), f))
			cmdline[0] = 0;
		fclose(f);
	}
	int aarch32 = strstr(cmdline, "ilp32test.aarch32=0") == NULL;
	printf("ILP32-TEST: AArch32 programs expected to %s\n", aarch32 ? "run" : "be refused (ENOEXEC)");

	n = scandir("/tests", &ents, NULL, by_name);
	for (int i = 0; i < n; i++) {
		char path[300];
		int st = 0;
		pid_t pid;

		if (ents[i]->d_name[0] == '.')
			continue;
		snprintf(path, sizeof(path), "/tests/%s", ents[i]->d_name);
		printf("########## %s\n", ents[i]->d_name);
		int is_a32 = strncmp(ents[i]->d_name, "aarch32-", 8) == 0;
		pid = fork();
		if (pid == 0) {
			char *argv[] = { path, NULL };
			char *envp[] = { "PATH=/tests", NULL };
			execve(path, argv, envp);
			if (errno == ENOEXEC)
				_exit(126);
			perror("execve");
			_exit(127);
		}
		total++;
		if (pid < 0 || waitpid(pid, &st, 0) != pid) {
			printf("########## %s: fork/wait failed\n", ents[i]->d_name);
			failed++;
		} else if (is_a32 && !aarch32) {
			if (WIFEXITED(st) && WEXITSTATUS(st) == 126) {
				printf("########## %s: ok (refused with ENOEXEC, no AArch32 in this kernel)\n",
				       ents[i]->d_name);
			} else {
				printf("########## %s: ran or failed differently on a kernel without AArch32\n",
				       ents[i]->d_name);
				failed++;
			}
		} else if (WIFEXITED(st) && WEXITSTATUS(st) == 126) {
			printf("########## %s: execve refused with ENOEXEC\n", ents[i]->d_name);
			failed++;
		} else if (WIFSIGNALED(st)) {
			printf("########## %s: killed by signal %d\n", ents[i]->d_name, WTERMSIG(st));
			failed++;
		} else if (WEXITSTATUS(st) != 0) {
			printf("########## %s: exit code %d\n", ents[i]->d_name, WEXITSTATUS(st));
			failed++;
		} else {
			printf("########## %s: ok\n", ents[i]->d_name);
		}
	}
	printf("ILP32-TEST-RESULT: %d of %d program(s) failed\n", failed, total);
	sync();
	reboot(RB_POWER_OFF);
	return 0;
}
