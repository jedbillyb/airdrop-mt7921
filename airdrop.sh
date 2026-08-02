#!/bin/bash
# Bring up the full AirDrop stack on the built-in MT7921 and try to talk to an
# Apple device.
#
#   ./airdrop.sh                 # discover only (opendrop find)
#   ./airdrop.sh receive         # advertise this box as an AirDrop target
#   ./airdrop.sh send <file>     # discover, then try to send <file>
#
#   KEEP_WIFI=1 ACTIVE=1 ./airdrop.sh receive   # keep the internet up (§38)
#
# Layers, and where each one comes from:
#   1. AWDL link sync          - OWL on a dedicated mon0 vif with PM off
#   2. awdl0 + IPv6 link-local - OWL creates this automatically
#   3. mDNS _airdrop._tcp      - OpenDrop (in .venv-opendrop)
#   4. AirDrop auth + HTTPS    - OpenDrop, patched for iOS 26 (see patches/)
#
# ON THE PHONE, before running:
#   - Settings > General > AirDrop > "Everyone for 10 Minutes".
#     This is the mode that needs no Apple-signed validation record.
#     Contacts-only will almost certainly fail.
#   - Open the SHARE SHEET and LEAVE IT OPEN. This applies to BOTH directions.
#     Apple bootstraps AirDrop discovery over Bluetooth LE - a sender's BLE
#     advertisement is what wakes a receiver's AWDL interface - and neither OWL
#     nor OpenDrop implements that side. So we cannot wake a dormant iPhone; it
#     must already have AWDL up, and the share sheet is what does that.
#     Measured: share sheet open -> sync and a peer. Control Centre only -> ZERO
#     AWDL frames on all five social channels. Control Centre is not enough.
#
# STATUS: receiving works, proven end to end against an iPhone on iOS 26
# (2026-07-31) - a 2.06 MB photo arrived intact. The auth wall that docs/
# FINDINGS.md §7 predicted was never reached: in "Everyone" mode the phone
# accepts an unsigned receiver. Sending TO the phone is UNTESTED.
#
# Throughput is ~40-45 kB/s: each AWDL availability window delivers ~22-25 kB and
# we get ~1.8 of them a second. Not TCP, not the PHY - see docs/FINDINGS.md §18.
#
# NOTE: by default this takes the Wi-Fi card exclusively - no internet while it
# runs. KEEP_WIFI=1 stays associated instead, at the cost of being locked to the
# AP's channel; see the KEEP_WIFI block below and FINDINGS §38.
#
# SAFETY: bash trap + setsid-detached watchdog restores networking even on
# kill -9 or hang.
set -u

MODE="${1:-find}"
SENDFILE="${2:-}"

