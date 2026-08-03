# airdrop-mt7921

AirDrop on Linux using the **built-in MediaTek MT7921** Wi-Fi chip, with no USB
adapter.

Sending to **and** receiving from an iPhone on iOS 26 both work, end to end,
with no Apple ID and no signed identity. This repo is the script that sets it up,
the OpenDrop patches that make iOS 26 transfers parse and send, and the research
that got there.

> **Unsupported personal fork / personal project.** This is my own work, done on
> my own laptop, published in case it is useful. It is not affiliated with the
> Open Wireless Link project, OpenDrop, or Apple. There is no support, no
> warranty, and no promise that it works on your hardware. Issues and PRs may
> sit unread.

## Documentation
- [docs/FINDINGS.md](docs/FINDINGS.md) - numbered session-by-session findings log
- [docs/NOTES.md](docs/NOTES.md) - project notes
- [patches/README.md](patches/README.md) - what each opendrop patch does and why
- [tools/README.md](tools/README.md) - diagnostic tool scripts

## Why this exists

Every guide for AirDrop on Linux tells you the same thing: you need a card with
working **active monitor mode**, and in practice that means buying an Atheros
AR9271 or AR9280 USB adapter. Upstream OWL's README says it outright.

The MT7921 was believed not to qualify. An active monitor vif on this chip is
pinned to 5180 MHz no matter what you ask for, and appears to destroy reception
while it is up.

Both halves of that turn out to be wrong, and the way around it is a
configuration, not a patch:

**Create a plain monitor vif first and tune it. Then add the active vif
alongside it.** They share one channel context. The active vif comes up on the
plain vif's channel with no reception penalty, and retuning either one moves
both - so you keep hardware ACKs *and* AWDL channel hopping.

That is the whole trick. Details, including the two false conclusions I reached
before finding it, are in [docs/FINDINGS.md](docs/FINDINGS.md) §13-§14.

## Status

| | |
|---|---|
| Receiving from an iPhone | **works** (iOS 26, proven end to end) |
| Sending to an iPhone | **works** (iOS 26, `POST /Upload -> 200`, file delivered - see [FINDINGS §37](docs/FINDINGS.md)) |
| Receive throughput | ~40-45 kB/s with `-S verbatim` - ~22 kB per availability window, ~1.8 windows/s ([§18](docs/FINDINGS.md)) |
| Send throughput | not yet measured - the proving run sent a 68-byte file; needs a real file + `tools/bursts.py` |
| Hardware tested | MT7921 (Filogic 330), Void Linux, kernel 6.18.33 |

The auth wall that everyone warns about was never reached, in **either**
direction. In **Everyone** mode an iPhone both accepts an unsigned receiver and
accepts an upload from an unsigned sender - no Apple ID, no push token, no signed
validation record. Contacts-only would need an Apple-key-signed validation record
and is genuinely not forgeable.

**What made sending work** ([§37](docs/FINDINGS.md)): the whole block was one
missing field. Our `/Ask` never declared a `TransferID`, but the `/Upload` header
asserted a fresh one, so the phone had no accepted transfer to bind the upload to
and refused it on the headers before reading the body. A real iOS 26 sender
announces `TransferID={'id': UUID}` in its `/Ask` body and repeats the same id on
`/Upload`. Do the same and the phone takes the file. It was never an auth wall.

## Requirements

- An MT7921 (or likely any `mt76`) card. Others may work; nothing here is
  MT7921-specific except the two driver workarounds below.
- `iw`, `tcpdump`, `libpcap`, `libev`, `libnl`
- A patched OWL build - see below
- OpenDrop, patched with `patches/opendrop-ios26-airdrop.patch`
- Root, and a willingness to lose networking for the duration of a run

## Setup

**1. Build the patched OWL.** Upstream OWL will sync but will not give you good
throughput; my fork adds the two mt7921 workarounds and the channel-sequence
fix:

```sh
git clone https://github.com/jedbillyb/owl.git ~/owl
cd ~/owl && cmake -S . -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build
```

**2. Install and patch OpenDrop.** Stock OpenDrop cannot complete an iOS 26
transfer in either direction. The patches are applied in order, in place, inside
the venv - see [patches/README.md](patches/README.md) for what each one does and
why:

```sh
python -m venv ~/owl/.venv-opendrop
~/owl/.venv-opendrop/bin/pip install opendrop
cd ~/owl/.venv-opendrop/lib/python*/site-packages
for p in ios26-airdrop recv-window py314-send mdns-repeat find-report \
         tls-keylog upload-arms; do
  git apply /path/to/airdrop-mt7921/patches/opendrop-$p.patch
done
```

