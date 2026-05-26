# Build kr260_hw: create the Vivado project, run synth + impl + bitstream,
# then export an XSA. The project lands in ./kr260_hw/ (i.e. vivado/kr260_hw/);
# the XSA is written to ./kr260_hw.xsa (vivado/).
#
# Run from this directory: `make`.

SHELL           := /bin/bash
VIVADO_SETTINGS ?= /tools/Xilinx/Vivado/2024.1/settings64.sh
VIVADO          ?= vivado
JOBS            ?= 1

PROJ_NAME := kr260_hw
PROJ_DIR  := $(PROJ_NAME)
XPR       := $(PROJ_DIR)/$(PROJ_NAME).xpr
XSA       := $(PROJ_NAME).xsa

VIVADO_FLAGS := -mode batch -nojournal -log build.log

.PHONY: all xsa clean

all: xsa

xsa:
	. $(VIVADO_SETTINGS) && JOBS=$(JOBS) $(VIVADO) $(VIVADO_FLAGS) -source build.tcl

clean:
	rm -rf $(PROJ_DIR) .Xil
	rm -f build.log vivado*.jou vivado*.log
	rm -f kr260_hw.xsa