# Where this script lives, so the analysis tools can be found regardless of the
# working directory it was invoked from.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Wi-Fi interface. Autodetected as the first mt7921-driven interface; override
# with IFACE=... if you have more than one Wi-Fi card.
if [ -z "${IFACE:-}" ]; then
  for d in /sys/class/net/*/device/driver; do
    case "$(basename "$(readlink -f "$d")")" in
      mt7921*) IFACE=$(basename "$(dirname "$(dirname "$d")")"); break ;;
    esac
  done
fi
[ -n "${IFACE:-}" ] || { echo "REFUSING: no mt7921 interface found. Set IFACE=..."; exit 1; }
# The phy backing that interface - not always phy0 on multi-radio machines.
PHY=$(basename "$(readlink -f "/sys/class/net/$IFACE/phy80211")" 2>/dev/null)
[ -n "$PHY" ] || { echo "REFUSING: could not resolve the phy for $IFACE"; exit 1; }
MON=mon0              # plain vif: owns and steers the channel
MONA=mon1             # active vif (ACTIVE=1 only): ACKs, rides mon0's channel
AWDL=awdl0

# ---------- KEEP_WIFI: run AirDrop without giving up the internet ----------
# FINDINGS §38 (2026-08-02). Measured on a live association: adding mon0, and a
# second `flags active` vif alongside it, does NOT disturb an associated managed
# vif. Link stayed up, ping stayed at 0% loss, both vifs came up clean. So the
# `ip link set $IFACE down` in the normal path was never about coexistence.
#
# What it WAS about is the channel. With the managed vif associated, the monitor
# vif gets no channel context of its own and `iw dev mon0 set freq` is refused
# with EBUSY (-16) - REJECTED, not silently ignored the way mon1's retunes are
# when mon0 owns the context. Radiotap confirms it: every frame arrives on the
# AP's frequency. So in this mode we do not choose the channel, the AP does.
#
# That is survivable only because §24 established OWL's hopping was already
# fiction - in every working transfer mon1's retunes were accepted and ignored
# and all four bisect builds transmitted on one channel to a phone on the same
# one. set_channel() is async and deliberately does not report errors
# (daemon/netutils.h:53), so OWL swallows the EBUSY and runs on regardless.
#
# The condition is therefore: the AP must be parked on a channel the phone's
# AWDL sequence actually uses. Refuse loudly if it is not, because everything
# downstream would fail for a reason that looks like anything but this.
#
#   KEEP_WIFI=1 ACTIVE=1 ./airdrop.sh receive
#
# UNPROVEN as of 2026-08-02: that a transfer completes in this configuration.
# Coexistence is measured; the transfer is not. This flag exists to test it.
KEEP_WIFI="${KEEP_WIFI:-0}"
if [ "$KEEP_WIFI" = "1" ]; then
  AP_CHAN=$(iw dev "$IFACE" info 2>/dev/null | grep -oP 'channel \K[0-9]+')
  if [ -z "${AP_CHAN:-}" ]; then
    echo "REFUSING: KEEP_WIFI=1 but $IFACE is not associated - it has no channel"
    echo "  to borrow. Connect to Wi-Fi first, or drop KEEP_WIFI and let the"
    echo "  script take the card exclusively."
    exit 1
  fi
  case "$AP_CHAN" in
    6|36|44|132|149) ;;
    *)
      echo "REFUSING: your AP is on channel $AP_CHAN, which is not an AWDL social"
      echo "  channel (6, 36, 44, 132, 149). With KEEP_WIFI=1 the monitor vif is"
      echo "  locked to the AP's channel - the retune is EBUSY - so there is no"
      echo "  way to reach the phone from here. Options:"
      echo "    - move the AP to 36, 44, 149 or 6"
      echo "    - drop KEEP_WIFI and let the script take the card (default)"
      echo "    - give AWDL its own radio (the AR9271: IFACE=... PHY=...)"
      exit 1 ;;
  esac
  if [ -n "${CHAN:-}" ] && [ "$CHAN" != "$AP_CHAN" ]; then
    echo "note: CHAN=$CHAN ignored - KEEP_WIFI=1 borrows the AP's channel"
    echo "      ($AP_CHAN) and cannot retune away from it."
  fi
  CHAN="$AP_CHAN"
fi
# Channel. Default 36: an iPhone was observed on 2026-07-30 advertising
# 36,36,149,0,0,0,0,36,6,36,149,36,0,0,0,36 - six slots on 36 against two on
# 149, so 149 is its MINORITY channel and sitting there misses most of its
# availability windows. Override with e.g. CHAN=149 ./airdrop.sh
# CHAN_PINNED records whether the operator named a channel. If they did, the
# sweep is skipped entirely rather than being allowed to overrule them: the
# sweep ranks channels by raw frame count, which is NOT the same as where the
# peer spends its slots, and it has picked the phone's worst channel more than
# once (ch6 at 1 slot of 16 over ch36 at 6 -- see FINDINGS §22).
# KEEP_WIFI pins it just as firmly, only the AP does the naming rather than the
# operator, and the sweep is not merely unwise there but impossible: it works by
# retuning mon0, and every retune is EBUSY while the managed vif holds the
# channel context.
CHAN_PINNED=0
[ -n "${CHAN:-}" ] && CHAN_PINNED=1
CHAN="${CHAN:-36}"
case "$CHAN" in
  6)   CHAN_MHZ=2437 ;;
  36)  CHAN_MHZ=5180 ;;
  44)  CHAN_MHZ=5220 ;;
  132) CHAN_MHZ=5660 ;;
  149) CHAN_MHZ=5745 ;;
  *)   echo "REFUSING: CHAN must be 6, 36, 44, 132 or 149 (got $CHAN)"; exit 1 ;;
esac
PEER_WAIT=45          # how long to wait for an AWDL peer before giving up
# How long to let opendrop browse for receivers. Generous on purpose: mDNS over
# AWDL is multicast, and we are only co-channel with the peer for ~68 ms at a time
# about 1.8 times a second, so a query and its response have few chances to line
# up. 25 s was not enough - a send failed with "No AirDrop service discovered"
# while AWDL sync itself was working fine.
#
# This is a CEILING, not a duration: the browse stops the instant a receiver is
# found. So the only thing this number buys is how long a FAILURE takes, and
# every failure so far has been categorical - the phone either advertises
# _airdrop._tcp or it does not, and no run has ever had one appear late. A long
# ceiling has never once turned a failure into a success; it has only made
# failures slow. 45 s is well past the point where anything new shows up.
FIND_TIME="${FIND_TIME:-45}"
# Throughput over AWDL measured at ~0.05 MB/s, so a single photo needs ~40-60s
# AFTER the user finds and taps this machine. 120s cut a 2 MB transfer off 370
# bytes from the end - the archive is then genuinely truncated, not mis-decoded.
RECV_TIME="${RECV_TIME:-90}"    # how long to advertise in receive mode
RECV_DIR="${RECV_DIR:-$HOME/Downloads}"   # where received files are extracted
# The watchdog has to outlast the whole run or it tears the card down mid-test.
if [ "$MODE" = "receive" ]; then WATCHDOG_TIMEOUT=$((RECV_TIME + 420)); else WATCHDOG_TIMEOUT=420; fi
MT76=/sys/kernel/debug/ieee80211/$PHY/mt76
# OWL binary and the OpenDrop venv. Point OWL_DIR at your owl checkout (the
# patched fork - see README) or set OWL/OPENDROP directly.
OWL_DIR="${OWL_DIR:-$HOME/owl}"
OWL="${OWL:-$OWL_DIR/build/daemon/owl}"
OPENDROP="${OPENDROP:-$OWL_DIR/.venv-opendrop/bin/opendrop}"
# Where per-run logs and captures land.
OUT="${OUT_DIR:-$PWD/runs}/airdrop-$(date +%Y%m%d-%H%M%S)"

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
[ -x "$OWL" ]  || { echo "REFUSING: no OWL binary at $OWL"; exit 1; }
[ -x "$OPENDROP" ] || { echo "REFUSING: no opendrop at $OPENDROP"; exit 1; }
if [ "$MODE" = "send" ]; then
  [ -n "$SENDFILE" ] || { echo "REFUSING: send needs a file: ./airdrop.sh send <file>"; exit 1; }
  [ -f "$SENDFILE" ] || { echo "REFUSING: no such file: $SENDFILE"; exit 1; }
fi
mkdir -p "$OUT" || exit 1
sudo -v || exit 1
sudo mountpoint -q /sys/kernel/debug || sudo mount -t debugfs none /sys/kernel/debug

# Bringing NetworkManager back is the single most important part of restore, so
# work out how to do it on this init system ONCE, up front, rather than guessing
# inside the watchdog. Void uses runit; most other distros use systemd.
if command -v sv >/dev/null 2>&1 && [ -e /var/service/NetworkManager ]; then
  NM_UP='sudo sv up NetworkManager'
  NM_DOWN='sudo sv down NetworkManager'
elif command -v systemctl >/dev/null 2>&1; then
  NM_UP='sudo systemctl start NetworkManager'
  NM_DOWN='sudo systemctl stop NetworkManager'
else
  echo "WARNING: no NetworkManager service found - you may have to restore"
  echo "  networking by hand after this run."
  NM_UP='true'
  NM_DOWN='true'
fi

# Regulatory domain. Governs which channels are legal to use; the 5 GHz AWDL
# social channels are not available everywhere. Set to your own country.
REG="${REG:-NZ}"


# avahi-daemon competes for awdl0. Captured on 2026-07-31 it was announcing
# _sftp-ssh._tcp and void-btw.local straight out of awdl0, which (a) burns the
# very scarce co-channel airtime we need for the _airdrop._tcp query and its
# reply and (b) holds UDP 5353, so any UNICAST mDNS answer from the phone can be
# delivered to avahi's socket instead of python-zeroconf's. Stopped for the run
# and restored afterwards. AVAHI=keep to leave it alone.
AVAHI_WAS=""
if [ "${AVAHI:-stop}" = "stop" ] && pgrep -x avahi-daemon >/dev/null 2>&1; then
  AVAHI_WAS=1
fi
if [ -n "$AVAHI_WAS" ] && [ -d /etc/sv/avahi-daemon ]; then
  AVAHI_RESTORE='sudo sv up avahi-daemon 2>/dev/null || true'
  AVAHI_STOP='sudo sv down avahi-daemon 2>/dev/null || true'
elif [ -n "$AVAHI_WAS" ] && command -v systemctl >/dev/null 2>&1; then
  AVAHI_RESTORE='sudo systemctl start avahi-daemon 2>/dev/null || true'
  AVAHI_STOP='sudo systemctl stop avahi-daemon 2>/dev/null || true'
elif [ -n "$AVAHI_WAS" ]; then
  # Killing it with no supervisor to bring it back would leave the user's
  # machine changed after the script exits. Warn instead.
  echo "note: avahi-daemon is running and shares awdl0 with us, but there is no"
  echo "      service manager here to restart it, so it is being left alone."
  AVAHI_RESTORE='true'
  AVAHI_STOP='true'
else
  AVAHI_RESTORE='true'
  AVAHI_STOP='true'
fi

# Common half: undo what we created, in both modes.
RESTORE_CMDS='
  '"$AVAHI_RESTORE"' 2>/dev/null || true
  sudo pkill -x owl 2>/dev/null || true
  sudo ip link set '"$MONA"' down 2>/dev/null || true
  sudo iw dev '"$MONA"' del 2>/dev/null || true
  sudo ip link set '"$MON"' down 2>/dev/null || true
  sudo iw dev '"$MON"' del 2>/dev/null || true
  sudo sh -c "echo 1 > '"$MT76"'/runtime-pm" 2>/dev/null || true
  sudo sh -c "echo 1 > '"$MT76"'/deep-sleep" 2>/dev/null || true
'
# Under KEEP_WIFI the association was never touched, so restore must not touch
# it either. Bouncing the interface and restarting NetworkManager here would
# take down a working connection that the run had left alone the whole time -
# turning "no harm done" into exactly the outage this mode exists to avoid.
if [ "$KEEP_WIFI" != "1" ]; then
  RESTORE_CMDS="$RESTORE_CMDS"'
  sudo ip link set '"$IFACE"' down 2>/dev/null || true
  sudo iw dev '"$IFACE"' set type managed 2>/dev/null || true
  sudo ip link set '"$IFACE"' up 2>/dev/null || true
  '"$NM_UP"' 2>/dev/null || true
'
fi
setsid nohup bash -c "sleep $WATCHDOG_TIMEOUT; $RESTORE_CMDS" >/dev/null 2>&1 &
WATCHDOG_PID=$!
echo "watchdog armed (pid $WATCHDOG_PID, fires in ${WATCHDOG_TIMEOUT}s)"

RESTORED=0
restore() {
  [ "$RESTORED" = "1" ] && return 0
  RESTORED=1
  echo ""
  echo "--- restoring ---"
  [ -n "${POLL_PID:-}" ] && kill "$POLL_PID" 2>/dev/null
  if [ -f "$OUT/radio.log" ]; then
    echo "  channels the radio actually visited:"
    awk '{print $2}' "$OUT/radio.log" | sort | uniq -c | sort -rn | head -5 | sed 's/^/    /'
  fi
  eval "$RESTORE_CMDS"
  kill "$WATCHDOG_PID" 2>/dev/null || true
  echo "restored. logs in $OUT"
}
# INT/TERM must restore AND exit. With a bare `trap restore EXIT INT TERM`, a
# Ctrl-C during the opendrop pipeline ran restore (tearing the card down) and
# then let the rest of the script run on regardless - which is exactly what
# happened on the first real run.
trap 'restore; exit 130' INT TERM
trap restore EXIT

# ---------- layer 1: AWDL link ----------
echo ""
echo "### layer 1: AWDL link on $MON"
if [ "$KEEP_WIFI" = "1" ]; then
  echo "  KEEP_WIFI=1: leaving $IFACE associated on ch $CHAN."
  echo "  NetworkManager, wpa_supplicant and the regulatory domain are all left"
  echo "  alone - stopping them is what would drop the connection, and none of"
  echo "  it is needed to create a monitor vif (§38)."
else
  $NM_DOWN
fi
eval "$AVAHI_STOP"
[ -n "$AVAHI_WAS" ] && echo "  avahi-daemon stopped for this run (restored on exit)"
if [ "$KEEP_WIFI" != "1" ]; then
  sudo pkill -x wpa_supplicant 2>/dev/null; sudo pkill -x dhcpcd 2>/dev/null; sleep 1
  # Skipped under KEEP_WIFI: a regulatory change while associated is at best
  # overridden by the AP's own country IE and at worst disrupts the link, and we
  # are not choosing the channel in that mode anyway.
  sudo iw reg set "$REG"
  sudo ip link set $IFACE down
fi
sudo iw dev $MONA del 2>/dev/null
sudo iw dev $MON del 2>/dev/null
# Monitor vif setup. THE PAIR (activelate2.sh/activelate3.sh, 2026-07-31).
#
# A vif created with `flags active` on its own is stuck at 5180 MHz forever, by
# every ordering tried - see FINDINGS §13/§14. But an active vif created
# ALONGSIDE a plain vif that already owns the channel comes up on that channel,
# at full reception, and the two share one channel context: retuning either one
# moves both. Measured, radiotap-verified, twice:
#
#   plain alone           2437 (667 frames)
#   active alongside      2437 (710)   <- no RX penalty
#   retune plain -> 2412  active follows to 2412, and back again
#   retune ACTIVE -> 2412 works too, so OWL can steer its own interface
#
# So `flags active` never cost us reception; being dumped on an empty 5180 did.
# That removes both obstacles at once: ACKs for unicast AWDL data AND the
# channel hopping needed to follow the peer's sequence.
#
#   ACTIVE=1 ./airdrop.sh        # the pair: ACKs + hopping. Use this for transfer.
#   ./airdrop.sh                 # default: plain only, hops, one-way (no ACKs)
#
# NOT YET CONFIRMED: that the firmware really does ACK in this configuration.
# Monitor flags cannot be read back (`iw dev <vif> info` prints nothing about
# them), so the only proof is layer 2.5 below reporting bidirectional IP.
if [ "${ACTIVE:-0}" = "1" ]; then
  echo "  mode: PAIR - plain $MON steers the channel, active $MONA ACKs"
else
  echo "  mode: plain monitor only (hops, but one-way - no ACKs)"
fi
sudo iw phy $PHY interface add $MON type monitor \
  || { echo "FAILED to create $MON"; exit 1; }
sudo ip link set $MON up
sudo sh -c "echo 0 > $MT76/runtime-pm"
sudo sh -c "echo 0 > $MT76/deep-sleep"
# Under KEEP_WIFI this retune is EBUSY by construction - the managed vif owns
# the channel context - and mon0 is already sitting on the AP's channel, which
# is the one we want. Attempting it only prints an alarming error for a
# non-event, so don't.
if [ "$KEEP_WIFI" != "1" ]; then
  sudo iw dev $MON set freq $CHAN_MHZ
fi
OWL_IF=$MON
if [ "${ACTIVE:-0}" = "1" ]; then
  # order matters: the plain vif must exist and be tuned FIRST
  if sudo iw phy $PHY interface add $MONA type monitor flags active 2>/dev/null \
     && sudo ip link set $MONA up 2>/dev/null; then
    OWL_IF=$MONA
    sudo sh -c "echo 0 > $MT76/runtime-pm"
    sudo sh -c "echo 0 > $MT76/deep-sleep"
    echo "  active vif $MONA up alongside $MON - OWL will run on $MONA"
  else
    echo "  WARNING: could not bring up the active vif; falling back to $MON."
    echo "  Without ACKs the path is one-way and a transfer cannot complete."
    sudo iw dev $MONA del 2>/dev/null
  fi
fi
sleep 2
# Which vif to ASK about the channel. Under KEEP_WIFI mon0 has no channel of its
# own to report - it rides the managed vif's context - so `iw dev mon0 info`
# prints nothing and both the line below and the poller would read a blank as
# "NA", which looks like a broken radio rather than a shared one.
if [ "$KEEP_WIFI" = "1" ]; then CHAN_VIF=$IFACE; else CHAN_VIF=$MON; fi
echo "  PM off, $MON on $(iw dev $CHAN_VIF info 2>/dev/null | grep -oP 'channel \K[0-9]+') (requested $CHAN / $CHAN_MHZ MHz)"
[ "$KEEP_WIFI" = "1" ] && echo "  (channel read from $IFACE - $MON shares its context and reports none)"

# independent radio poller - confirms OWL really hops, without trusting its logs
( while :; do
    printf '%s %s\n' "$(date +%s.%N)" \
      "$(iw dev $CHAN_VIF info 2>/dev/null | grep -oP 'channel \K[0-9]+' || echo NA)"
    sleep 0.05
  done ) > "$OUT/radio.log" &
POLL_PID=$!

# ---------- layer 0: find which channel the phone is actually on ----------
# The phone's channel sequence drifts between runs (36-dominant and
# 149-dominant were both observed on 2026-07-30), and OWL sits statically on
# its master channel until it discovers a peer - so guessing wrong means never
# hearing it. Sweep first, on raw AWDL frames, before committing OWL.
# This also distinguishes "phone is silent" from "phone is elsewhere", which
# guessing cannot.
echo ""
# The sweep now runs in BOTH modes: the active vif rides mon0's channel, so
# steering mon0 steers the pair. Nothing has to be forced to ch36 any more.
echo "### layer 0: locating the phone (AWDL BSSID 00:25:00:ff:94:73)"
AWDL_BSSID="00:25:00:ff:94:73"

if [ "$KEEP_WIFI" = "1" ]; then
  # No sweep is POSSIBLE here: it works by retuning mon0 and every retune is
  # EBUSY. But a single dwell on the AP's channel is still worth 6 seconds,
  # because it answers the one question this mode can actually fail on - is the
  # phone on the channel our AP happens to occupy? A "no" here is categorical
  # and worth reporting as such, rather than letting it surface 45 s later as a
  # generic "no AWDL peer found".
  echo "  KEEP_WIFI=1: cannot sweep (retunes are EBUSY). Checking ch $CHAN only."
  sudo rm -f "$OUT/scan-$CHAN.pcap"
  sudo timeout 7 tcpdump -i $MON -w "$OUT/scan-$CHAN.pcap" -c 300 \
       "wlan addr3 $AWDL_BSSID" >/dev/null 2>&1 &
  sleep 5
  sudo pkill -x tcpdump 2>/dev/null || true
  sleep 1
  BEST_N=$(sudo tcpdump -r "$OUT/scan-$CHAN.pcap" 2>/dev/null | wc -l)
  BEST_N=${BEST_N:-0}
  BEST_CHAN=$CHAN
  printf '  ch %-4s AWDL frames: %s\n' "$CHAN" "$BEST_N"
  if [ "$BEST_N" -eq 0 ]; then
    echo ""
    echo "  No AWDL frames on ch $CHAN, and this mode cannot look anywhere else."
    echo "  Two different failures look identical from here:"
    echo "    a) the phone is asleep / not advertising  -> unlock it, set AirDrop"
    echo "       to 'Everyone for 10 Minutes' (it EXPIRES), open the share sheet"
    echo "    b) the phone IS awake but on another social channel -> your AP's"
    echo "       channel ($CHAN) is simply the wrong place to be sitting"
    echo "  To tell them apart, re-run WITHOUT KEEP_WIFI: the sweep can then"
    echo "  visit every social channel and will say which case this is."
    exit 1
  fi
  echo "  --> phone is present on the AP's channel; KEEP_WIFI is viable this run"
  SKIP_SWEEP=1
elif [ "$CHAN_PINNED" = "1" ]; then
  echo "  CHAN=$CHAN was given explicitly - skipping the sweep."
  echo "  (unset CHAN to let it search; with -S pin OWL will move to the peer's"
  echo "   dominant channel by itself once it sees a sequence)"
  SKIP_SWEEP=1
else
  SKIP_SWEEP=0
fi

if [ "$SKIP_SWEEP" = "0" ]; then
BEST_CHAN=""; BEST_N=0; SAW_ANY=0
# Try whichever channel won last time first, and stop the sweep early if it is
# clearly busy. The phone is usually where it was a few minutes ago, and the full
# four-channel sweep costs ~28 s before we can start advertising - which is dead
# time the user spends staring at a share sheet that has not found us yet.
# A cold cache, or a phone that moved, just falls through to the full sweep.
CHAN_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/airdrop-mt7921-channel"
SWEEP_ORDER="36 149 6 44 132"
EARLY_OK=100          # frames on ANY channel that mean "found it, stop looking"
# A far lower bar applies to the CACHED channel, because that one already won a
# complete sweep - we are confirming a previous result, not choosing blind. Each
# channel costs ~7 s, so confirming the cache instead of sweeping all five saves
# ~28 s off every run. Measured: the winning channel yields ~50 frames in the 5 s
# dwell, a loser yields 0, so 25 separates them with room to spare.
CACHED_OK=25
CACHED_CHAN=""
if [ -r "$CHAN_CACHE" ]; then
  LAST=$(cat "$CHAN_CACHE" 2>/dev/null)
  case "$LAST" in
    6|36|44|132|149)
      CACHED_CHAN="$LAST"
      SWEEP_ORDER="$LAST $(echo "$SWEEP_ORDER" | tr ' ' '\n' | grep -vx "$LAST" | tr '\n' ' ')"
      echo "  (trying ch $LAST first - it won the last run)" ;;
  esac
fi
for c in $SWEEP_ORDER; do
  case "$c" in 6) mhz=2437 ;; 36) mhz=5180 ;; 44) mhz=5220 ;; 132) mhz=5660 ;; 149) mhz=5745 ;; esac
  sudo iw dev $MON set freq $mhz 2>/dev/null
  sleep 1
  sudo rm -f "$OUT/scan-$c.pcap"
  sudo timeout 7 tcpdump -i $MON -w "$OUT/scan-$c.pcap" -c 300 \
       "wlan addr3 $AWDL_BSSID" >/dev/null 2>&1 &
  sleep 5
  sudo pkill -x tcpdump 2>/dev/null || true
  sleep 1
  n=$(sudo tcpdump -r "$OUT/scan-$c.pcap" 2>/dev/null | wc -l)
  n=${n:-0}
  printf '  ch %-4s AWDL frames: %s\n' "$c" "$n"
  [ "$n" -gt 0 ] && SAW_ANY=1
  if [ "$n" -gt "$BEST_N" ]; then BEST_N=$n; BEST_CHAN=$c; fi
  if [ "$n" -ge "$EARLY_OK" ]; then
    echo "  ch $c is busy enough ($n frames) - skipping the rest of the sweep"
    break
  fi
  if [ "$c" = "$CACHED_CHAN" ] && [ "$n" -ge "$CACHED_OK" ]; then
    echo "  ch $c confirmed ($n frames, it won last time) - skipping the rest"
    break
  fi
done

if [ "$SAW_ANY" = "0" ]; then
  echo ""
  echo "  No AWDL frames on ANY channel. The phone is not advertising."
  echo "  This is not a Linux-side problem - nothing to sync with."
  echo "  On the phone, immediately before re-running:"
  echo "    1. unlock it and keep the screen ON"
  echo "    2. Settings > General > AirDrop > 'Everyone for 10 Minutes'"
  echo "       (this EXPIRES - re-arm it each time)"
  echo "    3. open the share sheet and leave it open"
  exit 1
fi

echo "  --> strongest on channel $BEST_CHAN ($BEST_N frames); using it"
mkdir -p "$(dirname "$CHAN_CACHE")" 2>/dev/null && echo "$BEST_CHAN" > "$CHAN_CACHE"
CHAN=$BEST_CHAN
fi   # SKIP_SWEEP

case "$CHAN" in 6) CHAN_MHZ=2437 ;; 36) CHAN_MHZ=5180 ;; 44) CHAN_MHZ=5220 ;; 149) CHAN_MHZ=5745 ;; esac
sudo iw dev $MON set freq $CHAN_MHZ 2>/dev/null
sleep 1

# -N because the vif is already a monitor and up; OWL's own set-monitor-mode
# would fail with EBUSY. We did that setup ourselves above. In ACTIVE mode
# OWL_IF is the active vif, so OWL's frames go out on the vif that ACKs.
# STRATEGY picks how OWL derives its channel sequence from the peer's; see
# channel.h in the owl fork and FINDINGS §21, §25.
#
#   verbatim  copy the sync master's sequence -- upstream behaviour, and the
#             DEFAULT until a real transfer says otherwise (§26).
#   widen     the peer's own sequence with up to WIDEN_MAX of its empty slots
#             filled with the peer's dominant channel. Accepted by the phone at
#             every width tested (§26); this is the candidate for the §21
#             duty-cycle win and the arm to measure against verbatim.
#   pin       sit on the peer's dominant social channel in all 16 slots. BREAKS
#             AIRDROP against iOS 26: the phone stops replying entirely. Measured
#             twice in one session against verbatim's 60% ping loss. Only useful
#             now as the experiment for how much slot structure Apple requires.
#   rotate    copy it but rotate into our own clock phase first
#
# The point of exposing it is that all three can be measured against the same
# phone in one session, which is the only way this gets settled:
#   for s in verbatim widen; do STRATEGY=$s ACTIVE=1 ./airdrop.sh receive; done
#   tools/bursts.py runs/<widen-run>/receive.pcap --baseline runs/<verbatim-run>/receive.pcap
STRATEGY="${STRATEGY-verbatim}"
# Set STRATEGY= (empty) to omit the flag entirely, which is what an OWL build
# from before -S existed needs -- the pre-change binary is the reference for
# deciding whether a regression is ours or the environment's, and it aborts on
# an unknown option.
# WIDEN_MAX is how many of the peer's empty slots -S widen may fill (owl's own
# default is 4). Only meaningful with STRATEGY=widen; see FINDINGS §26.
WIDEN_MAX="${WIDEN_MAX:-}"
if [ -n "$STRATEGY" ]; then
  set -- -S "$STRATEGY"
  [ -n "$WIDEN_MAX" ] && set -- "$@" -W "$WIDEN_MAX"
else
  set --
  echo "  (no -S flag: assuming an OWL build that predates channel strategies)"
fi
sudo stdbuf -oL "$OWL" -i $OWL_IF -c $CHAN -N "$@" -vv > "$OUT/owl.log" 2>&1 &
sleep 4

if ! grep -q "Host device" "$OUT/owl.log"; then
  echo "  OWL failed to start:"
  grep -iE "error|unable" "$OUT/owl.log" | head -5 | sed 's/^/    /'
  exit 1
fi
echo "  OWL up. $(grep -m1 'Host device' "$OUT/owl.log" | sed 's/.*INFO *: *//')"

