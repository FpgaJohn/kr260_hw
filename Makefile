KR260_HOST ?= kr260u
KR260_USER ?= ubuntu
SCRIPT     := list_uio.sh
REMOTE_DIR := /home/$(KR260_USER)

.PHONY: info deploy deploy-run

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

