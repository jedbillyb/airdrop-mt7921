#!/bin/bash
# Which half of PIN killed unicast TX?
#
# §24 re-read the §23 bisect logs and found the software TX gate is NOT the
# culprit: all four builds emitted exactly 4 unicast data frames to the phone,
# the ping6 packets. What separates them is channel switching -- the one build
# that passed switched 21 times in 6 s, and all three that failed switched once
# at startup and then never again, because a pinned sequence is constant.
#
# But PIN changed two things in the same commit, and the bisect cannot tell them
# apart:
#
#   (1) the radio stopped being re-tuned, and
#   (2) the sequence we ADVERTISE stopped looking like anything an Apple device
#       emits -- one channel in all 16 slots, no infra channel in slot 0.
#
# Arm C separates them. It pins exactly as arm B does, so what we advertise is
# identical, and re-issues set_channel() for the channel we are already on every
# 250 ms, so the radio is poked at roughly the rate arm A pokes it.
#
#   C PASSES  -> the driver needs the re-tune. PIN's channel logic is fine and
#                the fix is a keepalive, not a revert.
#   C FAILS   -> the phone is refusing our advertised sequence. The fix is to
#                sit on one channel while still advertising a conformant one.
#
# Arm D re-runs arm B last. If D does not reproduce B, the phone drifted during
# the run and every row is void -- this project has been burnt by run-order
# confounds three times, so the re-test is not optional.
#
# One binary throughout (HEAD), so nothing here depends on prebuilt binaries in
# a scratchpad that may not survive the session.
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
case "$CHAN" in
  6) CHAN_MHZ=2437 ;; 36) CHAN_MHZ=5180 ;; 44) CHAN_MHZ=5220 ;;
  132) CHAN_MHZ=5660 ;; 149) CHAN_MHZ=5745 ;;
  *) echo "unknown channel $CHAN"; exit 1 ;;
esac
MT76=/sys/kernel/debug/ieee80211/$PHY/mt76
OWL="${OWL:-/home/jed/owl/build/daemon/owl}"
PEER_WAIT="${PEER_WAIT:-40}"
OUT="${OUT_DIR:-$PWD/runs}/txarms-$(date +%Y%m%d-%H%M%S)"

# <label>:<args>. Arm A first so a PASS establishes the phone is reachable at
# all before anything is concluded from a FAIL.
ARMS="${ARMS:-
A-verbatim:-S verbatim
B-pin:-S pin
C-pin-retune250:-S pin -K 250
D-pin-again:-S pin
}"

[ -x "$OWL" ] || { echo "no owl binary at $OWL (set OWL=)"; exit 1; }
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
NARMS=$(echo "$ARMS" | grep -c ':')
setsid nohup bash -c "sleep $((NARMS * 90 + 180)); $RESTORE_CMDS" >/dev/null 2>&1 &
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

echo "TX arms on channel $CHAN ($CHAN_MHZ MHz), interface $IFACE/$PHY"
echo "binary: $OWL"
echo "PHONE: unlock it, AirDrop > Everyone, and leave a share sheet OPEN for the"
echo "whole run. Everyone EXPIRES after 10 minutes - re-arm it before starting."
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

printf "%-18s %-6s %-8s %-8s %s\n" ARM PING SWITCHES TXUNI VERDICT
echo "---------------------------------------------------------------------"

echo "$ARMS" | while IFS=: read -r label args; do
  [ -z "${label:-}" ] && continue
  LOG="$OUT/owl-$label.log"
  # shellcheck disable=SC2086
  sudo stdbuf -oL "$OWL" -i "$MONA" -c "$CHAN" -N $args -vv > "$LOG" 2>&1 &
  for i in $(seq "$PEER_WAIT"); do
    grep -q "add peer" "$LOG" 2>/dev/null && break
    sleep 1
  done
  if ! grep -q "add peer" "$LOG" 2>/dev/null; then
    sudo pkill -x owl 2>/dev/null; sleep 2
    printf "%-18s %-6s %-8s %-8s %s\n" "$label" "-" "-" "-" "VOID - no peer, phone asleep?"
    continue
  fi
  for i in $(seq 15); do ip link show $AWDL >/dev/null 2>&1 && break; sleep 1; done
  sudo ip link set $AWDL up 2>/dev/null
  PEER=$(ip -6 neigh show dev $AWDL 2>/dev/null | awk '/lladdr/{print $1; exit}')
  if [ -z "${PEER:-}" ]; then
    sudo pkill -x owl 2>/dev/null; sleep 2
    printf "%-18s %-6s %-8s %-8s %s\n" "$label" "-" "-" "-" "VOID - no IPv6 neighbour"
    continue
  fi
  LOSS=$(ping6 -c 5 -W 2 -i 1 "$PEER%$AWDL" 2>/dev/null | grep -oE "[0-9]+% packet loss" | head -1)
  LOSS="${LOSS:-100% packet loss}"
  case "$LOSS" in
    "0% packet loss")   V="PASS" ;;
    "100% packet loss") V="FAIL - nothing gets through" ;;
    *)                  V="PASS (partial loss)" ;;
  esac
  # Both counters come from the same log, so a row is self-describing: TXUNI is
  # how many unicast data frames OWL handed to the radio, and it was 4 in every
  # arm of the §23 bisect including the failures. If it is 4 here too, the
  # software gate is again not the story and SWITCHES is what to read.
  SW=$(grep -c "switch channel to\|retune to channel" "$LOG")
  TXU=$(grep "Send data" "$LOG" | grep -vc "33:33")
  printf "%-18s %-6s %-8s %-8s %s\n" "$label" "${LOSS% packet loss}" "$SW" "$TXU" "$V"
  sudo pkill -x owl 2>/dev/null
  sleep 3
done

echo ""
echo "Reading it:"
echo "  The first and last arms are the controls, whatever ARMS you passed."
echo "  If the first arm FAILS the phone was never reachable and every row is"
echo "  void. If the last arm does not reproduce the earlier arm it repeats, the"
echo "  phone drifted mid-run and every row is void. Only once both controls hold"
echo "  does any middle row mean anything."
echo ""
echo "  TXUNI is how many unicast frames OWL handed to the radio. It was 4 in"
echo "  every arm of the §23 bisect INCLUDING the failures, so a FAIL with TXUNI"
echo "  at 4 is not a software gate - it means the phone chose not to answer."