# ---------- layer 2: awdl0 ----------
echo ""
echo "### layer 2: $AWDL interface"
for i in $(seq 10); do ip link show $AWDL >/dev/null 2>&1 && break; sleep 1; done
if ! ip link show $AWDL >/dev/null 2>&1; then
  echo "  $AWDL never appeared - cannot continue"; exit 1
fi
sudo ip link set $AWDL up 2>/dev/null
ip -6 addr show $AWDL | grep -E "inet6|state" | sed 's/^/  /'

# ---------- wait for an AWDL peer ----------
echo ""
echo "### waiting up to ${PEER_WAIT}s for an AWDL peer ..."
echo "    (AirDrop sheet must be OPEN on the phone, set to Everyone for 10 Minutes)"
FOUND=0
for i in $(seq $PEER_WAIT); do
  if grep -q "add peer" "$OUT/owl.log"; then FOUND=1; break; fi
  sleep 1
done
if [ "$FOUND" = "0" ]; then
  echo "  no AWDL peer found in ${PEER_WAIT}s."
  if [ "${BEST_N:-0}" -gt 0 ] 2>/dev/null; then
    # Only meaningful when the sweep actually ran; with an explicit CHAN it did
    # not, and there is no frame count to reason from.
    echo "  DESPITE $BEST_N AWDL frames present on ch $CHAN during the scan."
    echo "  So the phone IS transmitting but OWL is not adding it as a peer -"
    echo "  that points at OWL parsing/election, not the radio."
  else
    echo "  No scan was run (CHAN=$CHAN was given explicitly), so we cannot tell"
    echo "  'phone is silent' from 'phone is on another channel' from here."
    echo "  Re-run without CHAN= to sweep, or check the phone is awake:"
    echo "    - unlock it, keep the screen ON"
    echo "    - AirDrop > Everyone  (this EXPIRES after 10 minutes - re-arm it)"
    echo "    - open a share sheet and LEAVE IT OPEN; that is what wakes its"
    echo "      AWDL interface, and nothing on this side can do it for you"
  fi
  echo "  Logs: $OUT/"
  exit 1
