#!/usr/bin/env python3
"""Compare the results of measure-memory.sh for two builds: median of the runs for each value.

Usage: summarize-memory.py <out dir> <name A> <name B> [mode...]   (e.g. out-memory lp64 ilp32 initramfs squashfs)
Prints Markdown tables: /proc/meminfo, the RSS and PSS of each process (by name) with the sums, and binary sizes.
"""
import glob
import json
import statistics
import sys


def load(d, name, mode):
    return [json.load(open(f)) for f in sorted(glob.glob(f"{d}/{name}-{mode}-*.json"))]


def med(v):
    v = [x for x in v if x is not None]
    return statistics.median(v) if v else None


def per_proc(runs):
    # several processes can share a name (e.g. two udhcpc): add them up per run
    names = sorted({p["comm"] for r in runs for p in r["processes"]})
    out = {}
    for n in names:
        v = {}
        for k in ("rss_kB", "anon_kB", "pss_kB"):
            vals = [[p[k] for p in r["processes"] if p["comm"] == n] for r in runs]
            v[k] = med([-1 if any(x < 0 for x in vs) else sum(vs) for vs in vals])
        out[n] = v
    return out


def pct(a, b):
    return f"{(b - a) * 100.0 / a:+.1f}%" if a and a > 0 and b is not None and b >= 0 else "-"


def num(v):
    # PSS is -1 without CONFIG_PROC_PAGE_MONITOR (no smaps_rollup)
    return "n/a" if v is None or v < 0 else f"{v:.0f}"


def diff(a, b):
    return "n/a" if a is None or b is None or a < 0 or b < 0 else f"{b - a:+.0f} ({pct(a, b)})"


def main():
    d, A, B = sys.argv[1:4]
    modes = sys.argv[4:] or ["initramfs", "squashfs"]
    for mode in modes:
        ra, rb = load(d, A, mode), load(d, B, mode)
        if not ra or not rb:
            print(f"(no {mode} results)\n")
            continue
        print(f"## {mode}: {A} ({len(ra)} runs) vs {B} ({len(rb)} runs), median\n")
        print(f"| /proc/meminfo (kB) | {A} | {B} | {B} - {A} |")
        print("|---|---|---|---|")
        for k in ra[0]["meminfo_kB"]:
            x, y = med([r["meminfo_kB"].get(k) for r in ra]), med([r["meminfo_kB"].get(k) for r in rb])
            print(f"| {k} | {x:.0f} | {y:.0f} | {y - x:+.0f} |")
        ua = med([r["meminfo_kB"]["MemTotal"] - r["meminfo_kB"]["MemAvailable"] for r in ra])
        ub = med([r["meminfo_kB"]["MemTotal"] - r["meminfo_kB"]["MemAvailable"] for r in rb])
        print(f"| used (MemTotal - MemAvailable) | {ua:.0f} | {ub:.0f} | {ub - ua:+.0f} ({pct(ua, ub)}) |\n")
        pa, pb = per_proc(ra), per_proc(rb)
        zero = {"rss_kB": 0, "anon_kB": 0, "pss_kB": 0}
        print(f"| process (kB) | RSS {A} | RSS {B} | Anon {A} | Anon {B} | PSS {A} | PSS {B} | PSS {B} - {A} |")
        print("|---|---|---|---|---|---|---|---|")
        for n in sorted(set(pa) | set(pb), key=lambda n: -(pa.get(n, zero)["rss_kB"] or 0)):
            xa, xb = pa.get(n, zero), pb.get(n, zero)
            print(f"| {n} | {xa['rss_kB']:.0f} | {xb['rss_kB']:.0f} | {xa['anon_kB']:.0f} | {xb['anon_kB']:.0f} | "
                  f"{num(xa['pss_kB'])} | {num(xb['pss_kB'])} | {diff(xa['pss_kB'], xb['pss_kB'])} |")
        s = {}
        for k in ("sum_rss_kB", "sum_anon_kB", "sum_pss_kB"):
            s[k] = (med([r[k] for r in ra]), med([r[k] for r in rb]))
        print(f"| **sum** | {s['sum_rss_kB'][0]:.0f} | {s['sum_rss_kB'][1]:.0f} | {s['sum_anon_kB'][0]:.0f} | "
              f"{s['sum_anon_kB'][1]:.0f} | {num(s['sum_pss_kB'][0])} | {num(s['sum_pss_kB'][1])} | "
              f"{diff(s['sum_pss_kB'][0], s['sum_pss_kB'][1])} |")
        print(f"\nRSS sum {B} vs {A}: {pct(s['sum_rss_kB'][0], s['sum_rss_kB'][1])}, "
              f"anon sum: {pct(s['sum_anon_kB'][0], s['sum_anon_kB'][1])}\n")
        print(f"| binary (bytes) | {A} | {B} | {B} - {A} |")
        print("|---|---|---|---|")
        ba, bb = ra[0]["binary_bytes"], rb[0]["binary_bytes"]
        for k in sorted(set(ba) | set(bb)):
            x, y = ba.get(k), bb.get(k)
            print(f"| {k} | {x} | {y} | " + (f"{y - x:+d} ({pct(x, y)})" if x and y else "-") + " |")
        print(f"\nboot (s): {A} {med([r['boot_s'] for r in ra])}, {B} {med([r['boot_s'] for r in rb])}")
        print(f"{A}: {ra[0]['release']}\n{B}: {rb[0]['release']}\n")


if __name__ == "__main__":
    main()
