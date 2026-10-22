#!/bin/bash
# Rebuild the whole AArch64 ILP32 glibc toolchain from scratch, in order: stage 1 GCC (+ binutils, kernel
# headers), glibc, stage 2 GCC, then the QEMU tests. autoconf (out-host/) is kept.
#
#   rebuild-all.sh
# Uses J (default 2) for every build; check the VM load before starting it.
set -euo pipefail
R=$(dirname "$(realpath "$0")")		# this directory of test-ilp32
WORK=${GLIBC_WORK:-$HOME/work/ilp32-glibc}	# toolchain, builds and results (not in git)
mkdir -p "$WORK"
cd "$WORK"
TOP=$PWD
T=aarch64-linux-gnu_ilp32
log() { printf '\033[1;32m==> %s\033[0m\n' "$*"; }

log "clean ($(date +%H:%M))"
rm -rf toolchain/out toolchain/build/{binutils,gcc1,gcc2,kheaders} toolchain/src/binutils-2.44 toolchain/src/gcc-14.3.0
rm -f toolchain/build/.{sources,binutils,gcc1,kheaders,gcc2}

log "stage 1 ($(date +%H:%M))"
"$R/toolchain/build-toolchain.sh"

log "glibc ($(date +%H:%M))"
"$R/build-glibc.sh" configure build install

log "stage 2 ($(date +%H:%M))"
STAGE=2 "$R/toolchain/build-toolchain.sh"

log "libgcc spec of the new compiler"
toolchain/out/bin/$T-gcc -dumpspecs | grep -A1 '^\*libgcc:'

log "tests ($(date +%H:%M))"
"$R/test/run-glibc-test.sh" > test/out-run.log 2>&1 || true
grep -a '##########\|FAIL\|RESULT' test/out-run.log
log "done ($(date +%H:%M))"
