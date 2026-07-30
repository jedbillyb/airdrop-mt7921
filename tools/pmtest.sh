#!/bin/bash
# Is mt7921 runtime power management the reason monitor RX delivers nothing?
#
# Hypothesis. mt7921 is aggressively power managed: runtime-pm=1, deep-sleep=1,
# and runtime_pm_stats showed the chip dozing ~2x longer than it was awake. In
# managed mode the association keeps it awake. In monitor mode there is no
# association, nothing keeps it awake, so it dozes and delivers no frames - with
# no firmware error, which is exactly the silent failure we see.
#
# Phase A: monitor mode, PM left ON  (control - expect 0 frames)
# Phase B: same session, PM turned OFF (expect frames if the hypothesis holds)
# Phase C: PM back ON again           (expect 0 again - proves it is causal,
#                                      not just "it warmed up")
#
# Parked on 2.4 GHz where the AP is, so traffic is guaranteed to exist.
#
# SAFETY: bash trap + setsid-detached watchdog that restores networking even on
# kill -9 or hang. PM knobs are restored to their original values on exit.
set -u

IFACE="${IFACE:-wlp2s0}"        # override for your machine
DWELL=10
WATCHDOG_TIMEOUT=200
MT76=/sys/kernel/debug/ieee80211/phy0/mt76
OUT="${OUT_DIR:-$PWD/runs}/pmtest-$(date +%Y%m%d-%H%M%S)"

KREL=$(uname -r)
case "$KREL" in
  6.12.97*) echo "kernel $KREL - ok" ;;
  *) echo "REFUSING: kernel is $KREL, need 6.12.97."; exit 1 ;;
esac
command -v tcpdump >/dev/null || { echo "REFUSING: no tcpdump"; exit 1; }
mkdir -p "$OUT" || exit 1
sudo -v || exit 1

sudo mountpoint -q /sys/kernel/debug || sudo mount -t debugfs none /sys/kernel/debug
sudo test -f "$MT76/runtime-pm" || { echo "REFUSING: no $MT76/runtime-pm"; exit 1; }

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

set_pm() {  # $1 = 0 (off) or 1 (on)
  sudo sh -c "echo $1 > $MT76/runtime-pm" 2>/dev/null
  sudo sh -c "echo $1 > $MT76/deep-sleep" 2>/dev/null
  printf '  runtime-pm=%s deep-sleep=%s\n' \
    "$(sudo cat $MT76/runtime-pm 2>/dev/null)" "$(sudo cat $MT76/deep-sleep 2>/dev/null)"
}

netdev_rx() { awk -v i="$IFACE:" '$1==i {print $2}' /proc/net/dev; }

capture() {  # $1 = label
  local LABEL="$1" PCAP="$OUT/$1.pcap" RX0 RX1 COUNT FREQS BEACONS
  RX0=$(netdev_rx)
  sudo rm -f "$PCAP"
  sudo timeout $((DWELL + 3)) tcpdump -i $IFACE -w "$PCAP" -c 2000 >/dev/null 2>&1 &
  local TD=$!
  sleep $DWELL
  sudo pkill -x tcpdump 2>/dev/null || true
  wait $TD 2>/dev/null
  RX1=$(netdev_rx)
  COUNT=$(sudo tcpdump -r "$PCAP" 2>/dev/null | wc -l)
  BEACONS=$(sudo tcpdump -r "$PCAP" 2>/dev/null | grep -ci beacon)
  FREQS=$(sudo tcpdump -e -r "$PCAP" 2>/dev/null | grep -oP '\b\d{4} MHz' \
            | sort | uniq -c | sort -rn | awk '{printf "%s(%sx) ", $2, $1}')
  echo "  netdev rx delta: $((RX1 - RX0))   pcap frames: ${COUNT:-0}   beacons: ${BEACONS:-0}"
  echo "  freqs seen: ${FREQS:-none}"
  printf '%-22s netdev_delta=%-7s pcap=%-6s beacons=%-6s freqs=%s\n' \
    "$LABEL" "$((RX1 - RX0))" "${COUNT:-0}" "${BEACONS:-0}" "${FREQS:-none}" >> "$OUT/summary.txt"
}

: > "$OUT/summary.txt"
echo "original: runtime-pm=$(sudo cat $MT76/runtime-pm) deep-sleep=$(sudo cat $MT76/deep-sleep)"

sudo sv down NetworkManager
sudo pkill -x wpa_supplicant 2>/dev/null; sudo pkill -x dhcpcd 2>/dev/null; sleep 1
sudo iw reg set NZ
sudo ip link set $IFACE down
sudo iw dev $IFACE set monitor active
sudo ip link set $IFACE up
sudo iw dev $IFACE set channel 2 2>/dev/null
iw dev $IFACE info 2>/dev/null | grep -E "type|channel" | sed 's/^/  /'

echo ""
echo "=== PHASE A: PM ON (control) ==="
set_pm 1
capture "A_pm_on"

echo ""
echo "=== PHASE B: PM OFF ==="
set_pm 0
capture "B_pm_off"

echo ""
echo "=== PHASE C: PM ON again ==="
set_pm 1
capture "C_pm_on_again"

echo ""
echo "=========== SUMMARY ==========="
cat "$OUT/summary.txt"
echo "==============================="
echo ""
echo "  A=0, B>0, C=0  -> runtime PM is the cause. Disable it for every OWL run."
echo "  A=0, B=0       -> PM is innocent; look elsewhere."
