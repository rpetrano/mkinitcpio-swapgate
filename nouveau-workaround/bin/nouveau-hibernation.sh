#!/bin/bash
set -euo pipefail

# --- ADJUST THESE IF NEEDED ---
GPU_PCI="0000:01:00.0"
# ------------------------------

find_swaysock() {
  # pick the newest socket if multiple (resume cases)
  ls -1t /run/user/"$(id -u)"/sway-ipc.*.sock 2>/dev/null | head -n1 || {
    logger "[nouveau-park] can't find sway socket"
    return 1
  }
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
  logger "[nouveau-park] can't find nvidia_card for $GPU_PCI"
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

action="${1:-}"

if [[ "$action" != "pre" && "$action" != "post" ]]; then
  echo "Usage: $0 pre|post" >&2
  exit 1
fi

card="$(nvidia_card)"
swaysock="$(find_swaysock)"

case "$action" in
  pre)
    logger "[nouveau-park] pre: preparing NVIDIA $GPU_PCI (card=$card)"

    mapfile -t outs < <(nvidia_connected_outputs "$card")
    if ((${#outs[@]})); then
      for o in "${outs[@]}"; do
        SWAYSOCK="$swaysock" swaymsg -- output "$o" disable || {
          logger "[nouveau-park] swaymsg disable failed for $o"
          exit 254
        }
      done
      logger "[nouveau-park] disabled outputs: ${outs[*]}"
    else
      logger "[nouveau-park] no connected NVIDIA outputs found"
      exit 1
    fi

    ;;

  post)
    logger "[nouveau-park] post: restoring NVIDIA $GPU_PCI (card=$card)"

    mapfile -t outs < <(nvidia_connected_outputs "$card")
    if ((${#outs[@]})); then
      for o in "${outs[@]}"; do
        SWAYSOCK="$swaysock" swaymsg -- output "$o" enable || {
           logger "[nouveau-park] swaymsg enable failed for $o" 
           exit 254
        }
      done
      logger "[nouveau-park] re-enabled outputs: ${outs[*]}"
    else
      logger "[nouveau-park] no connected NVIDIA outputs to re-enable"
    fi

    ;;
esac

