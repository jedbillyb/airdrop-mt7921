# airdrop-mt7921

AirDrop on Linux using the **built-in MediaTek MT7921** Wi-Fi chip, with no USB
adapter.

Receiving a photo from an iPhone on iOS 26 works, end to end. This repo is the
script that sets it up, the OpenDrop patches that make iOS 26 transfers parse,
and the research that got there.

> **Unsupported personal fork / personal project.** This is my own work, done on
> my own laptop, published in case it is useful. It is not affiliated with the
> Open Wireless Link project, OpenDrop, or Apple. There is no support, no
> warranty, and no promise that it works on your hardware. Issues and PRs may
> sit unread.

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
| Sending to an iPhone | **untested** |
| Throughput | ~50 kB/s - a duty-cycle limit, see [FINDINGS §16](docs/FINDINGS.md) |
| Hardware tested | MT7921 (Filogic 330), Void Linux, kernel 6.12.97 |

The auth wall that everyone warns about was never reached. In **Everyone** mode
an iPhone accepts an unsigned receiver. Contacts-only would need an
Apple-key-signed validation record and is genuinely not forgeable.

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

**2. Install and patch OpenDrop.** iOS 26 breaks stock OpenDrop in three
independent places - see [patches/README.md](patches/README.md):

```sh
python -m venv ~/owl/.venv-opendrop
~/owl/.venv-opendrop/bin/pip install opendrop
git apply --directory=... patches/opendrop-ios26-airdrop.patch   # see patches/README.md
```

**3. Run it.**

```sh
./airdrop.sh receive          # advertise this machine as an AirDrop target
./airdrop.sh                  # discover nearby devices only
./airdrop.sh send <file>      # send to a phone
```

On the phone, **Settings → General → AirDrop → Everyone for 10 Minutes** — and
then it depends which way you are going, because the two directions want
*opposite* things:

| you want to | phone's role | open on the phone |
|---|---|---|
| **receive** from the phone | sender | the **share sheet** |
| **send** to the phone | receiver | **Control Centre** (long-press the connectivity tile) |

With the share sheet open, iOS browses for receivers and does not advertise
`_airdrop._tcp` at all - so a send will find nothing and report no receivers.

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

## Safety

`airdrop.sh` takes the Wi-Fi card exclusively - **you have no internet while it
runs**. It restores NetworkManager on exit via a bash trap *and* a
`setsid`-detached watchdog, so networking comes back even if the script is
`kill -9`ed or hangs. Init system is detected (runit or systemd).

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
