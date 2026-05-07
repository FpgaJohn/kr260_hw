KR260_HOST ?= kr260u
KR260_USER ?= ubuntu
SCRIPT     := list_uio.sh
REMOTE_DIR := /home/$(KR260_USER)

.PHONY: info

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

