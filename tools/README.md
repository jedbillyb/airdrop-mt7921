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

The last two are the important ones. `activelate2.sh` phase F found that an
active vif created *alongside* an already-tuned plain vif comes up on that
channel at full reception, and `activelate3.sh` showed the pair retunes as a
unit. Everything in `airdrop.sh` follows from those two results.

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
