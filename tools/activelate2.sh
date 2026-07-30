#!/bin/bash
# Can an active monitor vif INHERIT a channel that was set before it existed?
#
# Follow-up to activelate.sh. That script showed active mode always lands on
# 5180 - but its phase D was void: `iw dev mon0 set freq` on a DOWN vif fails
# with EBUSY (-16), so D never actually requested a channel. Only phases B and C
# (tune while up) were real, and both were pinned.
#
# Mechanism this tests. mt7921 implements chanctx ops (mt7921/main.c:1394), so
# mac80211 runs the chanctx path in ieee80211_set_monitor_channel(), which
# retunes `local->monitor_sdata` - the VIRTUAL monitor. A vif created with
# `flags active` is a real driver vif, not the virtual monitor, so it keeps
# whatever chanctx it was assigned when it came up, and the default is the first
# 5 GHz channel: 5180. cfg80211 still records the request, which is why `iw`
# reports the channel we asked for while the frames say 5180.
#
# If that is the mechanism, the channel has to be in place BEFORE the active vif
# opens, because there is no way to move it afterwards:
#
#   E  plain vif, tune it, DELETE it, then create the active vif and never
#      tune it - does it come up on the remembered channel?
#   F  plain vif, tune it, and add the active vif ALONGSIDE it - does the
#      existing chanctx get shared? (Monitor appears in no valid interface
#      combination on this phy, so this may simply be refused - that is a
#      result too, and it is recorded rather than treated as failure.)
#
# Baseline A is repeated so every number here is same-run and same-frequency.
#
# SAFETY: bash trap + setsid-detached watchdog.
set -u

IFACE="${IFACE:-wlp2s0}"        # override for your machine
MON=mon0
MON2=mon1
DWELL=15
WATCHDOG_TIMEOUT=420
MT76=/sys/kernel/debug/ieee80211/phy0/mt76
STUCK_MHZ=5180
OUT="${OUT_DIR:-$PWD/runs}/activelate2-$(date +%Y%m%d-%H%M%S)"

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

echo "scanning for the busiest 2.4 GHz channel..."
sudo ip link set $IFACE up 2>/dev/null
MHZ=$(sudo iw dev $IFACE scan 2>/dev/null | grep -oP '(?<=^\tfreq: )2\d{3}' \
        | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')
MHZ=${MHZ:-2437}
echo "target frequency: $MHZ MHz"

sudo sv down NetworkManager
sudo pkill -x wpa_supplicant 2>/dev/null; sudo pkill -x dhcpcd 2>/dev/null; sleep 1
sudo iw reg set NZ

pm_off() {
  sudo sh -c "echo 0 > $MT76/runtime-pm"
  sudo sh -c "echo 0 > $MT76/deep-sleep"
}

# capture on $1 for DWELL, label $2 -> ALL_N, DOM, STUCK_N
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
  STUCK_N=$(sudo tcpdump -e -r "$PCAP" 2>/dev/null | grep -c "$STUCK_MHZ MHz")
  printf '  actual_freq=%-6s frames=%-6s at_5180=%s\n' "${DOM:-none}" "${ALL_N:-0}" "${STUCK_N:-0}"
}

wipe() {
  sudo ip link set $MON2 down 2>/dev/null; sudo iw dev $MON2 del 2>/dev/null
  sudo ip link set $MON  down 2>/dev/null; sudo iw dev $MON  del 2>/dev/null
  sudo ip link set $IFACE down
  sleep 1
}

# --- A: baseline -------------------------------------------------------------
echo ""
echo "=== A: plain monitor, tuned while up (baseline) ==="
wipe
sudo iw phy phy0 interface add $MON type monitor 2>/dev/null
sudo ip link set $MON up; pm_off
sudo iw dev $MON set freq $MHZ || echo "  SET FREQ FAILED"
sleep 2; capture $MON "A_plain"; A_DOM=$DOM; A_ALL=$ALL_N

# --- E: tune, delete the vif, then create the active one ---------------------
echo ""
echo "=== E: plain tuned -> deleted -> active vif created, never tuned ==="
wipe
sudo iw phy phy0 interface add $MON type monitor 2>/dev/null
sudo ip link set $MON up; pm_off
sudo iw dev $MON set freq $MHZ || echo "  SET FREQ FAILED"
sleep 2
sudo ip link set $MON down; sudo iw dev $MON del
sudo iw phy phy0 interface add $MON type monitor flags active 2>"$OUT/E.err" \
  && E_ACT=yes || { E_ACT=no; echo "  ACTIVE CREATE FAILED: $(cat "$OUT/E.err")"; }
sudo ip link set $MON up; pm_off
sleep 2
echo "  iw says: $(sudo iw dev $MON info 2>/dev/null | grep -oP 'channel \d+ \(\d+' | head -1)"
capture $MON "E_inherit"; E_DOM=$DOM; E_ALL=$ALL_N

# --- F: active vif added alongside a tuned plain vif -------------------------
echo ""
echo "=== F: active vif added ALONGSIDE a tuned plain vif ==="
wipe
sudo iw phy phy0 interface add $MON type monitor 2>/dev/null
sudo ip link set $MON up; pm_off
sudo iw dev $MON set freq $MHZ || echo "  SET FREQ FAILED"
sleep 2
if sudo iw phy phy0 interface add $MON2 type monitor flags active 2>"$OUT/F.err"; then
  F_ACT=yes
  if sudo ip link set $MON2 up 2>>"$OUT/F.err"; then
    pm_off; sleep 2
    capture $MON2 "F_alongside"; F_DOM=$DOM; F_ALL=$ALL_N
  else
    echo "  ACTIVE VIF WOULD NOT COME UP: $(cat "$OUT/F.err")"
    F_DOM=none; F_ALL=0; F_ACT=no
  fi
else
  echo "  REFUSED: $(cat "$OUT/F.err")"
  F_DOM=none; F_ALL=0; F_ACT=no
fi

echo ""
echo "=========== RESULT (target $MHZ MHz) ==========="
printf '  A plain baseline    : freq=%-6s frames=%s\n'                   "${A_DOM:-none}" "$A_ALL"
printf '  E active inherits   : freq=%-6s frames=%-6s created=%s\n'      "${E_DOM:-none}" "$E_ALL" "${E_ACT:-no}"
printf '  F active alongside  : freq=%-6s frames=%-6s created=%s\n'      "${F_DOM:-none}" "$F_ALL" "${F_ACT:-no}"
echo ""
if [ "${A_DOM:-x}" != "$MHZ" ]; then
  echo "  VOID: baseline did not land on $MHZ (got ${A_DOM:-nothing}). Nothing else means anything."
else
  for P in E F; do
    eval "F_F=\$${P}_DOM; F_A=\$${P}_ACT; F_N=\$${P}_ALL"
    if [ "$F_A" != "yes" ]; then
      echo "  $P: the active vif could not be brought up at all - path unavailable."
    elif [ "${F_F:-x}" = "$MHZ" ]; then
      echo "  *** $P: ACTIVE MONITOR ON $MHZ MHz ($F_N frames) ***"
      echo "  Active mode and an arbitrary channel CAN coexist. This is the setup"
      echo "  airdrop.sh must use, and AirDrop on the MT7921 is back on the table."
    elif [ "${F_F:-x}" = "$STUCK_MHZ" ]; then
      echo "  $P: pinned at $STUCK_MHZ - the channel is not inherited either."
    else
      echo "  $P: no usable frames (${F_N}); inconclusive, not a pass."
    fi
  done
fi
echo "==============================================="
