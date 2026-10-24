/* Minimal S-mode payload used to exercise OpenSBI on the core:
 * SBI calls, a delegated supervisor timer interrupt, Sv32 paging (4 KiB + 4 MiB
 * mappings) and a delegated load page fault. Ends in a spin loop at `done`. */
typedef unsigned int u32;

#define SBI_EXT_BASE  0x10
#define SBI_EXT_TIME  0x54494D45

struct sbiret { long err, val; };

static inline struct sbiret sbi_call(long eid, long fid, long a0, long a1)
{
	register long r0 asm("a0") = a0;
	register long r1 asm("a1") = a1;
	register long r6 asm("a6") = fid;
	register long r7 asm("a7") = eid;
	asm volatile("ecall" : "+r"(r0), "+r"(r1) : "r"(r6), "r"(r7) : "memory");
	return (struct sbiret){ r0, r1 };
}

static void putc_(char c) { sbi_call(1, 0, c, 0); }   /* legacy console putchar */

static void puts_(const char *s) { while (*s) putc_(*s++); }

static void puthex(u32 v)
{
	for (int i = 28; i >= 0; i -= 4)
		putc_("0123456789abcdef"[(v >> i) & 15]);
}

static inline u32 rdtime(void)
{
	u32 t;
	asm volatile("csrr %0, time" : "=r"(t));
	return t;
}

static volatile u32 timer_fired, fault_count, last_cause, last_tval;

u32 handle_trap(u32 cause, u32 epc, u32 tval)
{
	last_cause = cause;
	last_tval  = tval;
	if (cause & 0x80000000u) {
		if ((cause & 0xff) == 5) {            /* supervisor timer */
			timer_fired++;
			sbi_call(SBI_EXT_TIME, 0, -1, -1);   /* clear: timer = never */
			asm volatile("csrc sie, %0" :: "r"(1 << 5));
		}
		return epc;
	}
	fault_count++;
	return epc + 4;                             /* skip the faulting access */
}

#define PTE_V (1 << 0)
#define PTE_R (1 << 1)
#define PTE_W (1 << 2)
#define PTE_X (1 << 3)
#define PTE_A (1 << 6)
#define PTE_D (1 << 7)

static u32 root[1024] __attribute__((aligned(4096), section(".pt")));
static u32 leaf[1024] __attribute__((aligned(4096), section(".pt")));

#define ALIAS_VA   0xC0000000u
#define TARGET_PA  0x80500000u

static int check(const char *name, int ok)
{
	puts_(name);
	puts_(ok ? ": ok\n" : ": FAIL\n");
	return ok;
}

void main(void)
{
	int bad = 0;

	puts_("\nrv32-linux payload in S-mode\n");

	long spec = sbi_call(SBI_EXT_BASE, 0, 0, 0).val;
	puts_("SBI spec ");
	puthex(spec);
	putc_('\n');
	bad += !check("TIME extension", sbi_call(SBI_EXT_BASE, 3, SBI_EXT_TIME, 0).val != 0);

	/* supervisor timer interrupt delegated by OpenSBI */
	timer_fired = 0;
	asm volatile("csrs sie, %0" :: "r"(1 << 5));
	asm volatile("csrs sstatus, %0" :: "r"(1 << 1));
	sbi_call(SBI_EXT_TIME, 0, rdtime() + 2000, 0);
	for (u32 spin = 0; !timer_fired && spin < 2000000; spin++)
		asm volatile("nop");
	bad += !check("timer interrupt", timer_fired == 1);

	/* Sv32: identity-map firmware+payload with 4 MiB superpages, alias one 4 KiB page */
	root[0x80000000u >> 22] = ((0x80000000u >> 12) << 10) | PTE_V | PTE_R | PTE_W | PTE_X | PTE_A | PTE_D;
	root[0x80400000u >> 22] = ((0x80400000u >> 12) << 10) | PTE_V | PTE_R | PTE_W | PTE_X | PTE_A | PTE_D;
	root[ALIAS_VA >> 22]    = (((u32)leaf >> 12) << 10) | PTE_V;
	leaf[(ALIAS_VA >> 12) & 0x3ff] = ((TARGET_PA >> 12) << 10) | PTE_V | PTE_R | PTE_W | PTE_A | PTE_D;

	*(volatile u32 *)TARGET_PA = 0;
	asm volatile("csrw satp, %0" :: "r"(0x80000000u | ((u32)root >> 12)));
	asm volatile("sfence.vma" ::: "memory");

	*(volatile u32 *)ALIAS_VA = 0xcafe1234;
	bad += !check("paging alias write/read", *(volatile u32 *)TARGET_PA == 0xcafe1234 &&
	                                         *(volatile u32 *)ALIAS_VA == 0xcafe1234);

	/* unmapped address -> delegated load page fault (cause 13) */
	fault_count = 0;
	(void)*(volatile u32 *)0x00001000u;
	bad += !check("load page fault", fault_count == 1 && last_cause == 13 && last_tval == 0x1000);

	/* write to a read-only mapping -> store page fault (cause 15) */
	leaf[(ALIAS_VA >> 12) & 0x3ff] = ((TARGET_PA >> 12) << 10) | PTE_V | PTE_R | PTE_A;
	asm volatile("sfence.vma" ::: "memory");
	fault_count = 0;
	*(volatile u32 *)ALIAS_VA = 0;
	bad += !check("store page fault", fault_count == 1 && last_cause == 15);

	asm volatile("csrw satp, zero; sfence.vma" ::: "memory");
	puts_(bad ? "PAYLOAD FAILED\n" : "PAYLOAD OK\n");

	asm volatile(".globl done\ndone: j done");
}
