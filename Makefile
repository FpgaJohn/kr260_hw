KR260_HOST ?= kr260u
KR260_USER ?= ubuntu
SCRIPT     := list_uio.sh
REMOTE_DIR := /home/$(KR260_USER)

MAKEFLAGS += --no-print-directory

.PHONY: info deploy deploy-run xsa xsa-clean bare-metal-build bare-metal-run bare-metal-clean

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

