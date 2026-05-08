# Simple Icarus Verilog flow

RTL := $(wildcard rtl/core/*.v) $(wildcard rtl/mem/*.v)
TB  := tb/tb_cpu.v
TOP := tb_cpu

SIM_DIR ?= sim
VVP     := $(SIM_DIR)/cpu.vvp
VCD     := $(SIM_DIR)/cpu.vcd

PROG ?= tb/programs/test01.hex
TIMEOUT_NS ?= 2000

# 设置 VCD=1 才会 dump 波形（回归测试默认关闭，避免巨量磁盘 I/O 卡顿）
VCD ?= 0
ifeq ($(VCD),1)
  VCD_FLAGS := -DENABLE_VCD -DVCD_FILE='"$(SIM_DIR)/cpu.vcd"'
else
  VCD_FLAGS :=
endif

.PHONY: all run wave clean build robust

all: build

# 每次都重新编译，避免 PROG 切换时使用旧的 VVP
build: | $(SIM_DIR)
	iverilog -g2012 -I rtl/core -DPROG_HEX='"$(PROG)"' -DSIM_TIMEOUT_NS=$(TIMEOUT_NS) $(VCD_FLAGS) -o $(VVP) -s $(TOP) $(RTL) $(TB)

$(SIM_DIR):
	mkdir -p $(SIM_DIR)

run: build
	vvp $(VVP)

wave:
	$(MAKE) build VCD=1
	vvp $(VVP)
	gtkwave $(SIM_DIR)/cpu.vcd &

clean:
	rm -rf $(SIM_DIR)

# Front-end wrong-path regression. MUST PASS before landing any IF-stage
# optimization (slot1 JAL fast predict, active RAS, BTB-fetch hint, etc.).
robust:
	python3 tools/run_a2step2_robustness.py
