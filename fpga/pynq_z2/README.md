# PYNQ-Z2 bring-up

Build (needs Vivado and the TUL PYNQ-Z2 board files, `pynq-z2/A.0/board.xml`):

    vivado -mode batch -source fpga/pynq_z2/build.tcl -tclargs <board_repo_dir>
    # -> build/fpga/out/rv32_pynq.{bit,hwh,xsa}

Result at 50 MHz (whole SoC, post-route): 4.7k LUT, 5.0k FF, 0 BRAM, 4 DSP, WNS +1.65 ns (critical path ~18.4 ns, so roughly 54 MHz as built).

## Memory map

| RV32 address | What |
|---|---|
| `0x0200_0000` | CLINT (mtime ticks at 10 MHz) |
| `0x1000_0000` | 16550 UART, 115200 8N1 on Pmod JA1 (TX, Y18) / JA2 (RX, Y19) |
| `0x8000_0000` + 64 MiB | RAM = PS DDR `0x1C00_0000..0x1FFF_FFFF` via S_AXI_HP0 (fetch) / HP1 (data) |

## Running (verified on a PYNQ-Z2, PYNQ v2.7 image)

1. Reserve the top 64 MiB of DDR from PYNQ Linux. This image boots through U-Boot with `boot.scr`,
   which imports `/boot/uEnv.txt`; create it with one line (same arguments as before plus `mem=448M`):

       uenvcmd=setenv bootargs root=/dev/mmcblk0p2 rw earlyprintk rootfstype=ext4 rootwait devtmpfs.mount=1 uio_pdrv_genirq.of_id=generic-uio clk_ignore_unused mem=448M; fatload ${devtype} ${devnum}:${distro_bootpart} 0x10000000 image.ub; bootm 0x10000000

   Reboot, check `free -m` (~430 MB) and `/proc/cmdline`. Deleting `uEnv.txt` undoes it.
2. Copy `rv32_pynq.bit`, `rv32_pynq.hwh`, `fw_payload.bin` and `run_on_board.py` to the board and run
   (not from `/home/xilinx`, whose `pynq/` folder shadows the real package):

       cd /tmp && sudo env XILINX_XRT=/usr /usr/local/share/pynq-venv/bin/python run_on_board.py \
           rv32_pynq.bit fw_payload.bin --probe

   The script loads the bitstream, **sets the HP ports to 32-bit** (see below), holds the core in
   reset, zeroes nothing unless `--check`, writes the image through uncached `/dev/mem`, and
   releases the core through EMIO GPIO 0 (sysfs 960 on kernel 5.15: chip base 906 + 54).
3. Open the console on the Pmod JA UART (3.3 V adapter, 115200 8N1).

### Linux

Use `fw_linux.bin` (from `sw/build_linux_fw.sh`) instead of `fw_payload.bin`. With no UART adapter,
`--log SEC` polls the kernel's `__log_buf` in DDR and prints new text; the offset is
`System.map` vaddr of `__log_buf` minus `0xC0000000` plus `0x400000` (the kernel load offset), and
`--logoff` overrides the default. The initramfs script `S99hello` writes userspace progress to
`/dev/kmsg` so it appears there too. Boot to `/init` takes about 6 minutes.

LEDs: LD0 running, LD1 UART TX, LD2 UART RX, LD3 timer pending.

`--probe` reads a debug window the PL exports through the other EMIO GPIO lines: last retired PC,
last fetch/data addresses, handshake counters, the first trap's cause/epc, the first fetch
responses, and a 32-cycle trace of the fetch AXI channel. It works without a UART adapter.

## Lessons from bring-up

- **HP ports power up in 64-bit mode.** The PS register `AFI_RDCHAN_CTRL`/`AFI_WRCHAN_CTRL`
  (`0xF8008000`/`0xF8009000`, bit 0 `FabricWidth`) is set by the boot ROM's `ps7_init`, not by the
  bitstream, and PYNQ's overlay load does not reapply it. A 32-bit master then reads the low lane
  for every word (odd words come back as the even word) and misplaces stores. `run_on_board.py`
  sets it to 32-bit before releasing the core.
- **Stale AXI responses outlive the PL.** A reset with a read in flight leaves the answer parked in
  the PS port; the bridge keeps `rready`/`bready` high so it drains, and only accepts a response
  after its own request was accepted.
- Reads are issued as aligned 2-beat bursts (a leftover of the lane debugging; single beats work
  now that the width is right, so this could go back to one beat for lower latency).

## Caveats

- `BD 41-1348` (async reset) is expected: `rv_soc` synchronizes reset itself.
- The `PSU-*` negative DQS skew warnings come from the board preset; DDR is already
  initialised by the PYNQ boot, the overlay does not touch it.
- The Pmod UART pins are untested (no adapter yet); everything else above is verified: OpenSBI,
  the S-mode payload and Linux 6.18 to userspace run on the board.
- Known oddity: a 10 s `sleep` advances `/proc/uptime` by only ~3.4 s; not yet investigated.
