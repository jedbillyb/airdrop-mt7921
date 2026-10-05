# airdrop-mt7921

AirDrop between an iPhone and a Linux laptop, using the laptop's built-in
MediaTek MT7921 or MT7922 Wi-Fi. No USB adapter, no Apple ID.

## Status

| | Status |
|---|---|
| Receive from an iPhone | works: waybar switch or `airdrop.sh` |
| Send to an iPhone | works with `airdrop.sh send`; right-click send proven on MT7922 |
| Speed | about 40-67 kB/s, so a 3-4 MB photo takes 1-2 minutes |
| Wi-Fi during a transfer | off, restored automatically afterwards (see [Modes](#modes)) |
| Tested on | MT7921 (Void Linux), MT7922 (Arch, Hyprland), iOS 26 |

The phone must have AirDrop on **Everyone**. Contacts Only needs an
Apple-signed identity that cannot be produced off Apple hardware. Everyone mode
accepts an unsigned peer in both directions.

## Install

```sh
git clone https://github.com/jedbillyb/airdrop-mt7921.git
cd airdrop-mt7921
./install.sh
```

It builds [owl](https://github.com/jedbillyb/owl) and a patched OpenDrop,
installs a root-owned helper, adds one passwordless-sudo rule for it (it shows
you the rule and asks first), writes `~/.config/airdrop/config` and links the
waybar module. **Run it again after every `git pull`**: the owl build, the
patched venv and the root-owned copies are copies, and a pull updates none of
them.

Needs NetworkManager (runit or systemd), git, cmake, a C compiler, python3, iw
and tcpdump. waybar is optional.

<details>
<summary>Manual install</summary>

1. **owl.** Next to this repo (or set `OWL_DIR`):
   ```sh
   git clone https://github.com/jedbillyb/owl.git ../owl
   cmake -S ../owl -B ../owl/build -DCMAKE_BUILD_TYPE=Release
   cmake --build ../owl/build --target owl    # googletest fails under current GCC
   ```
2. **OpenDrop**, patched. The patches are a series: apply all of them, in this
   order, to a clean 0.13.0. `GIT_DIR` must point nowhere, because this
   directory is inside the owl checkout and `git apply` inside a repo silently
   patches nothing.
   ```sh
   python3 -m venv ../owl/.venv-opendrop
   ../owl/.venv-opendrop/bin/pip install opendrop==0.13.0 'setuptools<81'
   cd ../owl/.venv-opendrop/lib/python*/site-packages
   for p in ios26-airdrop recv-window py314-send mdns-repeat find-report tls-keylog \
            upload-arms ask-confirm mdns-reannounce threaded-server url-items \
            zeroconf-update-service salvage-truncated salvage-trim \
            send-multifile send-status send-stall; do
     GIT_DIR=/nonexistent git apply /path/to/airdrop-mt7921/patches/opendrop-$p.patch || break
   done
   ```
   `setuptools<81` because OpenDrop imports `pkg_resources`. What each patch
   does: [patches/README.md](patches/README.md).
3. **Root-owned helper, sudoers, waybar:** see
   [daemon/README.md](daemon/README.md#install).

</details>

## Receiving

1. Click **drop off** on the bar. It reads **drop on**, and your Wi-Fi drops.
2. On the iPhone, set AirDrop to **Everyone for 10 Minutes**, open the share
   sheet and pick your laptop.
3. Accept the prompt on the laptop. The bar shows **drop 61%** while the file
   arrives. Leave it on.
4. A minute after the last file it switches itself off and the Wi-Fi comes
   back. The bar reads **wifi…** until it has.

Without waybar: `ACTIVE=1 ./airdrop.sh receive`.

The share sheet must be **open** on the phone: that is what wakes its AWDL.
Control Centre alone is not enough, and a locked phone is invisible.

**What lands on disk.** iOS wraps every transfer in an `NSIRD_AirDrop_*`
directory with `._` metadata files. Both paths flatten that away, so you get
`IMG_8370.PNG` straight in `RECV_DIR`. Name clashes get `-1`, `-2`; nothing is
overwritten. `AIRDROP_TIDY_ON=0` keeps the transfer as sent;
`tools/airdrop-tidy <dir>` tidies old receives.

**Links.** A shared link never arrives as a file: it is opened in Firefox once
you accept. `AIRDROP_BROWSER` picks another browser, `AIRDROP_URL_HOOK` runs
your own script. Only `http`/`https` are passed on, since the URL comes from an
unauthenticated peer.

## Sending

```sh
ACTIVE=1 ./airdrop.sh send photo.jpg
RECEIVER="Jed's iPhone" ACTIVE=1 ./airdrop.sh send photo.jpg   # pick a phone by name
```

The phone must be unlocked with its share sheet **closed** (an open sheet makes
it a sender, which never advertises). The script wakes the phone's AWDL with a
Bluetooth LE advertisement. With AirDrop on Everyone, every Apple device nearby
is a candidate, so name the receiver rather than taking the first one found.

**From the file manager.** `airdropd send` attaches to a running switch instead
of taking the card, and backs a Thunar right-click:

```sh
sudo ln -s "$PWD/daemon/airdrop-send" /usr/local/bin/airdrop-send   # a symlink, not a copy
thunar -q                                                           # it rewrites uca.xml on exit
tools/install-thunar-action.sh                                      # --remove undoes it
```

Select files, right-click, **Send via AirDrop**; progress comes as
notifications. Proven on an MT7922 (with `tools/blewake-dbus.py` running
alongside); on the MT7921 only `airdrop.sh send` has completed a send so far, so if the
right-click finds nobody, try `ACTIVE=1 ./airdrop.sh send <file>` first.

## Settings

`~/.config/airdrop/config` is read by both `airdrop.sh` and the switch. Use
`VAR="${VAR:-value}"` so the environment still wins.

| Setting | Default | What it does |
|---|---|---|
| `AIRDROP_MODE` | `exclusive` | which [mode](#modes) the switch uses |
| `AIRDROP_REG` | detected | your two-letter country; needed once Wi-Fi is down |
| `AIRDROP_NAME` | hostname | name the phone shows (no apostrophes) |
| `RECV_DIR` | `~/Downloads` | where received files go |

`airdrop.sh` only:

| Setting | Default | What it does |
|---|---|---|
| `ACTIVE` | `0` | `1` adds the ACK interface; needed for any transfer |
| `REG` | `NZ` | regulatory country; set yours |
| `CHAN` | `36` | starting channel (6, 36, 44, 149); unset to search |
| `RECV_TIME` | `90` | seconds to stay receiving |
| `KEEP_WIFI` | `0` | `1` keeps the association (see [Modes](#modes)) |
| `RECEIVER` | first found | send target, by name or ID |
| `FIND_TIME` | `45` | send/discover: give up after this long |
| `STRATEGY` | `verbatim` | owl channel strategy; `pin` breaks iOS 26 |
| `WIDEN_MAX` | owl's own (4) | with `STRATEGY=widen`, how many empty slots it may fill |
| `AIRDROP_CONF` | `~/.config/airdrop/config` | which config file to read |
| `IFACE`, `OWL_DIR`, `OWL`, `OPENDROP`, `OUT_DIR` | detected | paths and interface |

The switch's own settings (timeouts, channels, prompts):
[daemon/README.md](daemon/README.md#tuning).

## Modes

- **exclusive** (the switch's default): takes the whole Wi-Fi card while on.
  It finds the phone on any network, then gives the card back. `airdrop.sh`
  works the same way, and restores networking through a trap and a detached
  watchdog even if it is killed.
- **shared** (switch): keeps your Wi-Fi up by holding AirDrop on one channel
  beside it. It only finds the phone when the phone is on that channel too,
  needs a 5 GHz connection and a patched `hostapd` that `install.sh` does not
  build, and adds 200-400 ms of latency while on. Setup:
  [daemon/README.md](daemon/README.md).
- **`KEEP_WIFI=1`** (`airdrop.sh`): borrows your access point's channel. Only
  works when that happens to be 6, 36, 44 or 149 and the phone is there too;
  not yet seen to complete a transfer.

For AirDrop with no trade-off at all, a second Wi-Fi adapter (an AR9271 on USB)
is still the unconditional answer.

## Troubleshooting

- **Phone doesn't show the laptop.** Check AirDrop is still on Everyone: iOS
  turns it back off after 10 minutes without telling you. Then give it up to a
  minute with the share sheet open.
- **The switch flips straight back to drop off.** Run `daemon/airdropd run` in
  a terminal; the error prints there.
- **Something broke after a `git pull`.** Run `./install.sh` again.
- **No internet afterwards.** It normally returns within about 30 s. If not:
  `sudo sv up NetworkManager` (runit) or `sudo systemctl start NetworkManager`.
- Logs: `$XDG_RUNTIME_DIR/airdropd/airdropd.log` for the switch, `./runs/` for
  `airdrop.sh`. More in
  [daemon/README.md](daemon/README.md#first-three-things-to-check-when-my-phone-cant-see-me).

**MT7921 driver traps** (both handled for you, both silent):

1. Runtime power management stops all monitor reception. `runtime-pm` and
   `deep-sleep` in `/sys/kernel/debug/ieee80211/<phy>/mt76` must be 0.
2. `iw dev X set type monitor` never retunes the radio; use a separate monitor
   interface.

Also, `iw` reports the channel you asked for, not the one the radio is on. Trust
the radiotap frequency in a capture instead.

## How it works

[owl](https://github.com/seemoo-lab/owl) speaks AWDL, Apple's peer-to-peer Wi-Fi
link, and [OpenDrop](https://github.com/seemoo-lab/opendrop) speaks AirDrop on
top of it. Both are normally said to need a USB adapter with working active
monitor mode, because on the MT7921 an active monitor interface is stuck on
channel 36.

The way around it is configuration, not a patch: create a plain monitor
interface and tune it first, then add the active one beside it. They share one
channel, so the active one sends ACKs and follows the phone's channel hopping.
The OpenDrop patches make iOS 26 transfers work (chunked requests, the `dvzip`
container, and a `TransferID` the phone requires before it accepts an upload).
The full investigation, wrong turns included, is in
[docs/FINDINGS.md](docs/FINDINGS.md).

## Open questions

- **Send speed** is unmeasured; the proving send was 68 bytes. Send a real file
  and run `tools/bursts.py runs/<run>/send.pcap`.
- **Can receive go faster?** The ~45 kB/s ceiling looks like the 2-of-16 slots
  we copy from the phone. `STRATEGY=widen` fills its empty slots, which iOS 26
  accepts; compare it against `verbatim` with `tools/bursts.py --baseline`.
  Predictions are in [FINDINGS §21](docs/FINDINGS.md).

## Repo layout

```
install.sh          install and update everything
airdrop.sh          the standalone tool
daemon/             airdropd: the waybar switch
waybar/             the bar module
patches/            OpenDrop fixes for iOS 26
docs/FINDINGS.md    the investigation
docs/NOTES.md       lab notebook
tools/              diagnostic scripts, one question each
```

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
- the always-on health watch checks every vif the armed state needs (the ACK vif and, under dual-channel, `go0`), not just `awdl0`, and names the one that went ([#18](https://github.com/jedbillyb/airdrop-mt7921/pull/18))

Their reports ([#2](https://github.com/jedbillyb/airdrop-mt7921/issues/2),
[#7](https://github.com/jedbillyb/airdrop-mt7921/issues/7),
[#15](https://github.com/jedbillyb/airdrop-mt7921/issues/15)) gave the
project its first always-on receive and its first daemon send on an MT7922,
and turned up real bugs in the daemon.

Built on [seemoo-lab/owl](https://github.com/seemoo-lab/owl),
[seemoo-lab/opendrop](https://github.com/seemoo-lab/opendrop) and the
[Open Wireless Link](https://owlink.org) project's reverse engineering.

## Licence

[GPLv3](LICENSE), matching OWL.

*Independent project, not affiliated with Apple, OWL or OpenDrop. No warranty.*
