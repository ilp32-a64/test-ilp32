#!/bin/bash
# Test the installed ILP32 compiler and runtime (the hand-off trees in /, as the packages install them):
# C, C++ with exceptions, threads, OpenMP, atomics, libm; dynamic, static and PIE; each program is run.
# Run inside the clean chroot (compilibary).
set -uo pipefail
T=aarch64-linux-gnu_ilp32
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
pass=0 fail=0
ok()  { echo "ok    $*"; pass=$((pass+1)); }
bad() { echo "FAIL  $*"; fail=$((fail+1)); }
t() { # <name> <expected output> <compiler and flags...> [-- <libraries>] (source in $D/<name>.c or .cc)
	# (libraries after the source: Debian's gcc links with --as-needed)
	local n=$1 want=$2 src out a=() l=(); shift 2
	while [ $# -gt 0 ] && [ "$1" != -- ]; do a+=("$1"); shift; done
	[ $# -gt 0 ] && { shift; l=("$@"); }
	src=$D/$n.c; [ -f "$src" ] || src=$D/$n.cc
	if ! "${a[@]}" -o "$D/$n" "$src" "${l[@]}" 2> "$D/$n.err"; then bad "$n: build: $(head -3 "$D/$n.err" | tr '\n' ' ')"; return; fi
	out=$(timeout 60 "$D/$n" 2>&1); local rc=$?	# (a broken lock can hang instead of failing)
	[ $rc -ne 124 ] || out="$out (timed out after 60 s)"
	if [ $rc -eq 0 ] && [ "$out" = "$want" ]; then ok "$n"; else bad "$n: rc=$rc output '$out' (want '$want')"; fi
}

cat > "$D/hello.c" <<'EOF'
#include <stdio.h>
int main(void) { printf("%zu %zu\n", sizeof(long), sizeof(void *)); return 0; }
EOF
cat > "$D/math.c" <<'EOF'
#include <math.h>
#include <stdio.h>
int main(void) { volatile double x = 2.0; printf("%.6f\n", sqrt(x) * cos(0.0)); return 0; }
EOF
cat > "$D/omp.c" <<'EOF'
#include <omp.h>
#include <stdio.h>
int main(void) {
	long s = 0; int nt = 0;
#pragma omp parallel reduction(+:s)
	{
#pragma omp single
		nt = omp_get_num_threads();
#pragma omp for
		for (int i = 1; i <= 1000; i++) s += i;
	}
	printf("%ld %s\n", s, nt >= 1 ? "threads" : "none");
	return 0;
}
EOF
cat > "$D/atomic.c" <<'EOF'
#include <stdatomic.h>
#include <stdio.h>
struct big { long long a, b; };
int main(void) {
	_Atomic struct big v = { 1, 2 }; struct big w = { 3, 4 };
	atomic_store(&v, w); struct big r = atomic_load(&v);
	_Atomic long long c = 0; atomic_fetch_add(&c, 5);
	printf("%lld %lld %lld\n", r.a, r.b, (long long)c);
	return 0;
}
EOF
# omp.h's lock types against libgomp's configured sizes (AArch64 ILP32: 16/8 and 24/8)
cat > "$D/ompsize.c" <<'EOF'
#include <omp.h>
#include <stdio.h>
int main(void) {
	printf("%zu/%zu %zu/%zu\n", sizeof(omp_lock_t), _Alignof(omp_lock_t),
	       sizeof(omp_nest_lock_t), _Alignof(omp_nest_lock_t));
	return 0;
}
EOF
# nest locks used from a plain pthread, the lock right before a barrier (as libgomp's lock-3.c):
# a too small omp_nest_lock_t lets libgomp overwrite the barrier
cat > "$D/nestlock.c" <<'EOF'
#include <omp.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
static struct { omp_nest_lock_t lock; pthread_barrier_t bar; } s;
static void *tf(void *p) {
	if (p) { if (omp_test_nest_lock(&s.lock) != 1 || omp_test_nest_lock(&s.lock) != 2) abort(); }
	pthread_barrier_wait(&s.bar);
	if (!p && omp_test_nest_lock(&s.lock) != 0) abort();
	pthread_barrier_wait(&s.bar);
	if (p) { if (omp_test_nest_lock(&s.lock) != 3) abort(); omp_unset_nest_lock(&s.lock);
		omp_unset_nest_lock(&s.lock); omp_unset_nest_lock(&s.lock); }
	pthread_barrier_wait(&s.bar);
	if (!p) { if (omp_test_nest_lock(&s.lock) != 1) abort(); omp_unset_nest_lock(&s.lock); }
	return NULL;
}
int main(void) {
	pthread_t th; omp_lock_t l;
	omp_init_nest_lock(&s.lock); pthread_barrier_init(&s.bar, NULL, 2);
	pthread_create(&th, NULL, tf, NULL); tf(""); pthread_join(th, NULL);
	omp_destroy_nest_lock(&s.lock);
	omp_init_lock(&l); omp_set_lock(&l); if (omp_test_lock(&l)) abort(); omp_unset_lock(&l); omp_destroy_lock(&l);
	printf("nest lock ok\n");
	return 0;
}
EOF
cat > "$D/cxx.cc" <<'EOF'
#include <iostream>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>
#include <atomic>
static void thrower(int i) { if (i % 2) throw std::runtime_error("odd " + std::to_string(i)); }
int main() {
	int caught = 0;
	for (int i = 0; i < 10; i++) try { thrower(i); } catch (const std::exception &e) { caught++; }
	std::atomic<int> n{0}; std::vector<std::thread> v;
	for (int i = 0; i < 4; i++) v.emplace_back([&n] { n += 1; });
	for (auto &t : v) t.join();
	std::cout << caught << " " << n << std::endl;
	return 0;
}
EOF

echo "== compilers"
"$T-gcc" --version | head -1; "$T-g++" --version | head -1; "$T-ld" --version | head -1
for f in libgomp.spec libgomp.so libatomic.so libstdc++.so libgcc_s.so libc.so crt1.o; do
	echo "  $f -> $("$T-gcc" -print-file-name=$f)"
done
echo "== builds and runs"
t hello "4 4" "$T-gcc" -O2
cp "$D/hello.c" "$D/hello-static.c"; cp "$D/hello.c" "$D/hello-nopie.c"; cp "$D/hello.c" "$D/hello-bti.c"
t hello-static "4 4" "$T-gcc" -O2 -static
t hello-nopie "4 4" "$T-gcc" -O2 -no-pie
t math "1.414214" "$T-gcc" -O2 -- -lm
t omp "500500 threads" "$T-gcc" -O2 -fopenmp
cp "$D/omp.c" "$D/omp-static.c"; t omp-static "500500 threads" "$T-gcc" -O2 -fopenmp -static
t atomic "3 4 5" "$T-gcc" -O2 -- -latomic
cp "$D/atomic.c" "$D/atomic-static.c"; t atomic-static "3 4 5" "$T-gcc" -O2 -static -- -latomic
t ompsize "16/8 24/8" "$T-gcc" -O2 -fopenmp
for i in 1 2 3; do cp "$D/nestlock.c" "$D/nestlock$i.c"; t nestlock$i "nest lock ok" "$T-gcc" -O2 -fopenmp -pthread; done
cp "$D/nestlock.c" "$D/nestlock-static.c"; t nestlock-static "nest lock ok" "$T-gcc" -O2 -fopenmp -pthread -static
# Debian's test line: libm and libatomic after the source
cp "$D/omp.c" "$D/debian-line.c"; t debian-line "500500 threads" "$T-gcc" -O2 -fopenmp -- -lm -latomic
t cxx "5 4" "$T-g++" -O2 -pthread
cp "$D/cxx.cc" "$D/cxx-static.cc"; t cxx-static "5 4" "$T-g++" -O2 -static -pthread
cp "$D/cxx.cc" "$D/cxx-staticlib.cc"; t cxx-staticlib "5 4" "$T-g++" -O2 -static-libstdc++ -static-libgcc -pthread
t hello-bti "4 4" "$T-gcc" -O2 -mbranch-protection=bti -Wl,-z,force-bti
echo "== loaded libraries of the dynamic C++ program"
"$T-g++" -O2 -pthread -o "$D/cxx2" "$D/cxx.cc" && LD_TRACE_LOADED_OBJECTS=1 "$D/cxx2" | sed 's/ (0x.*//'
"$T-readelf" -l "$D/cxx2" | grep -o 'interpreter: [^]]*'
echo "RESULT: $pass ok, $fail failed"
[ $fail -eq 0 ]
