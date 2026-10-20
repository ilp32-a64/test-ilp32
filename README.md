# ilp32-test

Toolchain and tests for the AArch64 ILP32 ABI (32-bit `long` and pointers on a 64-bit kernel).
The kernel branches are in [ilp32-a64/linux](https://github.com/ilp32-a64/linux), the C library in
[ilp32-a64/glibc](https://github.com/ilp32-a64/glibc).

QEMU user mode has no AArch64 ILP32 support, so the tests boot our kernel in QEMU system emulation
(`qemu-system-aarch64 -M virt -cpu cortex-a35 -smp 2 -m 256`) with a small initramfs, run the test programs
and power off.

## Layout

| Path | Content |
|---|---|
| `toolchain/build-toolchain.sh` | ILP32 cross toolchain `aarch64-linux-gnu_ilp32`: binutils 2.35.2, GCC 10.5, glibc 2.30 (`ilp32-a64/glibc` branch `ilp32-2.30`), kernel headers from an ILP32 kernel tree |
| `tests/` | test programs (`build.sh` builds them into `tests/out/`) |
| `qemu/` | QEMU kernel (`build-kernel.sh`), initramfs with a static ILP32 `/init` (`init.c`, `make-initramfs.sh`), boot and test (`run.sh`) |
| `kernel/` | kernel build test (`build.sh`), AArch32 on/off check (`verify.sh`), vDSO relocation check test (`test-vdso-check.sh`), paths (`env.sh`) |
| `run-all.sh` | everything for one or more kernel branches |

## Tests

| Program | ABI | Checks |
|---|---|---|
| `syscall-test-ilp32` | ILP32, static, no C library | data model, auxv, write, uname, getpid, `clock_gettime` (time32) and `clock_gettime64`, mmap and stack below 4 GB, vDSO: ELF32, `ET_DYN`, `__kernel_clock_gettime` in the dynamic symbol table |
| `glibc-test-ilp32` | ILP32, glibc | type sizes, malloc, threads, `clock_gettime` through the vDSO compared with the system call (speed and time over a 200 ms sleep), signal handler and return, fork, stat, dlopen |
| `cxx-test-ilp32` | ILP32, libstdc++ | STL, exceptions through 50 frames, `std::thread` |
| `aarch32-test` | AArch32 (armhf), static | data model, uname (`aarch64`, `armv8l` with `PER_LINUX32`), time, signals, fork, mmap; on a kernel without `AARCH32_EL0` it must be refused with `ENOEXEC` |

`/init` prints one line per program and `ILP32-TEST-RESULT: <failed> of <total> program(s) failed`.
Timings in QEMU (TCG) are not performance numbers; they only show whether the vDSO is used.

## Usage

Ubuntu 24.04 packages:

```
sudo apt-get install build-essential g++ gawk m4 bzip2 flex bison bc libssl-dev libelf-dev cpio \
    gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu gcc-arm-linux-gnueabihf qemu-system-arm
```

Kernel trees (defaults in `kernel/env.sh`): a clone of `ilp32-a64/linux` in `~/work/linux`, one work tree per
branch in `~/work/wt/<branch>`, build directories in `~/work/build/`.

```
git clone https://github.com/ilp32-a64/linux.git ~/work/linux
./run-all.sh ilp32-6.6 ilp32-5.10
```

`run-all.sh` builds the toolchain once (about 15 minutes on 6 cores), then for each branch a full kernel
build with AArch32 and the QEMU test with AArch32 on and off. Single steps:

```
./kernel/build.sh ilp32-6.6 [a32|noa32]
./qemu/build-kernel.sh ~/work/wt/ilp32-6.6 ilp32-6.6
./qemu/run.sh ilp32-6.6            # AARCH32=0 for a kernel without AARCH32_EL0
./kernel/test-vdso-check.sh ilp32-6.6
```

## Results

| Kernel | AArch32 | ILP32 tests | `aarch32-test` | vDSO `clock_gettime` / system call (QEMU) |
|---|---|---|---|---|
| `ilp32-6.6` | on | 3/3 pass | pass | ~0.1 us / ~15 us |
| `ilp32-6.6` | off | 3/3 pass | refused (`ENOEXEC`) | |
| `ilp32-5.10` | on | 3/3 pass | pass | ~0.1 us / ~14 us |
| `ilp32-5.10` | off | 3/3 pass | refused (`ENOEXEC`) | |
| `ilp32-6.6-olk` (openEuler series only) | on | `syscall-test`, `glibc-test` fail: the ILP32 vDSO has no usable symbols | | ~16 us / ~16 us |

## License

GPL-2.0-only, see `LICENSE`.
