# Console UART on Pmod JA pins 1/2 (3.3 V). Connect a USB-UART adapter:
#   adapter RX <- JA1 (uart_txd, Y18)    adapter TX -> JA2 (uart_rxd, Y19)    GND <-> JA GND
set_property -dict { PACKAGE_PIN Y18 IOSTANDARD LVCMOS33 } [get_ports uart_txd]
set_property -dict { PACKAGE_PIN Y19 IOSTANDARD LVCMOS33 } [get_ports uart_rxd]

# LD0 run, LD1 uart tx, LD2 uart rx, LD3 timer pending
set_property -dict { PACKAGE_PIN R14 IOSTANDARD LVCMOS33 } [get_ports {led[0]}]
set_property -dict { PACKAGE_PIN P14 IOSTANDARD LVCMOS33 } [get_ports {led[1]}]
set_property -dict { PACKAGE_PIN N16 IOSTANDARD LVCMOS33 } [get_ports {led[2]}]
set_property -dict { PACKAGE_PIN M14 IOSTANDARD LVCMOS33 } [get_ports {led[3]}]

# Slow, asynchronous board I/O
set_false_path -to   [get_ports {uart_txd led[*]}]
set_false_path -from [get_ports uart_rxd]
