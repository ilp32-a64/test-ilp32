/*
 * Minimal static AArch64 test without a C library: raw syscalls only.
 *
 * Built as ILP32 (-mabi=ilp32) to check the ILP32 kernel support (hardware or QEMU system emulation), and as
 * LP64 from the same source to check the program itself (the LP64 build runs under qemu-aarch64; QEMU user
 * mode has no ILP32 support).
 *
 * Checks: data model, initial stack and auxv (ELF32 words for ILP32), write, uname, getpid,
 * clock_gettime (time32 for ILP32) and clock_gettime64 (ILP32 only), mmap below 4 GB, and the vDSO
 * (AT_SYSINFO_EHDR: ELF class, ET_DYN and a dynamic symbol table with __kernel_clock_gettime, which the
 * ILP32 vDSO link fix is about: a PIE vDSO is ET_DYN too but has no usable symbols).
 * Exit code: number of failed checks.
 */

typedef long long reg_t;            /* syscall registers are 64-bit in both ABIs */

#define NR_write            64
#define NR_exit_group       94
#define NR_clock_gettime   113      /* ILP32: 32-bit time_t (old_timespec32) */
#define NR_uname           160
#define NR_getpid          172
#define NR_mmap            222      /* ILP32: mmap2 semantics (offset in pages) */
#define NR_clock_gettime64 403      /* ILP32 only: 64-bit time_t */

#define AT_NULL          0
#define AT_PAGESZ        6
#define AT_HWCAP        16
#define AT_SYSINFO_EHDR 33