fi
echo "  peer found:"
grep -E "add peer|changed channel sequence" "$OUT/owl.log" | tail -3 | sed 's/.*[0-9]\{2\}:[0-9]\{2\}:[0-9]\{2\} //' | sed 's/^/    /'
echo "  IPv6 neighbours on $AWDL:"
ip -6 neigh show dev $AWDL | sed 's/^/    /' || echo "    (none yet)"

# ---------- layer 2.5: is there actually an IP data path? ----------
# The neighbour table entry above only proves AWDL link-layer sync. It says
# nothing about whether IPv6 packets actually traverse the link. If mDNS finds
# nothing, the first thing to establish is whether ANY packet gets through.
echo ""
echo "### layer 2.5: IP reachability over $AWDL"
PEER6=$(ip -6 neigh show dev $AWDL | awk '/^fe80:/{print $1; exit}')
if [ -z "${PEER6:-}" ]; then
  echo "  no link-local peer address in the neighbour table - cannot test"
else
  echo "  peer: $PEER6"
  # capture while we ping, so we see whether replies come back at all
  sudo timeout 14 tcpdump -i $AWDL -w "$OUT/awdl0.pcap" >/dev/null 2>&1 &
  sleep 1
  # RE-MEASURE ON PARTIAL LOSS. Our TX to the phone is intermittent and it is
  # the single best predictor of how far a transfer gets (§28): the 21:02 run
  # pinged 0% and reached "Receiver accepted", the 21:07 run pinged 60% and
  # stalled with the phone retransmitting its /Ask response 13 times into 18
  # seconds of silence. Loss here is not cosmetic, it is the outcome. Retrying
  # costs 8 s; a bad run costs a share sheet, an Accept tap and two minutes.
  PING_MAX_LOSS="${PING_MAX_LOSS:-20}"
  PING_TRIES="${PING_TRIES:-3}"
  LOSS=100
  for try in $(seq "$PING_TRIES"); do
    [ "$try" -gt 1 ] && echo "  ping6 (attempt $try of $PING_TRIES - retrying, loss was ${LOSS}%):"
    [ "$try" = "1" ] && echo "  ping6 (5 attempts, 8s):"
    PING_OUT=$(timeout 12 ping6 -c 5 -W 2 -I $AWDL "$PEER6" 2>&1)
    echo "$PING_OUT" | tail -4 | sed "s/^/    /"
    LOSS=$(echo "$PING_OUT" | grep -oE "[0-9]+% packet loss" | grep -oE "^[0-9]+")
    LOSS="${LOSS:-100}"
    [ "$LOSS" -le "$PING_MAX_LOSS" ] && break
    [ "$try" -lt "$PING_TRIES" ] && sleep 2
  done
  if [ "$LOSS" -gt "$PING_MAX_LOSS" ] && [ "$LOSS" -lt 100 ]; then
    echo ""
    echo "  WARNING: ${LOSS}% of our frames are not reaching the phone, after"
    echo "  $PING_TRIES attempts. The link is up and TCP will connect, but a"
    echo "  transfer is likely to stall partway: measured, the phone sends its"
    echo "  reply, our ACK never lands, and it retransmits until it gives up."
    echo "  This is a TX-reliability problem, not a protocol one, and it varies"
    echo "  run to run - re-running is often enough. Set PING_MAX_LOSS=100 to"
    echo "  silence this."
    echo ""
  fi
  sleep 2
  sudo pkill -x tcpdump 2>/dev/null || true
  sleep 1
  # Count by tcpdump FILTER, not by grepping the text for the peer address.
  # The old grep matched the peer address wherever it appeared, including as the
  # DESTINATION of our own outbound pings, so it could not tell direction at all.
  TOT=$(sudo tcpdump -r "$OUT/awdl0.pcap" 2>/dev/null | wc -l)
  FROMPEER=$(sudo tcpdump -r "$OUT/awdl0.pcap" "ip6 src $PEER6" 2>/dev/null | wc -l)
  TOPEER=$(sudo tcpdump -r "$OUT/awdl0.pcap" "ip6 dst $PEER6" 2>/dev/null | wc -l)
  MDNS=$(sudo tcpdump -r "$OUT/awdl0.pcap" "port 5353" 2>/dev/null | wc -l)
  echo "  packets on $AWDL: total=$TOT to_peer=$TOPEER from_peer=$FROMPEER mdns=$MDNS"
  if [ "${TOT:-0}" = "0" ]; then
    echo "  ==> NOTHING traverses awdl0. AWDL syncs but carries no data."
    echo "      That is a data-path problem, not an AirDrop auth problem."
  elif [ "${FROMPEER:-0}" = "0" ]; then
    # This IS evidence of a one-way path. The long-standing reading here - that
    # iOS ignores ICMP6 from strangers, so 100%% loss tells you nothing - is
    # RETRACTED (§23). On 2026-07-31 the same iPhone answered 5/5 as soon as the
    # TX path genuinely worked and 0/5 when it did not, with nothing else
    # changed. So ping6 is a reliable 8-second test of whether our frames reach
    # the phone, and a far better one than waiting two minutes for a file
    # transfer that will fail for the same reason.
    echo "  ==> NO PING REPLIES - treat this as a real failure of the TX path."
    echo "      Our frames are not reaching the phone. Nothing past this point"
    echo "      can work: the phone may still find us and open TCP, but the"
    echo "      handshake will never complete (it SYNs, we SYN-ACK, it SYNs"
    echo "      again forever) and no file will move."
    echo "      Earlier advice here said this was INCONCLUSIVE because iOS"
    echo "      ignores pings from strangers. That is RETRACTED (§23): on"
    echo "      2026-07-31 the same phone answered 5/5 when the path worked."
  else
    echo "  ==> bidirectional IP works. Any failure past here is service/auth level."
  fi
