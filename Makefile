CORE := rtl/core/rv_pkg.sv rtl/core/rv_alu.sv rtl/core/rv_regfile.sv rtl/core/rv_decode.sv \
        rtl/core/rv_muldiv.sv rtl/core/rv_tlb.sv rtl/core/rv_ptw.sv rtl/core/rv_dmux.sv \
        rtl/core/rv_fetch.sv rtl/core/rv_csr.sv rtl/core/rv_core.sv
TB   := tb/sim_ram.sv tb/sim_periph.sv tb/tb_top.sv
VFLAGS := -Wno-UNUSEDPARAM -Wno-UNUSEDSIGNAL

.PHONY: sim-soc test-soc lint sim sim-lat test test-lat test-isa test-isa-lat test-custom test-custom-lat opensbi clean

lint:
	verilator --lint-only -Wall $(VFLAGS) --top-module rv_core $(CORE)

build/sim/Vtb_top: $(CORE) $(TB)
	@mkdir -p $(@D)
	verilator --binary --timing -Wall $(VFLAGS) -Wno-fatal --top-module tb_top \
	  -O3 --Mdir build/sim -o Vtb_top $(CORE) $(TB)

sim: build/sim/Vtb_top

# same bench with random 0-3 cycle extra memory latency
build/sim_lat/Vtb_top: $(CORE) $(TB)
	@mkdir -p $(@D)
	verilator --binary --timing -Wall $(VFLAGS) -Wno-fatal --top-module tb_top \
	  -DMAX_EXTRA=3 -O3 --Mdir build/sim_lat -o Vtb_top $(CORE) $(TB)

sim-lat: build/sim_lat/Vtb_top

test-isa: sim
	sw/run_isa.sh build/sim/Vtb_top

test-isa-lat: sim-lat
	sw/run_isa.sh build/sim_lat/Vtb_top

clean:
	rm -rf build

opensbi:
	sw/build_opensbi.sh

test-custom: sim
	sw/run_custom.sh build/sim/Vtb_top

test-custom-lat: sim-lat
	sw/run_custom.sh build/sim_lat/Vtb_top

test: test-isa test-custom
test-lat: test-isa-lat test-custom-lat

# ---- FPGA SoC (core + serial UART + AXI bridges) against an AXI memory model
SOC := rtl/soc/soc_uart.sv rtl/soc/soc_periph.sv rtl/soc/soc_axi_master.sv rtl/soc/rv_soc.sv
TBSOC := tb/axi_ram.sv tb/tb_soc.sv

build/sim_soc/Vtb_soc: $(CORE) $(SOC) $(TBSOC)
	@mkdir -p $(@D)
	verilator --binary --timing -Wall $(VFLAGS) -Wno-fatal --top-module tb_soc \
	  -O3 --Mdir build/sim_soc -o Vtb_soc $(CORE) $(SOC) $(TBSOC)

sim-soc: build/sim_soc/Vtb_soc

test-soc: sim-soc
	sw/run_soc.sh build/sim_soc/Vtb_soc
