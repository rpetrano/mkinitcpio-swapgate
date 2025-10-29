#!/bin/bash

set -euo pipefail

: ${BOOT:=/boot}
. /etc/swapgate.conf

tempfile=$(mktemp /tmp/swapgate.key.XXX)

mkdir -p "$(dirname "${BOOT}${ID_ENC_PATH}")"
mkdir -p "$(dirname "${BOOT}${PUBKEY_PATH}")"
mkdir -p "$(dirname "${BOOT}${ENCK_PATH}")"

openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out "$tempfile"
openssl rsa -in "$tempfile" -aes256 -out "${BOOT}${ID_ENC_PATH}"
openssl rsa -in "$tempfile" -pubout -out "${BOOT}${PUBKEY_PATH}"
shred -n3 -u "$tempfile"

K0=$(mktemp /tmp/swapgate-K0.key.XXX)
cleanup() {
    echo shred -n3 -u "$K0"
}
trap cleanup EXIT

dd if=/dev/urandom of="$K0" bs=32 count=1 status=none
openssl pkeyutl -encrypt -pubin \
  -inkey "${BOOT}${PUBKEY_PATH}" \
  -pkeyopt rsa_padding_mode:oaep \
  -pkeyopt rsa_oaep_md:sha256 \
  -pkeyopt rsa_mgf1_md:sha256 \
  -in "$K0" \
  -out "${BOOT}${ENCK_PATH}" || {
    echo "[swapgate] ERROR: Failed to write Enc(K)."
    exit 1
  }


SWAP_DEV=/dev/disk/by-partuuid/$SWAP_PARTUUID
echo If not already done, format your swap as luks encrypted partition

echo cryptsetup luksFormat "$SWAP_DEV" "$K0" \
    --type luks2 --pbkdf pbkdf2 --pbkdf-force-iterations 1000 --keyfile-size 32 --batch-mode
echo cryptsetup luksOpen "$SWAP_DEV" "$MAP_NAME" --key-file "$K0"
echo mkswap "/dev/mapper/$MAP_NAME"
echo swapon "/dev/mapper/$MAP_NAME"

