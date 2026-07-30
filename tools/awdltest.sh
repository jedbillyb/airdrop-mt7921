#!/bin/bash
# Can active monitor hear AWDL at all? Back-to-back plain vs active on 5180 MHz.
#
# This is THE decisive question for AirDrop on the built-in MT7921:
#
#   plain  retunes and hears well, but never ACKs -> one-way path, no transfer
#   active ACKs (so transfer is possible in principle) but is pinned to 5180 MHz
#          and loses ~81% of reception (activetest2.sh: 186 -> 35 frames)
#
# 81% loss might still be enough to hear an iPhone's AWDL action frames, or it
# might not. If active monitor cannot receive AWDL frames, it cannot sync, and
# then no amount of ACK capability helps - AirDrop is genuinely unreachable on
# this chip. If it CAN hear them, `ACTIVE=1 ./airdrop.sh` should work.
#
# Both phases run on 5180 MHz (the only frequency active monitor can reach) and
# back-to-back, so the phone's behaviour is roughly constant across them. The
# actual radiotap frequency is verified in both - the mistake that invalidated
# activetest.sh was comparing counts from different channels.
#
# THE PHONE MUST BE ADVERTISING for this to mean anything:
#   unlock it, screen on, AirDrop > "Everyone for 10 Minutes", share sheet open.
# If plain sees 0 AWDL frames the phone was silent and the run is void - it is
# reported as such rather than being read as a result.
#
# SAFETY: bash trap + setsid-detached watchdog.
set -u

IFACE="${IFACE:-wlp2s0}"        # override for your machine
MON=mon0
MHZ=5180
DWELL=20              # AWDL action frames are sparser than beacons - dwell longer
WATCHDOG_TIMEOUT=300
MT76=/sys/kernel/debug/ieee80211/phy0/mt76
AWDL_BSSID="00:25:00:ff:94:73"
OUT="${OUT_DIR:-$PWD/runs}/awdltest-$(date +%Y%m%d-%H%M%S)"

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
  echo "restored. logs in $OUT"
}
trap 'restore; exit 130' INT TERM
trap restore EXIT

sudo sv down NetworkManager
sudo pkill -x wpa_supplicant 2>/dev/null; sudo pkill -x dhcpcd 2>/dev/null; sleep 1
sudo iw reg set NZ

# $1 = label, $2 = plain|active  -> sets ALL_N, AWDL_N, DOM
probe() {
  local LABEL="$1" KIND="$2" PCAP="$OUT/$1.pcap" RC
  sudo ip link set $MON down 2>/dev/null
  sudo iw dev $MON del 2>/dev/null
  sudo ip link set $IFACE down
  if [ "$KIND" = "active" ]; then
    sudo iw phy phy0 interface add $MON type monitor flags active 2>/dev/null; RC=$?
  else
    sudo iw phy phy0 interface add $MON type monitor 2>/dev/null; RC=$?
  fi
  [ "$RC" != "0" ] && { echo "  CREATE FAILED"; ALL_N=0; AWDL_N=0; DOM=none; return; }
  sudo ip link set $MON up
  sudo sh -c "echo 0 > $MT76/runtime-pm"
  sudo sh -c "echo 0 > $MT76/deep-sleep"
  sudo iw dev $MON set freq $MHZ 2>/dev/null
  sleep 2
  sudo rm -f "$PCAP"
  sudo timeout $((DWELL + 4)) tcpdump -i $MON -w "$PCAP" >/dev/null 2>&1 &
  local TD=$!
  sleep $DWELL
  sudo pkill -x tcpdump 2>/dev/null || true
  wait $TD 2>/dev/null
  ALL_N=$(sudo tcpdump -r "$PCAP" 2>/dev/null | wc -l)
  AWDL_N=$(sudo tcpdump -r "$PCAP" "wlan addr3 $AWDL_BSSID" 2>/dev/null | wc -l)
  DOM=$(sudo tcpdump -e -r "$PCAP" 2>/dev/null | grep -oP '\b\d{4}(?= MHz)' \
          | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')
  echo "  actual_freq=${DOM:-none}  all_frames=${ALL_N:-0}  AWDL_frames=${AWDL_N:-0}"
}

echo ""
echo "=== phase 1: PLAIN monitor on $MHZ (${DWELL}s) ==="
probe "plain" plain
P_ALL=$ALL_N; P_AWDL=$AWDL_N; P_DOM=$DOM

echo ""
echo "=== phase 2: ACTIVE monitor on $MHZ (${DWELL}s) ==="
probe "active" active
A_ALL=$ALL_N; A_AWDL=$AWDL_N; A_DOM=$DOM

echo ""
echo "=========== RESULT ==========="
printf '  plain : freq=%-6s all=%-6s AWDL=%s\n' "${P_DOM:-none}" "$P_ALL" "$P_AWDL"
printf '  active: freq=%-6s all=%-6s AWDL=%s\n' "${A_DOM:-none}" "$A_ALL" "$A_AWDL"
echo ""
if [ "${P_DOM:-x}" != "${A_DOM:-y}" ]; then
  echo "  INVALID: the two phases were on different frequencies"
  echo "  ($P_DOM vs $A_DOM). Counts are not comparable - do not draw conclusions."
elif [ "${P_AWDL:-0}" -eq 0 ]; then
  echo "  VOID: plain monitor saw no AWDL frames either, so the phone was not"
  echo "  advertising on ch36 during this run. Re-arm AirDrop and repeat."
elif [ "${A_AWDL:-0}" -gt 0 ]; then
  echo "  *** ACTIVE MONITOR CAN HEAR AWDL ($A_AWDL frames) ***"
  echo "  So ACKs and sync are both possible -> try: ACTIVE=1 ./airdrop.sh"
  echo "  AirDrop on the built-in MT7921 is NOT ruled out."
else
  echo "  ACTIVE MONITOR HEARS NO AWDL ($P_AWDL frames under plain, 0 under active)."
  echo "  Reception loss is severe enough to prevent sync, so ACK capability is"
  echo "  useless: cannot discover the peer in the mode that could talk to it."
  echo "  THAT is the real dead end for AirDrop on this chip - and unlike the"
  echo "  earlier claim, this comparison is same-frequency and back-to-back."
fi
echo "=============================="
