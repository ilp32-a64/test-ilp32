# Paths of the kernel trees, sourced by the scripts of this repository. Override in the environment.
#   KERNEL_REPO   git repository with the ILP32 branches (ilp32-a64/linux)
#   KERNEL_WT     one git work tree per branch: $KERNEL_WT/<branch> (created by the scripts if missing)
#   KERNEL_BUILD  build directories (O=): $KERNEL_BUILD/<branch>[-noa32], $KERNEL_BUILD/qemu-<name>
#   JOBS          parallel make jobs (default: all CPUs)
KERNEL_REPO=${KERNEL_REPO:-$HOME/work/linux}
KERNEL_WT=${KERNEL_WT:-$HOME/work/wt}
KERNEL_BUILD=${KERNEL_BUILD:-$HOME/work/build}
JOBS=${JOBS:-$(nproc)}
export ARCH=arm64 CROSS_COMPILE=${CROSS_COMPILE:-aarch64-linux-gnu-}

# work tree of a branch, created from $KERNEL_REPO when missing
kernel_wt() {
	[ -d "$KERNEL_WT/$1" ] || git -C "$KERNEL_REPO" worktree add -q "$KERNEL_WT/$1" "$1"
	echo "$KERNEL_WT/$1"
}
