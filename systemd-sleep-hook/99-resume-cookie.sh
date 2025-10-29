#!/bin/sh
set -euo pipefail
STATE="${2:-}"
BOOT="/boot"

. /etc/swapgate.conf

COOKIE="${BOOT}${COOKIE_PATH}"

case "$1" in
  pre)
    # Only create cookie for hibernate/hybrid-sleep
    case "$STATE" in
      hibernate|hybrid-sleep)
        # Ensure /boot is mounted (usually is)
        mountpoint -q "$BOOT" || mount "$BOOT" || true
        date -u +"%FT%TZ" > "$COOKIE"
        sync
        ;;
    esac
    ;;
  post)
    # After successful resume, systemd will run this; remove cookie if present
    [ -f "$COOKIE" ] && rm -f "$COOKIE"
    ;;
esac

