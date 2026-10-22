#!/usr/bin/env python3
"""Boot an OpenWrt armsr ILP32 initramfs image in QEMU and check it over the serial console.

Started by run-openwrt-qemu.sh. Each check prints "ok   <name>" or "FAIL <name>"; the last line is
"OPENWRT-QEMU-RESULT: <failed> of <total> check(s) failed" and the exit code is the number of failures.
The whole serial output goes to --log.
"""
import argparse
import re
import sys
import time

import pexpect

PROMPT = r"root@[^:\r\n]*:[^#\r\n]*# "


class Console:
    def __init__(self, child):
        self.c = child
        self.n = 0

    def run(self, cmd, timeout=60):
        """Run a shell command, return (exit code, output)."""
        self.n += 1
        mark = f"__END{self.n}__"
        self.c.sendline(f"{cmd}; echo {mark}=$?")
        self.c.expect(rf"{mark}=(\d+)\r*\n", timeout=timeout)
        out = self.c.before.decode(errors="replace")
        rc = int(self.c.match.group(1))
        self.c.expect(PROMPT, timeout=timeout)
        # drop the echoed command line
        out = out.split("\n", 1)[1] if "\n" in out else ""
        return rc, out.replace("\r", "")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--kernel", required=True)
    ap.add_argument("--initrd", required=True)
    ap.add_argument("--append", required=True)
    ap.add_argument("--cpu", default="cortex-a53")
    ap.add_argument("--log", required=True)
    ap.add_argument("--boot-timeout", type=int, default=600)
    ap.add_argument("--notime32", action="store_true")
    a = ap.parse_args()

    qemu = ["qemu-system-aarch64", "-M", "virt", "-cpu", a.cpu, "-smp", "2", "-m", "512",
            "-nographic", "-no-reboot", "-kernel", a.kernel, "-initrd", a.initrd, "-append", a.append,
            "-netdev", "user,id=lan", "-device", "virtio-net-pci,netdev=lan",
            "-netdev", "user,id=wan", "-device", "virtio-net-pci,netdev=wan"]
    log = open(a.log, "wb")
    child = pexpect.spawn(qemu[0], qemu[1:], timeout=60)
    child.logfile_read = log

    results = []

    def check(name, ok, detail=""):
        results.append((name, ok))
        print(f"{'ok  ' if ok else 'FAIL'} {name}" + (f"  ({detail})" if detail and not ok else ""), flush=True)

    t0 = time.time()
    try:
        child.expect("Please press Enter to activate this console", timeout=a.boot_timeout)
    except (pexpect.TIMEOUT, pexpect.EOF) as e:
        check("boot to console", False, type(e).__name__)
        return finish(child, results)
    check("boot to console", True)
    print(f"     boot took {time.time() - t0:.0f} s", flush=True)
    child.sendline("")
    child.expect(PROMPT, timeout=60)
    sh = Console(child)

    def run_check(name, cmd, want=None, timeout=60):
        try:
            rc, out = sh.run(cmd, timeout)
        except (pexpect.TIMEOUT, pexpect.EOF) as e:
            check(name, False, type(e).__name__)
            return ""
        ok = rc == 0 and (want is None or re.search(want, out) is not None)
        check(name, ok, f"rc={rc}, output: {out.strip()[-300:]}")
        return out

    run_check("kernel 6.12.114", "cat /proc/version", r"Linux version 6\.12\.114")
    run_check("ILP32 dynamic linker", "ls /lib/ld-musl-aarch64_ilp32.so.1")
    run_check("seccomp filter active" if a.notime32 else "no seccomp filter",
              "grep '^Seccomp:' /proc/1/status", r"Seccomp:\s+2" if a.notime32 else r"Seccomp:\s+0")
    run_check("ubus system board", "ubus call system board", r'"release"')
    # the console comes up before procd has started all services
    run_check("procd init complete",
              "for i in $(seq 120); do logread | grep -q \"init complete\" && break; sleep 1; done; "
              "logread | grep \"init complete\"", r"init complete", timeout=150)
    # services that procd starts on a default image
    for d in ("procd", "ubusd", "logd", "netifd", "dnsmasq", "dropbear", "odhcpd"):
        run_check(f"daemon {d}", f"pidof {d}")
    # WAN gets an address from the QEMU user network (DHCP), within 60 s
    run_check("wan DHCP (udhcpc)",
              "for i in $(seq 60); do ifstatus wan | grep -q '\"address\": \"10.0.2.15\"' && break; sleep 1; done; "
              "ifstatus wan", r'"address": "10\.0\.2\.15"', timeout=90)
    run_check("lan 192.168.1.1", "ifstatus lan", r'"address": "192\.168\.1\.1"')
    run_check("firewall4 (nftables)", "nft list tables", r"table inet fw4")
    run_check("uci", "uci get system.@system[0].hostname", r"OpenWrt")
    run_check("time: sleep and clock", "a=$(date +%s); sleep 2; b=$(date +%s); [ $((b - a)) -ge 2 ]")
    run_check("musl-test dynamic (image libc)", "LD_LIBRARY_PATH=/usr/lib /tests/musl-test-dynamic", timeout=120)
    run_check("musl-test static", "/tests/musl-test-static", timeout=120)
    if not a.notime32:
        run_check("syscall-test (raw, time32 too)", "/tests/syscall-test-ilp32", timeout=60)
    # nothing crashed, no SIGSYS, no kernel trouble
    run_check("no crashes in logread",
              "! logread | grep -iE 'segfault|crashed|signal 31|bad system call|illegal instruction'")
    run_check("no kernel warnings in dmesg",
              "! dmesg | grep -E 'Oops|BUG:|WARNING:|Unable to handle|audit:.*sig=31'")
    return finish(child, results, sh)


def finish(child, results, sh=None):
    if sh is not None:
        try:
            child.sendline("poweroff")
            child.expect(pexpect.EOF, timeout=60)
        except (pexpect.TIMEOUT, pexpect.EOF):
            pass
    child.close(force=True)
    failed = sum(1 for _, ok in results if not ok)
    print(f"OPENWRT-QEMU-RESULT: {failed} of {len(results)} check(s) failed", flush=True)
    return failed


if __name__ == "__main__":
    sys.exit(main())
