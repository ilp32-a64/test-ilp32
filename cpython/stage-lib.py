#!/usr/bin/env python3
"""Stage one library of the AArch64 ILP32 CPython set for the debian session: a read-only snapshot with
<package>-ilp32/ trees (unstripped), doc/<source>.{copyright,changelog} and a MANIFEST in the format
debian asked for (versions, packages, dev-depends, file lists).

  stage-lib.py <source> <build output> <Debian source dir> <stage file> <new stage dir>
    <build output>  build-lib-clean.sh's py-out/<source>/ (raw/, build-env.txt, dpkg-l.txt, check.log)
    <Debian source dir>  the unpacked source (debian/control, changelog, copyright, patches/series)
    <stage file>   recipes/<source>.stage (recipes/README)
Every installed file must go to exactly one package or match a drop line; ELF files must be ELF32,
shared objects need the BTI property note; no build machine paths.
"""
import hashlib
import os
import re
import shutil
import subprocess
import sys

SUFFIX = "+ilp32a64.1"
T = "aarch64-linux-gnu_ilp32"
READELF = os.environ.get("READELF", os.path.expanduser(
    "~/work/build/deb-tc-futex/out/bin/aarch64-linux-gnu_ilp32-readelf"))
IT = os.path.realpath(os.path.join(os.path.dirname(os.path.realpath(__file__)), ".."))


def die(msg):
    sys.exit(f"stage-lib: {msg}")


def glob_re(pat):
    out = ""
    for ch in pat:
        out += {"*": "[^/]*", "?": "[^/]"}.get(ch, re.escape(ch))
    return re.compile(out + r"\Z")


def control(path):
    stanzas, cur, key = [], {}, None
    for line in open(path, encoding="utf-8"):
        line = line.rstrip("\n")
        if not line.strip():
            if cur:
                stanzas.append(cur)
            cur, key = {}, None
        elif line[0] in " \t" and key:
            cur[key] += "\n" + line
        elif ":" in line and not line.startswith("#"):
            key, val = line.split(":", 1)
            cur[key] = val.strip()
    if cur:
        stanzas.append(cur)
    return stanzas[0], {s["Package"]: s for s in stanzas[1:] if "Package" in s}


def sha(path):
    return hashlib.sha256(open(path, "rb").read()).hexdigest()


def readelf(*args):
    return subprocess.run([READELF, *args], capture_output=True, text=True).stdout


