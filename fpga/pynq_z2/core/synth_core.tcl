# Out-of-context synthesis of rv_core alone: area + timing estimate.
set root [file normalize [file dirname [info script]]/../../..]
set out  $root/build/fpga/core
file mkdir $out
read_verilog -sv $root/rtl/core/rv_pkg.sv
foreach f [glob $root/rtl/core/*.sv] { if {![string match *rv_pkg.sv $f]} { read_verilog -sv $f } }
synth_design -top rv_core -part xc7z020clg400-1 -mode out_of_context -flatten_hierarchy rebuilt
create_clock -period 10.0 -name clk [get_ports clk]
report_utilization    -file $out/util.rpt
report_timing_summary -file $out/timing.rpt -max_paths 5
report_timing -file $out/paths.rpt -max_paths 3 -nworst 1
puts "DONE"
