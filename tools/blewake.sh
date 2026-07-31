#!/bin/bash
# Broadcast the Apple Continuity "AirDrop" BLE advertisement, to wake a nearby
# iPhone's AWDL interface so it will act as an AirDrop *receiver*.
#
# WHY THIS EXISTS (FINDINGS §19, and the sender/receiver pincer)
#
# Receiving from an iPhone works. Sending to one does not, and the blocker is
# not in OWL or OpenDrop - it is that the phone's AWDL interface is asleep:
#
#   - Share sheet OPEN  -> AWDL is awake, but the phone is a *sender*. It
#                          queries _airdrop._tcp and never advertises it, so
#                          there is nothing for us to send to.
#   - Share sheet CLOSED -> the phone would advertise as a receiver, but AWDL
#                          is asleep.
#
# Apple's own bootstrap out of that deadlock is Bluetooth. From Stute et al.
# (USENIX Security '19): when a sender opens the share sheet it emits BLE
# advertisements carrying truncated hashes of its contact identifiers, and
# "the receiver activates their AWDL interface if at least one contact match
# was found in contacts-only mode, OR IF IT IS DISCOVERABLE BY EVERYONE".
#
# That last clause is the opening. With the target phone set to
# Settings -> General -> AirDrop -> Everyone, the hashes do not have to match
# anything - any well-formed AirDrop advertisement should be enough to wake it.
# In contacts-only mode you need hashes of an identifier already in its address
# book, which --email / --phone below will compute for you.
#
# WIRE FORMAT (furiousMAC/continuity, message type 0x05)
#
#   AD structure:  17 FF          length 23, manufacturer-specific data
#                  4C 00          company 0x004C = Apple, little endian
#                  05             Continuity message type: AirDrop
#                  12             length 18
#                  00 x8          zero prefix
#                  01             AirDrop version
#                  HH HH          first 2 bytes of SHA256(Apple ID)
#                  HH HH          first 2 bytes of SHA256(phone number)
#                  HH HH          first 2 bytes of SHA256(email)
#                  HH HH          first 2 bytes of SHA256(second email)
#                  00             zero suffix
#
# Verified 2026-07-31 on this machine: BlueZ's own btmon dissector decodes the
# result as "Company: Apple, Inc. (76) / Type: AirDrop (5) / Data[18]", so the
# framing is right. Whether an iPhone actually wakes on it is UNTESTED - that
# needs a phone in the room.
#
# NOTE ON TOOLING: hcitool cmd cannot be used here. bluetoothd owns the
# controller and every raw HCI advertising command comes back 0x0C "Command
# Disallowed". btmgmt goes through the kernel management API and coexists with
# bluetoothd, which is why it is used instead. btmgmt also reads stdin and will
# drop into an interactive shell if a command errors, so every call redirects
# from /dev/null.

set -u

INSTANCE="${INSTANCE:-1}"
DURATION="${DURATION:-0}"     # 0 = run until interrupted
APPLEID=""
PHONE=""
EMAIL=""
EMAIL2=""
VERIFY=0

usage() {
	cat <<EOF
usage: $0 [options]

  --appleid <id>   compute the Apple ID hash from this identifier
  --phone <num>    compute the phone-number hash (use the form stored in the
                   target's address book, e.g. +64211234567)
  --email <addr>   compute the email hash
  --email2 <addr>  compute the second email hash
  --duration <s>   stop advertising after this many seconds (default: run until Ctrl-C)
  --verify         dump the advertisement back out of btmon to confirm the framing
  -h, --help       this

With no identifiers the hash fields are zero. That is fine when the target
phone is set to AirDrop -> Everyone, which is the configuration to test first.
For contacts-only you must supply an identifier that is already in the target's
address book.
EOF
	exit 0
}

while [ $# -gt 0 ]; do
	case "$1" in
		--appleid) APPLEID="$2"; shift 2 ;;
		--phone)   PHONE="$2";   shift 2 ;;
		--email)   EMAIL="$2";   shift 2 ;;
		--email2)  EMAIL2="$2";  shift 2 ;;
		--duration) DURATION="$2"; shift 2 ;;
		--verify)  VERIFY=1; shift ;;
		-h|--help) usage ;;
		*) echo "unknown option: $1" >&2; exit 2 ;;
	esac
done

if [ "$(id -u)" = "0" ]; then
	echo "run this as a normal user; it calls sudo where it needs to" >&2
	exit 1
fi

# First 2 bytes of SHA256(identifier), or 0000 for an empty identifier.
hash2() {
	if [ -z "$1" ]; then
		printf '0000'
	else
		printf '%s' "$1" | sha256sum | cut -c1-4
	fi
}