static reg_t sc(reg_t n, reg_t a, reg_t b, reg_t c, reg_t d, reg_t e, reg_t f)
{
	register reg_t x8 __asm__("x8") = n;
	register reg_t x0 __asm__("x0") = a;
	register reg_t x1 __asm__("x1") = b;
	register reg_t x2 __asm__("x2") = c;
	register reg_t x3 __asm__("x3") = d;
	register reg_t x4 __asm__("x4") = e;
	register reg_t x5 __asm__("x5") = f;
	__asm__ volatile("svc #0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2), "r"(x3), "r"(x4), "r"(x5) : "memory");
	return x0;
}

static unsigned long slen(const char *s) { unsigned long n = 0; while (s[n]) n++; return n; }
static void out(const char *s) { sc(NR_write, 1, (reg_t)(unsigned long)s, (reg_t)slen(s), 0, 0, 0); }

static void outu(unsigned long long v, int base)
{
	char b[24]; int i = sizeof(b) - 1;
	b[i] = 0;
	do { b[--i] = "0123456789abcdef"[v % base]; v /= base; } while (v);
	if (base == 16) { b[--i] = 'x'; b[--i] = '0'; }
	out(&b[i]);
}

/* syscall return value that is not an error (-4095..-1) */
#define SC_OK(r) ((unsigned long long)(r) < (unsigned long long)-4095LL)

static int fails;
static void check(const char *what, int ok)
{
	out(ok ? "  ok    " : "  FAIL  "); out(what); out("\n");
	if (!ok) fails++;
}

struct utsname_k { char sysname[65], nodename[65], release[65], version[65], machine[65], domainname[65]; };
struct ts32 { int sec; int nsec; };              /* old_timespec32 */
struct ts64 { long long sec; long long nsec; };  /* __kernel_timespec */

#ifdef __ILP32__
#define ABI "ILP32"
#else
#define ABI "LP64"
#endif

/*
 * Look up a defined symbol in the vDSO's dynamic symbol table (PT_DYNAMIC -> DT_HASH or DT_GNU_HASH for the
 * symbol count, DT_SYMTAB, DT_STRTAB; the LP64 vDSO has DT_HASH, the ILP32 vDSO only DT_GNU_HASH).
 * A vDSO without a dynamic symbol table (e.g. linked without -shared) cannot be used by the C library.
 * Returns the number of dynamic symbols in *nsyms and 1 if <name> is defined.
 */
#ifdef __ILP32__
struct ephdr { unsigned p_type, p_offset, p_vaddr, p_paddr, p_filesz, p_memsz, p_flags, p_align; };
struct edyn { int d_tag; unsigned d_val; };
struct esym { unsigned st_name, st_value, st_size; unsigned char st_info, st_other; unsigned short st_shndx; };
#define E_PHOFF(e)  (*(const unsigned *)((e) + 28))
#define E_PHNUM(e)  (*(const unsigned short *)((e) + 44))
#else
struct ephdr { unsigned p_type, p_flags; unsigned long long p_offset, p_vaddr, p_paddr, p_filesz, p_memsz, p_align; };
struct edyn { long long d_tag; unsigned long long d_val; };
struct esym { unsigned st_name; unsigned char st_info, st_other; unsigned short st_shndx; unsigned long long st_value, st_size; };
#define E_PHOFF(e)  (*(const unsigned long long *)((e) + 32))
#define E_PHNUM(e)  (*(const unsigned short *)((e) + 56))
#endif
#define PT_LOAD     1
#define PT_DYNAMIC  2
#define DT_NULL     0
#define DT_HASH     4
#define DT_STRTAB   5
#define DT_SYMTAB   6
#define DT_GNU_HASH 0x6ffffef5

static int seq(const char *a, const char *b) { while (*a && *a == *b) { a++; b++; } return *a == *b; }

static int vdso_has(const unsigned char *e, const char *name, unsigned *nsyms)
{
	const struct ephdr *ph = (const struct ephdr *)(e + E_PHOFF(e));
	const struct edyn *dyn = 0;
	unsigned long bias = 0;
	int have_load = 0;
	*nsyms = 0;
	for (unsigned i = 0; i < E_PHNUM(e); i++) {
		if (ph[i].p_type == PT_LOAD && !have_load) { bias = (unsigned long)e - (unsigned long)ph[i].p_vaddr; have_load = 1; }
		if (ph[i].p_type == PT_DYNAMIC) dyn = (const struct edyn *)(e + ph[i].p_offset);
	}
	if (!dyn || !have_load) return 0;
	const unsigned *hash = 0, *gnu = 0; const struct esym *sym = 0; const char *str = 0;
	for (; dyn->d_tag != DT_NULL; dyn++) {
		if (dyn->d_tag == DT_HASH) hash = (const unsigned *)(bias + (unsigned long)dyn->d_val);
		if (dyn->d_tag == DT_GNU_HASH) gnu = (const unsigned *)(bias + (unsigned long)dyn->d_val);
		if (dyn->d_tag == DT_SYMTAB) sym = (const struct esym *)(bias + (unsigned long)dyn->d_val);
		if (dyn->d_tag == DT_STRTAB) str = (const char *)(bias + (unsigned long)dyn->d_val);
	}
	if (!sym || !str) return 0;
	if (hash) {
		*nsyms = hash[1];               /* nchain = number of symbols */
	} else if (gnu) {
		/* GNU hash: nbuckets, symoffset, bloom words, bloom shift, bloom[] (address-sized), buckets[], chains[] */
		unsigned nb = gnu[0], symoff = gnu[1], nbloom = gnu[2];
		const unsigned *buckets = (const unsigned *)((const unsigned long *)(gnu + 4) + nbloom);
		const unsigned *chains = buckets + nb;
		unsigned last = 0;
		for (unsigned i = 0; i < nb; i++)
			if (buckets[i] > last) last = buckets[i];
		if (last >= symoff)
			while (!(chains[last - symoff] & 1)) last++;
		*nsyms = last + 1;
	} else {
		return 0;
	}
	for (unsigned i = 1; i < *nsyms; i++)
		if (sym[i].st_shndx != 0 && seq(str + sym[i].st_name, name)) return 1;
	return 0;
}

/* sp points to argc; then argv[], NULL, envp[], NULL, auxv pairs. Words are pointer-sized (32-bit in ILP32). */
void cmain(unsigned long *sp)
{
	unsigned long argc = sp[0], *p = sp + 1 + argc + 1, vdso = 0, hwcap = 0, pagesz = 0;
	while (*p) p++;
	for (p++; p[0] != AT_NULL; p += 2) {
		if (p[0] == AT_SYSINFO_EHDR) vdso = p[1];
		if (p[0] == AT_HWCAP) hwcap = p[1];
		if (p[0] == AT_PAGESZ) pagesz = p[1];
	}

	out("ILP32 syscall test, built as " ABI "\n");
	out("  sizeof(long)="); outu(sizeof(long), 10); out(" sizeof(void*)="); outu(sizeof(void *), 10);
	out(" sp="); outu((unsigned long)sp, 16); out(" argc="); outu(argc, 10); out("\n");
#ifdef __ILP32__
	check("long and pointers are 32-bit", sizeof(long) == 4 && sizeof(void *) == 4);
#else
	check("long and pointers are 64-bit", sizeof(long) == 8 && sizeof(void *) == 8);
#endif
	check("auxv: AT_PAGESZ is 4096", pagesz == 4096);
	out("  AT_HWCAP="); outu(hwcap, 16); out(" AT_SYSINFO_EHDR="); outu(vdso, 16); out("\n");

	check("write", sc(NR_write, 1, (reg_t)(unsigned long)"  (write ok)\n", 13, 0, 0, 0) == 13);

	struct utsname_k u;
	check("uname", sc(NR_uname, (reg_t)(unsigned long)&u, 0, 0, 0, 0, 0) == 0);
	out("  uname: "); out(u.sysname); out(" "); out(u.release); out(" "); out(u.machine); out("\n");
	check("uname machine is aarch64", u.machine[0] == 'a' && u.machine[1] == 'a' && u.machine[2] == 'r');

	reg_t pid = sc(NR_getpid, 0, 0, 0, 0, 0, 0);
	out("  pid="); outu((unsigned long long)pid, 10); out("\n");
	check("getpid > 0", pid > 0);

#ifdef __ILP32__
	struct ts32 t32 = { 0, 0 };
	reg_t r32 = sc(NR_clock_gettime, 1, (reg_t)(unsigned long)&t32, 0, 0, 0, 0);
	struct ts64 t64 = { 0, 0 };
	reg_t r64 = sc(NR_clock_gettime64, 1, (reg_t)(unsigned long)&t64, 0, 0, 0, 0);
	out("  clock_gettime returned "); outu((unsigned long long)-r32, 10); out(" (errno, 0 = ok), clock_gettime64 returned ");
	outu((unsigned long long)-r64, 10); out("\n  monotonic: time32 "); outu((unsigned)t32.sec, 10); out(" s "); outu((unsigned)t32.nsec, 10);
	out(" ns, time64 "); outu((unsigned long long)t64.sec, 10); out(" s "); outu((unsigned long long)t64.nsec, 10); out(" ns\n");
	check("clock_gettime (time32)", r32 == 0 && (t32.sec > 0 || t32.nsec > 0));
	check("clock_gettime64", r64 == 0 && (t64.sec > 0 || t64.nsec > 0));
#else
	struct ts64 t64 = { 0, 0 };
	check("clock_gettime", sc(NR_clock_gettime, 1, (reg_t)(unsigned long)&t64, 0, 0, 0, 0) == 0 && t64.sec >= 0);
#endif

	/* PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS */
	reg_t m = sc(NR_mmap, 0, 65536, 3, 0x22, -1, 0);
	out("  mmap="); outu((unsigned long long)m, 16); out("\n");
	check("mmap 64 KB", m != 0 && SC_OK(m));
	if (m != 0 && SC_OK(m)) {
		volatile char *q = (volatile char *)(unsigned long)m;
		q[0] = 1; q[65535] = 2;
		check("mmap memory writable", q[0] == 1 && q[65535] == 2);
	}
#ifdef __ILP32__
	check("mmap address below 4 GB", (unsigned long long)m < 0x100000000ULL);
	check("stack below 4 GB", (unsigned long long)(unsigned long)sp < 0x100000000ULL);
#endif

	if (vdso) {
		const unsigned char *e = (const unsigned char *)vdso;
		unsigned type = e[16] | (e[17] << 8);
		out("  vDSO: class="); outu(e[4], 10); out(" (1=ELF32, 2=ELF64) e_type="); outu(type, 10); out(" (3=ET_DYN)\n");
		check("vDSO is an ELF image", e[0] == 0x7f && e[1] == 'E' && e[2] == 'L' && e[3] == 'F');
#ifdef __ILP32__
		check("vDSO is ELF32 (ILP32 vDSO)", e[4] == 1);
#endif
		check("vDSO is ET_DYN (shared object or PIE)", type == 3);
		unsigned nsyms;
		int has = vdso_has(e, "__kernel_clock_gettime", &nsyms);
		out("  vDSO dynamic symbols: "); outu(nsyms, 10); out("\n");
		check("vDSO exports __kernel_clock_gettime", has);
	} else {
		out("  no vDSO (AT_SYSINFO_EHDR missing)\n");
#ifdef __ILP32__
		check("vDSO present", 0);
#endif
	}

	out(fails ? "RESULT: FAIL (" : "RESULT: PASS ("); outu(fails, 10); out(" failed)\n");
	sc(NR_exit_group, fails, 0, 0, 0, 0, 0);
	for (;;) ;
}

__asm__(
	".text\n"
	".global _start\n"
	"_start:\n"
	"	mov x0, sp\n"
	"	bl cmain\n"
);
