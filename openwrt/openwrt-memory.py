#!/usr/bin/env python3
"""Boot an OpenWrt armsr image in QEMU once and collect memory numbers over the serial console.

Started by measure-memory.sh. Writes one JSON file (--out) with /proc/meminfo, free, the RSS and PSS of
every user process (from /proc/<pid>/smaps_rollup) and the sizes of some binaries. The serial output goes
to --log.
"""
import argparse
import json
import re
import sys
import time

import pexpect

PROMPT = r"root@[^:\r\n]*:[^#\r\n]*# "
MEMINFO = ("MemTotal", "MemFree", "MemAvailable", "Buffers", "Cached", "AnonPages", "Mapped", "Shmem",
           "Slab", "SReclaimable", "SUnreclaim", "PageTables", "KernelStack")
BINARIES = ("/bin/busybox", "/lib/libc.so", "/sbin/procd", "/sbin/ubusd", "/sbin/netifd", "/sbin/logd",
            "/usr/sbin/dnsmasq", "/usr/sbin/dropbear", "/usr/sbin/odhcpd", "/lib/libubox.so*", "/lib/libubus.so*",
            "/lib/libuci.so*", "/usr/lib/libnftnl.so*", "/usr/sbin/nft", "/usr/lib/libjson-c.so*")


def run(c, cmd, timeout=120):
    mark = f"__END{int(time.time() * 1000) % 1000000}__"
    # a busy guest (QEMU TCG) loses serial input that comes too fast: send long lines in pieces
    line = f"{cmd}; echo {mark}=$?"
    for i in range(0, len(line), 64):
        c.send(line[i:i + 64])
        time.sleep(0.05)
    c.send("\r")
    c.expect(rf"{mark}=(\d+)\r*\n", timeout=timeout)
    out = c.before.decode(errors="replace").replace("\r", "")
    c.expect(PROMPT, timeout=timeout)
    # drop the echoed command line (ash echoes it, possibly wrapped) and terminal escape sequences (colored ls)
    i = out.find(f"echo {mark}=$?")
    if i >= 0:
        out = out[out.find("\n", i) + 1:]
    return re.sub(r"\x1b\[[0-9;]*m", "", out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--qemu", required=True, help="QEMU command line (one string)")
    ap.add_argument("--settle", type=int, default=60)
    ap.add_argument("--workload", help="file with one shell command per line, run before settling")
    ap.add_argument("--boot-timeout", type=int, default=600)
    ap.add_argument("--log", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()

    c = pexpect.spawn("/bin/sh", ["-c", a.qemu], timeout=120)
    c.logfile_read = open(a.log, "wb")
    t0 = time.time()
    c.expect("Please press Enter to activate this console", timeout=a.boot_timeout)
    boot = time.time() - t0
    c.sendline("")
    c.expect(PROMPT, timeout=60)
    # wait for procd to start everything, then let things settle
    run(c, "for i in $(seq 120); do logread | grep -q 'init complete' && break; sleep 1; done", timeout=150)
    wl = []
    if a.workload:
        for line in open(a.workload):
            line = line.strip()
            if line and not line.startswith("#"):
                wl.append({"cmd": line[:80], "out": run(c, line, timeout=1200).strip()[-300:]})
    run(c, f"sleep {a.settle}", timeout=a.settle + 60)

    r = {"boot_s": round(boot, 1), "workload": wl}
    r["uname"] = run(c, "uname -a").strip()
    r["release"] = run(c, ". /etc/openwrt_release; echo \"$DISTRIB_DESCRIPTION $DISTRIB_ARCH\"").strip()
    r["free"] = run(c, "free")
    mi = {}
    for line in run(c, "cat /proc/meminfo").splitlines():
        m = re.match(r"(\w+):\s+(\d+) kB", line)
        if m and m.group(1) in MEMINFO:
            mi[m.group(1)] = int(m.group(2))
    r["meminfo_kB"] = mi
    r["meminfo_all"] = run(c, "cat /proc/meminfo")
    r["modules"] = run(c, "cat /proc/modules | awk '{s += $2} END {print NR, s}'")
    r["vmalloc"] = run(c, "awk '{s += $2} END {print NR, s}' /proc/vmallocinfo 2>/dev/null")
    r["mounts_tmpfs"] = run(c, "df -k | grep -E 'tmpfs|overlay|rom'")
    # user processes (kernel threads have no VmRSS): VmRSS and its parts from status, PSS from smaps_rollup
    # (needs CONFIG_PROC_PAGE_MONITOR; -1 without it)
    procs = []
    out = run(c, "for d in /proc/[0-9]*; do s=$(grep -E '^(VmRSS|RssAnon|RssFile|RssShmem):' $d/status 2>/dev/null "
                 "| awk '{printf \"%s \", $2}'); [ -n \"$s\" ] || continue; "
                 "p=$(awk '/^Pss:/ {print $2}' $d/smaps_rollup 2>/dev/null); "
                 "echo \"P ${d#/proc/} $(cat $d/comm) $s ${p:--1}\"; done")
    for line in out.splitlines():
        f = line.split()
        if len(f) == 8 and f[0] == "P":
            procs.append({"pid": int(f[1]), "comm": f[2], "rss_kB": int(f[3]), "anon_kB": int(f[4]),
                          "file_kB": int(f[5]), "shmem_kB": int(f[6]), "pss_kB": int(f[7])})
    r["processes"] = procs
    r["sum_rss_kB"] = sum(p["rss_kB"] for p in procs)
    r["sum_anon_kB"] = sum(p["anon_kB"] for p in procs)
    r["sum_pss_kB"] = sum(p["pss_kB"] for p in procs) if all(p["pss_kB"] >= 0 for p in procs) else -1
    sizes = {}
    for line in run(c, "ls -lL " + " ".join(BINARIES) + " 2>/dev/null").splitlines():
        f = line.split()
        if len(f) >= 9 and f[0].startswith("-"):
            sizes[f[-1]] = int(f[4])
    r["binary_bytes"] = sizes
    r["df_root"] = run(c, "df -k / /rom /overlay 2>/dev/null")

    c.sendline("poweroff")
    try:
        c.expect(pexpect.EOF, timeout=60)
    except pexpect.TIMEOUT:
        pass
    c.close(force=True)
    json.dump(r, open(a.out, "w"), indent=1)
    print(f"boot {r['boot_s']} s, MemAvailable {mi.get('MemAvailable')} kB, "
          f"user processes {len(procs)}, PSS sum {r['sum_pss_kB']} kB", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
