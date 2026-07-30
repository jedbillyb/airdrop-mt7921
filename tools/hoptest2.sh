#!/bin/bash
# AWDL hop test, take 2 - on a dedicated monitor vif with power management off.
#
# Supersedes hoptest.sh. Two mt7921 bugs had to be worked around first, both
# established on 2026-07-30 (see FINDINGS.md §8):
#
#   1. runtime-pm / deep-sleep must be DISABLED. With PM on, monitor RX delivers
#      literally zero frames - netdev rx_packets never advances - and no firmware
#      error is logged. This is what made the whole setup look broken.
#   2. The interface type must NOT be switched in place. `iw dev wlp2s0 set type
#      monitor` leaves the radio pinned at 5180 MHz forever, no matter what
#      channel is requested, while iw cheerfully reports the requested channel.
#      A dedicated vif (`iw phy phy0 interface add mon0 type monitor`) tunes
#      correctly. montest.sh proves this: in-place stays on 5180, mon0 reaches
#      5745.
#
# So OWL runs on mon0, not on wlp2s0. This is the run that can finally validate
# the follow-the-peer-channel-sequence fix (9bac866): does the peer survive past
# the ~2-3 s eviction window now that we can actually hear it hop?
#
# The iPhone/Mac must be actively advertising AWDL - open the AirDrop sheet and
# leave it open for the whole run, or the peer will not be there to find.
#
# SAFETY: bash trap + setsid-detached watchdog. Restore deletes mon0, restores
# the PM knobs, returns wlp2s0 to managed and brings NetworkManager back.
set -u

IFACE=wlp2s0
MON=mon0
CHAN=149
CHAN_MHZ=5745
DUR=60
WATCHDOG_TIMEOUT=$((DUR + 90))
MT76=/sys/kernel/debug/ieee80211/phy0/mt76
OWL=/home/jed/owl/build/daemon/owl
OUT=/mnt/shared/owl-hoptest2-$(date +%Y%m%d-%H%M%S)

# The "6.12.97 is required" rule is RELAXED as of 2026-07-30. That belief came
# from a 6.18-vs-6.12.97 comparison that we now know was confounded by the
# runtime-PM bug (FINDINGS.md §8) - the kernel may never have been the variable.
# Warn, do not refuse, so other kernels can actually be tested.
KREL=$(uname -r)
case "$KREL" in
  6.12.97*) echo "kernel $KREL - known-good" ;;
  *) echo "kernel $KREL - NOT the pinned 6.12.97. Continuing anyway;"
     echo "  if RX misbehaves, boot 6.12.97 before concluding anything." ;;
esac
[ -x "$OWL" ] || { echo "REFUSING: no binary at $OWL"; exit 1; }
mkdir -p "$OUT" || exit 1
sudo -v || exit 1
sudo mountpoint -q /sys/kernel/debug || sudo mount -t debugfs none /sys/kernel/debug

RESTORE_CMDS='
  sudo pkill -x owl 2>/dev/null || true
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
echo "watchdog armed (pid $WATCHDOG_PID, fires in ${WATCHDOG_TIMEOUT}s)"

restore() {
  echo ""
  echo "--- restoring ---"
  [ -n "${POLL_PID:-}" ] && kill "$POLL_PID" 2>/dev/null
  sudo pkill -x tcpdump 2>/dev/null || true
  eval "$RESTORE_CMDS"
  kill "$WATCHDOG_PID" 2>/dev/null || true
  echo "restored. logs in $OUT"
}
trap restore EXIT INT TERM

# --- take the card ---
sudo sv down NetworkManager
sudo pkill -x wpa_supplicant 2>/dev/null; sudo pkill -x dhcpcd 2>/dev/null; sleep 1
sudo iw reg set NZ

# --- dedicated monitor vif (bug 2 workaround) ---
sudo ip link set $IFACE down
sudo iw dev $MON del 2>/dev/null   # in case a previous run left one
# PLAIN, not `flags active` - active monitor destroys ~96% of RX on mt7921
# (activetest.sh: plain=140, active=6, plain=144 frames). See FINDINGS.md §10.
sudo iw phy phy0 interface add $MON type monitor || { echo "FAILED to create $MON"; exit 1; }
sudo ip link set $MON up

# --- power management off (bug 1 workaround) ---
sudo sh -c "echo 0 > $MT76/runtime-pm"
sudo sh -c "echo 0 > $MT76/deep-sleep"
echo "PM: runtime-pm=$(sudo cat $MT76/runtime-pm) deep-sleep=$(sudo cat $MT76/deep-sleep)"

sudo iw dev $MON set freq $CHAN_MHZ
sleep 2
echo "monitor vif state:"
iw dev $MON info 2>/dev/null | grep -E "type|channel" | sed 's/^/  /'

