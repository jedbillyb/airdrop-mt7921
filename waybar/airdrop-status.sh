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

# The bar is a plain on/off switch: "on" must mean "you can AirDrop to this
# machine right now", with no BLE step in between and without dropping the
# Wi-Fi association - which is exactly always-on plus P2P-GO. Override either
# in the environment if you want the BLE-triggered behaviour back.
export AIRDROP_ALWAYS="${AIRDROP_ALWAYS:-1}"
export AIRDROP_DUALCHAN="${AIRDROP_DUALCHAN:-1}"

# Optimistic state, written by the CLICK rather than by the daemon. Bringing
# the radio up takes ~20s, and waybar only polls every 2s, so without this the
# bar sits on the old label for several polls after a click and the switch
# feels broken - which gets it clicked again, and a second toggle mid-bring-up
# is exactly the race the daemon's flock exists to stop. Writing the
# transitional state here means the very next poll reflects the click. The
# daemon overwrites this with the truth (armed, or error) as soon as it knows.
RUNDIR="${XDG_RUNTIME_DIR:-/tmp}/airdropd"
STATE_FILE="$RUNDIR/state.json"

nudge_state() {
  mkdir -p "$RUNDIR" 2>/dev/null || return 0
  printf '{"state":"%s","detail":"%s","ts":%s}\n' "$1" "${2:-}" "$(date +%s)" \
    > "$STATE_FILE.tmp" 2>/dev/null && mv "$STATE_FILE.tmp" "$STATE_FILE" 2>/dev/null
}

if [ "${1:-}" = "toggle" ]; then
  if "$DAEMON" status | grep -q '"state":"off"'; then
    nudge_state waking "switch"
    setsid nohup "$DAEMON" run >/dev/null 2>&1 &
  else
    # Same on the way down: teardown takes a moment and the bar should not
    # keep claiming to be on while it happens.
    nudge_state off
    "$DAEMON" stop
  fi
  exit 0
fi

STATE_JSON=$("$DAEMON" status 2>/dev/null || echo '{"state":"off"}')
state=$(printf '%s' "$STATE_JSON" | grep -oP '"state":"\K[^"]+')

# Escape for JSON. A sender name or an error string can contain a quote or a
# backslash, and one of those on the bar breaks waybar's parse for every
# module, not just this one.
esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

case "$state" in
  # Only ever two labels: the switch is on or it is off. Everything else is
  # carried by the class, which is the colour. "waking" reads as on
  # deliberately - the click has happened and the switch IS on, the radio is
  # just still catching up, and a third transient label made the bar look
  # busier than the thing it describes. An error still reads "off", because
  # that is the truth: you cannot receive. It is coloured red instead.
  off)    text="drop off"; class="off"    ;;
  idle)   text="drop on";  class="idle"   ;;
  waking) text="drop on";  class="waking" ;;
  armed)  text="drop on";  class="armed"  ;;
  # The station was on 2.4GHz, where a GO cannot coexist with it, so the daemon
  # is moving the Wi-Fi to the SSID's 5GHz BSS for the duration. Reads as on -
  # the switch is on and this resolves itself in a few seconds - but carries its
  # own class, because the Wi-Fi is reassociating and the bar should say so
  # rather than looking identical to a normal bring-up. Still no third label:
  # two labels was an explicit call and the colour carries the rest.
  switching) text="drop on"; class="switching" ;;
  # The stack is up and advertising, but the phone we can see is on a channel
  # we cannot follow it to (see airdropd's go_target). Reads as on, because it
  # is - a phone on our channel would be served right now - with its own class
  # so the colour can say "not everyone can see you". Without this arm it fell
  # through to the catch-all below and claimed to be off while receiving.
  unreachable) text="drop on"; class="unreachable" ;;
  error)  text="drop off"; class="error"  ;;
  *)      text="drop off"; class="error"  ;;
esac

# No tooltip key at all - waybar shows nothing on hover when it is absent.
printf '{"text":"%s","class":"%s"}\n' "$(esc "$text")" "$(esc "$class")"