fi

# ---------- layers 3 + 4: OpenDrop ----------
# In receive mode, SKIP discovery. It contributes nothing - we are the one being
# discovered - and it is pure dead time before we start advertising, which is the
# only thing that makes this machine appear on the phone's share sheet. Measured
# on a real run: 89 s from script start to the first mDNS announcement, of which
# ~25 s was this phase. It is also currently broken on Python 3.14 (opendrop's
# client passes key_file= to HTTPSConnection, removed in 3.12+), so in receive
# mode it only ever produced a traceback and a misleading "No AirDrop service
# discovered" warning. Set FIND=1 to run it anyway when debugging discovery.
if [ "$MODE" != "receive" ] || [ "${FIND:-0}" = "1" ]; then
  echo ""
  echo "### layer 3: AirDrop service discovery over $AWDL"
  # CHECK THE BLE ADVERT IS ACTUALLY UP. §27 established that the phone only
  # advertises _airdrop._tcp while a Continuity advert is running, and this has
  # now cost two runs: blewake.sh's advert expires on a timer, and it has also
  # been observed to vanish while the script still looked alive. The process
  # existing is NOT the test - the registered advertising instance is.
  if [ "$MODE" = "send" ]; then
    ADV_N=$(sudo timeout 5 btmgmt advinfo 2>/dev/null \
            | grep -oP 'Instances list with \K[0-9]+' || echo "?")
    case "$ADV_N" in
      0)
        # START IT HERE, not before the run. The advert was killed three times
        # in a row despite being launched with a 2400 s duration, always around
        # a run. The mt7921 is a COMBO Wi-Fi/Bluetooth part: taking the radio
        # into monitor mode and writing runtime-pm/deep-sleep resets the shared
        # controller, and the registered advertising instance goes with it. So
        # an advert started before layer 1 cannot survive layer 1, and the only
        # safe moment to start it is here, after the radio has settled.
        echo "  no BLE advert registered - starting one now."
        echo "  (starting it BEFORE a run does not work: the mt7921 is a combo"
        echo "   Wi-Fi/BT part and layer 1 resets the shared controller)"
        setsid nohup "$PWD/tools/blewake.sh" --duration 600 \
          > "$OUT/blewake.log" 2>&1 < /dev/null &
        for _ in $(seq 20); do
          sleep 1
          ADV_N=$(sudo timeout 5 btmgmt advinfo 2>/dev/null \
                  | grep -oP 'Instances list with \K[0-9]+' || echo 0)
          [ "${ADV_N:-0}" != "0" ] && break
        done
        if [ "${ADV_N:-0}" != "0" ]; then
          echo "  BLE advert up ($ADV_N instance) - giving the phone 3s to react"
          sleep 3
        else
          echo "  WARNING: could not bring the advert up; see $OUT/blewake.log."
          echo "  §27: without it the phone does not advertise _airdrop._tcp and"
          echo "  this browse will find nothing (the tell is from_peer=0 below)."
        fi
        ;;
      [0-9]*) echo "  BLE advert: $ADV_N instance(s) registered - good" ;;
      *)      echo "  BLE advert: could not query btmgmt; continuing" ;;
    esac
  fi
  # opendrop writes its discovery report here and `opendrop send` reads it back.
  # Remember the mtime so a stale report cannot be mistaken for this run's.
  OD_REPORT="${OD_REPORT:-$HOME/.opendrop/discover.last.json}"
  OD_REPORT_MTIME=$(stat -c %Y "$OD_REPORT" 2>/dev/null || echo 0)
  # -s INT, not the default SIGTERM. `opendrop find` blocks forever and only
  # writes its discovery report from a finally: block reached via KeyboardInterrupt.
  # Python does not turn SIGTERM into KeyboardInterrupt, so plain `timeout` killed
  # it outright and the report was NEVER written - which surfaces much later, and
  # very confusingly, as "No discovery report exists, please run 'opendrop find'
  # first" during send. SIGINT lets the finally: block run.
  # Capture the whole browse window. Until now awdl0 was only captured during
  # layer 2.5's 14 s ping window, so the discovery phase - the part that keeps
  # failing - was the one part never on tape. Without this you cannot tell
  # "our query never went out" from "it went out and the phone ignored it".
  sudo timeout $((FIND_TIME + 10)) tcpdump -i $AWDL -w "$OUT/find.pcap" >/dev/null 2>&1 &
  sleep 1

  # STOP AS SOON AS SOMETHING IS FOUND. `opendrop find` never exits on its own,
  # so this used to burn the whole FIND_TIME even when the receiver turned up in
  # the first few seconds. FIND_TIME is now only a ceiling, not a duration: the
  # browse runs in the background, we poll its log, and the moment a receiver
  # line appears we SIGINT it (SIGINT, not SIGTERM - see above, the report is
  # written from a finally: block reached via KeyboardInterrupt).
  : > "$OUT/find.log"
  # PYTHONUNBUFFERED is load-bearing, not hygiene. Python block-buffers stdout
  # when it is a file rather than a tty, so the receiver line would sit in an
  # 8 KiB buffer until exit - and the poll below, which exists to notice that
  # line, would never see it until it was too late to matter.
  PYTHONUNBUFFERED=1 "$OPENDROP" -i $AWDL find > "$OUT/find.log" 2>&1 &
  FIND_PID=$!
  # --pid so tail exits with the browse instead of being orphaned. `kill $!` on a
  # pipeline only kills the LAST stage (the sed), which would leave `tail -f`
  # running against the log forever.
  tail -f --pid=$FIND_PID "$OUT/find.log" 2>/dev/null | sed 's/^/  /' &
  TAIL_PID=$!
  FOUND=0
  HALVES=0
  MAX_HALVES=$((FIND_TIME * 2))
  while [ $HALVES -lt $MAX_HALVES ]; do
    kill -0 $FIND_PID 2>/dev/null || break
    if grep -qE "^\s*[0-9]+\)|Found" "$OUT/find.log" 2>/dev/null; then
      FOUND=1
      # Give it a beat to print the whole list before we cut it off - a second
      # receiver one line later would otherwise be lost.
      sleep 2
      break
    fi
    sleep 0.5
    HALVES=$((HALVES + 1))
  done
  # BOUNDED wait, never `wait $FIND_PID`. Measured 2026-07-31: an unbounded wait
  # hung for 2m10s AFTER the browse had already finished and produced its result,
  # which was most of a 5-minute run. `opendrop find` handles the
  # KeyboardInterrupt and then calls zeroconf.close(), which tears down threads
  # and sockets and does not reliably return. We already have everything we need
  # from the log by this point, so give it a few seconds to write its report and
  # then stop caring.
  # Wait for the REPORT, not for the process. Those are different events and
  # conflating them cost a working send: the browse found the iPhone, we gave it
  # a flat 5s, zeroconf.close() had not returned, we SIGKILLed it, and the report
  # was never written -- so `opendrop send` then read a THREE HOUR OLD empty
  # report and failed. Waiting on the file distinguishes "has written what we
  # need" from "has finished tidying up", and only the first one matters.
  kill -INT $FIND_PID 2>/dev/null || true
  for _ in $(seq 80); do
    kill -0 $FIND_PID 2>/dev/null || break
    [ -s "$OD_REPORT" ] && [ "$(stat -c %Y "$OD_REPORT" 2>/dev/null || echo 0)" -gt "$OD_REPORT_MTIME" ] && break
    sleep 0.25
  done
  if kill -0 $FIND_PID 2>/dev/null; then
    if [ "$(stat -c %Y "$OD_REPORT" 2>/dev/null || echo 0)" -gt "$OD_REPORT_MTIME" ]; then
      echo "  (report written; killing the browse, which does not exit cleanly)"
    else
      echo "  (browse wrote no discovery report within 20s - killing it)"
    fi
    kill -9 $FIND_PID 2>/dev/null || true
  fi
  wait $FIND_PID 2>/dev/null || true
  kill $TAIL_PID 2>/dev/null || true
  sudo pkill -x tcpdump 2>/dev/null || true
  if [ "$FOUND" = "1" ]; then
    echo "  found a receiver after ~$((HALVES / 2))s - stopping the browse early"
  fi
  sleep 1

  # Did our _airdrop._tcp query leave, and did anything answer?
  F_Q=$(sudo tcpdump -r "$OUT/find.pcap" -nn 2>/dev/null | grep -c "_airdrop" || true)
  if [ -n "${PEER6:-}" ]; then
    F_IN=$(sudo tcpdump -r "$OUT/find.pcap" -nn "port 5353 and ip6 src $PEER6" 2>/dev/null | wc -l)
  else
    F_IN="?"
  fi
  F_OUT=$(sudo tcpdump -r "$OUT/find.pcap" -nn "port 5353" 2>/dev/null | wc -l)
  echo "  mDNS during browse: total=$F_OUT  from_peer=$F_IN  mentioning _airdrop=$F_Q"

  if ! grep -qE "^\s*[0-9]+\)|Found" "$OUT/find.log" 2>/dev/null; then
    echo ""
    echo "  No AirDrop service discovered."
    echo "  AWDL sync works (peer was found), so this is layer 3/4: the phone is"
    echo "  not advertising _airdrop._tcp to us, or is refusing us. Check that"
    echo "  AirDrop is set to 'Everyone for 10 Minutes' and the sheet is open."
  fi
