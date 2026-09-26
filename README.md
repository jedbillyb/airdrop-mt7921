# airdrop-mt7921

AirDrop on Linux using the **built-in MediaTek MT7921** Wi-Fi chip, with no USB
adapter.

Sending to **and** receiving from an iPhone on iOS 26 both work, end to end,
with no Apple ID and no signed identity. This repo is the script that sets it up,
the OpenDrop patches that make iOS 26 transfers parse and send, and the research
that got there.

> **Independent project.** It started as my own work on my own laptop, and it is now built together with [Alban Peralta](https://github.com/Peralban), who brought it to the MT7922 and wrote much of the sending path (see [Credit](#credit)). It is published in case it is useful, and it is not affiliated with the Open Wireless Link project, OpenDrop, or Apple. There is no warranty, and no promise that it works on your hardware. Issues and PRs may be slow to respond, but I do try to help when I can.

## Support

If you need help or run into issues:

- **Email:** [hello@jedbillyb.com](mailto:hello@jedbillyb.com)
- **Website:** [jedbillyb.com](https://jedbillyb.com) for other contact methods
- **GitHub Issues:** Open an issue in this repo

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
| Receive throughput | 45-67 kB/s with `-S verbatim`, varying run to run with the sequence the peer advertises - ~22 kB per availability window ([§18](docs/FINDINGS.md)) |
| Send throughput | not yet measured - the proving run sent a 68-byte file; needs a real file + `tools/bursts.py` |
| Wi-Fi at the same time | **works**, via P2P-GO ([§46](docs/FINDINGS.md)); costs ~200-400 ms uplink latency while up |
| Hardware tested | MT7921 (Filogic 330), Void Linux, kernel 6.18.33; MT7922 (`14c3:0616`) on Hyprland by a contributor ([#2](https://github.com/jedbillyb/airdrop-mt7921/issues/2)) |

**Two paths, and they are at different stages.** The standalone `airdrop.sh` is
the proven one: a full 2.56 MB photo, byte-exact and PIL-verified, in 40 s at
~67 kB/s. It takes the card exclusively, so you have no internet while it runs.
The `daemon/airdropd` waybar switch keeps your Wi-Fi up and has carried a real
transfer to **99.1%**, but has not yet been seen to complete one on the MT7921
(it has on an MT7922, receive and send) - see
[`daemon/README.md`](daemon/README.md#limitations) for exactly what is and is
not proven there.

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
  (`airdrop.sh` only - the `daemon/` path keeps the association up and needs a
  5 GHz AP plus the patched hostapd instead; see
  [`daemon/README.md`](daemon/README.md))

## Setup

**1. Build the patched OWL.** Upstream OWL will sync but will not give you good
throughput; my fork adds the two mt7921 workarounds and the channel-sequence
fix:

```sh
git clone https://github.com/jedbillyb/owl.git ~/owl
cd ~/owl && cmake -S . -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build
```

`~/owl` is the default, but a checkout sitting beside this repo is found too, so
`projects/owl` next to `projects/airdrop-mt7921` needs no configuration. Anywhere
else, set `OWL_DIR`. A missing OWL binary makes `airdropd run` exit before it
opens its log, so the only trace is `missing or not executable` on stderr that
the waybar toggle throws away - the bar just falls straight back to `drop off`.

**2. Install and patch OpenDrop.** Stock OpenDrop cannot complete an iOS 26
transfer in either direction. The patches are applied in order, in place, inside
the venv - see [patches/README.md](patches/README.md) for what each one does and
why:

```sh
python -m venv ~/owl/.venv-opendrop
~/owl/.venv-opendrop/bin/pip install opendrop==0.13.0
cd ~/owl/.venv-opendrop/lib/python*/site-packages
for p in ios26-airdrop recv-window py314-send mdns-repeat find-report tls-keylog \
         upload-arms ask-confirm mdns-reannounce threaded-server url-items \
         zeroconf-update-service salvage-truncated salvage-trim \
         send-multifile send-status; do
  git apply /path/to/airdrop-mt7921/patches/opendrop-$p.patch || break
done
```

The patches are a series: each one is made against the result of the ones
before it, so apply all sixteen, in exactly this order, to a clean OpenDrop
0.13.0. `url-items` in particular will not apply without the three daemon
patches ahead of it. If a `git apply` fails, rebuild the venv rather than
retrying on a half-patched tree.

`pip install 'setuptools<81'` into that venv as well. OpenDrop 0.13.0 imports
`pkg_resources` at module scope, Python 3.12+ venvs no longer ship setuptools,
and setuptools 81 removed `pkg_resources` outright - so on a modern Python the
receiver dies with `ModuleNotFoundError: No module named 'pkg_resources'` before
it opens a socket. Through the daemon that surfaces as `receiver never started
listening`, with the traceback only in the log.

The first two make **receiving** work, `url-items` adds received **links** (see
[Receiving a link](#receiving-a-link)), and the rest make **sending** work
(`py314-send` unbreaks the send path on modern Python, `mdns-repeat` gets the
phone to answer, `find-report` hands the receiver to `send`, `tls-keylog` makes
failures decryptable, and `upload-arms` carries the `TransferID` fix that
delivers the file). `ask-confirm`, `mdns-reannounce` and `threaded-server` are
what the always-on daemon needs (the accept prompt, staying visible, and not
wedging on iOS keep-alive; see [daemon/README.md](daemon/README.md)).
`zeroconf-update-service` stops a re-announcing device from killing discovery,
`salvage-truncated` and `salvage-trim` keep what arrived of a transfer that was
cut off, `send-multifile` sends several files as one transfer and one Accept,
and `send-status` makes `opendrop send` exit non-zero when a send fails. Void has
no `patch(1)`; `git apply` is what the patches are verified against.

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

### Sending from the file manager

**Proven on an MT7922, not yet on the MT7921.** Alban Peralta has sent to an
iPhone through `airdropd send`, attached to the always-on stack, with Wi-Fi up
the whole time and nothing taking the card exclusively
([#2](https://github.com/jedbillyb/airdrop-mt7921/issues/2),
[#9](https://github.com/jedbillyb/airdrop-mt7921/pull/9)). Every one of those
sends had the bluetoothd advert from
[#8](https://github.com/jedbillyb/airdrop-mt7921/pull/8) (`tools/blewake-dbus.py`)
running alongside; a run with only the daemon's own `btmgmt` advert did not find
the phone. The daemon still uses `btmgmt`, so start `tools/blewake-dbus.py`
yourself for a send.

On the MT7921, sending has only ever completed through `airdrop.sh send` in
exclusive mode (`ACTIVE=1`, Wi-Fi dropped for the run). If the right-click
finds nobody there, try `ACTIVE=1 ./airdrop.sh send <file>` before debugging
the daemon. Details in
[daemon/README.md](daemon/README.md#known-good-and-not-yet-proven).

`airdrop.sh send` owns the radio, so it cannot run while the waybar toggle is
on. `airdropd send` can - it attaches to the running stack instead of building
its own - and that is what the Thunar right-click uses:

```sh
sudo ln -s "$PWD/daemon/airdrop-send" /usr/local/bin/airdrop-send  # symlink, not a copy
thunar -q                                                          # it rewrites uca.xml on exit
tools/install-thunar-action.sh                                     # --remove undoes it
```

Then select any files, right-click, **Send via AirDrop**. Progress arrives as
notifications, because a custom action has no terminal to print into. Full
detail in [`daemon/README.md`](daemon/README.md).

### Which phone am I sending to?

`AirDrop → Everyone` makes *every* Apple device in range a candidate, and the
default `-r 0` picks whichever answered mDNS first. Check the discovered list the
script prints, then select by name rather than position:

```sh
RECEIVER="Jed's iPhone" ./airdrop.sh send photo.jpg
```

Files land in `~/Downloads`. Per-run logs and captures go to `./runs/`.

### Receiving a link

A shared **link** does not arrive as a file. iOS puts the URL in the `/Ask`
body and never sends an upload, so nothing lands in `RECV_DIR` - the link is
opened directly instead, in Firefox, once you accept the same prompt a file
transfer raises. Send it from the phone exactly like a file: share sheet ->
AirDrop -> **void-btw**.

Where it goes is configurable without touching the patch:

```sh
AIRDROP_BROWSER=chromium ...        # a different browser
AIRDROP_URL_HOOK=/path/to/script    # or do something else entirely
```

`daemon/airdrop-url` accepts `http`/`https` only. The URL comes from an
unauthenticated network peer, so handing it to a browser unfiltered would hand
a stranger every scheme handler on the box.

### What lands on disk

iOS never sends a bare file ([§49](docs/FINDINGS.md)). Even one photo arrives as
a cpio holding a staging directory and an AppleDouble sidecar:

```
NSIRD_AirDrop_wvB8nv/
  IMG_8370.PNG          the photo
  ._IMG_8370.PNG        resource fork + Finder flags, ~1.6 KB
```

The wrapper name is random per transfer and the `._` file is metadata only
Finder reads, so `tools/airdrop-tidy` flattens both away and you get
`IMG_8370.PNG` directly in `RECV_DIR`. Both `airdrop.sh receive` and `airdropd`
do this automatically - the daemon sweeps every couple of seconds while it is
running, so files appear as they arrive rather than when it stops. Name clashes
get a `-1`, `-2` suffix before the extension; nothing is ever overwritten.

Set `AIRDROP_TIDY_ON=0` to keep the transfer exactly as the phone packed it,
which is what you want when the packing itself is what you are debugging. The
tool also runs standalone over a directory of past receives:

```sh
tools/airdrop-tidy ~/Downloads
```

### Configuration

All optional, all environment variables. They can also go in
`~/.config/airdrop/config`, which both `airdrop.sh` and `daemon/airdropd`
source - useful because the callers that would otherwise set them (the waybar
module, a sway keybind) are tracked files in this repo. Write it with `:-`
assignments so the environment still wins:

```sh
# ~/.config/airdrop/config
RECV_DIR="${RECV_DIR:-/mnt/shared/airdrop}"
```


| variable | default | meaning |
|---|---|---|
| `IFACE` | autodetected mt7921 interface | Wi-Fi interface |
| `REG` | `NZ` | regulatory domain - **set this to your country** |
| `CHAN` | `36` | starting channel (6, 36, 44, 149) |
| `OWL_DIR` | `~/owl` | your patched OWL checkout |
| `RECV_DIR` | `~/Downloads` | where received files are extracted |
| `AIRDROP_TIDY_ON` | `1` | flatten the `NSIRD_AirDrop_*` wrapper and drop `._` sidecars; `0` keeps the transfer as sent |
| `RECV_TIME` | `90` | seconds to stay advertising |
| `OUT_DIR` | `./runs` | where logs and captures go |
| `AIRDROP_NAME` | hostname | name the phone shows for this machine |
| `AIRDROP_CONF` | `~/.config/airdrop/config` | config file to source |
| `ACTIVE` | `0` | `1` = add the active vif beside the plain one (ACKs + hopping). Use it for transfers |
| `KEEP_WIFI` | `0` | `1` = keep the association and borrow the AP's channel; see [below](#keeping-your-internet-keep_wifi1) |
| `FIND_TIME` | `45` | send/discover: ceiling on the browse, not a duration |
| `RECEIVER` | first found | send: receiver ID or name, see [Which phone am I sending to?](#which-phone-am-i-sending-to) |
| `OWL`, `OPENDROP` | under `OWL_DIR` | explicit paths to the owl binary and the opendrop CLI |
| `STRATEGY` | `verbatim` | how OWL derives its channel sequence: `verbatim`, `widen`, `intersect`, `rotate`, `pin`. `verbatim` is the default because `pin` breaks TX to iOS 26 ([§25](docs/FINDINGS.md)) |
| `WIDEN_MAX` | owl's own (4) | with `STRATEGY=widen`, how many empty slots it may fill (`-W`) |

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

This mechanism **is now ported into `daemon/airdropd`** as an opt-in mode
(`AIRDROP_DUALCHAN=1`), and it is what the waybar switch actually runs. It has
since carried a real transfer to 99.1% with the association up throughout, so
"untested" no longer describes it - but it has not been seen to complete one on
the MT7921 (an MT7922 has completed both receives and sends through it),
and the remaining faults are listed honestly in
[`daemon/README.md`](daemon/README.md#limitations). It is **not** wired into the
plain `KEEP_WIFI=1` / `airdrop.sh` path, only the daemon.

Constraints on this mode worth knowing before you try it:

- Your station must be on **5 GHz**. A 2.4 GHz association provably cannot
  survive a second channel context, whatever channel the GO uses. If your SSID
  also has a 5 GHz BSS the daemon moves you to it for the session; if it does
  not, the switch refuses.
- The GO is built on `6/36/44/149`. A station on any *other* 5 GHz channel is
  fine - the GO goes to ch149 alongside it (confirmed on ch100 and ch157).
- Uplink latency is ~200-400 ms the whole time it is up.

If you want AirDrop with no caveats at all, giving AWDL its own radio (an
AR9271 on USB) is still the unconditional answer: two phys, no shared channel
context.

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
airdrop.sh          the tool - exclusive card, proven, no internet while it runs
daemon/             airdropd: the always-on waybar switch, keeps your Wi-Fi up
waybar/             the bar module (JSON status + click-to-toggle)
patches/            OpenDrop fixes for iOS 26
docs/FINDINGS.md    the full investigation, including what I got wrong
docs/NOTES.md       dated lab notebook
tools/              diagnostic harnesses, each answering one question
```

`tools/` is research, not a test suite. Each script isolates one question and
restores your networking afterwards. `activelate2.sh` and `activelate3.sh` are
the two that establish the pair configuration this whole project rests on.

## Credit

**[Alban Peralta](https://github.com/Peralban)**, co-developer. Everything
this project knows about the MT7922 comes from their hardware and their
measurements. On the code side:

- portability fixes and two OpenDrop patches, from an MT7922 on Hyprland ([#1](https://github.com/jedbillyb/airdrop-mt7921/pull/1))
- `tools/beaconwatch.sh`, which tells you why the station died ([#5](https://github.com/jedbillyb/airdrop-mt7921/pull/5))
- configurable paths and service manager in `tools/` ([#6](https://github.com/jedbillyb/airdrop-mt7921/pull/6))
- `tools/blewake-dbus.py`, the Continuity advert through bluetoothd ([#8](https://github.com/jedbillyb/airdrop-mt7921/pull/8))
- the send path no longer discovers itself ([#9](https://github.com/jedbillyb/airdrop-mt7921/pull/9))
- `AIRDROP_CONFIRM_UI`, to pick how the accept prompt appears ([#10](https://github.com/jedbillyb/airdrop-mt7921/pull/10))
- the channel watch no longer reports `unreachable` from an empty log ([#13](https://github.com/jedbillyb/airdrop-mt7921/pull/13))
- salvaged partial files are trimmed to the bytes that actually arrived ([#14](https://github.com/jedbillyb/airdrop-mt7921/pull/14))
- several files go in one transfer and one Accept, each announced with its own type ([#12](https://github.com/jedbillyb/airdrop-mt7921/pull/12))
- OpenDrop's CLI exits non-zero when a send fails ([#17](https://github.com/jedbillyb/airdrop-mt7921/pull/17))
- the channel watch reads only what owl wrote since the last tick, so a phone that left stops being reported ([#19](https://github.com/jedbillyb/airdrop-mt7921/pull/19))

Their reports ([#2](https://github.com/jedbillyb/airdrop-mt7921/issues/2),
[#7](https://github.com/jedbillyb/airdrop-mt7921/issues/7),
[#15](https://github.com/jedbillyb/airdrop-mt7921/issues/15)) gave the
project its first always-on receive and its first daemon send on an MT7922,
and turned up real bugs in the daemon.

Built on:

- [seemoo-lab/owl](https://github.com/seemoo-lab/owl) - the AWDL implementation
- [seemoo-lab/opendrop](https://github.com/seemoo-lab/opendrop) - the AirDrop layer
- The [Open Wireless Link](https://owlink.org) project's reverse engineering

## Licence

GPLv3, matching OWL.
