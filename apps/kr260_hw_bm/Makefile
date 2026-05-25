# Build and run apps/kr260_hw_bm — bare-metal kr260_hw exerciser.
#
# Recipes (Linux host, KR260 attached via the J7 micro-USB):
#
#   make build  Build the bare-metal ELF from a clean checkout.
#               If vivado/kr260_hw.xsa is missing, builds it first via
#               vivado/Makefile (~25-35 min). Then builds the ELF via
#               'xsct build.tcl' (~2 min first time, faster after).
#
#   make run    Program PL + download ELF + run on Cortex-A53 #0 via JTAG.
#               Captures PS-UART output to $(LOG_FILE) for $(TIMEOUT_S)
#               seconds, then prints it.
#
#   make clean  Remove vitis_ws/ and the local log.
#
# Required, one-time:
#   - Vivado 2024.1 installed (for the XSA build)
#   - Vitis CLASSIC 2024.1 installed (provides xsct; the new Vitis Unified
#     IDE does NOT include xsct — ships 'vitis -s' Python scripting instead)
#   - User in the dialout group:  sudo usermod -aG dialout $$USER
#   - Xilinx cable drivers installed (one-time):
#       sudo /tools/Xilinx/Vivado/2024.1/data/xicom/cable_drivers/lin64/install_script/install_drivers/install_drivers
#
# Common overrides:
#   make run UART_DEV=/dev/ttyUSB2
#   make run TIMEOUT_S=30
#   make build VITIS_SETTINGS=/opt/Xilinx/Vitis/2024.1/settings64.sh

SHELL           := /bin/bash

XSA             := ../../vivado/kr260_hw.xsa
WS              := vitis_ws
ELF             := $(WS)/kr260_hw_bm/Debug/kr260_hw_bm.elf

VITIS_SETTINGS  ?= /tools/Xilinx/Vitis/2024.1/settings64.sh

UART_DEV        ?= /dev/ttyUSB1
LOG_FILE        ?= bm.log
TIMEOUT_S       ?= 10

.PHONY: build run clean

build: $(ELF)

# Auto-build the XSA via vivado/Makefile if missing — covers the cleanly
# cloned repo case (XSA is no longer checked in; see commit "Removing XSA").
$(XSA):
	@echo "==> XSA not found at $@ — building via vivado/Makefile (25-35 min)"
	$(MAKE) -C ../../vivado xsa

# build.tcl's importsources call sits inside an 'if app does not exist' guard,
# so edits to main.c are silently ignored on incremental rebuilds. rm -rf the
# workspace before each rebuild so the dependency on main.c actually works.
# (No-op on the cleanly-cloned-repo path since vitis_ws does not exist yet.)
$(ELF): $(XSA) main.c build.tcl
	@if [ ! -f "$(VITIS_SETTINGS)" ]; then \
	    echo "error: Vitis Classic not found at $(VITIS_SETTINGS)" >&2; \
	    echo "  install Vitis Classic 2024.1 or override VITIS_SETTINGS=..." >&2; \
	    exit 1; \
	fi
	rm -rf $(WS)
	source $(VITIS_SETTINGS) && xsct build.tcl

run: $(ELF)
	@if [ ! -e "$(UART_DEV)" ]; then \
	    echo "error: $(UART_DEV) does not exist" >&2; \
	    echo "  KR260 J7 USB enumerates 4 ttyUSBs; PS-UART is usually ttyUSB1" >&2; \
	    echo "  check: ls /dev/ttyUSB* ; dmesg | tail" >&2; \
	    exit 1; \
	fi
	@if [ ! -r "$(UART_DEV)" ] || [ ! -w "$(UART_DEV)" ]; then \
	    echo "error: $(UART_DEV) not accessible — add yourself to dialout group:" >&2; \
	    echo "  sudo usermod -aG dialout \$$USER && newgrp dialout" >&2; \
	    exit 1; \
	fi
	@if [ ! -f "$(VITIS_SETTINGS)" ]; then \
	    echo "error: Vitis Classic not found at $(VITIS_SETTINGS)" >&2; \
	    exit 1; \
	fi
	@echo "==> Configuring $(UART_DEV) (115200 8N1)"
	@stty -F $(UART_DEV) 115200 cs8 -cstopb -parenb -ixon raw -echo
	@rm -f $(LOG_FILE)
	@bash -c 'set -e; \
	    stdbuf -oL cat $(UART_DEV) > $(LOG_FILE) & \
	    CAT_PID=$$!; \
	    trap "kill $$CAT_PID 2>/dev/null || true" EXIT; \
	    sleep 0.2; \
	    echo "==> Programming PL + downloading ELF via xsct load.tcl"; \
	    source $(VITIS_SETTINGS) && xsct load.tcl; \
	    echo "==> ELF running — capturing UART for $(TIMEOUT_S)s"; \
	    sleep $(TIMEOUT_S); \
	    kill $$CAT_PID 2>/dev/null || true; \
	    wait $$CAT_PID 2>/dev/null || true; \
	    echo; \
	    echo "==> Captured output (saved to $(LOG_FILE)):"; \
	    echo "------------------------------------------------"; \
	    cat $(LOG_FILE); \
	    echo "------------------------------------------------"'

clean:
	rm -rf $(WS) $(LOG_FILE)
