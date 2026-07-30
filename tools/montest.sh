#!/bin/bash
# How do we get the mt7921 to actually tune where we ask, in monitor mode?
#
# Established so far: with PM off, RX works but only as a trickle, and the radio
# stays pinned at 5180 MHz regardless of the requested channel (chansweep2.sh).
# Two candidate explanations, tested here against target channel 149 (5745 MHz):
#
#   Q1. Is only the FIRST channel set honoured, with later ones ignored?
#       -> ask for 149 as the very first thing after entering monitor mode.
#   Q2. Is the in-place type switch (set type monitor on wlp2s0) the problem?
#       -> compare against a dedicated monitor vif added with
#          `iw phy phy0 interface add mon0 type monitor`, which is the more
#          conventional path and engages a fresh vif in the driver.
#   Q3. Does `set freq` behave differently from `set channel`, and does an
#       explicit width help?
#   Q4. Does a link down/up bounce after setting the channel make it apply?
#
# SAFETY: bash trap + setsid-detached watchdog. Restore also deletes mon0 and
# puts the PM knobs back.
set -u

IFACE="${IFACE:-wlp2s0}"        # override for your machine
MON=mon0
DWELL=8
WATCHDOG_TIMEOUT=320
MT76=/sys/kernel/debug/ieee80211/phy0/mt76
TARGET_MHZ=5745
OUT="${OUT_DIR:-$PWD/runs}/montest-$(date +%Y%m%d-%H%M%S)"

KREL=$(uname -r)
case "$KREL" in 6.12.97*) echo "kernel $KREL - ok" ;; *) echo "REFUSING: kernel $KREL"; exit 1 ;; esac
mkdir -p "$OUT" || exit 1
sudo -v || exit 1
sudo mountpoint -q /sys/kernel/debug || sudo mount -t debugfs none /sys/kernel/debug

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
echo "watchdog armed (pid $WATCHDOG_PID)"
restore() {
  echo "--- restoring ---"
  sudo pkill -x tcpdump 2>/dev/null || true
  eval "$RESTORE_CMDS"
  kill "$WATCHDOG_PID" 2>/dev/null || true
  echo "restored. logs in $OUT"
}
trap restore EXIT INT TERM

pm_off() {
  sudo sh -c "echo 0 > $MT76/runtime-pm" 2>/dev/null
  sudo sh -c "echo 0 > $MT76/deep-sleep" 2>/dev/null
}

# $1 = label, $2 = interface to capture on
probe() {
  local LABEL="$1" DEV="$2" PCAP="$OUT/$1.pcap" INFO CLAIMED_MHZ COUNT FREQS DOM VERDICT
  INFO=$(iw dev "$DEV" info 2>/dev/null)
  CLAIMED_MHZ=$(echo "$INFO" | grep -oP 'channel [0-9]+ \(\K[0-9]+')
  sudo rm -f "$PCAP"
  sudo timeout $((DWELL + 3)) tcpdump -i "$DEV" -w "$PCAP" -c 3000 >/dev/null 2>&1 &
  local TD=$!
  sleep $DWELL
  sudo pkill -x tcpdump 2>/dev/null || true
  wait $TD 2>/dev/null
  COUNT=$(sudo tcpdump -r "$PCAP" 2>/dev/null | wc -l)
  FREQS=$(sudo tcpdump -e -r "$PCAP" 2>/dev/null | grep -oP '\b\d{4} MHz' \
            | sort | uniq -c | sort -rn | awk '{printf "%s(%sx) ", $2, $1}')
  DOM=$(sudo tcpdump -e -r "$PCAP" 2>/dev/null | grep -oP '\b\d{4}(?= MHz)' \
          | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')
  if [ -z "${DOM:-}" ]; then VERDICT="no frames"
  elif [ "$DOM" = "$TARGET_MHZ" ]; then VERDICT="*** SUCCESS: tuned to $TARGET_MHZ ***"
  else VERDICT="stuck on $DOM"; fi
  echo "  iw_mhz=${CLAIMED_MHZ:-NA} frames=${COUNT:-0} freqs=${FREQS:-none}"
  echo "  --> $VERDICT"
  printf '%-26s iw_mhz=%-6s dom_rx=%-6s frames=%-6s %s\n' \
    "$LABEL" "${CLAIMED_MHZ:-NA}" "${DOM:-none}" "${COUNT:-0}" "$VERDICT" >> "$OUT/summary.txt"
}

: > "$OUT/summary.txt"
sudo sv down NetworkManager
sudo pkill -x wpa_supplicant 2>/dev/null; sudo pkill -x dhcpcd 2>/dev/null; sleep 1
sudo iw reg set NZ

echo ""
echo "=== Q1: in-place monitor, ask for 149 as the FIRST channel set ==="
sudo ip link set $IFACE down
sudo iw dev $IFACE set monitor active
sudo ip link set $IFACE up
pm_off; sleep 2
sudo iw dev $IFACE set channel 149 2>&1 | sed 's/^/  set: /'
sleep 1
probe "Q1_inplace_first_149" $IFACE

echo ""
echo "=== Q3: set freq 5745 explicitly (different nl80211 path) ==="
sudo iw dev $IFACE set freq $TARGET_MHZ 2>&1 | sed 's/^/  set: /'
sleep 1
probe "Q3_set_freq" $IFACE

echo ""
echo "=== Q3b: set freq 5745 HT20 (explicit width) ==="
sudo iw dev $IFACE set freq $TARGET_MHZ HT20 2>&1 | sed 's/^/  set: /'
sleep 1
probe "Q3b_set_freq_HT20" $IFACE

echo ""
echo "=== Q4: set channel then bounce link down/up ==="
sudo iw dev $IFACE set channel 149 2>/dev/null
sudo ip link set $IFACE down; sleep 1; sudo ip link set $IFACE up
pm_off; sleep 2
probe "Q4_bounce_after_set" $IFACE

echo ""
echo "=== Q2: dedicated mon0 vif (conventional path) ==="
sudo ip link set $IFACE down
sudo iw dev $IFACE set type managed 2>/dev/null
sudo iw phy phy0 interface add $MON type monitor 2>&1 | sed 's/^/  add: /'
if iw dev $MON info >/dev/null 2>&1; then
  sudo ip link set $MON up
  pm_off; sleep 2
  sudo iw dev $MON set freq $TARGET_MHZ 2>&1 | sed 's/^/  set: /'
  sleep 1
  probe "Q2_mon0_vif" $MON
else
  echo "  mon0 could not be created - monitor absent from interface combinations"
  echo "Q2_mon0_vif                 CREATION FAILED" >> "$OUT/summary.txt"
fi

echo ""
echo "=========== SUMMARY ==========="
cat "$OUT/summary.txt"
echo "==============================="