H_APPLEID=$(hash2 "$APPLEID")
H_PHONE=$(hash2 "$PHONE")
H_EMAIL=$(hash2 "$EMAIL")
H_EMAIL2=$(hash2 "$EMAIL2")

ZERO_PREFIX="0000000000000000"   # 8 bytes, fixed by the format
ADV="17FF4C000512${ZERO_PREFIX}01${H_APPLEID}${H_PHONE}${H_EMAIL}${H_EMAIL2}00"

RESTORED=0
restore() {
	[ "$RESTORED" = "1" ] && return
	RESTORED=1
	echo
	echo "removing advertising instance $INSTANCE"
	timeout 10 sudo btmgmt rm-adv "$INSTANCE" </dev/null >/dev/null 2>&1 || true
}
trap 'restore' EXIT
trap 'restore; exit 130' INT TERM

# A detached watchdog, so the advertisement is torn down even if this script is
# SIGKILLed - the same rule the monitor-mode harnesses in this repo follow. An
# advertising instance left behind keeps broadcasting indefinitely and is not
# obvious from any UI.
setsid bash -c "
  for _ in \$(seq 1 1800); do
    sleep 1
    kill -0 $$ 2>/dev/null || { timeout 10 sudo btmgmt rm-adv $INSTANCE </dev/null >/dev/null 2>&1; exit 0; }
  done
  timeout 10 sudo btmgmt rm-adv $INSTANCE </dev/null >/dev/null 2>&1
" >/dev/null 2>&1 &

echo "AirDrop Continuity BLE advertisement"
echo "  advertising data : $ADV"
echo "  apple id hash    : $H_APPLEID  ${APPLEID:-(empty)}"
echo "  phone hash       : $H_PHONE  ${PHONE:-(empty)}"
echo "  email hash       : $H_EMAIL  ${EMAIL:-(empty)}"
echo "  email2 hash      : $H_EMAIL2  ${EMAIL2:-(empty)}"
echo

# Clear any leftover instance from a previous run before claiming the slot.
timeout 10 sudo btmgmt rm-adv "$INSTANCE" </dev/null >/dev/null 2>&1 || true

BTMON_PID=""
if [ "$VERIFY" = "1" ]; then
	BTLOG=$(mktemp -t blewake-XXXXXX.log)
	sudo btmon -w "$BTLOG" >/dev/null 2>&1 &
	BTMON_PID=$!
	sleep 1
fi

if ! timeout 15 sudo btmgmt add-adv -d "$ADV" -g "$INSTANCE" </dev/null 2>&1 | grep -q "Instance added"; then
	echo "failed to register the advertising instance" >&2
	[ -n "$BTMON_PID" ] && sudo kill "$BTMON_PID" 2>/dev/null
	exit 1
fi
echo "advertising (instance $INSTANCE)"

if [ "$VERIFY" = "1" ]; then
	sleep 2
	sudo kill "$BTMON_PID" 2>/dev/null
	sleep 1
	echo
	echo "--- as decoded by btmon on the way to the controller ---"
	# Only the OUTGOING Set Extended Advertising Data command. Grepping for
	# "Company: Apple" alone matches every Continuity advertisement from every
	# Apple device in the room, which is misleading in exactly the direction
	# that would make a broken payload look fine.
	sudo btmon -r "$BTLOG" 2>/dev/null |
		awk '/^< HCI Command: LE Set Extended Adv.*0x0037/ {p=1} p{print} p&&/Type: AirDrop/{c=6} c&&c--==1{exit}' |
		head -20
	rm -f "$BTLOG"
	echo "-------------------------------------------------------"
	echo
fi

cat <<EOF
Now, on the iPhone:
  1. Settings -> General -> AirDrop -> Everyone (for 10 Minutes is fine).
  2. Leave the share sheet CLOSED. That is the whole point - an open share
     sheet makes the phone a sender, and a sender never advertises
     _airdrop._tcp for us to find.
  3. In another terminal, look for it:
       ./airdrop.sh send <file>
     or just watch for the service:
       .venv-opendrop/bin/opendrop -i awdl0 find

What success looks like: 'opendrop find' lists a receiver while the share
sheet is closed. That has never happened yet - every previous attempt found
nothing, because nothing was waking the phone's AWDL.
EOF

if [ "$DURATION" != "0" ]; then
	echo
	echo "advertising for ${DURATION}s"
	sleep "$DURATION"
else
	echo
	echo "advertising until interrupted (Ctrl-C)"
	while true; do sleep 3600; done
fi
