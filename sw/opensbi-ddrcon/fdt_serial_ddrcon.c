/*
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * DDR mailbox console for the rv32-linux PYNQ-Z2 SoC: with no UART adapter attached, the ARM host
 * (fpga/pynq_z2/console.py) reads/writes two byte rings in a reserved DDR page over /dev/mem.
 *
 * Layout (32-bit little-endian words, one writer per word so no read-modify-write races):
 *   0x00 magic 'DCON'   (set here at init, so the host can tell OpenSBI is alive)
 *   0x04 host_attached  (host: 1 while a host console is running; output is dropped when 0)
 *   0x08 tx_head (here)  0x0C tx_tail (host)   guest -> host ring, TX_SZ bytes at 0x100
 *   0x10 rx_head (host)  0x14 rx_tail (here)   host -> guest ring, RX_SZ bytes at 0x500
 */
#include <sbi/sbi_console.h>
#include <sbi/sbi_domain.h>
#include <sbi/riscv_asm.h>
#include <sbi_utils/fdt/fdt_helper.h>
#include <sbi_utils/serial/fdt_serial.h>

#define MB_MAGIC 0x00
#define MB_ATTACHED 0x04
#define MB_TX_HEAD 0x08
#define MB_TX_TAIL 0x0C
#define MB_RX_HEAD 0x10
#define MB_RX_TAIL 0x14
#define MB_TX_BUF 0x100
#define MB_RX_BUF 0x500
#define TX_SZ 1024
#define RX_SZ 1024
#define SPIN_LIMIT 200000

static volatile char *mb;

static inline volatile unsigned int *w(unsigned off) { return (volatile unsigned int *)(mb + off); }

static void ddrcon_putc(char ch)
{
	unsigned int head, spin = 0;

	if (!*w(MB_ATTACHED))
		return;
	head = *w(MB_TX_HEAD);
	while (((head + 1) % TX_SZ) == *w(MB_TX_TAIL)) {
		if (++spin > SPIN_LIMIT)
			return;	/* host stopped draining: drop instead of hanging the boot */
	}
	mb[MB_TX_BUF + head] = ch;
	__asm__ __volatile__("fence w,w" ::: "memory");
	*w(MB_TX_HEAD) = (head + 1) % TX_SZ;
}

static int ddrcon_getc(void)
{
	unsigned int tail = *w(MB_RX_TAIL);
	int c;

	if (tail == *w(MB_RX_HEAD))
		return -1;
	c = (unsigned char)mb[MB_RX_BUF + tail];
	*w(MB_RX_TAIL) = (tail + 1) % RX_SZ;
	return c;
}

static struct sbi_console_device ddrcon_console = {
	.name = "ddrcon",
	.console_putc = ddrcon_putc,
	.console_getc = ddrcon_getc
};

static const struct fdt_match serial_ddrcon_match[] = {
	{ .compatible = "rv32-linux,ddrcon" },
	{ },
};

static int serial_ddrcon_init(const void *fdt, int nodeoff, const struct fdt_match *match)
{
	uint64_t addr = 0, size = 0;
	int rc = fdt_get_node_addr_size(fdt, nodeoff, 0, &addr, &size);

	if (rc)
		return rc;
	mb = (volatile char *)(unsigned long)addr;
	*w(MB_MAGIC) = 0x4e4f4344;	/* "DCON" little-endian */
	sbi_console_set_device(&ddrcon_console);
	return 0;
}

const struct fdt_driver fdt_serial_ddrcon = {
	.match_table = serial_ddrcon_match,
	.init = serial_ddrcon_init
};
