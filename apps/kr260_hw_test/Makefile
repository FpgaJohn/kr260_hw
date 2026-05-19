# Cross-compile kr260_hw_test for the KR260's cortexa72 sysroot.
#
# The PetaLinux SDK at $(SDK)/environment-setup-cortexa72-cortexa53-xilinx-linux
# sets CC, CXX, CFLAGS, LDFLAGS to the right cross-toolchain. Source it, then
# `make`.

SDK ?= /home/john/work/kr260_petalinux/sdk
ENV := $(SDK)/environment-setup-cortexa72-cortexa53-xilinx-linux

TARGET := kr260_hw_test

# When the SDK env is sourced, $(CC) is the cross gcc with sysroot wired in.
# Fall back to a bare `aarch64-...-gcc` if env not sourced (will fail visibly).
CC ?= aarch64-xilinx-linux-gcc
CFLAGS ?= -O2 -Wall -Wextra -std=gnu11

REMOTE_HOST ?= kr260u
REMOTE_PATH ?= /tmp/

.PHONY: all clean deploy run

all: $(TARGET)

$(TARGET): main.c
	$(CC) $(CFLAGS) -o $@ $<
	@file $@

clean:
	rm -f $(TARGET)

deploy: $(TARGET)
	scp $(TARGET) $(REMOTE_HOST):$(REMOTE_PATH)

run: deploy
	ssh $(REMOTE_HOST) "sudo $(REMOTE_PATH)$(TARGET)"
