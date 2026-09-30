#!/bin/sh
# Samples the chip's own queues alongside the station counters, once a second.
#
# WHY THIS EXISTS. beaconwatch.sh establishes THAT the station stops hearing
# beacons under a sustained AWDL session (#7), and separates "never arrived"
# from "arrived and got dropped" from "TX saturated". What it cannot say is
# whether the host is still feeding the chip, because every counter it reads
# sits above the driver. This reads the two mt76 debugfs files below it, so one
# run covers the whole path from mac80211 down to the MAC:
#
#   xmit-queues  WFDMA0 / MCUWM / MCUFWQ, the DMA and firmware-command rings
#   acq          the chip's PLE per-AC queues (mt792x_queues_acq, walking
#                MT_PLE_AC_QEMPTY), so a frame counted there has already
#                crossed DMA and is waiting on-chip for airtime
#
# What the combination separates, on the run it was written for:
#
#   acq climbs while wfdma0 stays at 0  the host keeps handing frames down and
#                                       DMA keeps moving them, so the chip is
#                                       holding them. Not an mt76 TX gate: a
#                                       gated scheduler stops feeding the chip
#                                       and the PLE count would not grow.
#   tx_retries frozen, tx_failed 0      nothing is being attempted, rather than
#                                       attempted and failing.
#   both, at a strong signal            not a busy medium. Contention delays
#                                       transmissions and shows up as retries,
#                                       and it does not stop you hearing an AP
#                                       at -40 dBm.
#
# NOTE ON AC NUMBERING, which is easy to get wrong and changes the conclusion.
# The LMAC numbers ACs in reverse from mac80211 (mt76_connac_lmac_mapping does
# `3 - ac`), so the AC1 column below is mac80211's AC_BE: ordinary station
# traffic. Read as mac80211 AC1 it looks like an exotic class stalling instead.
#
# Needs root, unlike beaconwatch.sh, because debugfs is 0700. It reads only:
# no interface is touched and no setting changed, so it is meant to be left
# running while something else does the disruptive part.
#
#   sudo ./queuewatch.sh [interface] [logfile]
#
# IFACE, OUT_DIR, PHY and DEBUGFS may be set in the environment instead.
set -u

IFACE="${1:-${IFACE:-wlan0}}"
OUT_DIR="${OUT_DIR:-./runs}"
LOG="${2:-$OUT_DIR/queuewatch.log}"
DEBUGFS="${DEBUGFS:-/sys/kernel/debug}"

# Derived from the interface rather than assumed to be phy0. Reading another
# radio's queues does not fail - it produces a flat log, which looks exactly
# like the finding "the queues never moved".
PHY="${PHY:-}"
if [ -z "$PHY" ]; then
  PHY=$(readlink -f "/sys/class/net/$IFACE/phy80211" 2>/dev/null)
  PHY=${PHY##*/}
fi
case "$PHY" in
  phy[0-9]*) ;;
  *) echo "queuewatch: cannot resolve the phy for $IFACE - set PHY=" >&2; exit 1 ;;
esac

MT76="$DEBUGFS/ieee80211/$PHY/mt76"
for f in xmit-queues acq; do
  if [ ! -r "$MT76/$f" ]; then
    echo "queuewatch: cannot read $MT76/$f - run as root, and check this is an mt76 card" >&2
    exit 1
  fi
done

mkdir -p "$(dirname "$LOG")"
if [ ! -s "$LOG" ]; then
  printf 'when\tsignal\tbeacon_loss\trx_drop_misc\ttx_retries\ttx_failed\twfdma0\tmcuwm\tmcufwq\tac0\tac1\tac2\tac3\n' > "$LOG"
fi

# One value out of `iw station dump`, by its label.
field() {
  printf '%s' "$1" | awk -F: -v k="$2" \
    '$0 ~ "^[[:space:]]*"k":" { gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); print $2; exit }'
}

# `queued=` for one named ring or AC, out of lines that read
#
#   WFDMA0:<TAB>queued=0 head=772 tail=772
#   AC0: queued=0
#
# Matched by label AND by key, never by column: the two files disagree on the
# separator after the label and on how many fields follow, and a later kernel
# may reorder them. Anything unmatched yields nothing and the caller writes `-`,
# which is the honest answer - reporting a neighbouring queue's depth as this
# one's is how a stalled AC gets blamed on the wrong traffic class.
queued() {
  printf '%s' "$1" | awk -v k="$2" '
    $1 == k ":" {
      for (i = 2; i <= NF; i++)
        if ($i ~ /^queued=/) { sub(/^queued=/, "", $i); print $i; exit }
    }'
}

while :; do
  d=$(iw dev "$IFACE" station dump 2>/dev/null)
  x=$(cat "$MT76/xmit-queues" 2>/dev/null)
  a=$(cat "$MT76/acq" 2>/dev/null)

  # `signal` reads "-40 [-44, -41] dBm": the first number only, the per-chain
  # values teach us nothing here.
  sig=$(field "$d" "signal" | awk '{print $1}')

  bl=$(field "$d" "beacon loss")
  rx=$(field "$d" "rx drop misc")
  tr=$(field "$d" "tx retries")
  tf=$(field "$d" "tx failed")
  w0=$(queued "$x" WFDMA0)
  mw=$(queued "$x" MCUWM)
  mf=$(queued "$x" MCUFWQ)
  a0=$(queued "$a" AC0)
  a1=$(queued "$a" AC1)
  a2=$(queued "$a" AC2)
  a3=$(queued "$a" AC3)

  # Every field falls back to `-`, never to an empty column: a blank cell in a
  # TSV shifts every column after it when the log is read back, so one missing
  # counter silently corrupts the rest of the row.
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date '+%Y-%m-%d %H:%M:%S')" \
    "${sig:--}" "${bl:--}" "${rx:--}" "${tr:--}" "${tf:--}" \
    "${w0:--}" "${mw:--}" "${mf:--}" \
    "${a0:--}" "${a1:--}" "${a2:--}" "${a3:--}" >> "$LOG"
  sleep 1
done
