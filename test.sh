#!/bin/bash

set -euo pipefail

# -------- config you may tweak for the test ----------
BOOT=${BOOT:-/boot}
KERNEL=${KERNEL:-$BOOT/vmlinuz-linux}
INITRD=${INITRD:-$BOOT/initramfs-linux-fallback.img}
IMG=${IMG:-/tmp/swapgate-qemu.img}
IMG_SIZE_MB=${IMG_SIZE_MB:-128}        # total image size
ESP_SIZE_MB=${ESP_SIZE_MB:-32}         # ESP size inside the image
QEMU_CPU=${QEMU_CPU:-qemu64}           # cpu to use with qemu
QEMU_RAM=${QEMU_RAM:-512M}              # guest RAM for qemu
BREAK_STAGE=${BREAK_STAGE:-premount}   # mkinitcpio break=premount|postmount
CREATE_COOKIE=${CREATE_COOKIE:-0}      # 1 => put resume.cookie on ESP to exercise resume path
SERIAL=${SERIAL:-stdio}                # stdio or pty
# -----------------------------------------------------

CONF=/etc/swapgate.conf
if [[ ! -r "$CONF" ]]; then
  echo "Missing $CONF" >&2; exit 1
fi

# shellcheck disable=SC1091
. "$CONF"
PUBKEY="${BOOT}${PUBKEY_PATH}"
ID_ENC="${BOOT}${ID_ENC_PATH}"

if [[ -z "${SWAP_PARTUUID:-}" || -z "${ESP_PARTUUID:-}" ]]; then
  echo "SWAP_PARTUUID / ESP_PARTUUID must be set in $CONF" >&2; exit 1
fi

if [[ ! -r "$PUBKEY" || ! -r "$ID_ENC" ]]; then
  echo "Missing "$PUBKEY" or "$ID_ENC". Create them first." >&2; exit 1
fi

cleanup() {
  set +e
  [[ -n "${LOOP:-}" ]] && losetup -d "$LOOP" 2>/dev/null || true
}
trap cleanup EXIT

echo ">> Creating raw image: $IMG (${IMG_SIZE_MB} MiB)"
rm -f "$IMG"
truncate -s "${IMG_SIZE_MB}M" "$IMG"

echo ">> Partitioning (GPT) and assigning PARTUUIDs"
LOOP=$(losetup -fP --show "$IMG")
# GPT fresh label
sgdisk --zap-all "$LOOP" >/dev/null

# Create ESP as partition 1 (size ESP_SIZE_MB), type EF00
sgdisk -n 1:2048:+${ESP_SIZE_MB}M -t 1:EF00 "$LOOP" >/dev/null
# Create swap as partition 2 (rest), type 8200 (Linux swap)
sgdisk -n 2:0:0 -t 2:8200 "$LOOP" >/dev/null

# Set the *partition GUIDs* to match your config (these become PARTUUIDs)
sgdisk -u 1:"$ESP_PARTUUID" -u 2:"$SWAP_PARTUUID" "$LOOP" >/dev/null

partprobe "$LOOP"
ESP_PART=${LOOP}p1
SWAP_PART=${LOOP}p2

# Verify the PARTUUIDs are exactly as requested
got_esp=$(blkid -s PARTUUID -o value "$ESP_PART" || true)
got_swap=$(blkid -s PARTUUID -o value "$SWAP_PART" || true)
if [[ "$got_esp" != "$ESP_PARTUUID" || "$got_swap" != "$SWAP_PARTUUID" ]]; then
  echo "PARTUUID mismatch after sgdisk. Got ESP=$got_esp SWAP=$got_swap" >&2
  exit 1
fi

echo ">> Formatting ESP (vfat) and populating /rsa"
mkfs.vfat -F32 -n ESP "$ESP_PART" >/dev/null
mnt=/tmp/esp-mnt.$$; mkdir -p "$mnt"
mount -o rw "$ESP_PART" "$mnt"
mkdir -p "$mnt/rsa"
install -m 0644 "$PUBKEY" "${mnt}${PUBKEY_PATH}"
install -m 0600 "$ID_ENC" "${mnt}${ID_ENC_PATH}"

# Make a throwaway test key K0
K0=$(mktemp /tmp/swapgate-K0.key.XXX)
dd if=/dev/urandom of="$K0" bs=32 count=1 status=none

if [[ "${CREATE_COOKIE}" == "1" ]]; then
  echo "$(date -u +%FT%TZ)" > "${mnt}${COOKIE_PATH}"
  openssl pkeyutl -encrypt -pubin \
    -inkey "${mnt}${PUBKEY_PATH}" \
    -pkeyopt rsa_padding_mode:oaep \
    -pkeyopt rsa_oaep_md:sha256 \
    -pkeyopt rsa_mgf1_md:sha256 \
    -in "$K0" \
    -out "${mnt}${ENCK_PATH}" || {
      echo "[swapgate] ERROR: Failed to write Enc(K)."
      umount "$mnt"
      exit 1
    }

  sync
  echo ">> Created resume.cookie and generated swap key on ESP (will exercise resume path)"
fi
umount "$mnt"; rmdir "$mnt"

# Create LUKS header on the swap partition with K0 (so your hook sees 'already LUKS')
cryptsetup luksFormat "$SWAP_PART" "$K0" \
    --type luks2 --pbkdf pbkdf2 --pbkdf-force-iterations 1000 --keyfile-size 32 --batch-mode

# QEMU boot: pass kernel/initrd directly, attach the image as virtio-blk
# We set root=/dev/ram0 so we never need a real root; we just want initramfs.
# IMPORTANT: keep your real cmdline bits that your initramfs expects (quiet/loglevel as you like)
APPEND=(
  "console=ttyS0"
  "root=/dev/ram0"
  "rw"
  "resume=/dev/mapper/swap"
  "break=${BREAK_STAGE}"
  # add anything you usually pass: fbcon=scrollback:2048k, loglevel=7, etc.
)
ARGS=()
if [ "$QEMU_CPU" = "host" ]; then
    case "$(uname -s)" in
        Darwin)
            ARGS+=(-accel hvf)
            ;;
        Linux)
            ARGS+=(-accel kvm)
            ;;
    esac
fi

echo ">> Launching qemu (Ctrl+A then X to quit if using -nographic), press any key"
read
qemu-system-x86_64 \
  -cpu "${QEMU_CPU}" \
  -m "${QEMU_RAM}" \
  -nodefaults -no-reboot \
  -kernel "${KERNEL}" \
  -initrd "${INITRD}" \
  -append "${APPEND[*]}" \
  -drive if=virtio,format=raw,file="${IMG}",cache=writeback \
  -serial "mon:${SERIAL}" \
  -nographic \
  "${ARGS[@]}"

# Cleanup happens via trap
