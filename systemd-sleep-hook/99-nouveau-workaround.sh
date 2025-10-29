#!/bin/bash
set -euo pipefail

# --- ADJUST THESE IF NEEDED ---
USER_NAME="icewootra"
GPU_PCI="0000:01:00.0"
GPU_DRV="nouveau"
UNLOAD_NOUVEAU="no"
# ------------------------------

uid="$(id -u "$USER_NAME")"
# Find Sway IPC socket (if any)
find_swaysock() {
  # pick the newest socket if multiple (resume cases)
  ls -1t /run/user/"$uid"/sway-ipc.*.sock 2>/dev/null | head -n1 || true
}

# Map NVIDIA PCI device -> DRM card index (cardN)
nvidia_card() {
  for d in /sys/class/drm/card*; do
    [ -e "$d/device" ] || continue
    if [[ "$(readlink -f "$d/device")" =~ $GPU_PCI$ ]]; then
      basename "$d"
      return 0
    fi
  done
  return 1
}

# List connected connectors (names like HDMI-A-1, DP-1) on that card
nvidia_connected_outputs() {
  local card="$1"
  for c in /sys/class/drm/"$card"-*; do
    [ -e "$c/status" ] || continue
    if [[ "$(cat "$c/status")" == "connected" ]]; then
      # connector name is basename after "cardN-"
      basename "$c" | sed "s/^$card-//"
    fi
  done
}

swaysock="$(find_swaysock || true)"
card="$(nvidia_card || true)"

case "$1" in
  pre)
    logger "[nouveau-park] pre-$2: preparing NVIDIA $GPU_PCI (card=$card)"
    # 1) disable *only* NVIDIA outputs in Sway
    if [[ -n "$swaysock" && -n "$card" ]]; then
      mapfile -t outs < <(nvidia_connected_outputs "$card")
      if ((${#outs[@]})); then
        for o in "${outs[@]}"; do
          su - "$USER_NAME" -c "SWAYSOCK='$swaysock' swaymsg -- output '$o' disable" || true
        done
        logger "[nouveau-park] disabled outputs: ${outs[*]}"
      else
        logger "[nouveau-park] no connected NVIDIA outputs found"
      fi
    else
      logger "[nouveau-park] sway socket or NVIDIA card not found; skipping output disable"
    fi

    # 2) optionally unload nouveau (safest) and undbind
    if [[ "$UNLOAD_NOUVEAU" == "yes" ]]; then
      modprobe -r "$GPU_DRV" 2>/dev/null || true
      echo "$GPU_PCI" > /sys/bus/pci/devices/$GPU_PCI/driver/unbind 2>/dev/null || true
    fi
    ;;

  post)
    logger "[nouveau-park] post-$2: restoring NVIDIA $GPU_PCI"

    # 1) reload nouveau if we removed it
    if [[ "$UNLOAD_NOUVEAU" == "yes" ]]; then
      echo "$GPU_PCI" > /sys/bus/pci/drivers_probe 2>/dev/null || true
      # give it a moment to enumerate DRM nodes
      sleep 1

      modprobe "$GPU_DRV" 2>/dev/null || true
      sleep 1
    fi

    # refresh handles
    swaysock="$(find_swaysock || true)"
    card="$(nvidia_card || true)"

    # 2) re-enable only NVIDIA outputs
    if [[ -n "$swaysock" && -n "$card" ]]; then
      mapfile -t outs < <(nvidia_connected_outputs "$card")
      if ((${#outs[@]})); then
        for o in "${outs[@]}"; do
          su - "$USER_NAME" -c "SWAYSOCK='$swaysock' swaymsg -- output '$o' enable" || true
        done
        logger "[nouveau-park] re-enabled outputs: ${outs[*]}"
      fi
    fi
    ;;
esac

