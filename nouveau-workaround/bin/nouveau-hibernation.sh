#!/bin/bash
set -euo pipefail

# --- ADJUST THESE IF NEEDED ---
GPU_PCI="0000:01:00.0"
PRE_SLEEP_DELAY=2
POST_SOCKET_LOOP_DELAY=0.2
POST_SOCKET_LOOP_N=10
POST_SLEEP_DELAY=2
# ------------------------------

loop_find_swaysock() {
  local i=0
  while [ "$i" -lt "$POST_SOCKET_LOOP_N" ]; do
    find_swaysock -q || {
      i=$((i+1))
      sleep "$POST_SOCKET_LOOP_DELAY"
      continue
    }
    return
  done
  local _time="$(bc -ql <<< "scale=3; $POST_SOCKET_LOOP_N * $POST_SOCKET_LOOP_DELAY")"
  logger "[nouveau-park] can't find sway sock after $POST_SOCKET_LOOP_N tries ($_time seconds)"
  return 1
}

find_swaysock() {
  local quiet=""
  [[ "$#" -gt 0 && "$1" = "-q" ]] && quiet=1

  # pick the newest socket if multiple (resume cases)
  ls -1t /run/user/"$(id -u)"/sway-ipc.*.sock 2>/dev/null | head -n1 || {
    if [ ! "$quiet" ]; then
      logger "[nouveau-park] can't find sway socket"
    fi
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

case "$action" in
  pre)
    logger "[nouveau-park] pre: preparing NVIDIA $GPU_PCI (card=$card)"

    swaysock="$(find_swaysock)"
    mapfile -t outs < <(nvidia_connected_outputs "$card")
    if ((${#outs[@]})); then
      for o in "${outs[@]}"; do
        SWAYSOCK="$swaysock" swaymsg -- output "$o" disable || {
          logger "[nouveau-park] swaymsg disable failed for $o"
          exit 254
        }
      done
      logger "[nouveau-park] disabled outputs: ${outs[*]}"
      if [ -n "$PRE_SLEEP_DELAY" ]; then
          logger "[nouveau-park] waiting for sway to settle up ($PRE_SLEEP_DELAY)"
          sleep "$PRE_SLEEP_DELAY"
      fi
    else
      logger "[nouveau-park] no connected NVIDIA outputs found"
      exit 1
    fi

    ;;

  post)
    logger "[nouveau-park] post: restoring NVIDIA $GPU_PCI (card=$card)"
    swaysock="$(loop_find_swaysock)"

    mapfile -t outs < <(nvidia_connected_outputs "$card")
    if ((${#outs[@]})); then
      if [ -n "$POST_SLEEP_DELAY" ]; then
          logger "[nouveau-park] waiting for sway to settle up ($POST_SLEEP_DELAY)"
          sleep "$POST_SLEEP_DELAY"
      fi
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

