# Diagnostic harnesses

These are **research artefacts, not a test suite**. Each one isolates a single
question about the MT7921's monitor mode and answers it with measurements rather
than with what `iw` claims. They are kept because the answers in
[../docs/FINDINGS.md](../docs/FINDINGS.md) are only as good as the runs behind
them, and because two of them are what this whole project rests on.

Every script takes the Wi-Fi card exclusively and restores networking on exit
via a bash trap **and** a `setsid`-detached watchdog, so your networking comes
back even on `kill -9`.

Set `IFACE=` if your card is not `wlp2s0`, and `OUT_DIR=` to move the logs; they
default to `./runs`. They still assume `phy0` and Void's `sv`, unlike
`airdrop.sh` - these were written for one machine and are published as they ran.

| script | question it answers |
|---|---|
| `pmtest.sh` | Is runtime power management why monitor RX delivers nothing? (**yes**) |
| `montest.sh` | How do we make the chip actually tune where we ask in monitor mode? |
| `chansweep2.sh` | Does the radio tune where we ask? Corrected version, with PM off. |
| `rxcounters.sh` | Where are frames lost - radio, driver, or pcap? Compares three independent counters. |
| `hoptest2.sh` | Does OWL's channel hopping reach the away-channel? Radio truth vs OWL's belief. |
| `activetest2.sh` | Plain vs active monitor, both verified on the *same* frequency. |
| `awdltest.sh` | Can active monitor hear AWDL at all? |
| `activelate2.sh` | **Can an active vif inherit a channel set before it existed?** Phase F is the discovery. |
| `activelate3.sh` | **Does the pair hop together?** Yes - one shared channel context. |
| `bursts.py` | How fast was a transfer, and *why*? Splits the stream into availability windows. |
| `slotmap.py` | Which slots does each peer actually transmit in, and how many does it offer us? |
| `blewake.sh` | Emits the Apple Continuity BLE advertisement that wakes a receiver's AWDL. |

The last three need no radio setup and do not touch networking: `bursts.py` and
`slotmap.py` read artefacts a run already produced, and `blewake.sh` only uses
the Bluetooth controller. `slotmap.py --log` is the first thing to run on any
disappointing transfer - if it says the peer never offered more than 2 of 16
slots, there was nothing to win and the run proves nothing (FINDINGS §21).

The last two are the important ones. `activelate2.sh` phase F found that an
active vif created *alongside* an already-tuned plain vif comes up on that
channel at full reception, and `activelate3.sh` showed the pair retunes as a
unit. Everything in `airdrop.sh` follows from those two results.

## `airdrop-tidy` is not one of these

It sits in this directory but breaks every rule above: it is not a research
artefact, it answers no question about the radio, and it never touches the
Wi-Fi card. It is a plain utility that both receivers call, and it is here only
because there is nowhere better to put a single script.

What it does is undo iOS's packaging. A transfer arrives as a cpio holding a
staging directory and an AppleDouble sidecar, even when one photo was sent:

```
NSIRD_AirDrop_wvB8nv/
  IMG_8370.PNG          the photo
  ._IMG_8370.PNG        resource fork + Finder flags, ~1.6 KB
```

`NSIRD` is NSItemProvider ReceiveDirectory and the suffix is regenerated every
transfer, so it cannot even be used to group a multi-file drop. `airdrop-tidy`
moves the contents up into `RECV_DIR` and deletes the sidecars.

```sh
tools/airdrop-tidy [DIR]          # tidy once; DIR defaults to $RECV_DIR
tools/airdrop-tidy --watch DIR    # tidy every AIRDROP_TIDY_POLL seconds
```

`airdrop.sh receive` runs it once when its window closes; `airdropd` runs the
`--watch` form for its whole lifetime, because in always-on mode opendrop is a
long-lived process and sweeping only on its exit would leave files wrapped for
hours. `AIRDROP_TIDY_ON=0` disables both.

Three things it deliberately will not do. It only touches directories matching
`NSIRD_AirDrop_*`. It skips any that changed within `AIRDROP_TIDY_SETTLE`
seconds, because opendrop buffers the whole archive to disk before extracting,
so a directory still changing is one that is half-extracted and moving out of it
would take a partial file. And it never overwrites: a name that already exists
gets a `-1`, `-2` suffix before the extension, and the wrapper is only ever
`rmdir`ed, so anything unexpected left inside stops the removal rather than
being deleted to keep things tidy.

## A note on the ones that are missing

Several earlier harnesses (`activetest.sh`, `activelate.sh`, `chansweep.sh`,
`hoptest.sh`, `rxtest.sh`) are not here. Each was superseded by the numbered
version above, usually because it reached a *wrong* conclusion from an invalid
comparison - most often by comparing a busy channel against a quiet one and
reading the frame-count difference as a capability difference. They are in the
history of [jedbillyb/owl](https://github.com/jedbillyb/owl) if you want to see
how the errors went.

The methodology rule that came out of all of it: **on this chip `iw` lies about
the channel.** It reports what you asked for. Only the radiotap frequency on
captured frames is trustworthy, and no two captures are comparable unless both
are verified to have been on the same actual frequency.