def main():
    if len(sys.argv) != 6:
        die(__doc__)
    source, out, src, stagefile, stage = sys.argv[1:]
    raw = os.path.join(out, "raw")
    if os.path.exists(stage):
        die(f"{stage} exists: a hand-off is not changed afterwards")
    srcstanza, pkgs = control(os.path.join(src, "debian/control"))
    first = open(os.path.join(src, "debian/changelog"), encoding="utf-8").readline()
    m = re.match(r"(\S+) \(([^)]+)\)", first)
    if not m or m.group(1) != source:
        die(f"debian/changelog: {first.strip()}")
    version = m.group(2) + SUFFIX

    # the stage file
    packages, devdeps, drops, deviations = {}, {}, [], []
    for n, line in enumerate(open(stagefile, encoding="utf-8"), 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        kind, rest = line.split(None, 1)
        if kind == "pkg":
            p, *pats = rest.split()
            if p not in pkgs:
                die(f"{stagefile}:{n}: {p} is not in debian/control")
            packages.setdefault(p, []).extend(pats)
        elif kind == "dev-depends":
            p, *deps = rest.split()
            devdeps[p] = deps
        elif kind == "drop":
            pat, reason = rest.split(" -- ", 1)
            drops.append((pat.strip(), reason.strip()))
        elif kind == "deviation":
            deviations.append(rest)
        else:
            die(f"{stagefile}:{n}: unknown line kind {kind}")

    # assign every installed file
    files = []
    for root, dirs, names in os.walk(raw):
        for name in names + [d for d in dirs if os.path.islink(os.path.join(root, d))]:
            files.append(os.path.relpath(os.path.join(root, name), raw))
    files.sort()
    assign, dropped = {}, {}
    for f in files:
        hits = [p for p, pats in packages.items() if any(glob_re(x).match(f) for x in pats)]
        dhits = [r for pat, r in drops if glob_re(pat).match(f)]
        if len(hits) + (1 if dhits else 0) != 1:
            die(f"{f}: matches {hits + (['drop'] if dhits else [])} (must match exactly one)")
        if hits:
            assign.setdefault(hits[0], []).append(f)
        else:
            dropped.setdefault(dhits[0], []).append(f)
    for p in packages:
        if p not in assign:
            die(f"{p}: no files")

    # copy the trees
    os.makedirs(os.path.join(stage, "doc"))
    for p, fl in assign.items():
        for f in fl:
            a, b = os.path.join(raw, f), os.path.join(stage, p + "-ilp32", f)
            os.makedirs(os.path.dirname(b), exist_ok=True)
            if os.path.islink(a):
                os.symlink(os.readlink(a), b)
            else:
                shutil.copy2(a, b)
    shutil.copy2(os.path.join(src, "debian/copyright"), os.path.join(stage, "doc", source + ".copyright"))
    shutil.copy2(os.path.join(src, "debian/changelog"), os.path.join(stage, "doc", source + ".changelog"))

    # checks: ELF32 everywhere (archive members too), BTI note on shared objects, no machine paths
    elfs = 0
    for root, _, names in os.walk(stage):
        for name in names:
            f = os.path.join(root, name)
            if os.path.islink(f):
                continue
            data = open(f, "rb").read()
            for bad in (b"/home/", b"/srv/", b"ubuntu-VirtualBox"):
                if bad in data:
                    die(f"{f}: contains {bad.decode()}")
            if data[:4] == b"\x7fELF" or data[:8] == b"!<arch>\n":
                h = readelf("-h", f)
                classes = re.findall(r"Class:\s+(\S+)", h)
                if not classes or any(c != "ELF32" for c in classes):
                    die(f"{f}: not ELF32 ({sorted(set(classes))})")
                notes = readelf("-n", f)
                if "corrupt" in notes:
                    die(f"{f}: corrupt note")
                if data[:4] == b"\x7fELF" and ".so" in name and "AArch64 feature: BTI" not in notes:
                    die(f"{f}: no BTI property note")
                elfs += 1

    # MANIFEST
    head = subprocess.run(["git", "-C", IT, "log", "-1", "--format=%h"], capture_output=True, text=True).stdout.strip()
    dirty = subprocess.run(["git", "-C", IT, "status", "--porcelain", "cpython"], capture_output=True, text=True).stdout
    if dirty:
        die("test-ilp32 cpython/ has uncommitted changes")
    series = os.path.join(src, "debian/patches/series")
    npatch = len([l for l in open(series) if l.strip() and not l.startswith("#")]) if os.path.exists(series) else 0
    env = open(os.path.join(out, "build-env.txt")).read().strip().splitlines()
    names = [p + "-ilp32" for p in packages]
    L = []
    L.append(f"# AArch64 ILP32 {source} from Debian 13 sources: install trees (<package>/)")
    L.append(f"date: {subprocess.run(['date', '-u', '+%F'], capture_output=True, text=True).stdout.strip()}"
             f"   test-ilp32 {head} cpython/stage-lib.py {source}")
    L += ["", "versions:", f"  {', '.join(names)}  {version}", "", "packages:"]
    for p in packages:
        s = pkgs[p]
        sec = s.get("Section", srcstanza.get("Section", "UNKNOWN"))
        desc = s.get("Description", "").splitlines()[0].strip()
        L.append(f"  {p}-ilp32  section={sec}  desc={desc} (AArch64 ILP32)  source={source}")
    L += ["", "dev-depends:"]
    for p in packages:
        if p in devdeps:
            L.append(f"  {p}-ilp32  {', '.join(devdeps[p]) if devdeps[p] else '(none)'}")
    L += ["", "source (Debian 13, checked against InRelease by fetch-sources.py):"]
    L += ["  " + l for l in env if l.startswith(("source:", "recipe:"))]
    L.append(f"  Debian patches: all {npatch} of debian/patches/series, applied by dpkg-source -x")
    L += ["", "build: test-ilp32 cpython/build-lib-clean.sh, in a fresh clean chroot (pristine Debian 13 arm64",
          "  buildd base, thrown away afterwards) on an arm64 Debian 13 board: the source's Build-Depends from",
          "  Debian (apt-get build-dep), the ILP32 toolchain and the set's earlier -ilp32 packages (list below);",
          "  debian/rules' arm64 options for the triplet aarch64-linux-gnu_ilp32, dpkg-buildflags of trixie",
          "  with -mbranch-protection=bti instead of standard (GCC has no pac-ret for ILP32); libraries in",
          f"  /usr/libilp32, headers in /usr/{T}/include"]
    for l in env:
        if l.startswith(("source:", "recipe:")):
            continue
        if l == "toolchain: local":
            l = ("toolchain: local debs, debian's v2026.10.30 candidates (compiler .4, runtime .2, glibc .2;"
                 " versions in the package list below), not yet from the repository")
        elif l == "toolchain: repo":
            l = "toolchain: from the signed repository (pinned versions, in the package list below)"
        L.append("  " + l)
    if deviations:
        L += ["", "deviations from Debian's build:"] + [f"  - {d}" for d in deviations]
    if dropped:
        L += ["", "installed but not packaged:"]
        for r, fl in dropped.items():
            L.append(f"  - {len(fl)} file(s), {r}: {', '.join(fl[:4])}{' ...' if len(fl) > 4 else ''}")
    chk = os.path.join(out, "check.log")
    L += ["", "tests (Debian's test step, in the same chroot):"]
    if os.path.exists(chk):
        L += ["  " + l for l in open(chk, errors="replace").read().strip().splitlines()[-12:]]
    else:
        L.append("  (Debian runs none)")
    L += ["", f"checks: {elfs} ELF files/archives all ELF32; shared objects with the BTI property note;",
          "  no build machine paths", "", f"doc/: Debian's copyright and changelog of {source}"]
    for p in packages:
        L += ["", f"## {p}-ilp32"]
        for f in assign[p]:
            a = os.path.join(raw, f)
            L.append(f"  /{f} -> {os.readlink(a)}" if os.path.islink(a) else f"  /{f} {sha(a)[:16]}")
    L += ["", "## build environment: packages installed in the clean chroot (dpkg-query)"]
    L += ["  " + l for l in open(os.path.join(out, "dpkg-l.txt")).read().splitlines()]
    with open(os.path.join(stage, "MANIFEST"), "w", newline="\n") as fh:
        fh.write("\n".join(L) + "\n")
    for p in packages:
        print(f"{p}-ilp32: {len(assign[p])} files")
    for r, fl in dropped.items():
        print(f"dropped {len(fl)}: {r}")


if __name__ == "__main__":
    main()