fi

if [ "$MODE" = "receive" ]; then
  echo ""
  echo "### layer 4: advertising as an AirDrop receiver for ${RECV_TIME}s"
  echo "    received files go to $RECV_DIR"
  echo "    On the phone NOW: share sheet -> AirDrop -> tap this machine."
  echo ""
  # THE ACK DISCRIMINATOR. If the phone initiates, it must send unicast to us,
  # and unicast only completes if we ACK. So any frame with the peer as SOURCE
  # during this window proves active monitor really is ACKing - which ping6
  # alone cannot show, since iOS may just ignore pings from an unknown peer.
  sudo timeout $((RECV_TIME + 10)) tcpdump -i $AWDL -w "$OUT/receive.pcap" >/dev/null 2>&1 &
  sleep 1
  # opendrop extracts into its working directory, so run it from RECV_DIR
  mkdir -p "$RECV_DIR"
  # -d so the phone's own request headers land in the log. §31/§32: sending TO
  # the phone is refused on its headers, and every guess about which header has
  # been wrong. The receive direction works, so it is the one place we can read
  # what an Apple sender actually puts on an /Upload rather than theorising. The
  # extra verbosity is worth the ground truth.
  ( cd "$RECV_DIR" && timeout $RECV_TIME "$OPENDROP" -d -i $AWDL receive ) 2>&1 | tee "$OUT/receive.log"
  if grep -q "POST request at" "$OUT/receive.log" 2>/dev/null; then
    echo ""
    echo "### the phone's own request headers (ground truth for the send path)"
    grep -A 8 "POST request at" "$OUT/receive.log" \
      | sed 's/^[0-9-]* [0-9:,]* [A-Z]* *opendrop.server: //' \
      | grep -v "^--$" | sed 's/^/    /'
    echo ""
    if grep -q "POST request at /Upload" "$OUT/receive.log" 2>/dev/null; then
      echo "  /Upload headers captured - this is what the send path must match."
    else
      echo "  NO /Upload yet. /Discover and /Ask are not enough: the send path"
      echo "  fails specifically on /Upload, so its headers are the ones needed."
      echo "  The transfer has to COMPLETE. If it reset partway, that is §28 TX"
      echo "  loss - just run it again."
    fi
  fi
  sudo pkill -x tcpdump 2>/dev/null || true
  sleep 1
  R_TOT=$(sudo tcpdump -r "$OUT/receive.pcap" 2>/dev/null | wc -l)
  if [ -n "${PEER6:-}" ]; then
    R_FROM=$(sudo tcpdump -r "$OUT/receive.pcap" "ip6 src $PEER6" 2>/dev/null | wc -l)
  else
    R_FROM=0
  fi
  echo ""
  echo "  during the receive window: total=$R_TOT from_peer=$R_FROM"

  # Score the run while the artefacts are in front of us. The numbers that
  # matter are bursts/s and the slot offering, not raw throughput: FINDINGS §18
  # showed bytes-per-burst is fixed at ~22-25 kB and cannot be moved from this
  # side, so only more availability windows per second is a real win.
  if [ -s "$OUT/receive.pcap" ] && command -v python3 >/dev/null 2>&1; then
    echo ""
    echo "### burst structure (strategy: $STRATEGY)"
    python3 "$HERE/tools/bursts.py" "$OUT/receive.pcap" 2>/dev/null | sed 's/^/  /' || true
    echo ""
    echo "### what the peers were offering"
    python3 "$HERE/tools/slotmap.py" --log "$OUT/owl.log" --chan "$CHAN" 2>/dev/null |
      sed 's/^/  /' || true
    echo ""
    echo "  Compare against another strategy with:"
    echo "    tools/bursts.py $OUT/receive.pcap --baseline runs/<other>/receive.pcap"
  fi
  if [ "${R_FROM:-0}" -gt 0 ]; then
    echo "  *** THE PHONE SENT US $R_FROM PACKETS - the path is TWO-WAY ***"
    echo "  Unicast reached us, so the chip IS ACKing: active monitor works in"
    echo "  the pair configuration. Anything failing past here is auth (§7),"
    echo "  not the radio."
  else
    echo "  ==> still nothing from the phone, even when IT initiates."
    echo "  Check the ping6 result above first. If that also failed, this is a"
    echo "  TX problem and not an auth one - our frames are not reaching the"
    echo "  phone at all, so nothing at the service layer can succeed."
    echo "  The old reading here blamed mt76 not honouring"
    echo "  NL80211_FEATURE_ACTIVE_MONITOR. That is not settled: ACKs were"
    echo "  confirmed working in §15, and again on 2026-07-31 with ping6 at 5/5,"
    echo "  so the chip CAN ACK in the pair configuration. Suspect the software"
    echo "  before reaching for a driver patch or the AR9271."
  fi