The first two make **receiving** work; the rest make **sending** work
(`py314-send` unbreaks the send path on modern Python, `mdns-repeat` gets the
phone to answer, `find-report` hands the receiver to `send`, `tls-keylog` makes
failures decryptable, and `upload-arms` carries the `TransferID` fix that
delivers the file). Void has no `patch(1)`; `git apply` is what the patches are
verified against.

**3. Run it.**

```sh
./airdrop.sh receive          # advertise this machine as an AirDrop target
./airdrop.sh                  # discover nearby devices only
./airdrop.sh send <file>      # send to a phone
```

On the phone, always: **Settings → General → AirDrop → Everyone for 10 Minutes**
(this expires - re-arm it). The rest depends on direction, because the phone
plays opposite roles:

- **Receiving** (`./airdrop.sh receive`): the phone is the *sender*. **Open a
  share sheet and leave it open** - that wakes its AWDL and lets it query for you.
- **Sending** (`./airdrop.sh send <file>`): the phone must be the *receiver*, so
  **do not open a share sheet** (that puts it in sender mode, where it queries but
  never advertises). Just keep the phone unlocked and awake. The script wakes the
  phone's AWDL over Bluetooth LE itself (see below), then discovers it.

**The Bluetooth LE bootstrap.** Apple bootstraps AirDrop discovery over BLE: a
sender broadcasts a Continuity advertisement, and that is what wakes a nearby
receiver's AWDL interface. For *receiving*, opening the share sheet is how a user
forces the phone's AWDL up. For *sending*, `tools/blewake.sh` emits that
advertisement for us - and `airdrop.sh send` now starts it automatically, because
the MT7921 is a combined Wi-Fi/BT chip and reconfiguring Wi-Fi resets the BT
controller, so the advert has to come up *after* the radio is set
([§36](docs/FINDINGS.md)).

Measured on this hardware, sweeping all five AWDL social channels:

| phone state | AWDL frames heard |
|---|---|
| share sheet open | sync established, peer found |
| Control Centre only | **zero, on every channel** |

So Control Centre is not enough, and a phone sitting locked on a desk is
invisible no matter what AirDrop is set to.

### Which phone am I sending to?

`AirDrop → Everyone` makes *every* Apple device in range a candidate, and the
default `-r 0` picks whichever answered mDNS first. Check the discovered list the
script prints, then select by name rather than position:

```sh
RECEIVER="Jed's iPhone" ./airdrop.sh send photo.jpg
```

Files land in `~/Downloads`. Per-run logs and captures go to `./runs/`.

### Configuration

All optional, all environment variables:

| variable | default | meaning |
|---|---|---|
| `IFACE` | autodetected mt7921 interface | Wi-Fi interface |
| `REG` | `NZ` | regulatory domain - **set this to your country** |
| `CHAN` | `36` | starting channel (6, 36, 44, 149) |
| `OWL_DIR` | `~/owl` | your patched OWL checkout |
| `RECV_DIR` | `~/Downloads` | where received files are extracted |
| `RECV_TIME` | `300` | seconds to stay advertising |
| `OUT_DIR` | `./runs` | where logs and captures go |
| `STRATEGY` | `verbatim` | how OWL derives its channel sequence: `verbatim`, `widen`, `rotate`, `pin`. `verbatim` is the default because `pin` breaks TX to iOS 26 ([§25](docs/FINDINGS.md)) |

## Open questions

Two throughput questions remain; both need a human and a phone in the room.

**1. How fast is sending?** Sending is proven to *work* ([§37](docs/FINDINGS.md))
but the proving run sent a 68-byte file, which measures nothing. Send a real one
and read the rate:

```sh
./airdrop.sh send ~/some-photo.jpg
tools/bursts.py runs/<send-run>/send.pcap
```

