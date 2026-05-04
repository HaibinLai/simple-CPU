# Simple Icarus Verilog flow

RTL := $(wildcard rtl/core/*.v) $(wildcard rtl/mem/*.v)
TB  := tb/tb_cpu.v
TOP := tb_cpu

SIM_DIR := sim
VVP     := $(SIM_DIR)/cpu.vvp
VCD     := $(SIM_DIR)/cpu.vcd

PROG ?= tb/programs/test01.hex

.PHONY: all run wave clean build

all: build

# 每次都重新编译，避免 PROG 切换时使用旧的 VVP
build: | $(SIM_DIR)
	iverilog -g2012 -I rtl/core -DPROG_HEX='"$(PROG)"' -o $(VVP) -s $(TOP) $(RTL) $(TB)

$(SIM_DIR):
	mkdir -p $(SIM_DIR)

run: build
	vvp $(VVP)

wave: $(VCD)
	gtkwave $(VCD) &

clean:
	rm -rf $(SIM_DIR)