elif [ "$MODE" = "send" ]; then
  echo ""
  # Sending needs a discovery report, and `opendrop send` reports a missing one
  # as "please run 'opendrop find' first" - which is confusing when find DID run
  # and simply found nobody. Say what actually happened instead.
  if ! grep -qE "^\s*[0-9]+\)|Found" "$OUT/find.log" 2>/dev/null; then
    echo "### cannot send: no AirDrop receiver was discovered."
    echo ""
    echo "  AWDL sync worked, so the radio is fine. Two usual causes:"
    echo ""
    echo "  1. The phone's AWDL is asleep. Apple wakes a receiver with a"
    echo "     Bluetooth LE Continuity advertisement. OWL and OpenDrop cannot"
    echo "     send one, but tools/blewake.sh now can:"
    echo ""
    echo "         ./tools/blewake.sh            # leave running in another terminal"
    echo "         ./airdrop.sh send <file>"
    echo ""
    echo "     Set the phone to AirDrop > Everyone and leave the share sheet"
    echo "     CLOSED for this - an open sheet makes it a sender, and a sender"
    echo "     never advertises _airdrop._tcp for us to find. Control Centre is"
    echo "     NOT enough either; measured, it leaves AWDL completely asleep."
    echo ""
    echo "  2. The share sheet route: open a share sheet on the phone and leave"
    echo "     it open. This is what worked for receiving. It does NOT work for"
    echo "     sending, for the reason in (1) - it is listed only because it is"
    echo "     the thing to try if blewake.sh turns out not to wake the phone."
    echo ""
    echo "  NOT the cause: FIND_TIME. It is a ceiling, not a duration - the"
    echo "  browse stops the moment a receiver appears - and raising it has"
    echo "  never once turned a failure into a success. Every failure so far has"
    echo "  been categorical."
    echo ""
    echo "  On the phone: unlock it, AirDrop > Everyone for 10 Minutes (this"
    echo "  EXPIRES - re-arm it)."
    exit 1
  fi
  echo "### discovered receivers:"
  grep -oP 'Found\s+index\s+\K.*' "$OUT/find.log" | sed 's/^/    index /'
  echo ""
  # WHICH PHONE? -r takes an index, a 12-char ID, or the device name. Index is
  # positional and depends on which device answered mDNS first, so with several
  # Apple devices in range - and "Everyone" makes every one of them a candidate -
  # index 0 is a coin toss. Prefer the NAME:
  #     RECEIVER="Jed's iPhone" ./airdrop.sh send photo.jpg
  # Default to the ID of the first device THIS run found, not to index 0.
  #
  # Index 0 is worse than it looks. opendrop's _get_receiver_info() does
  # int(receiver), indexes the report, and on IndexError falls through to
  # len(receiver) -- which is now an int, so an empty or short report does not
  # produce "receiver does not exist" but a TypeError traceback. That is exactly
  # what a stale report gave us, and it reads as an opendrop crash rather than as
  # "the report is empty". An ID from this run's own log cannot be stale, and
  # unlike an index it is not positional, so extra Apple devices in range cannot
  # silently redirect the transfer.
  DISCOVERED_ID=$(grep -oP 'Found\s+index\s+\S+\s+ID\s+\K[0-9a-f]{12}' "$OUT/find.log" | head -1)
  RECEIVER="${RECEIVER:-${DISCOVERED_ID:-0}}"
  case "$RECEIVER" in
    [0-9]) echo "    sending to index $RECEIVER - no ID was parsed, so this is positional" ;;
    *)     echo "    sending to \"$RECEIVER\"" ;;
  esac
  echo ""
  echo "### layer 4: sending $SENDFILE"
  # CAPTURE THE SEND. The first run to get this far died with "Remote end closed
  # connection without response" on /Upload, and there was nothing to look at:
  # the layer-2.5 capture had already been stopped, so the only TCP in the pcap
  # was the ping. A transfer that fails after "Receiver accepted" is a
  # conversation, and a conversation has to be recorded to be read.
  #
  # SSLKEYLOGFILE makes it readable rather than just present - opendrop's
  # get_ssl_context() is patched to honour it. Decrypt with:
  #   tshark -r send.pcap -o tls.keylog_file:sslkeys.log -Y http
  sudo tcpdump -i $AWDL -n -s 0 -U -w "$OUT/send.pcap" >/dev/null 2>&1 &
  sleep 1
  SSLKEYLOGFILE="$OUT/sslkeys.log" "$OPENDROP" -i $AWDL send -r "$RECEIVER" -f "$SENDFILE" 2>&1 | tee "$OUT/send.log"
  sleep 1
  sudo pkill -x tcpdump 2>/dev/null || true
  if [ -s "$OUT/send.pcap" ]; then
    echo ""
    echo "  send captured: $OUT/send.pcap"
    if [ -s "$OUT/sslkeys.log" ]; then
      echo "  TLS keys logged - read the HTTP exchange with:"
      echo "      tshark -r $OUT/send.pcap \\"
      echo "        -o tls.keylog_file:$OUT/sslkeys.log -Y http"
    fi
  fi
else
  echo ""
  echo "### discovery-only mode. Re-run with:"
  echo "      ./airdrop.sh receive          - advertise, then send FROM the phone"
  echo "      ./airdrop.sh send <file>      - try to send TO the phone"
  echo ""
  echo "    'receive' is the better bet: sending from the phone to Linux is the"
  echo "    direction that has historically been less gated by auth."
fi