# --- verify we can actually hear the requested channel before spending 60s ---
echo ""
echo "preflight: 5s capture to confirm RX on $CHAN_MHZ MHz ..."
sudo timeout 8 tcpdump -i $MON -w "$OUT/preflight.pcap" -c 200 >/dev/null 2>&1 &
sleep 5; sudo pkill -x tcpdump 2>/dev/null; sleep 1
PRE=$(sudo tcpdump -r "$OUT/preflight.pcap" 2>/dev/null | wc -l)
PREFREQ=$(sudo tcpdump -e -r "$OUT/preflight.pcap" 2>/dev/null \
            | grep -oP '\b\d{4}(?= MHz)' | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')
echo "  preflight frames=$PRE dominant_freq=${PREFREQ:-none}"
if [ "${PREFREQ:-0}" != "$CHAN_MHZ" ]; then
  echo "  WARNING: not tuned to $CHAN_MHZ (got ${PREFREQ:-none}). Continuing anyway,"
  echo "           but a null result will be inconclusive."
fi

# --- stream 2: radio truth, 20 Hz, independent of OWL ---
( while :; do
    printf '%s %s\n' "$(date +%s.%N)" \
      "$(iw dev $MON info 2>/dev/null | grep -oP 'channel \K[0-9]+' || echo NA)"
    sleep 0.05
  done ) > "$OUT/radio.log" &
POLL_PID=$!

# --- stream 3: independent capture of AWDL frames, for ground truth ---
sudo timeout $((DUR + 5)) tcpdump -i $MON -w "$OUT/awdl.pcap" >/dev/null 2>&1 &

# --- stream 1: OWL on the monitor vif, timestamped on the same clock ---
# -N = do not try to put the device in monitor mode. mon0 is ALREADY a monitor
# vif and is up, so OWL's own nl80211 set-type call fails with EBUSY ("Object
# busy") and init aborts. -N skips that step. Without it OWL never starts.
sudo stdbuf -oL "$OWL" -i $MON -c $CHAN -N -vv 2>&1 \
  | python3 -u -c 'import sys,time
for l in sys.stdin: sys.stdout.write("%.6f %s" % (time.time(), l))' > "$OUT/owl.log" &

echo ""
echo "running ${DUR}s of OWL on $MON (channel $CHAN) -> $OUT"
echo "keep the AirDrop sheet open on the phone for the whole run"
sleep $DUR

# --- results ---
echo ""
echo "=========== RESULT ==========="
RXFRAMES=$(sudo tcpdump -r "$OUT/awdl.pcap" 2>/dev/null | wc -l)
FREQS=$(sudo tcpdump -e -r "$OUT/awdl.pcap" 2>/dev/null | grep -oP '\b\d{4} MHz' \
          | sort | uniq -c | sort -rn | head -5 | awk '{printf "%s(%sx) ", $2, $1}')
echo "  frames captured on $MON : $RXFRAMES"
echo "  radiotap freqs          : ${FREQS:-none}"
echo "  channels the radio visited (from radio.log):"
awk '{print $2}' "$OUT/radio.log" | sort | uniq -c | sort -rn | sed 's/^/    /'
echo ""
echo "  OWL peer / election events:"
if grep -qE "add peer|remove peer|changed channel sequence|election tree" "$OUT/owl.log"; then
  grep -E "add peer|remove peer|changed channel sequence|election tree" "$OUT/owl.log" \
    | sed 's/^/    /'
  echo ""
  ADDS=$(grep -c "add peer" "$OUT/owl.log")
  REMS=$(grep -c "remove peer" "$OUT/owl.log")
  echo "    add peer x$ADDS, remove peer x$REMS"
  echo ""
  echo "  Peer lifetime (the 9bac866 question - did it survive past ~3s?):"
  python3 - "$OUT/owl.log" << 'PY'
import sys, re
stamps, adds, rems = [], [], []
for line in open(sys.argv[1], errors='replace'):
    m = re.match(r'(\d+\.\d+)', line)
    if not m: continue
    t = float(m.group(1))
    stamps.append(t)
    if 'add peer' in line: adds.append(t)
    elif 'remove peer' in line: rems.append(t)
if not adds:
    print("    no peer ever added")
else:
    last = max(stamps)
    for i, a in enumerate(adds):
        later = [r for r in rems if r > a]
        if later:
            print("    peer %d: held %.2f s (then evicted)" % (i + 1, later[0] - a))
        else:
            print("    peer %d: held >= %.2f s, STILL HELD when the run ended"
                  % (i + 1, last - a))
    print("    (old behaviour was eviction at ~2-3 s - anything well past that is the fix working)")
PY
else
  echo "    NONE - no peer discovered"
  echo "    If preflight frames were 0, this is an RX problem, not an OWL problem."
  echo "    If frames > 0 but no peer, the phone was probably not advertising -"
  echo "    reopen the AirDrop sheet and re-run."
fi
echo "=============================="
