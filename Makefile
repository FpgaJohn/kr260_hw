SHELL      := /bin/bash

KR260_HOST ?= kr260u
KR260_USER ?= ubuntu
SCRIPT     := list_uio.sh
REMOTE_DIR := /home/$(KR260_USER)

MAKEFLAGS += --no-print-directory

.DEFAULT_GOAL := help

.PHONY: help info deploy deploy-run xsa xsa-clean bare-metal-build bare-metal-run bare-metal-clean rtos-build rtos-run rtos-clean jtag-reboot tty

help:
	@echo "kr260_hw — available make targets:"
	@echo ""
	@echo "  Hardware (Vivado):"
	@echo "    xsa                Build Vivado project and export kr260_hw.xsa (~25-35 min)"
	@echo "    xsa-clean          Remove Vivado project and XSA"
	@echo ""
	@echo "  Bare-metal (Vitis Classic, JTAG):"
	@echo "    bare-metal-build   Build the bare-metal ELF (auto-builds XSA if missing)"
	@echo "    bare-metal-run     Program PL + run ELF on A53 #0 via JTAG, capture UART"
	@echo "    bare-metal-clean   Remove vitis_ws/ and bm.log"
	@echo ""
	@echo "  FreeRTOS (Vitis Classic, JTAG):"
	@echo "    rtos-build         Build the FreeRTOS ELF (auto-builds XSA if missing)"
	@echo "    rtos-run           Program PL + run ELF on A53 #0 via JTAG, capture UART"
	@echo "    rtos-clean         Remove vitis_ws/ and rtos.log"
	@echo ""
	@echo "  JTAG / UART utilities:"
	@echo "    jtag-reboot        Reboot KR260 via JTAG (returns to DIP-switch boot, e.g. SD)"
	@echo "    tty                Open screen on the KR260 PS-UART (115200 8N1)"
	@echo ""
	@echo "  Linux runtime (over ssh to ubuntu@$(KR260_HOST)):"
	@echo "    info               Run list_uio.sh on the board (temps + UIO table)"
	@echo "    deploy             scp scripts/ to the board"
	@echo "    deploy-run         Install kr260_hw firmware, xmutil loadapp, run kr260_hw_test"
	@echo ""
	@echo "  help                 Show this message (default target)"

# Step 1 - Build Vivado Project and Export XSA
xsa:
	$(MAKE) -C vivado xsa

xsa-clean:
	$(MAKE) -C vivado clean

# [LINUX] [BARE-METAL] Step 2
# - Builds on linux using Vitis
# - Programs KR260 using JTAG
# - Runs bare-metal and captures output over UART
#   apps/kr260_hw_bm
bare-metal-build:
	$(MAKE) -C apps/kr260_hw_bm build

bare-metal-run:
	$(MAKE) -C apps/kr260_hw_bm run

bare-metal-clean:
	$(MAKE) -C apps/kr260_hw_bm clean


# [FreeRTOS] Step 2
# - Builds on linux using Vitis
# - Programs KR260 using JTAG
# - Runs FreeRTOS and captures output over UART
#   apps/kr260_hw_rtos
rtos-build:
	$(MAKE) -C apps/kr260_hw_rtos build

rtos-run:
	$(MAKE) -C apps/kr260_hw_rtos run

rtos-clean:
	$(MAKE) -C apps/kr260_hw_rtos clean

VITIS_SETTINGS  ?= /tools/Xilinx/Vitis/2024.1/settings64.sh

# Reboot KR260 via JTAG — restores normal boot from DIP switches (SD/QSPI).
# Use after a bare-metal or FreeRTOS session to get back to Linux without
# physically power-cycling. Filters for the KR260 cable when multiple boards
# are connected.
jtag-reboot:
	@if [ ! -f "$(VITIS_SETTINGS)" ]; then \
	    echo "error: Vitis Classic not found at $(VITIS_SETTINGS)" >&2; \
	    exit 1; \
	fi
	@# Ensure KR260 JTAG interface (channel A) isn't claimed by ftdi_sio
	@for dev in /sys/bus/usb/devices/*; do \
	    if [ -f "$$dev/manufacturer" ] && [ "$$(cat $$dev/manufacturer 2>/dev/null)" = "Xilinx" ] && \
	       [ "$$(cat $$dev/idProduct 2>/dev/null)" = "6011" ]; then \
	        intf="$$(basename $$dev):1.0"; \
	        if [ -e "/sys/bus/usb/drivers/ftdi_sio/$$intf" ]; then \
	            echo "==> Unbinding $$intf from ftdi_sio (JTAG channel)"; \
	            echo "$$intf" | sudo tee /sys/bus/usb/drivers/ftdi_sio/unbind > /dev/null; \
	        fi; \
	    fi; \
	done
	@echo "==> Rebooting KR260 via JTAG (will boot from DIP switches)"
	@source $(VITIS_SETTINGS) && xsct -eval ' \
	    connect; \
	    targets -set -filter {name =~ "PSU" && jtag_cable_name =~ "Xilinx*"}; \
	    rst -system; \
	    puts "jtag-reboot: system reset issued — board will boot from DIP switches"; \
	    exit \
	'

# Auto-detect KR260 PS-UART (Xilinx FT4232H, interface 01).
KR260_UART ?= $(or $(shell for dev in /sys/class/tty/ttyUSB*; do \
    mfg=$$(cat "$$dev/device/../../manufacturer" 2>/dev/null); \
    intf=$$(cat "$$(readlink -f $$dev/device/..)/bInterfaceNumber" 2>/dev/null); \
    if [ "$$mfg" = "Xilinx" ] && [ "$$intf" = "01" ]; then \
        echo "/dev/$$(basename $$dev)"; break; \
    fi; \
done),/dev/ttyUSB1)

# Open KR260 PS-UART in screen. Ctrl-a k to quit.
tty:
	@echo "==> KR260 UART: $(KR260_UART) (115200 8N1)"
	screen $(KR260_UART) 115200

# [Ubuntu] Step 2
# - Builds Kria App
# - 



info:
	@echo "==> Copying $(SCRIPT) to $(KR260_USER)@$(KR260_HOST):$(REMOTE_DIR)/"
	scp $(SCRIPT) $(KR260_USER)@$(KR260_HOST):$(REMOTE_DIR)/
	@echo "==> Running $(SCRIPT) on $(KR260_HOST)"
	ssh $(KR260_USER)@$(KR260_HOST) 'chmod +x $(REMOTE_DIR)/$(SCRIPT) && $(REMOTE_DIR)/$(SCRIPT)'

# sudo xmutil xlnx_platformstats | grep temperature
#
#
deploy:
	@scp ./scripts/* $(KR260_USER)@kr260u:~/

# Install the just-scp'd kr260_hw firmware overlay, reload it under xmutil,
# and run the userspace test. Assumes:
#   - `cd kria_app && make deploy`  has put ~/kr260_hw on the board
#   - `cd apps/kr260_hw_test && make deploy`  has put /tmp/kr260_hw_test on the board
deploy-run:
	ssh $(KR260_USER)@$(KR260_HOST) ' \
	    sudo rm -rf /lib/firmware/xilinx/kr260_hw && \
	    sudo mv ~/kr260_hw /lib/firmware/xilinx/ && \
	    (sudo xmutil unloadapp 2>/dev/null || true) && \
	    sudo xmutil loadapp kr260_hw && \
	    cat /sys/class/fpga_manager/fpga0/state && \
	    echo 8 | sudo tee /proc/sys/vm/nr_hugepages > /dev/null && \
	    sudo /tmp/kr260_hw_test \
	'

