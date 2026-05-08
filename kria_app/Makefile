APP_NAME := kr260_hw
XSA      := ../kr260_hw.xsa
XSA_BIT  := kr260_hw.bit
BUILD    := build
BIT      := $(BUILD)/$(APP_NAME).bit
BIT_BIN  := $(BUILD)/$(APP_NAME).bit.bin
DTSO     := $(APP_NAME).dtso
DTBO     := $(BUILD)/$(APP_NAME).dtbo
SHELL_J  := shell.json
PKG      := $(BUILD)/$(APP_NAME)

PETALINUX_SETTINGS ?= /tools/Xilinx/PetaLinux/2024.1/settings.sh

.PHONY: all package clean deploy

all: package

$(BUILD):
	mkdir -p $(BUILD)

$(BIT): $(XSA) | $(BUILD)
	unzip -p $(XSA) $(XSA_BIT) > $@

$(BIT_BIN): $(BIT) $(APP_NAME).bif
	. $(PETALINUX_SETTINGS) && \
		bootgen -arch zynqmp -image $(APP_NAME).bif -w -o $@ -process_bitstream bin

$(DTBO): $(DTSO) | $(BUILD)
	. $(PETALINUX_SETTINGS) && \
		dtc -@ -O dtb -I dts -o $@ $(DTSO)

package: $(BIT_BIN) $(DTBO) $(SHELL_J)
	rm -rf $(PKG)
	mkdir -p $(PKG)
	cp $(BIT_BIN) $(PKG)/$(APP_NAME).bit.bin
	cp $(DTBO)    $(PKG)/$(APP_NAME).dtbo
	cp $(SHELL_J) $(PKG)/shell.json
	@echo "----"
	@echo "App package ready at: $(PKG)"
	@ls -la $(PKG)

clean:
	rm -rf $(BUILD)

deploy: package
	scp -r build/$(APP_NAME) ubuntu@kr260u:~/
