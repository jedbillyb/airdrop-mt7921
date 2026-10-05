# airdrop-mt7921

AirDrop between an iPhone and a Linux laptop, using the laptop's built-in
MediaTek MT7921 or MT7922 Wi-Fi. No USB adapter, no Apple ID.

Built by [Jed Blenkhorn](https://github.com/jedbillyb) and
[Alban Peralta](https://github.com/Peralban). Not affiliated with Apple, OWL or
OpenDrop. No warranty.

## Status

| | |
|---|---|
| Receive from an iPhone | works: waybar switch or `airdrop.sh` |
| Send to an iPhone | works with `airdrop.sh send`; right-click send proven on MT7922 |
| Speed | about 40-67 kB/s, so a 3-4 MB photo takes 1-2 minutes |
| Wi-Fi during a transfer | off, restored automatically afterwards (see [modes](#modes)) |
| Tested on | MT7921 (Void Linux), MT7922 (Arch, Hyprland), iOS 26 |

## Install

```sh
git clone https://github.com/jedbillyb/airdrop-mt7921.git
cd airdrop-mt7921
./install.sh
```

It builds [owl](https://github.com/jedbillyb/owl) and a patched OpenDrop,
installs a root-owned helper, adds one passwordless-sudo rule for it (it shows
you the rule and asks first), writes `~/.config/airdrop/config` and links the
waybar module. **Run it again after every `git pull`.**

Needs NetworkManager, git, cmake, a C compiler, python3, iw and tcpdump.
waybar is optional.

## Receive a photo

1. Click **drop off** on the bar. It reads **drop on**, and your Wi-Fi drops.
2. On the iPhone, set AirDrop to **Everyone for 10 Minutes**, then share to
   your laptop.
3. Accept the prompt on the laptop. The bar shows **drop 61%** while the file
   arrives. Leave it on.
4. A minute after the last file it switches itself off and the Wi-Fi comes
   back. The bar reads **wifi…** until it has.

Files land in `~/Downloads`. Without waybar, run `ACTIVE=1 ./airdrop.sh receive`.

## Send a file

```sh
ACTIVE=1 ./airdrop.sh send photo.jpg
```

Keep the phone unlocked with its share sheet **closed**. To pick a phone by
name, or to send from the file manager, see
[docs/REFERENCE.md](docs/REFERENCE.md#sending-from-the-file-manager).

## Settings

In `~/.config/airdrop/config` (install.sh writes a starter one):

| setting | default | |
|---|---|---|
| `AIRDROP_MODE` | `exclusive` | which [mode](#modes) the switch uses |
| `AIRDROP_REG` | detected | your two-letter country; needed in exclusive mode |
| `AIRDROP_NAME` | hostname | the name the phone shows |
| `RECV_DIR` | `~/Downloads` | where received files go |

Everything else: [daemon/README.md](daemon/README.md#tuning) for the switch,
[docs/REFERENCE.md](docs/REFERENCE.md#airdropsh-configuration) for `airdrop.sh`.

## Modes

- **exclusive** (default): the switch takes the whole Wi-Fi card while it is
  on. It finds the phone on any network, and gives the card back afterwards.
- **shared**: keeps your Wi-Fi up, but can only find the phone when both are on
  the same channel, which depends on the network. It also needs a patched
  `hostapd` that `install.sh` does not build. Setup in
  [daemon/README.md](daemon/README.md).

## Troubleshooting

- **Phone doesn't show the laptop.** Check AirDrop is still on Everyone: iOS
  turns it back off after 10 minutes without telling you. Then give it up to a
  minute with the share sheet open.
- **The switch flips straight back to drop off.** Run
  `daemon/airdropd run` in a terminal; the error prints there.
- **Something broke after a `git pull`.** Run `./install.sh` again.
- **No internet after using it.** It normally comes back by itself within
  about 30 s. If not: `sudo sv up NetworkManager` (runit) or
  `sudo systemctl start NetworkManager`.
- Logs: `$XDG_RUNTIME_DIR/airdropd/airdropd.log`. More in
  [daemon/README.md](daemon/README.md#first-three-things-to-check-when-my-phone-cant-see-me).

## How it works

[owl](https://github.com/seemoo-lab/owl) speaks AWDL, Apple's Wi-Fi link, and
[OpenDrop](https://github.com/seemoo-lab/opendrop) speaks AirDrop on top of
it. Both normally need a USB adapter with working active monitor mode. The
MT7921 gets there with two monitor interfaces: a plain one tuned first, then an
active one beside it, which shares its channel and sends the ACKs. The
OpenDrop patches in [patches/](patches/README.md) make iOS 26 transfers work.
The full investigation is in [docs/FINDINGS.md](docs/FINDINGS.md).

## Documentation

- [docs/REFERENCE.md](docs/REFERENCE.md): manual install, sending, links, every setting, driver bugs
- [daemon/README.md](daemon/README.md): the waybar switch
- [patches/README.md](patches/README.md): what each OpenDrop patch does
- [docs/FINDINGS.md](docs/FINDINGS.md): the investigation, including the wrong turns
- [docs/NOTES.md](docs/NOTES.md): lab notebook
- [tools/README.md](tools/README.md): diagnostic scripts

## Credit

[Alban Peralta](https://github.com/Peralban) is co-developer: MT7922 support,
much of the sending path and many daemon fixes
([their PRs](https://github.com/jedbillyb/airdrop-mt7921/pulls?q=author%3APeralban)).
Built on [seemoo-lab/owl](https://github.com/seemoo-lab/owl),
[seemoo-lab/opendrop](https://github.com/seemoo-lab/opendrop) and the
[Open Wireless Link](https://owlink.org) project's reverse engineering.

## Support

- Email: [hello@jedbillyb.com](mailto:hello@jedbillyb.com)
- Website: [jedbillyb.com](https://jedbillyb.com)
- [Open an issue](https://github.com/jedbillyb/airdrop-mt7921/issues)

## Licence

GPLv3, matching OWL.
