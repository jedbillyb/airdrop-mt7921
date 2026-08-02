#!/bin/bash
# waybar custom module for on-demand AirDrop. Emits one JSON object.
#
#   "custom/airdrop": {
#       "exec": "~/.config/waybar/airdrop-status.sh",
#       "return-type": "json",
#       "interval": 2,
#       "on-click": "~/.config/waybar/airdrop-status.sh toggle"
#   }
#
# Follows the pattern of the other modules on this box (caffeine-status.sh,
# vpn-status.sh): the script lives in the project and is symlinked into
# ~/.config/waybar/.
set -u

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
DAEMON="$HERE/../daemon/airdropd"

if [ "${1:-}" = "toggle" ]; then
  if "$DAEMON" status | grep -q '"state":"off"'; then
    setsid nohup "$DAEMON" run >/dev/null 2>&1 &
  else
    "$DAEMON" stop
  fi
  exit 0
fi

STATE_JSON=$("$DAEMON" status 2>/dev/null || echo '{"state":"off"}')
state=$(printf '%s' "$STATE_JSON" | grep -oP '"state":"\K[^"]+')
detail=$(printf '%s' "$STATE_JSON" | grep -oP '"detail":"\K[^"]*')

# Escape for JSON. A sender name or an error string can contain a quote or a
# backslash, and one of those on the bar breaks waybar's parse for every
# module, not just this one.
esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

case "$state" in
  off)    text=""; class="off";    tip="AirDrop off - click to start listening" ;;
  idle)   text=""; class="idle";   tip="AirDrop listening on Bluetooth. Open the share sheet on your iPhone." ;;
  waking) text=""; class="waking"; tip="AirDrop: phone detected ($detail) - bringing radio up" ;;
  armed)  text=""; class="armed";  tip="AirDrop ready ($detail) - pick this machine on your iPhone" ;;
  error)  text=""; class="error";  tip="AirDrop error: $detail" ;;
  *)      text=""; class="off";    tip="AirDrop: unknown state" ;;
esac

printf '{"text":"%s","class":"%s","tooltip":"%s"}\n' \
  "$(esc "$text")" "$(esc "$class")" "$(esc "$tip")"
