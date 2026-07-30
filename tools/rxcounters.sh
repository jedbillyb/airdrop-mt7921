#!/bin/bash
# Where are the frames being lost - radio, driver, or pcap?
#
# Compares three independent counters over the same monitor-mode window:
#   1. mt76 debugfs hardware RX counters  (did the chip receive anything?)
#   2. netdev rx_packets via ip -s link   (did the driver hand anything up?)
#   3. libpcap frame count via tcpdump    (did anything reach userspace?)
#
# hw>0, netdev=0  -> chip receives, driver drops. Driver/firmware bug.
# netdev>0, pcap=0 -> driver delivers, pcap does not see it. Capture-path bug.
# all 0            -> chip is not receiving at all in monitor mode.
#
# SAFETY: bash trap + detached watchdog restoring even on kill -9 or hang.
set -u

IFACE=wlp2s0
DWELL=10
WATCHDOG_TIMEOUT=150
DBG=/sys/kernel/debug/ieee80211/phy0

sudo -v || exit 1

RESTORE_CMDS='
  sudo ip link set '"$IFACE"' down 2>/dev/null || true
  sudo iw dev '"$IFACE"' set type managed 2>/dev/null || true
  sudo ip link set '"$IFACE"' up 2>/dev/null || true
  sudo sv up NetworkManager 2>/dev/null || true
'
setsid nohup bash -c "sleep $WATCHDOG_TIMEOUT; $RESTORE_CMDS" >/dev/null 2>&1 &
WATCHDOG_PID=$!
echo "watchdog armed (pid $WATCHDOG_PID)"

restore() {
  echo "--- restoring networking ---"
  sudo pkill -x tcpdump 2>/dev/null || true
  eval "$RESTORE_CMDS"
  kill "$WATCHDOG_PID" 2>/dev/null || true
  echo "restored."
}
trap restore EXIT INT TERM

netdev_rx() { awk -v i="$IFACE:" '$1==i {print $2}' /proc/net/dev; }

sudo sv down NetworkManager
sudo pkill -x wpa_supplicant 2>/dev/null; sudo pkill -x dhcpcd 2>/dev/null; sleep 1
sudo iw reg set NZ
sudo ip link set $IFACE down
sudo iw dev $IFACE set monitor active
sudo ip link set $IFACE up
# stay on 2.4 GHz where the AP currently is - guarantees traffic exists
sudo iw dev $IFACE set channel 2 2>/dev/null
iw dev $IFACE info 2>/dev/null | grep -E "type|channel|txpower" | sed 's/^/  /'

echo ""
echo "=== mt76 debugfs available? ==="
if sudo test -d "$DBG"; then
  sudo ls "$DBG" 2>/dev/null | tr '\n' ' '; echo
  sudo ls "$DBG/mt76" 2>/dev/null | tr '\n' ' '; echo
else
  echo "  no debugfs at $DBG"
fi

echo ""
echo "=== baseline ==="
RX0=$(netdev_rx)
echo "  netdev rx_packets: $RX0"
sudo cat "$DBG/mt76/queues" 2>/dev/null | sed 's/^/  queues: /'

echo ""
echo "=== capturing ${DWELL}s ==="
PCAP=/tmp/rxcount.pcap
sudo rm -f $PCAP
sudo timeout $((DWELL + 3)) tcpdump -i $IFACE -w $PCAP -c 500 >/dev/null 2>&1 &
TD=$!
sleep $DWELL
sudo pkill -x tcpdump 2>/dev/null || true
wait $TD 2>/dev/null

RX1=$(netdev_rx)
PCAPN=$(sudo tcpdump -r $PCAP 2>/dev/null | wc -l)

echo ""
echo "=========== RESULT ==========="
echo "  netdev rx_packets delta : $((RX1 - RX0))"
echo "  pcap frames captured    : ${PCAPN:-0}"
echo "  hw queue state after:"
sudo cat "$DBG/mt76/queues" 2>/dev/null | sed 's/^/    /'
echo "=============================="
