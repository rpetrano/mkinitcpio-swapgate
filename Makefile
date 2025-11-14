PREFIX  ?= /
DESTDIR ?=

ETC_DIR          := $(DESTDIR)$(PREFIX)etc
BIN_DIR          := $(DESTDIR)$(PREFIX)usr/local/bin
MKINIT_HOOK      := $(ETC_DIR)/initcpio/hooks
MKINIT_INST      := $(ETC_DIR)/initcpio/install
SYSTEMD_USER_DIR := $(ETC_DIR)/systemd/user
SLEEP_DIR        := $(DESTDIR)$(PREFIX)usr/lib/systemd/system-sleep

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
	install -D -m 0644 etc/swapgate.conf $(ETC_DIR)/swapgate.conf
	install -D -m 0755 initcpio/hooks/swapgate   $(MKINIT_HOOK)/swapgate
	install -D -m 0755 initcpio/install/swapgate $(MKINIT_INST)/swapgate
	install -D -m 0755 systemd-sleep-hook/99-resume-cookie.sh $(SLEEP_DIR)/99-resume-cookie

nouveau-workaround: nouveau-workaround/target/release/nouveau_sleep_daemon
	cd nouveau-workaround
	cargo build --release

.PHONY: install-nouveau-workaround
install-nouveau-workaround:
	install -D -m 0644 nouveau-workaround/systemd/nouveau-sleep-daemon.service $(SYSTEMD_USER_DIR)/nouveau-sleep-daemon.service
	install -D -m 0755 nouveau-workaround/bin/nouveau-hibernation.sh $(BIN_DIR)/nouveau-hibernation.sh
	install -D -m 0755 nouveau-workaround/target/release/nouveau_sleep_daemon $(BIN_DIR)/nouveau_sleep_daemon
	@echo
	@echo "Don't forget to run:"
	@echo "systemctl --user daemon-reload"
	@echo "systemctl --user enable --now nouveau-sleep-daemon.service"

.PHONY: uninstall-nouveau-workaround
uninstall-nouveau-workaround:
	rm -f $(SYSTEMD_USER_DIR)/nouveau-sleep-daemon.service
	rm -f $(BIN_DIR)/nouveau-hibernation.sh
	rm -f $(BIN_DIR)/nouveau_sleep_daemon

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

