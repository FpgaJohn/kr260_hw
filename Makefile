SHELL      := /bin/bash

KR260_HOST ?= kr260u
KR260_USER ?= ubuntu
SCRIPT     := list_uio.sh
REMOTE_DIR := /home/$(KR260_USER)

MAKEFLAGS += --no-print-directory

.DEFAULT_GOAL := help

.PHONY: help info deploy deploy-run xsa xsa-clean bare-metal-build bare-metal-run bare-metal-clean rtos-build rtos-run rtos-clean jtag-reboot tty tty-list tty-kill list-all

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
	@echo "    tty                Open the KR260 PS-UART (115200 8N1; default: tio, Ctrl-t q to quit)"
	@echo "    tty-list           List screen sessions and processes holding any /dev/ttyUSB*"
	@echo "    tty-kill           Kill any screen/process holding the KR260 PS-UART"
	@echo "    list-all           List all FPGA devices and which USB/tty port they are on"
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

# Open KR260 PS-UART in tio (tmux-friendly; Ctrl-t q to quit).
# Override TTY_TOOL=screen / picocom / minicom if preferred.
TTY_TOOL ?= tio
tty:
	@echo "==> KR260 UART: $(KR260_UART) (115200 8N1) via $(TTY_TOOL)"
	@case "$(TTY_TOOL)" in \
	    tio)     tio -b 115200 -d 8 -p none -s 1 -f none $(KR260_UART) ;; \
	    screen)  screen $(KR260_UART) 115200 ;; \
	    picocom) picocom -b 115200 $(KR260_UART) ;; \
	    minicom) minicom -D $(KR260_UART) -b 115200 ;; \
	    *)       echo "unknown TTY_TOOL=$(TTY_TOOL)" >&2; exit 1 ;; \
	esac

# List who is holding the serial ports (stray screen sessions, tio, etc.).
tty-list:
	@echo "==> screen sessions:"
	@out=$$(screen -ls 2>/dev/null | awk '/[0-9]+\./ {print "  " $$0}'); \
	if [ -n "$$out" ]; then echo "$$out"; else echo "  (none)"; fi
	@echo "==> /dev/ttyUSB* holders:"
	@found=0; \
	for dev in /dev/ttyUSB*; do \
	    [ -e "$$dev" ] || continue; \
	    pids=$$(fuser "$$dev" 2>/dev/null); \
	    if [ -n "$$pids" ]; then \
	        for p in $$pids; do \
	            cmd=$$(ps -p $$p -o comm= 2>/dev/null); \
	            args=$$(ps -p $$p -o args= 2>/dev/null); \
	            printf "  %-15s pid=%-7s %s   (%s)\n" "$$dev" "$$p" "$$cmd" "$$args"; \
	        done; \
	        found=1; \
	    fi; \
	done; \
	if [ $$found -eq 0 ]; then echo "  (none)"; fi
	@echo "==> KR260 PS-UART (auto-detected): $(KR260_UART)"

# Kill whatever is holding the KR260 PS-UART (stray screen session, tio, …).
# Prefers a clean 'screen -X quit' when the holder is a screen session.
tty-kill:
	@pids=$$(fuser $(KR260_UART) 2>/dev/null); \
	if [ -z "$$pids" ]; then \
	    echo "==> Nothing holding $(KR260_UART)"; \
	    exit 0; \
	fi; \
	for p in $$pids; do \
	    sname=$$(screen -ls 2>/dev/null | awk -v p=$$p '$$1 ~ ("^"p"\\.") {print $$1; exit}'); \
	    if [ -n "$$sname" ]; then \
	        echo "==> screen -X -S $$sname quit"; \
	        screen -X -S "$$sname" quit; \
	    else \
	        echo "==> kill $$p"; \
	        kill "$$p" 2>/dev/null || true; \
	    fi; \
	done

# List all FPGA dev boards: USB serial ports per cable, then the JTAG scan
# chain per cable as seen by xsct (a cable whose JTAG channel is blocked by
# ftdi_sio may appear in the USB list but not the JTAG list).
list-all:
	@echo "==> USB serial ports:"
	@found=0; \
	for dev in /sys/class/tty/ttyUSB*; do \
	    [ -e "$$dev" ] || continue; \
	    mfg=$$(cat "$$dev/device/../../manufacturer" 2>/dev/null); \
	    prod=$$(cat "$$dev/device/../../product" 2>/dev/null); \
	    ser=$$(cat "$$dev/device/../../serial" 2>/dev/null); \
	    intf=$$(cat "$$(readlink -f $$dev/device/..)/bInterfaceNumber" 2>/dev/null); \
	    usbpath=$$(basename "$$(readlink -f $$dev/device/../..)"); \
	    printf "  /dev/%-9s usb=%-10s if=%s  %s %s  serial=%s\n" \
	        "$$(basename $$dev)" "$$usbpath" "$$intf" "$$mfg" "$$prod" "$$ser"; \
	    found=1; \
	done; \
	if [ $$found -eq 0 ]; then echo "  (none)"; fi
	@if [ ! -f "$(VITIS_SETTINGS)" ]; then \
	    echo "==> JTAG: skipped (Vitis Classic not found at $(VITIS_SETTINGS))"; \
	    exit 0; \
	fi; \
	echo "==> JTAG scan chains (xsct):"; \
	source $(VITIS_SETTINGS) && xsct -eval ' \
	    connect; \
	    foreach t [jtag targets -target-properties] { \
	        set level [dict get $$t level]; \
	        set name  [dict get $$t name]; \
	        if {$$level == 0} { \
	            puts "  cable: $$name" \
	        } else { \
	            puts "    device: $$name" \
	        } \
	    }; \
	    disconnect' 2>/dev/null | grep -E "cable:|device:" \
	    || echo "  (no JTAG cables found)"

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

