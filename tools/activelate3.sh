#!/bin/bash
# Does the active monitor vif FOLLOW when the plain vif it rides on is retuned?
#
# activelate2.sh phase F found the way out of the 5180 pin: an active monitor
# vif created alongside a plain vif that already owns the channel comes up on
# that channel, at full reception (710 frames vs 667 for plain alone).
#
# That is only half of what AirDrop needs. OWL must follow the phone's channel
# sequence, so the pair has to be retunable mid-run. Two ways that could go:
#
#   the vifs share one channel context -> retuning the plain vif moves both,
#     and OWL gets ACKs and hopping at once. AirDrop is reachable.
#   the active vif holds its own context -> it stays put while the plain vif
#     moves, so ACKs only work on the channel it happened to open on.
#
# Both frequencies are picked from a scan (the two busiest 2.4 GHz channels) so
# there is always traffic to read a radiotap frequency from, and every phase is
# verified by that frequency rather than by what `iw` claims.
#
# SAFETY: bash trap + setsid-detached watchdog.
set -u

IFACE="${IFACE:-wlp2s0}"        # override for your machine
MON=mon0
MON2=mon1
DWELL=15
WATCHDOG_TIMEOUT=420
MT76=/sys/kernel/debug/ieee80211/phy0/mt76
OUT="${OUT_DIR:-$PWD/runs}/activelate3-$(date +%Y%m%d-%H%M%S)"

mkdir -p "$OUT" || exit 1
sudo -v || exit 1
sudo mountpoint -q /sys/kernel/debug || sudo mount -t debugfs none /sys/kernel/debug
echo "kernel: $(uname -r)"

RESTORE_CMDS='
  sudo ip link set '"$MON2"' down 2>/dev/null || true
  sudo iw dev '"$MON2"' del 2>/dev/null || true
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
  echo "restored. logs in $OUT"
}
trap 'restore; exit 130' INT TERM
trap restore EXIT

echo "scanning for the two busiest 2.4 GHz channels..."
sudo ip link set $IFACE up 2>/dev/null
mapfile -t FREQS < <(sudo iw dev $IFACE scan 2>/dev/null \
  | grep -oP '(?<=^\tfreq: )2\d{3}' | sort | uniq -c | sort -rn | awk '{print $2}')
MHZ1=${FREQS[0]:-2437}
MHZ2=${FREQS[1]:-2412}
[ "$MHZ1" = "$MHZ2" ] && MHZ2=2412
echo "frequencies: $MHZ1 -> $MHZ2"

sudo sv down NetworkManager
sudo pkill -x wpa_supplicant 2>/dev/null; sudo pkill -x dhcpcd 2>/dev/null; sleep 1
sudo iw reg set NZ

pm_off() {
  sudo sh -c "echo 0 > $MT76/runtime-pm"
  sudo sh -c "echo 0 > $MT76/deep-sleep"
}

