# Cross-compile kr260_hw_test for the KR260 (Ubuntu, aarch64).
#
# Default toolchain is Debian/Ubuntu's gcc-aarch64-linux-gnu package:
#   sudo apt install gcc-aarch64-linux-gnu
# main.c uses only stdlib + standard Linux syscalls, so no Xilinx sysroot
# is needed. Override CC=... if you want to use a different cross-gcc
# (e.g. the PetaLinux SDK's aarch64-xilinx-linux-gcc).

TARGET := kr260_hw_test

# CC must be `=`, not `?=` — make defines CC=cc as a built-in, so `?=` would
# silently keep the host x86_64 compiler and fail on the ARM64 inline asm
# (dsb / dc cvac / dc civac) in main.c. `=` still allows `make CC=...` from
# the command line, because command-line assignments outrank Makefile ones.
CC = aarch64-linux-gnu-gcc
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