The `send` TX path is hardcoded to 12 Mbit/s legacy OFDM (`src/tx.c`, under
upstream's own TODO), so send may well be slower than the ~45 kB/s receive
ceiling. Unknown until measured.

**2. Does widening the channel sequence beat `verbatim` on receive?**
[§21](docs/FINDINGS.md) argues the ~45 kB/s ceiling is the 2-of-16-slot sequence
we copy, while the phone offers up to 11 of 16. `-S pin` (all 16 slots) was the
first attempt and **breaks TX to iOS 26** ([§25](docs/FINDINGS.md)) - it is
disqualified. `-S widen -W n` keeps the peer's own sequence and fills only its
empty slots, which iOS 26 *does* accept ([§26](docs/FINDINGS.md)). To settle it:

```sh
STRATEGY=verbatim ACTIVE=1 ./airdrop.sh receive     # reproduce the baseline
STRATEGY=widen    ACTIVE=1 ./airdrop.sh receive     # the change under test

tools/bursts.py runs/<widen-run>/receive.pcap \
   --baseline runs/<verbatim-run>/receive.pcap
```

Read **bursts per second**, not throughput. §18 established that bytes per
availability window is fixed at ~22-25 kB and cannot be moved from this side, so
window count is the only real lever. **Check first whether the run was winnable:**
if `tools/slotmap.py --log runs/<run>/owl.log` shows the peer never offered more
than 2 of 16 slots, there was nothing to gain and the run proves nothing.

The predictions and their falsification conditions are written down in §21 in
advance, because the earlier confident diagnoses in this project were more than
once contradicted by their own logs.

## Safety

By default `airdrop.sh` takes the Wi-Fi card exclusively - **you have no internet
while it runs**. It restores NetworkManager on exit via a bash trap *and* a
`setsid`-detached watchdog, so networking comes back even if the script is
`kill -9`ed or hangs. Init system is detected (runit or systemd).

### Keeping your internet: `KEEP_WIFI=1`

```sh
KEEP_WIFI=1 ACTIVE=1 ./airdrop.sh receive
```

The monitor vifs coexist with an associated managed vif perfectly well - that
was measured, with a concurrent ping at 0% loss across a full run (FINDINGS
§38). The exclusive-card rule was never about the interfaces; it was about the
channel.

The catch is that the monitor vif then gets **no channel of its own** and is
locked to whatever channel your AP is on (`iw dev mon0 set freq` returns EBUSY).
So this mode only works when **your AP happens to be parked on a channel the
phone's AWDL sequence uses** - 36, 44, 149 or 6. It refuses up front if your AP
is somewhere else, rather than failing later in a way that looks like a dozen
other problems.

That is less alarming than it sounds: OWL's channel hopping was already fiction
in every working transfer (§24), so the radio has always been effectively pinned
to one channel. `KEEP_WIFI` only changes who chooses it.

**Not yet proven to complete a transfer** - only to coexist. If you want Wi-Fi
and AirDrop simultaneously with no conditions attached without touching your
AP's channel, that constraint is gone as of 2026-08-03: see
[`mt7921-dual-channel`](https://github.com/jedbillyb/mt7921-dual-channel)
(despite an earlier repo name, no kernel patch is involved). A
P2P-GO vif plus a MAC-aliased monitor vif lets a single MT7921 pick AWDL's
channel independently of the AP's, on a stock kernel, and it has now also been
shown to survive a real Wi-Fi reassociation.

This mechanism **is now ported into `daemon/airdropd`**, as an opt-in mode
(`AIRDROP_DUALCHAN=1`) rather than the default - it's newer and less proven
than the AP-channel mode above, and carries its own open questions (active-
monitor ACKs against a GO chanctx untested, ~40-590ms added latency the whole
time `go0` is up). See [`daemon/README.md`](daemon/README.md#p2p-go-mode-airdrop_dualchan1--opt-in-less-proven-than-the-default)
for the details. It is **not** wired into the plain `KEEP_WIFI=1` /
`airdrop.sh` path, only the daemon. Until either mode is shown to complete a
real transfer, the fallback for "Wi-Fi and AirDrop simultaneously with no
conditions attached, no caveats" is still giving AWDL its own radio (an
AR9271 on USB): two phys, no shared channel context.

## Two mt7921 driver bugs you will hit

Both are worked around by `airdrop.sh`; both cost me a day each, so they are
worth stating plainly:

1. **Runtime power management silently kills monitor RX.** With `runtime-pm=1`
   the chip dozes and you capture nothing, with no error anywhere. Set
   `runtime-pm` and `deep-sleep` to 0 in
   `/sys/kernel/debug/ieee80211/<phy>/mt76`.
2. **An in-place interface type switch never retunes the radio.** `iw dev X set
   type monitor` leaves the radio where it was. You must create a *dedicated*
   monitor vif.

And a methodology note that cost me more than either: **on this chip `iw` lies
about the channel.** It reports what you asked for, not where the radio is. The
only trustworthy source is the radiotap frequency on captured frames. Two of the
retracted conclusions in `docs/FINDINGS.md` come from trusting `iw`.

## Repo layout

```
airdrop.sh          the tool
patches/            OpenDrop fixes for iOS 26
docs/FINDINGS.md    the full investigation, including what I got wrong
docs/NOTES.md       dated lab notebook
tools/              diagnostic harnesses, each answering one question
```

`tools/` is research, not a test suite. Each script isolates one question and
restores your networking afterwards. `activelate2.sh` and `activelate3.sh` are
the two that establish the pair configuration this whole project rests on.

## Credit

- [seemoo-lab/owl](https://github.com/seemoo-lab/owl) - the AWDL implementation
- [seemoo-lab/opendrop](https://github.com/seemoo-lab/opendrop) - the AirDrop layer
- The [Open Wireless Link](https://owlink.org) project's reverse engineering

## Licence

GPLv3, matching OWL.