capture() {
  local DEV="$1" PCAP="$OUT/$2.pcap"
  sudo rm -f "$PCAP"
  sudo timeout $((DWELL + 4)) tcpdump -i "$DEV" -w "$PCAP" >/dev/null 2>&1 &
  local TD=$!
  sleep $DWELL
  sudo pkill -x tcpdump 2>/dev/null || true
  wait $TD 2>/dev/null
  ALL_N=$(sudo tcpdump -r "$PCAP" 2>/dev/null | wc -l)
  DOM=$(sudo tcpdump -e -r "$PCAP" 2>/dev/null | grep -oP '\b\d{4}(?= MHz)' \
          | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')
  printf '  actual_freq=%-6s frames=%s\n' "${DOM:-none}" "${ALL_N:-0}"
}

# --- build the pair ----------------------------------------------------------
sudo ip link set $MON2 down 2>/dev/null; sudo iw dev $MON2 del 2>/dev/null
sudo ip link set $MON  down 2>/dev/null; sudo iw dev $MON  del 2>/dev/null
sudo ip link set $IFACE down
sleep 1

sudo iw phy phy0 interface add $MON type monitor 2>/dev/null || { echo "plain vif failed"; exit 1; }
sudo ip link set $MON up; pm_off
sudo iw dev $MON set freq $MHZ1 || { echo "initial tune failed"; exit 1; }
sudo iw phy phy0 interface add $MON2 type monitor flags active 2>"$OUT/add.err" \
  || { echo "active vif refused: $(cat "$OUT/add.err")"; exit 1; }
sudo ip link set $MON2 up || { echo "active vif would not come up"; exit 1; }
pm_off; sleep 2

echo ""
echo "=== 1: pair on $MHZ1, capturing on the ACTIVE vif ==="
capture $MON2 "1_active_at_${MHZ1}"; P1_DOM=$DOM; P1_ALL=$ALL_N

echo ""
echo "=== 2: retune the PLAIN vif to $MHZ2, still capturing on the ACTIVE vif ==="
sudo iw dev $MON set freq $MHZ2 2>"$OUT/retune.err" \
  || echo "  RETUNE REFUSED: $(cat "$OUT/retune.err")"
sleep 2
echo "  iw says mon0: $(sudo iw dev $MON info 2>/dev/null | grep -oP 'channel \d+ \(\d+' | head -1)"
echo "  iw says mon1: $(sudo iw dev $MON2 info 2>/dev/null | grep -oP 'channel \d+ \(\d+' | head -1)"
capture $MON2 "2_active_after_retune"; P2_DOM=$DOM; P2_ALL=$ALL_N

echo ""
echo "=== 3: and back to $MHZ1, to rule out a one-way drift ==="
sudo iw dev $MON set freq $MHZ1 2>/dev/null
sleep 2
capture $MON2 "3_active_back"; P3_DOM=$DOM; P3_ALL=$ALL_N

echo ""
echo "=== 4: steer from the ACTIVE vif itself - does OWL need patching? ==="
# OWL retunes its own interface. If that works on mon1, OWL can just be pointed
# at mon1 unchanged; if it silently no-ops, OWL has to be taught to steer mon0.
sudo iw dev $MON2 set freq $MHZ2 2>"$OUT/steer.err" \
  || echo "  REFUSED: $(cat "$OUT/steer.err")"
sleep 2
capture $MON2 "4_steer_from_active"; P4_DOM=$DOM; P4_ALL=$ALL_N

echo ""
echo "=========== RESULT ==========="
printf '  1 pair tuned to %-5s : active vif on %-6s (%s frames)\n' "$MHZ1" "${P1_DOM:-none}" "$P1_ALL"
printf '  2 plain moved to %-5s: active vif on %-6s (%s frames)\n' "$MHZ2" "${P2_DOM:-none}" "$P2_ALL"
printf '  3 plain back to %-5s : active vif on %-6s (%s frames)\n' "$MHZ1" "${P3_DOM:-none}" "$P3_ALL"
printf '  4 steered via mon1 to %-5s: active vif on %-6s (%s frames)\n' "$MHZ2" "${P4_DOM:-none}" "$P4_ALL"
echo ""
if [ "${P4_DOM:-x}" = "$MHZ2" ]; then
  echo "  Steering from the active vif WORKS - point OWL at mon1 (with -N) as is."
else
  echo "  Steering from the active vif does not take (landed on ${P4_DOM:-nothing})."
  echo "  OWL must be taught to retune the plain vif instead of its own."
fi
echo ""
if [ "${P1_DOM:-x}" != "$MHZ1" ]; then
  echo "  VOID: the pair did not start on $MHZ1. Nothing below is interpretable."
elif [ "${P2_DOM:-x}" = "$MHZ2" ] && [ "${P3_DOM:-x}" = "$MHZ1" ]; then
  echo "  *** THE ACTIVE VIF FOLLOWS THE PLAIN ONE, BOTH WAYS ***"
  echo "  One shared channel context: retuning mon0 moves mon1 too. OWL can hop"
  echo "  AND keep active mode, which is everything AirDrop needs from the radio."
elif [ "${P2_DOM:-x}" = "$MHZ1" ]; then
  echo "  The active vif STAYED on $MHZ1 while the plain vif moved: separate"
  echo "  contexts. ACKs are then only available on the channel mon1 opened on,"
  echo "  so a hopping AirDrop session is still out - but a fixed-channel one is"
  echo "  not, if the phone can be met on that channel."
else
  echo "  Unclear (${P2_DOM:-none}/${P3_DOM:-none}); re-run before concluding."
fi
echo "=============================="
