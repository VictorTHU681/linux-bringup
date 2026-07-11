# program.tcl — program the FPGA with a bitstream over JTAG.
# Bitstream path is passed as tclarg 0 (a Windows path, e.g. C:\...\soc_top.bit).
# Invoked by scripts/flash-board.sh; not meant to be run by hand.
open_hw_manager
connect_hw_server
current_hw_target [lindex [get_hw_targets] 0]
open_hw_target
current_hw_device [lindex [get_hw_devices] 0]
set_property PROGRAM.FILE [lindex $argv 0] [current_hw_device]
program_hw_devices [current_hw_device]
refresh_hw_device [current_hw_device]
puts "PROGRAM_DONE done_status=[get_property REGISTER.IR.BIT5_DONE [current_hw_device]]"
close_hw_target
close_hw_manager
