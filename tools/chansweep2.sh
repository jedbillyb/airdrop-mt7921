#!/bin/bash
# Channel sweep, take 2 - this time with power management OFF so RX actually works.
#
# The first chansweep.sh ran with runtime-pm on, so it captured zero frames
# everywhere and I wrongly concluded "the radio tunes correctly" from iw's own
# claim. With PM off, frames arrive - and pmtest.sh showed them tagged 5180 MHz
# while iw claimed channel 2. So the 2026-07-25 channel-mismatch finding is REAL.
#
# This sweep answers it properly, with actual frames as evidence:
#   does the radiotap frequency of received frames follow the requested channel,
#   or does the radio sit on one frequency regardless of what iw reports?
#
# Also records tcpdump's kernel-drop count, because pmtest showed a large gap
# between netdev rx_packets and frames reaching pcap.
#
# SAFETY: bash trap + setsid-detached watchdog; PM knobs restored on exit.
set -u

IFACE="${IFACE:-wlp2s0}"        # override for your machine
CHANS="36 44 149 6 2"
DWELL=8
WATCHDOG_TIMEOUT=260
MT76=/sys/kernel/debug/ieee80211/phy0/mt76
OUT="${OUT_DIR:-$PWD/runs}/chansweep2-$(date +%Y%m%d-%H%M%S)"

KREL=$(uname -r)
case "$KREL" in
  6.12.97*) echo "kernel $KREL - ok" ;;
  *) echo "REFUSING: kernel is $KREL, need 6.12.97."; exit 1 ;;
esac
mkdir -p "$OUT" || exit 1
sudo -v || exit 1
sudo mountpoint -q /sys/kernel/debug || sudo mount -t debugfs none /sys/kernel/debug

RESTORE_CMDS='
  sudo sh -c "echo 1 > '"$MT76"'/runtime-pm" 2>/dev/null || true
  sudo sh -c "echo 1 > '"$MT76"'/deep-sleep" 2>/dev/null || true
  sudo ip link set '"$IFACE"' down 2>/dev/null || true
  sudo iw dev '"$IFACE"' set type managed 2>/dev/null || true
  sudo ip link set '"$IFACE"' up 2>/dev/null || true
  sudo sv up NetworkManager 2>/dev/null || true
'
setsid nohup bash -c "sleep $WATCHDOG_TIMEOUT; $RESTORE_CMDS" >/dev/null 2>&1 &
WATCHDOG_PID=$!
echo "watchdog armed (pid $WATCHDOG_PID)"

restore() {
  echo "--- restoring networking + power management ---"
  sudo pkill -x tcpdump 2>/dev/null || true
  eval "$RESTORE_CMDS"
  kill "$WATCHDOG_PID" 2>/dev/null || true
  echo "restored. logs in $OUT"
}
trap restore EXIT INT TERM

sudo sv down NetworkManager
sudo pkill -x wpa_supplicant 2>/dev/null; sudo pkill -x dhcpcd 2>/dev/null; sleep 1
sudo iw reg set NZ
sudo ip link set $IFACE down
sudo iw dev $IFACE set monitor active
sudo ip link set $IFACE up

# PM OFF FIRST, before any capture, and confirm it took
sudo sh -c "echo 0 > $MT76/runtime-pm"
sudo sh -c "echo 0 > $MT76/deep-sleep"
echo "PM: runtime-pm=$(sudo cat $MT76/runtime-pm) deep-sleep=$(sudo cat $MT76/deep-sleep)"
sleep 2

: > "$OUT/summary.txt"

for CH in $CHANS; do
  echo ""
  echo "=== requesting channel $CH ==="
  sudo iw dev $IFACE set channel $CH 2>&1 | sed 's/^/  set: /'
  sleep 1

  INFO=$(iw dev $IFACE info 2>/dev/null)
  CLAIMED=$(echo "$INFO" | grep -oP 'channel \K[0-9]+')
  CLAIMED_MHZ=$(echo "$INFO" | grep -oP 'channel [0-9]+ \(\K[0-9]+')
  echo "  iw claims: channel ${CLAIMED:-NA} (${CLAIMED_MHZ:-NA} MHz)"

  PCAP="$OUT/ch${CH}.pcap"
  sudo rm -f "$PCAP"
  # keep tcpdump's stderr - it reports "N packets dropped by kernel"
  sudo timeout $((DWELL + 3)) tcpdump -i $IFACE -w "$PCAP" -c 3000 2>"$OUT/ch${CH}.stderr" &
  TD=$!
  sleep $DWELL
  sudo pkill -x tcpdump 2>/dev/null || true
  wait $TD 2>/dev/null

  COUNT=$(sudo tcpdump -r "$PCAP" 2>/dev/null | wc -l)
  DROPS=$(grep -oP '\d+(?= packets dropped)' "$OUT/ch${CH}.stderr" 2>/dev/null | head -1)
  FREQS=$(sudo tcpdump -e -r "$PCAP" 2>/dev/null | grep -oP '\b\d{4} MHz' \
            | sort | uniq -c | sort -rn | awk '{printf "%s(%sx) ", $2, $1}')
  echo "  frames=${COUNT:-0} kernel_drops=${DROPS:-0}"
  echo "  radiotap freqs seen: ${FREQS:-none}"

  # does the dominant received frequency match what we asked for?
  DOM=$(sudo tcpdump -e -r "$PCAP" 2>/dev/null | grep -oP '\b\d{4}(?= MHz)' \
          | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')
  if [ -n "${DOM:-}" ] && [ -n "${CLAIMED_MHZ:-}" ]; then
    if [ "$DOM" = "$CLAIMED_MHZ" ]; then VERDICT="MATCH"; else VERDICT="MISMATCH (radio on $DOM, iw says $CLAIMED_MHZ)"; fi
  else
    VERDICT="no frames - inconclusive"
  fi
  echo "  --> $VERDICT"

  printf 'req_ch=%-4s iw_mhz=%-6s dominant_rx_mhz=%-6s frames=%-6s drops=%-7s %s\n' \
    "$CH" "${CLAIMED_MHZ:-NA}" "${DOM:-none}" "${COUNT:-0}" "${DROPS:-0}" "$VERDICT" >> "$OUT/summary.txt"
done

echo ""
echo "=========== SUMMARY ==========="
cat "$OUT/summary.txt"
echo "==============================="
