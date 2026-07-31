#!/bin/bash
# How long does a channel switch cost the event loop, and how often does each
# strategy fire one?
#
# Two questions, one short run per strategy, no phone required:
#
#   1. set_channel() used to end in a synchronous nl_recvmsgs_default() called
#      from inside the libev loop - measured mean 8.5 ms over 734 switches,
#      about 30% of loop time at 3.5 switches/s against a 16 TU (16.4 ms)
#      availability window. It now sends and returns, with the reply collected
#      by an ev_io watcher. OWL logs the cost either way, so the fix is
#      checkable directly: the "queued in N us" line should read microseconds,
#      not milliseconds.
#
#   2. How many switches each -S strategy actually performs. PIN should settle
#      to a single switch at startup and then none at all, because it sits on
#      one channel in all 16 slots (FINDINGS §21).
#
# Neither question needs an iPhone, only some Apple device in earshot
# advertising a channel sequence - without a peer OWL keeps its own static
# sequence and never switches, and the run is reported as inconclusive rather
# than as a pass.
#
# SAFETY: bash trap + setsid-detached watchdog, per this repo's harness rule.
# Restore deletes the vif, restores the PM knobs, returns the card to managed
# and brings NetworkManager back - even on kill -9.
set -u

IFACE="${IFACE:-}"
if [ -z "$IFACE" ]; then
  for d in /sys/class/net/*/device/driver; do
    case "$(basename "$(readlink -f "$d")")" in
      mt7921*) IFACE=$(basename "$(dirname "$(dirname "$d")")"); break ;;
    esac
  done
fi
[ -n "$IFACE" ] || { echo "no mt7921 interface found; set IFACE="; exit 1; }

PHY="${PHY:-$(basename "$(readlink -f "/sys/class/net/$IFACE/phy80211")" 2>/dev/null)}"
PHY="${PHY:-phy0}"
MON=mon0
CHAN="${CHAN:-149}"
case "$CHAN" in 6) CHAN_MHZ=2437 ;; 36) CHAN_MHZ=5180 ;; 44) CHAN_MHZ=5220 ;; 149) CHAN_MHZ=5745 ;; esac
DUR="${DUR:-45}"
STRATEGIES="${STRATEGIES:-pin verbatim}"
MT76="/sys/kernel/debug/ieee80211/$PHY/mt76"
OWL_DIR="${OWL_DIR:-$HOME/owl}"
OWL="${OWL:-$OWL_DIR/build/daemon/owl}"
OUT="${OUT_DIR:-$PWD/runs}/chanswitch-$(date +%Y%m%d-%H%M%S)"

[ -x "$OWL" ] || { echo "REFUSING: no binary at $OWL"; exit 1; }
if [ "$(id -u)" = "0" ]; then
  echo "run as a normal user; this sudos internally (as root, ~ would be /root)" >&2
  exit 1
fi
mkdir -p "$OUT" || exit 1
sudo -v || exit 1
sudo mountpoint -q /sys/kernel/debug || sudo mount -t debugfs none /sys/kernel/debug

NSTRAT=$(echo $STRATEGIES | wc -w)
WATCHDOG_TIMEOUT=$(( NSTRAT * (DUR + 20) + 90 ))

RESTORE_CMDS='
  sudo pkill -x owl 2>/dev/null || true
  sudo ip link set '"$MON"' down 2>/dev/null || true
  sudo iw dev '"$MON"' del 2>/dev/null || true
  sudo sh -c "echo 1 > '"$MT76"'/runtime-pm" 2>/dev/null || true
  sudo sh -c "echo 1 > '"$MT76"'/deep-sleep" 2>/dev/null || true
  sudo ip link set '"$IFACE"' down 2>/dev/null || true
  sudo iw dev '"$IFACE"' set type managed 2>/dev/null || true
  sudo ip link set '"$IFACE"' up 2>/dev/null || true
  sudo sv up NetworkManager 2>/dev/null || sudo systemctl start NetworkManager 2>/dev/null || true
'
setsid nohup bash -c "sleep $WATCHDOG_TIMEOUT; $RESTORE_CMDS" >/dev/null 2>&1 &
WATCHDOG_PID=$!
echo "watchdog armed (pid $WATCHDOG_PID, fires in ${WATCHDOG_TIMEOUT}s)"

RESTORED=0
restore() {
  [ "$RESTORED" = "1" ] && return
  RESTORED=1
  echo ""
  echo "--- restoring networking ---"
  eval "$RESTORE_CMDS"
  kill "$WATCHDOG_PID" 2>/dev/null || true
  echo "restored. logs in $OUT"
}
trap 'restore' EXIT
trap 'restore; exit 130' INT TERM

echo "interface $IFACE on $PHY, channel $CHAN ($CHAN_MHZ MHz), ${DUR}s per strategy"
echo "output: $OUT"

# Take the card. NetworkManager must be out of the way or it will fight us for
# the interface type.
sudo sv down NetworkManager 2>/dev/null || sudo systemctl stop NetworkManager 2>/dev/null || true
sleep 1
sudo ip link set "$IFACE" down 2>/dev/null

# A DEDICATED monitor vif, never an in-place type switch: an in-place switch
# leaves the radio pinned at 5180 MHz forever while iw reports whatever was
# asked for (FINDINGS §9).
sudo iw dev "$MON" del 2>/dev/null
sudo iw phy "$PHY" interface add "$MON" type monitor || { echo "could not create $MON"; exit 1; }
sudo ip link set "$MON" up

# Runtime PM must be off or monitor RX delivers literally zero frames, with no
# error logged anywhere (FINDINGS §9).
sudo sh -c "echo 0 > $MT76/runtime-pm" 2>/dev/null
sudo sh -c "echo 0 > $MT76/deep-sleep" 2>/dev/null
sudo iw dev "$MON" set freq "$CHAN_MHZ"
sleep 1

for S in $STRATEGIES; do
  echo ""
  echo "=== -S $S ==="
  LOG="$OUT/owl-$S.log"
  sudo stdbuf -oL "$OWL" -i "$MON" -c "$CHAN" -N -S "$S" -vv > "$LOG" 2>&1 &
  sleep "$DUR"
  sudo pkill -x owl 2>/dev/null
  sleep 2

  # NB: `grep -c` prints 0 AND exits 1 when there are no matches, so the
  # idiomatic-looking `|| echo 0` prints the count twice. Default the variable
  # instead, which only has to cover the log-missing case.
  count() { local n; n=$(grep -c "$1" "$LOG" 2>/dev/null); echo "${n:-0}"; }
  PEERS=$(count "add peer")
  SEQS=$(count "changed channel sequence")
  SWITCHES=$(count "switch channel to")
  RXACT=$(count "receive MIF\|receive PSF")

  echo "  peers discovered   : $PEERS"
  echo "  sequences seen     : $SEQS"
  echo "  action frames rx   : $RXACT"
  echo "  channel switches   : $SWITCHES  ($(awk -v s="$SWITCHES" -v d="$DUR" 'BEGIN{printf "%.2f", s/d}')/s)"

  # The latency claim. OWL logs "set_channel(N) queued in M us" per switch.
  if grep -q "queued in" "$LOG"; then
    grep -o "queued in [0-9]* us" "$LOG" | awk '{print $3}' |
      awk -v out="$OUT/lat-$S.txt" '
        {n++; s+=$1; if($1>max)max=$1; print $1 > out}
        END{ if(n) printf "  set_channel latency: n=%d  mean=%.0f us  max=%d us\n", n, s/n, max }'
    MEAN=$(awk '{s+=$1; n++} END{if(n) printf "%.0f", s/n}' "$OUT/lat-$S.txt" 2>/dev/null)
    N=$(wc -l < "$OUT/lat-$S.txt" 2>/dev/null)
    # The FIRST switch after a vif is created is not representative - it was
    # measured at 7144 us against 106 us for the same call in a later run, so
    # the initial tune evidently costs something in firmware that the steady
    # state does not. Refuse to pronounce on a handful of samples.
    if [ "${N:-0}" -lt 10 ]; then
      echo "  => only ${N:-0} switch(es): too few to call. The first tune after vif"
      echo "     creation is not representative. Needs a peer to generate traffic."
    elif [ "$MEAN" -lt 1000 ] 2>/dev/null; then
      echo "  => mean under 1 ms over $N switches: the synchronous netlink wait is gone"
      echo "     (it was a mean of 8500 us before)."
    else
      echo "  => still ${MEAN} us per switch over $N - the send is blocking on something."
    fi
  else
    echo "  set_channel latency: no switches to time"
  fi

  if [ "$PEERS" = "0" ]; then
    echo "  INCONCLUSIVE for strategy comparison: no peer was discovered, so OWL"
    echo "  kept its own static sequence and had nothing to adopt. Switch counts"
    echo "  below are not a test of $S. Have an Apple device awake and nearby."
  fi
done

echo ""
echo "=== summary ==="
for S in $STRATEGIES; do
  L="$OUT/owl-$S.log"
  p=$(grep -c 'add peer' "$L" 2>/dev/null); w=$(grep -c 'switch channel to' "$L" 2>/dev/null)
  printf "  %-9s peers=%-3s switches=%-5s\n" "$S" "${p:-0}" "${w:-0}"
done
echo ""
echo "Expected if a peer was present: pin settles to ~1 switch (it sits on one"
echo "channel in all 16 slots), verbatim fires one per sequence transition,"
echo "around 4 per 1.049 s period. See FINDINGS §21."
