PREFIX      ?= /
DESTDIR     ?=
ETC_DIR     := $(DESTDIR)$(PREFIX)etc
MKINIT_HOOK := $(DESTDIR)$(PREFIX)etc/initcpio/hooks
MKINIT_INST := $(DESTDIR)$(PREFIX)etc/initcpio/install
SLEEP_DIR   := $(DESTDIR)$(PREFIX)usr/lib/systemd/system-sleep

BOOT_IMG    ?= /boot/initramfs-linux.img
KERNEL_IMG  ?= /boot/vmlinuz-linux
BREAK_STAGE ?= premount
QEMU_RAM    ?= 1024
QEMU_CPU    ?= qemu64
IMG         ?= /tmp/swapgate-qemu.img

# Default target
.PHONY: all
all:
	@echo "Targets: install, uninstall, test, readme"

.PHONY: install
install:
	install -d $(ETC_DIR)
	install -D -m 0644 etc/swapgate.conf $(ETC_DIR)/swapgate.conf
	install -d $(MKINIT_HOOK) $(MKINIT_INST)
	install -D -m 0755 initcpio/hooks/swapgate   $(MKINIT_HOOK)/swapgate
	install -D -m 0755 initcpio/install/swapgate $(MKINIT_INST)/swapgate
	install -d $(SLEEP_DIR)
	install -D -m 0755 systemd-sleep-hook/99-resume-cookie.sh $(SLEEP_DIR)/99-resume-cookie

.PHONY: install-nouveau-workaround
install-nouveau-workaround:
	install -d $(SLEEP_DIR)
	install -D -m 0755 systemd-sleep-hook/99-nouveau-workaround.sh $(SLEEP_DIR)/99-nouveau-workaround

.PHONY: uninstall
uninstall:
	rm -f $(ETC_DIR)/swapgate.conf
	rm -f $(MKINIT_HOOK)/swapgate
	rm -f $(MKINIT_INST)/swapgate
	rm -f $(SLEEP_DIR)/99-resume-cookie

# QEMU test harness delegates to repo's test.sh
.PHONY: test
test:
	BOOT_IMG=$(BOOT_IMG) KERNEL_IMG=$(KERNEL_IMG) BREAK_STAGE=$(BREAK_STAGE) QEMU_RAM=$(QEMU_RAM) QEMU_CPU=$(QEMU_CPU) IMG=$(IMG) ./test.sh

.PHONY: readme
readme:
	@sed -n '1,999p' README.md

