# test-ilp32

Toolchain and tests for the AArch64 ILP32 ABI (32-bit `long` and pointers on a 64-bit kernel).
The kernel is [ilp32-a64/linux-ilp32](https://github.com/ilp32-a64/linux-ilp32) branch `ilp32-6.12.y` (its other
branches are deprecated), the C libraries are glibc 2.41
([ilp32-a64/glibc-ilp32](https://github.com/ilp32-a64/glibc-ilp32) branch `ilp32-2.41`) and musl 1.2.5
([ilp32-a64/musl-ilp32](https://github.com/ilp32-a64/musl-ilp32) branch `ilp32-1.2.5`).

QEMU user mode has no AArch64 ILP32 support, so the tests boot our kernel in QEMU system emulation
(`qemu-system-aarch64 -M virt -cpu cortex-a35 -smp 2 -m 256`, other CPUs with `QEMU_CPU`) with a small
initramfs, run the test programs and power off.

## Layout

| Path | Content |
|---|---|
| `toolchain/build-toolchain.sh` | ILP32 cross toolchain `aarch64-linux-gnu_ilp32`: binutils 2.35.2, GCC 10.5, glibc 2.30 (`ilp32-a64/glibc-ilp32` branch `ilp32-2.30`), kernel headers from an ILP32 kernel tree. **Deprecated**: no longer used or tested, and no script uses it; the toolchain and C library are the ones of `glibc/` (GCC 14.3.0, glibc 2.41) |
| `tests/` | test programs (`build.sh` builds them into `tests/out/` with the `glibc/` toolchain: GCC 14.3.0, glibc 2.41) |
| `qemu/` | QEMU kernel (`build-kernel.sh`), initramfs with a static ILP32 `/init` and the glibc 2.41 runtime (`init.c`, `make-initramfs.sh`), boot and test (`run.sh`, CPU `QEMU_CPU`, default cortex-a35) |
| `kernel/` | kernel build test (`build.sh`), AArch32 on/off check (`verify.sh`), vDSO relocation check test (`test-vdso-check.sh`), paths (`env.sh`) |
| `run-all.sh` | tests, initramfs, kernel builds and QEMU tests for one or more kernel branches (default `ilp32-6.12.y`) |
| `musl/` | musl 1.2.5 for AArch64 ILP32 (`ilp32-a64/musl-ilp32`, branch `ilp32-1.2.5`): cross toolchain `aarch64-linux-musl_ilp32` with the versions and patches of OpenWrt 25.12 (`toolchain/`), QEMU tests and libc-test (`test/`) |
| `glibc/` | glibc 2.41 for AArch64 ILP32 (`ilp32-a64/glibc-ilp32`, branch `ilp32-2.41`, 64-bit `time_t`): cross toolchain `aarch64-linux-gnu_ilp32` with GCC 14.3.0 and binutils 2.44 (`toolchain/`; GCC with the ILP32 fixes in `toolchain/patches/`), `build-glibc.sh`, `rebuild-all.sh`, LP64 regression check (`lp64-check.sh`), QEMU tests (`test/`) |
| `qemu/notime32-init.c` | `/init` for `NOTIME32=1` test runs (see below) |

## Tests

| Program | ABI | Checks |
|---|---|---|
| `syscall-test-ilp32` | ILP32, static, no C library | data model, auxv, write, uname, getpid, `clock_gettime` (time32) and `clock_gettime64`, mmap and stack below 4 GB, vDSO: ELF32, `ET_DYN`, `__kernel_clock_gettime` in the dynamic symbol table |
| `glibc-test-ilp32` | ILP32, glibc 2.41 | type sizes, malloc, threads, `clock_gettime` through the vDSO compared with the system call (speed and time over a 200 ms sleep), signal handler and return, fork, stat, dlopen |
| `cxx-test-ilp32` | ILP32, libstdc++ (GCC 14.3.0) | STL, exceptions through 50 frames, `std::thread` |
| `aarch32-test` | AArch32 (armhf), static | data model, uname (`aarch64`, `armv8l` with `PER_LINUX32`), time, signals, fork, mmap; on a kernel without `AARCH32_EL0` it must be refused with `ENOEXEC` |

`/init` prints one line per program and `ILP32-TEST-RESULT: <failed> of <total> program(s) failed`.
Timings in QEMU (TCG) are not performance numbers; they only show whether the vDSO is used.

## Usage

Ubuntu 24.04 packages:

```
sudo apt-get install build-essential g++ gawk m4 bzip2 flex bison bc libssl-dev libelf-dev cpio \
    gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu gcc-arm-linux-gnueabihf qemu-system-arm
```

Parallel jobs: `JOBS=<n>` (default: all CPUs). Kernel trees (defaults in `kernel/env.sh`): a clone of `ilp32-a64/linux-ilp32` in `~/work/linux-ilp32`, one work tree per
branch in `~/work/wt/<branch>`, build directories in `~/work/build/`.

```
git clone https://github.com/ilp32-a64/linux-ilp32.git ~/work/linux-ilp32
glibc/rebuild-all.sh       # the ILP32 toolchain (GCC 14.3.0, glibc 2.41), once
./run-all.sh               # ilp32-6.12.y
```

`run-all.sh` builds the test programs and the initramfs with that toolchain, then for each branch a full
kernel build with AArch32 and the QEMU test with AArch32 on and off. Single steps:

```
./kernel/build.sh ilp32-6.12.y [a32|noa32]
./qemu/build-kernel.sh ~/work/wt/ilp32-6.12.y ilp32-6.12.y
./qemu/run.sh ilp32-6.12.y         # AARCH32=0 for a kernel without AARCH32_EL0, QEMU_CPU=max for PAC/BTI/SVE
./kernel/test-vdso-check.sh ilp32-6.12.y
```

## C libraries: musl and glibc 2.41

The scripts in `musl/` and `glibc/` run from this tree and keep sources, toolchains, builds and results in a
work directory: `MUSL_WORK` (default `~/work/ilp32-musl`) and `GLIBC_WORK` (default `~/work/ilp32-glibc`).
Kernel headers come from `~/work/wt/ilp32-6.12.y`, musl from `~/work/musl-ilp32`, glibc from
`~/work/glibc-ilp32-2.41`. Each script describes its options in its header.

```
musl/toolchain/build-stage1.sh && musl/toolchain/build-stage2.sh
musl/test/run-musl-test.sh                  # installs MUSL_BUILD (default $MUSL_WORK/build-musl) first
musl/test/build-busybox.sh && ABI=ilp32 musl/test/run-libc-test.sh     # libc-test in ~/work/libc-test
glibc/rebuild-all.sh                        # stage 1, glibc, stage 2 (C++), QEMU tests
```

`NOTIME32=1` on the test scripts boots with `qemu/notime32-init.c` as `/init`: a seccomp filter makes every
time32 and stat64 system call of the ILP32 ABI fail with `SIGSYS` for the whole run, so a C library that
still uses one is caught.

Results on `ilp32-6.12.y` (QEMU, kernel without AArch32):

| Test | Normal | `NOTIME32=1` |
|---|---|---|
| musl 1.2.5: `musl-test` (static, dynamic), `cxx-test`, `syscall-test` | 4/4 pass | 3/3 pass (`syscall-test` calls time32 on purpose, not run) |
| musl 1.2.5: libc-test with busybox | 453/480 pass | 453/480 pass, no `SIGSYS` |
| glibc 2.41: `glibc-test`, `cxx-test`, libc tests (static, dynamic), `syscall-test` | 5/5 pass | 4/4 pass |

libc-test counts a test as failed when it exits non-zero or prints anything. Of the 27, 9 exit non-zero:
mntent, strptime, strtold and pthread_atfork-errno-clobber (static and dynamic) and powf, tests newer
than musl 1.2.5 or affected by the root resource limits; the other 18 print accuracy notes (math) or
diagnostics (wordexp) and exit 0. The LP64 musl fails the same tests (plus 8 that need a shell: its
run had no busybox).

## Results

Test programs built with GCC 14.3.0 and glibc 2.41, QEMU `-cpu cortex-a35`:

| Kernel | AArch32 | ILP32 tests | `aarch32-test` | vDSO `clock_gettime` / system call (QEMU) |
|---|---|---|---|---|
| `ilp32-6.12.y` (`a2b38d6f5f`) | on | 3/3 pass | pass | ~0.12 us / ~19 us |
| `ilp32-6.12.y` (`a2b38d6f5f`) | off | 3/3 pass | refused (`ENOEXEC`) | ~0.12 us / ~18 us |

The other kernel branches (`ilp32-6.12`, `ilp32-6.6.y`, `ilp32-6.6`, `ilp32-6.6-olk`, `ilp32-5.10`,
`ilp32-5.10-olk`) are deprecated and no longer tested.

## License

GPL-2.0-only, see `LICENSE`.
