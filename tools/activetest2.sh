#!/bin/bash
# Corrected active-monitor test.
#
# WHY: activetest.sh compared plain vs active WITHOUT verifying what frequency
# each phase was actually on. Result: plain landed on 2422 MHz (busy 2.4 GHz, AP
# present, 2000 frames) while active silently stayed on 5180 MHz (quiet 5 GHz,
# 9 frames). That is a channel difference, not an ACK difference, and the
# "active monitor destroys RX" conclusion drawn from it was invalid.
#
# This version:
#   * verifies the ACTUAL radiotap frequency of received frames, never trusting
#     iw's reported channel (which lies on this chip),
#   * tests both modes on BOTH frequencies, so like is compared with like,
#   * treats "could not reach the requested frequency" as a first-class result
#     rather than silently folding it into the frame count.
#
# Two separate questions, kept separate:
#   Q1: can an active-monitor vif change channel at all?
#   Q2: at equal frequency, does active monitor cost reception?
#
# SAFETY: bash trap + setsid-detached watchdog.
set -u

IFACE=wlp2s0
MON=mon0
DWELL=8
WATCHDOG_TIMEOUT=360
MT76=/sys/kernel/debug/ieee80211/phy0/mt76
OUT=/mnt/shared/owl-activetest2-$(date +%Y%m%d-%H%M%S)

mkdir -p "$OUT" || exit 1
sudo -v || exit 1
sudo mountpoint -q /sys/kernel/debug || sudo mount -t debugfs none /sys/kernel/debug
echo "kernel: $(uname -r)"

RESTORE_CMDS='
  sudo ip link set '"$MON"' down 2>/dev/null || true
  sudo iw dev '"$MON"' del 2>/dev/null || true
  sudo sh -c "echo 1 > '"$MT76"'/runtime-pm" 2>/dev/null || true
  sudo sh -c "echo 1 > '"$MT76"'/deep-sleep" 2>/dev/null || true
  sudo ip link set '"$IFACE"' down 2>/dev/null || true
  sudo iw dev '"$IFACE"' set type managed 2>/dev/null || true
  sudo ip link set '"$IFACE"' up 2>/dev/null || true
  sudo sv up NetworkManager 2>/dev/null || true
'
setsid nohup bash -c "sleep $WATCHDOG_TIMEOUT; $RESTORE_CMDS" >/dev/null 2>&1 &
WATCHDOG_PID=$!
RESTORED=0
restore() {
  [ "$RESTORED" = "1" ] && return 0
  RESTORED=1
  echo ""; echo "--- restoring ---"
  sudo pkill -x tcpdump 2>/dev/null || true
  eval "$RESTORE_CMDS"
  kill "$WATCHDOG_PID" 2>/dev/null || true
  echo "restored."
}
trap 'restore; exit 130' INT TERM
trap restore EXIT

sudo sv down NetworkManager
sudo pkill -x wpa_supplicant 2>/dev/null; sudo pkill -x dhcpcd 2>/dev/null; sleep 1
sudo iw reg set NZ

: > "$OUT/summary.txt"

# $1 = label, $2 = plain|active, $3 = target MHz
probe() {
  local LABEL="$1" KIND="$2" WANT="$3" PCAP="$OUT/$1.pcap" RC N DOM IWMHZ VERDICT
  sudo ip link set $MON down 2>/dev/null
  sudo iw dev $MON del 2>/dev/null
  sudo ip link set $IFACE down
  if [ "$KIND" = "active" ]; then
    sudo iw phy phy0 interface add $MON type monitor flags active 2>/dev/null; RC=$?
  else
    sudo iw phy phy0 interface add $MON type monitor 2>/dev/null; RC=$?
  fi
  [ "$RC" != "0" ] && { echo "  CREATE FAILED"; printf '%-26s CREATE FAILED\n' "$LABEL" >> "$OUT/summary.txt"; return; }
  sudo ip link set $MON up
  sudo sh -c "echo 0 > $MT76/runtime-pm"
  sudo sh -c "echo 0 > $MT76/deep-sleep"
  sudo iw dev $MON set freq "$WANT" 2>/dev/null
  sleep 2
  IWMHZ=$(iw dev $MON info 2>/dev/null | grep -oP 'channel [0-9]+ \(\K[0-9]+')

  sudo rm -f "$PCAP"
  sudo timeout $((DWELL + 3)) tcpdump -i $MON -w "$PCAP" -c 3000 >/dev/null 2>&1 &
  local TD=$!
  sleep $DWELL
  sudo pkill -x tcpdump 2>/dev/null || true
  wait $TD 2>/dev/null

  N=$(sudo tcpdump -r "$PCAP" 2>/dev/null | wc -l)
  DOM=$(sudo tcpdump -e -r "$PCAP" 2>/dev/null | grep -oP '\b\d{4}(?= MHz)' \
          | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')
  if [ -z "${DOM:-}" ]; then VERDICT="no frames - cannot tell"
  elif [ "$DOM" = "$WANT" ]; then VERDICT="on target"
  else VERDICT="OFF TARGET (wanted $WANT, got $DOM)"; fi

  printf '  iw_says=%-6s actual_rx=%-6s frames=%-6s %s\n' \
    "${IWMHZ:-NA}" "${DOM:-none}" "${N:-0}" "$VERDICT"
  printf '%-26s want=%-6s iw=%-6s actual=%-6s frames=%-6s %s\n' \
    "$LABEL" "$WANT" "${IWMHZ:-NA}" "${DOM:-none}" "${N:-0}" "$VERDICT" >> "$OUT/summary.txt"
}

for MHZ in 2422 5180; do
  echo ""
  echo "=========== target $MHZ MHz ==========="
  echo "-- plain --" ; probe "plain_$MHZ"  plain  $MHZ
  echo "-- active --"; probe "active_$MHZ" active $MHZ
done

echo ""
echo "=========== SUMMARY ==========="
cat "$OUT/summary.txt"
echo "==============================="
echo ""
echo "Read it as TWO questions:"
echo "  Q1 channel control: does 'active' ever land on target? If it is always"
echo "     OFF TARGET while plain is on target, active monitor blocks retuning."
echo "  Q2 reception cost: compare plain vs active ONLY where actual_rx matches"
echo "     between them. Any comparison across different actual_rx is invalid -"
echo "     that is exactly the mistake activetest.sh made."
