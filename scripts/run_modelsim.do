# Run from the npu_lite directory: vsim -c -do scripts/run_modelsim.do
onerror {quit -code 1 -force}
onbreak {quit -code 1 -force}
if {![file isdirectory work]} {vlib work}
vlog -sv -work work -f filelist.f tb/tb_npu.sv
vsim work.tb_npu
run -all
quit -code 0 -force
