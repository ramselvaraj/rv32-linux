# PYNQ-Z2 build: vivado -mode batch -source fpga/pynq_z2/build.tcl [-tclargs <board_files_dir> <until>]
#   board_files_dir  folder containing pynq-z2/A.0/board.xml (default: build/fpga/board_repo)
#   until            bd | synth | impl | bit (default bit)
set root  [file normalize [file dirname [info script]]/../..]
set bdir  $root/build/fpga/pynq_z2
set repo  [expr {$argc > 0 ? [lindex $argv 0] : "$root/build/fpga/board_repo"}]
set until [expr {$argc > 1 ? [lindex $argv 1] : "bit"}]
set fclk_mhz 50

file delete -force $bdir
set_param board.repoPaths [list $repo]
create_project rv32_pynq $bdir -part xc7z020clg400-1
set_property board_part tul.com.tw:pynq-z2:part0:1.0 [current_project]

# ---- RTL
set rtl [list]
foreach f {rv_pkg rv_alu rv_regfile rv_decode rv_muldiv rv_tlb rv_ptw rv_dmux rv_fetch rv_csr rv_core} {
  lappend rtl $root/rtl/core/$f.sv
}
foreach f {soc_uart soc_periph soc_axi_master rv_soc} { lappend rtl $root/rtl/soc/$f.sv }
add_files $rtl
set_property file_type SystemVerilog [get_files *.sv]
add_files -fileset constrs_1 $root/fpga/pynq_z2/soc/pynq_z2.xdc
update_compile_order -fileset sources_1

# ---- block design: PS7 (DDR + HP0/HP1 + FCLK + EMIO GPIO) and rv_soc
create_bd_design system
set ps [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7 ps7]
apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
  -config {make_external "FIXED_IO, DDR" apply_board_preset "1" Master "Disable" Slave "Disable"} $ps
set_property -dict [list \
  CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ $fclk_mhz \
  CONFIG.PCW_USE_M_AXI_GP0 0 \
  CONFIG.PCW_USE_S_AXI_HP0 1 CONFIG.PCW_S_AXI_HP0_DATA_WIDTH 32 \
  CONFIG.PCW_USE_S_AXI_HP1 1 CONFIG.PCW_S_AXI_HP1_DATA_WIDTH 32 \
  CONFIG.PCW_GPIO_EMIO_GPIO_ENABLE 1 CONFIG.PCW_GPIO_EMIO_GPIO_IO 64 \
  CONFIG.PCW_EN_CLK0_PORT 1 CONFIG.PCW_EN_RST0_PORT 1] $ps

set soc [create_bd_cell -type module -reference rv_soc soc]
connect_bd_intf_net [get_bd_intf_pins $soc/m_axi_ibus] [get_bd_intf_pins $ps/S_AXI_HP0]
connect_bd_intf_net [get_bd_intf_pins $soc/m_axi_dbus] [get_bd_intf_pins $ps/S_AXI_HP1]
connect_bd_net [get_bd_pins $ps/FCLK_CLK0] [get_bd_pins $soc/clk] \
  [get_bd_pins $ps/S_AXI_HP0_ACLK] [get_bd_pins $ps/S_AXI_HP1_ACLK]
connect_bd_net [get_bd_pins $ps/FCLK_RESET0_N] [get_bd_pins $soc/rstn]

# EMIO GPIO: [0] run, [2:1] debug select (ARM -> PL); 64 status bits back (PL -> ARM)
puts "PS7 GPIO pins: [get_bd_pins -quiet $ps/GPIO*] / intf: [get_bd_intf_pins -quiet $ps/GPIO*]"
set gpio_o [get_bd_pins -quiet $ps/GPIO_O]
if {$gpio_o eq ""} {
  make_bd_intf_pins_external [get_bd_intf_pins $ps/GPIO_0]
  error "EMIO GPIO is an interface here; adapt build.tcl to slice it"
}
connect_bd_net $gpio_o [get_bd_pins $soc/emio_o]
connect_bd_net [get_bd_pins $soc/emio_i] [get_bd_pins $ps/GPIO_I]

make_bd_pins_external [get_bd_pins $soc/uart_txd] [get_bd_pins $soc/uart_rxd] [get_bd_pins $soc/led]
foreach {p n} {uart_txd_0 uart_txd uart_rxd_0 uart_rxd led_0 led} {
  set_property name $n [get_bd_ports $p]
}
assign_bd_address
validate_bd_design
save_bd_design
make_wrapper -files [get_files $bdir/rv32_pynq.srcs/sources_1/bd/system/system.bd] -top
add_files -norecurse $bdir/rv32_pynq.gen/sources_1/bd/system/hdl/system_wrapper.v
set_property top system_wrapper [current_fileset]
update_compile_order -fileset sources_1
if {$until eq "bd"} { puts "BD OK"; exit 0 }

# ---- implementation
launch_runs synth_1 -jobs 8
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} { error "synthesis failed" }
if {$until eq "synth"} { exit 0 }
launch_runs impl_1 -jobs 8
wait_on_run impl_1
if {$until eq "impl"} { exit 0 }
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1

set out $root/build/fpga/out
file mkdir $out
open_run impl_1
report_timing_summary -file $out/timing.rpt
report_utilization -file $out/util.rpt
write_hw_platform -fixed -force $out/rv32_pynq.xsa
file copy -force $bdir/rv32_pynq.runs/impl_1/system_wrapper.bit $out/rv32_pynq.bit
file copy -force [glob $bdir/rv32_pynq.gen/sources_1/bd/system/hw_handoff/*.hwh] $out/rv32_pynq.hwh
puts "BITSTREAM: $out/rv32_pynq.bit"
