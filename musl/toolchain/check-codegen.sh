#!/bin/bash
# Check the ILP32 code generation of the stage 1 compiler (no C library needed):
#   data model and predefined macros, ELF32 objects, R_AARCH64_P32_* relocations in PIC and shared
#   objects, the TLS models (TLSDESC, initial-exec, local-exec), the musl dynamic linker name, and
#   the libc-free syscall test of ilp32-test built into out/test/.
#
#   check-codegen.sh
set -uo pipefail
R=$(dirname "$(realpath "$0")")		# this directory of test-ilp32
WORK=${MUSL_WORK:-$HOME/work/ilp32-musl}	# toolchain, builds and results (not in git)
mkdir -p "$WORK/toolchain"
cd "$WORK/toolchain"
TOP=$PWD
T=aarch64-linux-musl_ilp32
P=$PWD/out/bin/$T-
W=$PWD/out/test
mkdir -p "$W"
fails=0
check() { # <what> <command...>
	local what=$1; shift
	if "$@" > "$W/last.log" 2>&1; then echo "ok    $what"; else echo "FAIL  $what"; sed 's/^/      /' "$W/last.log"; fails=$((fails + 1)); fi
}
has() { grep -q -- "$1" "$2" || { echo "missing '$1' in $2"; return 1; }; }
hasnot() { ! grep -q -- "$1" "$2" || { echo "unexpected '$1' in $2"; grep -- "$1" "$2"; return 1; }; }

cat > "$W/model.c" <<'EOF'
#ifndef __ILP32__
#error __ILP32__ not defined
#endif
#ifdef __LP64__
#error __LP64__ defined
#endif
_Static_assert(sizeof(int) == 4, "int");
_Static_assert(sizeof(long) == 4, "long");
_Static_assert(sizeof(void *) == 4, "pointer");
_Static_assert(sizeof(long long) == 8, "long long");
_Static_assert(sizeof(__SIZE_TYPE__) == 4, "size_t");
_Static_assert(_Alignof(long long) == 8, "long long alignment");
_Static_assert(sizeof(long double) == 16, "long double");
int dummy;
EOF
check "data model (long, pointer, size_t 4 bytes, __ILP32__)" ${P}gcc -c -o "$W/model.o" "$W/model.c"

cat > "$W/pic.c" <<'EOF'
extern int ext_var;
extern void ext_fn(void);
int local_var = 1;
int *ptr_table[] = { &local_var, &ext_var };
void (*fn_ptr)(void) = ext_fn;
int get_ext(void) { ext_fn(); return ext_var + local_var; }
long ptr_bits(void) { return (long)&ext_var; }
EOF
check "PIC object compiles" ${P}gcc -O2 -fPIC -c -o "$W/pic.o" "$W/pic.c"
readelf -W -h "$W/pic.o" > "$W/pic.h.txt"; readelf -W -r "$W/pic.o" > "$W/pic.r.txt"
check "object is ELF32 AArch64" sh -c "grep -q 'ELF32' '$W/pic.h.txt' && grep -q 'AArch64' '$W/pic.h.txt'"
check "object uses R_AARCH64_P32_* relocations" has R_AARCH64_P32_ "$W/pic.r.txt"
check "object has no LP64 R_AARCH64_ABS64" hasnot "R_AARCH64_ABS64" "$W/pic.r.txt"

check "shared object links" ${P}gcc -shared -nostdlib -o "$W/libpic.so" "$W/pic.o"
readelf -W -r "$W/libpic.so" > "$W/so.r.txt"; readelf -W -h "$W/libpic.so" > "$W/so.h.txt"
check "shared object is ELF32 DYN" sh -c "grep -q 'ELF32' '$W/so.h.txt' && grep -q 'DYN' '$W/so.h.txt'"
check "shared object: P32 GLOB_DAT/ABS32/RELATIVE dynamic relocations" \
	sh -c "grep -Eq 'R_AARCH64_P32_(GLOB_DAT|ABS32|RELATIVE)' '$W/so.r.txt'"

cat > "$W/tls.c" <<'EOF'
extern __thread int ext_tls;
static __thread int local_tls;
int get_ext_tls(void) { return ext_tls; }
int *addr_local_tls(void) { return &local_tls; }
EOF
check "TLS general dynamic (TLSDESC) compiles" ${P}gcc -O2 -fPIC -c -o "$W/tls-gd.o" "$W/tls.c"
readelf -W -r "$W/tls-gd.o" > "$W/tls-gd.r.txt"
check "TLSDESC uses P32 relocations" has "R_AARCH64_P32_TLSDESC" "$W/tls-gd.r.txt"
check "TLS initial-exec compiles" ${P}gcc -O2 -ftls-model=initial-exec -c -o "$W/tls-ie.o" "$W/tls.c"
readelf -W -r "$W/tls-ie.o" > "$W/tls-ie.r.txt"
check "initial-exec uses P32 TLSIE relocations" has "R_AARCH64_P32_TLSIE" "$W/tls-ie.r.txt"
check "TLS local-exec compiles" ${P}gcc -O2 -ftls-model=local-exec -c -o "$W/tls-le.o" "$W/tls.c"
readelf -W -r "$W/tls-le.o" > "$W/tls-le.r.txt"
check "local-exec uses P32 TLSLE relocations" has "R_AARCH64_P32_TLSLE" "$W/tls-le.r.txt"
check "shared object with TLSDESC links" ${P}gcc -shared -nostdlib -o "$W/libtls.so" "$W/tls-gd.o" -Wl,--unresolved-symbols=ignore-all
readelf -W -r "$W/libtls.so" > "$W/tls-so.r.txt"
check "shared object has dynamic P32_TLSDESC" has "R_AARCH64_P32_TLSDESC" "$W/tls-so.r.txt"

${P}gcc -dumpspecs > "$W/specs.txt"
check "musl dynamic linker is /lib/ld-musl-aarch64_ilp32.so.1" sh -c \
	"${P}gcc -### -o /dev/null '$W/model.o' 2>&1 | grep -q 'ld-musl-aarch64_ilp32.so.1'"
check "linker emulation aarch64linux32" sh -c "${P}gcc -### -o /dev/null '$W/model.o' 2>&1 | grep -q aarch64linux32"

SYSCALL_TEST=${SYSCALL_TEST:-$(realpath "$R/../../tests/syscall-test.c")}
check "libc-free syscall test builds (static)" ${P}gcc -static -nostdlib -ffreestanding -fno-stack-protector \
	-fno-builtin -O2 -Wall -Wl,--build-id=none -o "$W/syscall-test-ilp32" "$SYSCALL_TEST" -lgcc
readelf -W -h "$W/syscall-test-ilp32" > "$W/st.h.txt" 2>&1
check "syscall test is ELF32 EXEC AArch64" sh -c "grep -q ELF32 '$W/st.h.txt' && grep -q EXEC '$W/st.h.txt'"

echo "$fails check(s) failed"
exit $((fails != 0))
