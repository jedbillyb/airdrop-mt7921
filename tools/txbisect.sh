#!/bin/bash
# Which commit killed the unicast TX path?
#
# ping6 to the peer turns out to be a reliable 8-second test of whether our
# frames reach the phone at all. Measured 2026-07-31: the pre-change OWL gets
# 5/5 replies on channel 149 while a later build gets 0/5 against the same phone
# in the same state, so the difference is ours and this is what finds it.
#
# (That also retires a long-standing ambiguity. FINDINGS §10 read 100% ping loss
# as "inconclusive, iOS ignores pings from strangers". iOS answers fine when the
# path works, so 100% loss is a real failure signal, not a shrug.)
#
# Sets the card up ONCE and runs each binary against it in turn, so a four-way
# comparison costs one setup instead of four, and every binary sees the same
# radio state and the same phone.
#
# SAFETY: bash trap + setsid-detached watchdog, per this repo's harness rule.
set -u

IFACE="${IFACE:-}"
if [ -z "$IFACE" ]; then
  for d in /sys/class/net/*/device/driver; do
    case "$(basename "$(readlink -f "$d")")" in
      mt7921*) IFACE=$(basename "$(dirname "$(dirname "$d")")"); break ;;
    esac
  done
fi
[ -n "$IFACE" ] || { echo "no mt7921 interface found"; exit 1; }
PHY=$(basename "$(readlink -f "/sys/class/net/$IFACE/phy80211")" 2>/dev/null)
MON=mon0
MONA=mon1
AWDL=awdl0
CHAN="${CHAN:-149}"
case "$CHAN" in 6) CHAN_MHZ=2437 ;; 36) CHAN_MHZ=5180 ;; 44) CHAN_MHZ=5220 ;; 132) CHAN_MHZ=5660 ;; 149) CHAN_MHZ=5745 ;; esac
MT76=/sys/kernel/debug/ieee80211/$PHY/mt76
PEER_WAIT="${PEER_WAIT:-40}"
OUT="${OUT_DIR:-$PWD/runs}/txbisect-$(date +%Y%m%d-%H%M%S)"

# Each entry: <label>:<binary>:<extra args>. Oldest first, so the first FAIL
# after a PASS names the culprit.
S=/tmp/claude-1000/-home-jed/3da1edfb-3941-43d6-bab5-b273a712f7c7/scratchpad
BUILDS="${BUILDS:-
0c48db8-base:$S/owl-good/build/daemon/owl:
c3fc4a4-strategies:$S/owl-c3fc4a4/build/daemon/owl:-S pin
92a12b8-async-setchan:$S/owl-92a12b8/build/daemon/owl:-S pin
HEAD-current:/home/jed/owl/build/daemon/owl:-S pin
}"

if [ "$(id -u)" = "0" ]; then echo "run as a normal user; it sudos internally"; exit 1; fi
mkdir -p "$OUT" || exit 1
sudo -v || exit 1
sudo mountpoint -q /sys/kernel/debug || sudo mount -t debugfs none /sys/kernel/debug

if command -v sv >/dev/null 2>&1 && [ -e /var/service/NetworkManager ]; then
  NM_UP='sudo sv up NetworkManager'; NM_DOWN='sudo sv down NetworkManager'
else
  NM_UP='sudo systemctl start NetworkManager'; NM_DOWN='sudo systemctl stop NetworkManager'
fi

RESTORE_CMDS='
  sudo pkill -x owl 2>/dev/null || true
  sudo ip link set '"$MONA"' down 2>/dev/null || true
  sudo iw dev '"$MONA"' del 2>/dev/null || true
  sudo ip link set '"$MON"' down 2>/dev/null || true
  sudo iw dev '"$MON"' del 2>/dev/null || true
  sudo sh -c "echo 1 > '"$MT76"'/runtime-pm" 2>/dev/null || true
  sudo sh -c "echo 1 > '"$MT76"'/deep-sleep" 2>/dev/null || true
  sudo ip link set '"$IFACE"' down 2>/dev/null || true
  sudo iw dev '"$IFACE"' set type managed 2>/dev/null || true
  sudo ip link set '"$IFACE"' up 2>/dev/null || true
  '"$NM_UP"' 2>/dev/null || true
'
NBUILDS=$(echo "$BUILDS" | grep -c ':')
setsid nohup bash -c "sleep $((NBUILDS * 90 + 180)); $RESTORE_CMDS" >/dev/null 2>&1 &
WATCHDOG_PID=$!

RESTORED=0
restore() {
  [ "$RESTORED" = "1" ] && return
  RESTORED=1
  echo ""; echo "--- restoring networking ---"
  eval "$RESTORE_CMDS"
  kill "$WATCHDOG_PID" 2>/dev/null || true
  echo "restored. logs in $OUT"
}
trap 'restore' EXIT
trap 'restore; exit 130' INT TERM

echo "TX bisect on channel $CHAN ($CHAN_MHZ MHz), interface $IFACE/$PHY"
echo "PHONE: unlock it, AirDrop > Everyone, and leave a share sheet OPEN for the"
echo "whole run - if its AWDL sleeps midway the later builds fail for that reason"
echo "and not for theirs."
echo ""

# THE PAIR, set up once: plain mon0 owns the channel, active mon1 ACKs. Order
# matters - mon0 must exist and be tuned before mon1 is created, or the active
# vif lands on 5180 and stays there (FINDINGS §14).
$NM_DOWN 2>/dev/null; sleep 1
sudo ip link set "$IFACE" down 2>/dev/null
sudo iw dev "$MONA" del 2>/dev/null; sudo iw dev "$MON" del 2>/dev/null
sudo iw phy "$PHY" interface add "$MON" type monitor || exit 1
sudo ip link set "$MON" up
sudo sh -c "echo 0 > $MT76/runtime-pm" 2>/dev/null
sudo sh -c "echo 0 > $MT76/deep-sleep" 2>/dev/null
sudo iw dev "$MON" set freq "$CHAN_MHZ"
sleep 1
sudo iw phy "$PHY" interface add "$MONA" type monitor flags active || exit 1
sudo ip link set "$MONA" up
sleep 1

printf "%-24s %-8s %-10s %s\n" BUILD PEER PING VERDICT
echo "--------------------------------------------------------------"

echo "$BUILDS" | while IFS=: read -r label bin args; do
  [ -z "${label:-}" ] && continue
  if [ ! -x "${bin:-}" ]; then
    printf "%-24s %-8s %-10s %s\n" "$label" "-" "-" "NO BINARY at $bin"
    continue
  fi
  LOG="$OUT/owl-$label.log"
  # shellcheck disable=SC2086
  sudo stdbuf -oL "$bin" -i "$MONA" -c "$CHAN" -N $args -vv > "$LOG" 2>&1 &
  for i in $(seq "$PEER_WAIT"); do
    grep -q "add peer" "$LOG" 2>/dev/null && break
    sleep 1
  done
  if ! grep -q "add peer" "$LOG" 2>/dev/null; then
    sudo pkill -x owl 2>/dev/null; sleep 2
    printf "%-24s %-8s %-10s %s\n" "$label" "no" "-" "VOID - no peer, phone asleep?"
    continue
  fi
  for i in $(seq 15); do ip link show $AWDL >/dev/null 2>&1 && break; sleep 1; done
  sudo ip link set $AWDL up 2>/dev/null
  PEER=$(ip -6 neigh show dev $AWDL 2>/dev/null | awk '/lladdr/{print $1; exit}')
  if [ -z "${PEER:-}" ]; then
    sudo pkill -x owl 2>/dev/null; sleep 2
    printf "%-24s %-8s %-10s %s\n" "$label" "yes" "-" "VOID - no IPv6 neighbour"
    continue
  fi
  LOSS=$(ping6 -c 5 -W 2 -i 1 "$PEER%$AWDL" 2>/dev/null | grep -oE "[0-9]+% packet loss" | head -1)
  LOSS="${LOSS:-100% packet loss}"
  case "$LOSS" in
    "0% packet loss") V="PASS - TX reaches the phone" ;;
    "100% packet loss") V="FAIL - nothing gets through" ;;
    *) V="PARTIAL" ;;
  esac
  printf "%-24s %-8s %-10s %s\n" "$label" "yes" "${LOSS% packet loss}" "$V"
  sudo pkill -x owl 2>/dev/null
  sleep 3
done

echo ""
echo "The first FAIL after a PASS is the commit that broke it."
echo "A VOID row means the phone was not reachable for that build - re-run;"
echo "it says nothing about that commit."
