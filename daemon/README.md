# AirDrop as a switch (`airdropd`)

`airdropd` has **two modes**, and the one the waybar toggle actually uses is
the second.

| mode | how it arms | what the switch means |
|---|---|---|
| **BLE-triggered** (`AIRDROP_ALWAYS=0`, the file default) | Idles on Bluetooth, brings AWDL up for `AIRDROP_WINDOW` seconds when an iPhone opens its share sheet nearby | "armed to notice you" |
| **Always-on** (`AIRDROP_ALWAYS=1`) | Brings the stack up once and stays advertising until toggled off | "you can AirDrop to this machine right now" |

**The waybar module sets `AIRDROP_ALWAYS=1 AIRDROP_DUALCHAN=1`**, so on this
box the switch is always-on P2P-GO. That combination is the current setup and
is what [Your current setup](#your-current-setup) documents.

The BLE model is the one macOS actually uses: a Mac does not hold AWDL up
permanently either, it scans BLE continuously (which costs nothing on the Wi-Fi
side) and brings AWDL up only when a phone announces it wants to send
something. That is viable here because **the whole AWDL stack comes up in
0.19 s** (FINDINGS §39): monitor vifs 0.057 s, OWL to ready 0.117 s, `awdl0`
0.015 s. The ~90 s time-to-advertising in `airdrop.sh` is almost entirely
conservative fixed `sleep`s, not a requirement.

It also sidesteps the §38 dilemma. Instead of choosing once between "no
internet" and "locked to the AP's channel", the radio is only committed while a
transfer is actually happening.

Always-on trades that away deliberately: with P2P-GO the cost of holding the
radio is **added uplink latency rather than a lost association**, which is a
trade worth making for a switch that just works with no second step.

## Pieces

| file | what it does |
|---|---|
| `ble-watch` | Detects Apple Continuity **AirDrop** adverts (company `0x004C`, type `0x05`) by parsing `btmon`. Prints one JSON line per sighting. |
| `airdrop-helper` | The **only** privileged entry point. `up` / `down` / `status` / `ap-channel` / `wifi-reset`, plus `go-up` / `go-down` / `owl-start` / `owl-stop` / `avahi-down` / `avahi-up` for the P2P-GO path. |
| `airdrop-confirm` | Asks the user, via `swaynag`, whether to accept an incoming file. |
| `airdropd` | Orchestrator. BLE mode: trigger → stack up → advertise → confirm → tear down. Always-on mode: stack up → advertise → confirm, staying up until stopped, with a health watch over it. |
| `../waybar/airdrop-status.sh` | waybar module: JSON status + click-to-toggle. |

## Security: read this before running it unattended

**OpenDrop 0.13.0 accepts every `/Ask` unconditionally.** `handle_ask` returns
200 with the machine name; there is no prompt and no extension point. For a
harness you launch by hand for one transfer that is tolerable. For an always-on
receiver it means **anyone in range with AirDrop set to Everyone can write files
to this machine, unattended and unlogged.**

`patches/opendrop-ask-confirm.patch` adds the hook. It is a **requirement** of
the always-on design, not a nicety, and it **fails closed**: if the hook cannot
be run, the transfer is refused. Verified:

| condition | result |
|---|---|
| `AIRDROP_CONFIRM` unset | accept (upstream behaviour, harness unaffected) |
| hook exits 0 | accept |
| hook exits non-zero | **403 Forbidden**, phone shows "Declined" |
| hook missing / unrunnable | **decline** |
| no Wayland session to prompt in | **decline** |
| prompt not answered within the timeout | **decline** |

The timeout is `AIRDROP_CONFIRM_TIMEOUT`, 45 s by default but **15 s in
always-on mode** — see Tuning.

An unaskable question is not consent.

## Install

Two things need root. Everything else runs as you.

**1. The privileged helper.** A wrapper, not an allowlist of commands —
`sudo tcpdump -w <path>` is an arbitrary-file-write-as-root primitive, so
NOPASSWD on `tcpdump` is indistinguishable from NOPASSWD on everything. `iw` and
`ip` are nearly as bad. The wrapper takes a fixed verb and accepts no paths.

Everything the helper runs as root must be installed **root-owned, outside the
repo**, for the same reason:

```sh
# The two sudoers entry points
sudo install -o root -g root -m 755 daemon/airdrop-helper /usr/local/bin/airdrop-helper
sudo install -o root -g root -m 755 daemon/ble-watch      /usr/local/bin/airdrop-ble-watch

# owl, which the helper starts as root. Its path is hard-coded in the helper -
# owl creates the awdl0 tun and cannot do it unprivileged, and pointing this at
# $OWL_DIR/build/daemon/owl would re-open the escalation the wrapper avoids.
sudo install -o root -g root -m 755 ~/owl/build/daemon/owl /usr/local/bin/airdrop-owl

# Only needed for AIRDROP_DUALCHAN=1: the patched hostapd from mt7921-dual-channel
sudo install -o root -g root -m 755 \
  /mnt/shared/build/hostapd-2.11/hostapd/hostapd /usr/local/bin/airdrop-go-hostapd
```

**Only the first two go in sudoers.** `airdrop-owl` and `airdrop-go-hostapd`
are invoked *by* the helper, which is already root by then, so giving them
their own NOPASSWD rules would widen the surface for nothing.

**Never point the sudoers rule at the copies in this repo.** The repo lives
under your home / `/mnt/shared/projects` and is writable by you, and NOPASSWD on
a script you can edit is a straight privilege escalation to root — anyone who
can write the file, or any process running as you, gains root by rewriting it.
The whole point of a narrow wrapper is lost if the wrapper is user-writable.
Re-run the two `install` commands after `git pull` to pick up changes.

**2. Passwordless sudo for them.** Required because **waybar has no tty** — a
`sudo` that wants a password simply hangs there. Same pattern as the existing
`/etc/sudoers.d/zzz-swaylock-fp-restart` on this box.

*Validate before installing.* A malformed file in `/etc/sudoers.d/` can lock you
out of `sudo` entirely, so never write one without `visudo -c` first:

```sh
TMP=$(mktemp)
cat > "$TMP" <<'RULES'
jed ALL=(root) NOPASSWD: /usr/local/bin/airdrop-helper
jed ALL=(root) NOPASSWD: /usr/local/bin/airdrop-ble-watch
RULES
sudo visudo -cf "$TMP" && sudo install -o root -g root -m 440 "$TMP" /etc/sudoers.d/zz-airdrop
rm -f "$TMP"
sudo visudo -c        # confirm the whole config is still valid
```

Check it took:

```sh
sudo -n /usr/local/bin/airdrop-helper status
```

**3. Apply the confirmation patch** (Void has no `patch(1)` — use `git apply`):

```sh
cd ~/owl/.venv-opendrop/lib/python3.14/site-packages
git apply --unsafe-paths --directory=. \
  /mnt/shared/projects/airdrop-mt7921/patches/opendrop-ask-confirm.patch
```

**4. waybar module.** Symlink it like the other modules on this box:

```sh
ln -sf /mnt/shared/projects/airdrop-mt7921/waybar/airdrop-status.sh ~/.config/waybar/
```

Then in `/mnt/shared/projects/dotfiles/waybar/config`:

```jsonc
"custom/airdrop": {
    "exec": "~/.config/waybar/airdrop-status.sh",
    "return-type": "json",
    "interval": 2,
    "on-click": "~/.config/waybar/airdrop-status.sh toggle"
}
```

## Use

```sh
daemon/airdropd run      # foreground; what the waybar toggle starts
daemon/airdropd status   # JSON for the bar
daemon/airdropd stop
```

On the phone: AirDrop → **Everyone for 10 Minutes** (it expires, re-arm it),
then open the share sheet. In BLE-triggered mode that share sheet is also what
emits the advert `airdropd` waits for; in always-on mode nothing is waited for
and the receiver is already up.

## Your current setup

What the waybar switch runs on this box, end to end:

```
click  →  AIRDROP_ALWAYS=1 AIRDROP_DUALCHAN=1 airdropd run
          ├─ stop avahi           (it answers for this host on awdl0 and wins
          │                        the race against opendrop, so we vanish)
          ├─ pick a GO channel    (go_target — station first, see below)
          ├─ go0 = P2P-GO vif on that channel, via the patched hostapd
          ├─ mon0/mon1            (MAC-aliased to go0; mon1 `flags active` ACKs)
          ├─ owl on mon1          → awdl0 appears
          └─ opendrop on awdl0    (re-announcing mDNS every 5s)
```

The Wi-Fi association is **never dropped** — that is the whole point of P2P-GO
mode over `airdrop.sh`'s exclusive path. `go0` holds its own channel context
while `wlp2s0` stays associated somewhere else.

**Measured cost while the switch is on:** uplink latency goes from ~2 ms to
roughly 200–400 ms, occasionally to ~590 ms, and stays there the entire time
`go0` is up. Packet loss stays at or near 0%. Toggling off returns it
immediately (measured 66 ms / 0% loss the second the GO came down). **Do not
read the elevated RTT as a broken link** — it is the documented dual-channel
cost, and on a busy network a lost packet or two proves nothing.

### What the bar colours mean

Only ever **two labels** — `drop on` and `drop off`. The label answers "can you
receive?" and nothing else; everything more detailed is carried by the colour,
which is what the CSS classes below are for. This was a deliberate call: a
third transient label made the bar look busier than the thing it describes.

| state | label | colour | meaning |
|---|---|---|---|
| `off` | drop off | grey | not running |
| `idle` | drop on | blue | BLE mode only: running, watching Bluetooth, radio not committed |
| `waking` | drop on | blue | click landed, stack coming up (or waiting for the Wi-Fi to settle) |
| `switching` | drop on | amber | station was on 2.4 GHz; the Wi-Fi is being moved to 5 GHz |
| `armed` | drop on | blue | up and advertising |
| `unreachable` | drop on | *(no rule yet)* | up and advertising, but the phone we can see is on a channel we cannot follow to |
| `error` | drop off | red | cannot receive |

`waking` reads as "drop on" deliberately — the click has happened and the
switch **is** on, the radio is just catching up. `error` reads "drop off"
because that is the truth about whether you can receive.

The module writes `waking` itself **on click**, before the daemon has done
anything, so the bar flips on the next 2 s poll instead of ~20 s later. The
user asked for the toggle to feel instant "even if it's not really" — so a blue
label is evidence that *the click landed*, not that anything is working. Check
`airdropd status` for the truth.

`.unreachable` still has no CSS rule and falls through to the default colour.

## Tuning

| env | default | why |
|---|---|---|
| `AIRDROP_MIN_RSSI` | `-70` | Ignore faint adverts. A transfer happens at arm's length; a weak advert is a stranger's phone and waking the radio for it is pure cost. |
| `AIRDROP_WINDOW` | `90` | How long to stay up after a trigger. Also the worst case for how long the radio is committed. |
| `AIRDROP_CONFIRM_TIMEOUT` | `45` | Unanswered prompt → decline. Always-on mode overrides this to `15`, so one unanswered prompt cannot fill the listen backlog. |
| `AIRDROP_DUALCHAN` | `0` | Set `1` to use P2P-GO mode instead of the default AP-channel-borrowing mode. See below. |
| `AIRDROP_GO_CHAN` | `auto` | Which channel `go0` sits on in P2P-GO mode. `auto` runs the full precedence below; an explicit value must be one of `6/36/44/149`. Never rewritten at runtime — the channel currently built is tracked separately, and conflating the two is what once turned `auto` into a constant after the first correction. |
| `AIRDROP_GO_FOLLOW` | `1` | Whether the wrong-channel watch may rebuild the GO on the peer's channel after `AIRDROP_WRONGCHAN_AFTER` seconds of zero overlap. `0` warns and stays put. Under station-first precedence the common answer is "stay" either way. |
| `AIRDROP_WRONGCHAN_AFTER` | `20` | Seconds of continuous zero overlap before the wrong-channel watch acts. |
| `AIRDROP_ALWAYS` | `0` | `1` = no BLE, stay advertising until toggled off. What the waybar switch sets. |
| `AIRDROP_REANNOUNCE` | `5` | Seconds between mDNS re-announcements. The iPhone **does not poll** for receivers — it only ever learns we exist by catching an announce burst, so a receiver that announces once is invisible from a few seconds after arming. Handled in-process by `patches/opendrop-mdns-reannounce.patch`, so it no longer costs a restart. |

The buildable channel set is `6/36/44/149` and is enforced in three places that
must agree: `airdropd`'s `GO_CHANNELS`, `airdrop-helper`'s `go-up` and
`owl-start`, and owl's own switch in `daemon/owl.c`. `132` was in the helper's
list and not in owl's, which built a GO fine and then had owl exit — surfacing
as the unrelated-sounding "awdl0 never appeared".

### Channel policy in `auto`

The **station's** channel wins; the peer's is a fallback used only when the
station is on a channel no GO can be built on. Measured against a phone
advertising `36,36,149,0,0,0,0,36,6,36,149,36,0,0,0,36` with the AP on 36:
following the peer to its dominant 149 gives 2/16 overlap and moved zero bytes
in 60 s, while the station's own 36 is 6/16 of the same sequence and is the
pairing that holds the association.

An **unreadable** station is not a fallback case — it used to be, and that was
the bug described two sections down. It now refuses and waits.

Consequence worth knowing: when the phone is on a *different* AP from us, we
now stay put and go `unreachable` rather than chasing it.

The full precedence, in order:

1. Station's channel is **unreadable** → refuse and retry in 2 s (see below).
2. Station is on **2.4 GHz** → band-lock to 5 GHz if possible, else refuse.
3. Station is on a **buildable** channel (`6/36/44/149`) → follow it.
4. Peer hint is buildable → use it.
5. Station is on **any other 5 GHz** channel (40, 48, 100, 157, 161 …) → ch149.
   Confirmed on a station on ch157 and again on ch100: the association held for
   the full window. This is why a 5 GHz AP outside the buildable set is no
   longer a dead end.
6. **No managed vif at all** and no peer → ch149.

### An unreadable station means "wait", not "no constraint"

`iw dev <if> info` only prints a channel line when the interface actually has
one, so a station that is mid-roam, scanning, or between associations reads as
empty — and empty is **not** the same as "there is no station".

This was a real bug, fixed 2026-08-04. Every guard was written
`[ -n "$sta_chan" ] && …`, so an empty read skipped the 2.4 GHz refusal, the
follow-the-station arm and the unbuildable-5 GHz arm alike, and fell through to
the last-resort ch149 arm. Building a blind ch149 GO is the most dangerous
thing to do without knowing the station's band: if it then lands on 2.4 GHz,
that is the pairing measured to drop the association.

Seen live: the daemon refused correctly on ch11 at 10:05:46, then at 10:11:37 —
mid-reassociation — read nothing and logged `no STA channel and no peer hint -
last-resort ch149` before bringing `go0` up. The radio had not changed. The
*read* had.

`sta_channel()` now reports three states, and only one of them is
unconstrained:

| `STA_STATE` | meaning | effect |
|---|---|---|
| `ok` | associated | normal policy |
| `unknown` | a managed vif exists but has no channel right now | refuse, retry every 2 s |
| `none` | no managed vif at all | genuinely unconstrained; may use ch149 |

`unknown` is retried on a short fixed interval rather than the escalating
backoff, because the gap is a second or two and the old ladder would have been
sleeping 40 s waiting for something that resolved long ago. Measured against a
forced reassociation: a ~2.5 s window in which the old code would have built
ch149 blind on all 10 consecutive ticks; the new code held off on all 10.

The health watch had the identical fail-open and now resolves an unknown read
with a few 1 s polls rather than skipping a whole 5 s tick while holding a
configuration that can drop the link.

Related: `sta_iface()` used to take whichever managed vif `iw dev` printed
first — roughly reverse creation order, so **any second managed vif on the phy
shadows the real station**. It now prefers an associated one.

### If the station is on 2.4 GHz

A 2.4 GHz association provably cannot survive a second chanctx — measured, and
the predictor is the station's own band, not whether the two channels match:

| station | GO | result |
|---|---|---|
| ch2 (2.4) | 149 | association **lost** |
| ch2 (2.4) | 6 | association **lost** — *same band, still fails* |
| ch36 (5) | 149 | held, 60 s clean, 0% loss |
| ch36 (5) | 36 | held |

**At bring-up** the daemon now takes the band rather than refusing. If the SSID
you are on also has a 5 GHz BSS, `802-11-wireless.band` is locked to `a` for
the session, the connection is reactivated, and the bar shows `switching` while
it lands. Released when the switch goes off. Measured end to end from a station
forced onto ch11: locked, reassociated to ch100 in 1 s, GO up on ch149, armed
at 3 s, internet up throughout.

Guards on it, all of which matter:

- **Never locks without confirming the SSID has a 5 GHz BSS.** Locking to `a`
  with no 5 GHz AP in range is not degraded AirDrop, it is no Wi-Fi at all.
  Single-band SSID → the old refusal, unchanged.
- **Once per run.** A station that stays on 2.4 GHz anyway is waited out, not
  reassociated in a loop on every retry tick.
- **`nmcli connection up` alone**, never a `disconnect` + `connect` pair — those
  two activations race NetworkManager's own autoconnect, and the observed result
  was an association that lasted about a second and then deauthenticated with no
  retry.
- **The lock outlives the process**, because it is written into the saved NM
  profile on disk rather than the running connection. The record is a file, and
  a stale lock from a killed run is released at the next start.
- **Release restores the setting only** and does not reactivate — the station is
  on 5 GHz by then, and forcing another activation would bounce the link a
  second time on the way out for no benefit.

**Mid-session** the health watch still tears the GO down within one 5 s tick if
the station roams to 2.4 GHz, then tries the same band lock once before falling
back to waiting for 5 GHz. Protecting the Wi-Fi outranks keeping AirDrop up.
This is a guard, not roam *following*: nothing tracks the station between
5 GHz channels while the stack is up.

### P2P-GO mode (`AIRDROP_DUALCHAN=1`) — opt-in, and what the switch runs

The default mode borrows whatever channel the AP is already on for AWDL —
which only works when the phone's AWDL happens to land there ([§38, the
original constraint](https://github.com/jedbillyb/mt7921-dual-channel)).
Setting `AIRDROP_DUALCHAN=1` switches `serve_window` to
[`mt7921-dual-channel`](https://github.com/jedbillyb/mt7921-dual-channel)'s
mechanism instead: `airdrop-helper go-up "$AIRDROP_GO_CHAN"` brings up a
`go0` P2P-GO vif on a channel chosen independently of the AP's, then a `mon0`
monitor vif with its MAC address aliased to `go0`'s, which `owl` runs against.
`go-down` tears both down. No `KEEP_WIFI`-style channel-context borrowing is
involved, and the association is never touched.

Requires the patched hostapd from that repo as `/usr/local/bin/airdrop-go-hostapd`
(see Install). `airdropd` refuses to start with `AIRDROP_DUALCHAN=1` if it is
missing, rather than failing later in a way that looks like a radio fault.

The **band lock** additionally uses `nmcli connection modify`, which needs
`org.freedesktop.NetworkManager.settings.modify.system` — check with
`nmcli general permissions`. No sudo, no extra rule. Without it the lock fails
cleanly and you get the old 2.4 GHz refusal.

**This mode is newer than the default, but it is now the better-exercised of
the two** — it is what the waybar switch runs, and it is the one that has
carried a real transfer to 99.1%. Active-monitor ACKs against a GO-held chanctx
are answered by that run: unicast AWDL got through, so `mon1 flags active`
MAC-aliased to `go0` does ACK.

It still defaults to `0` in the file, for two reasons: it needs the patched
hostapd above, which the default mode does not, and it costs ~200–400 ms of
uplink latency the whole time `go0` is up. The waybar module opts in
explicitly rather than the default being flipped, so running `airdropd` by hand
gets the dependency-free mode.

The *default* mode is the one with the stale caveat: it borrows the AP's
channel and has never been shown to complete a transfer either.

## Known-good and not-yet-proven

**Measured working:** BLE detection of real Apple Continuity adverts with RSSI;
correct filtering to type `0x05`; **no self-triggering** from our own
`blewake.sh` advert (verified with the advert registered — btmon shows outgoing
commands too, so this needed an explicit direction filter); helper up/down/status
with the association surviving throughout; all six confirmation paths above;
valid waybar JSON. The BLE trigger has since fired against a real iPhone: 297
type-`0x05` adverts at −26 dBm the moment the share sheet opened, `airdropd`
armed in 5 s, and a 4-minute control with the sheet closed saw **zero**.

**A real transfer has come through `airdropd` in always-on P2P-GO mode** — a
666 KB photo, **99.1% of it** (660,490 of 666,346 bytes) at ~73 kB/s with Wi-Fi
up throughout (§47). So discovery, `/Ask`, consent and the bulk of `/Upload`
all work through the daemon.

**Not yet proven: a transfer that completes.** The tail is lost (see
limitations), and the accept-race fix in §48 — which was turning *every* accept
into a 403 — landed after that run and has not been retested against a phone.
Retest a plain transfer before chasing anything more exotic.

For a receive that is proven to complete right now, use the standalone
`airdrop.sh` exclusive path (a full 2.56 MB photo, byte-exact, PIL-verified),
not the daemon. It drops your Wi-Fi for the duration.

## Limitations

Current, honest, and roughly in the order you are likely to hit them.

1. **The tail of a transfer is lost.** 99.1% arrived; it died in the last
   5,856 bytes. The phone collapses its channel-sequence window 15/16 → 5/16 →
   2/16 *during* the transfer and why is **unknown**. One untested hypothesis:
   INTERSECT mirrors the peer downward, so a brief dip narrows our
   advertisement, which may make it dip further — a feedback collapse.
2. **opendrop crashes on a truncated stream** rather than salvaging it
   (`ValueError: invalid literal for int() with base 16: b''` from
   `_next_chunk()` on EOF). The 660 KB survived only because the iOS 26 patch
   buffers the body to disk first.
3. **You are only visible on AirDrop → Everyone.** opendrop has no Apple ID
   validation record, and **iOS silently reverts Everyone → Contacts Only after
   ~10 minutes** with no outward sign. This is the single most common cause of
   "it stopped seeing me". Contacts-only needs an Apple-key-signed record and is
   genuinely not forgeable.
4. **A single-band 2.4 GHz SSID cannot work at all.** The band lock needs a
   5 GHz BSS on the same SSID to move to; without one the switch refuses and
   says so.
5. **Uplink latency is ~200–400 ms the whole time the switch is on.** Not a
   fault, not fixable from here — it is the cost of the second channel context.
6. **No roam following.** The GO tracks the station at bring-up only. Roaming
   between 5 GHz channels is undetected; roaming to 2.4 GHz is caught and
   protected against, but not followed.
7. **The GO cannot retune in place.** `hostapd_cli chan_switch` FAILs on every
   parameter form on this phy, including a same-subband 149→153 hop, so changing
   the GO's channel means a full teardown and bring-up — a few seconds of
   downtime.
8. **owl's channel switching is a no-op under P2P-GO.** 2425 of 2425 captured
   frames sat on 5180 MHz in a window where owl logged 20 switches. `go0` owns
   the channel context. Do not reason about owl's hopping in this mode.
9. **Killed opendrop instances do not deregister**, so the phone can show ghost
   duplicate `void-btw` entries. Flush by toggling AirDrop off and on on the
   phone (which also rotates its MAC).
10. **The consent prompt auto-declines after 15 s** in always-on mode. It no
    longer needs to be that tight now the server is threaded, but it still is.
11. **`~/owl/.venv-opendrop` is not version controlled.** Every opendrop fix
    lives in `patches/` and must be reapplied after a venv rebuild.

## Gotchas paid for already

- **`stdbuf -oL btmon` is load-bearing.** btmon's stdout is a pipe here, so libc
  gives it 4 KiB full buffering and nothing arrives until it fills. Piping btmon
  straight into the parser produced **zero output over 20 s** while the identical
  parse of a captured file worked every time.
- **Parse the bytes, not btmon's labels.** btmon renders unrecognised Continuity
  subtypes as `Type: Unknown (16)` and its label set varies by bluez version.
- **Continuity type `1` is real**, not a parser artefact — the advert is
  literally `4c 00 01 00 …`, which btmon labels "Identifier". Only type `0`
  (padding) needed suppressing. Don't "fix" it.
- **The mt7921 autodetect must skip monitor vifs.** They are mt7921-driven too
  and `mon0` sorts before `wlp2s0`, so a naive driver match picks a monitor vif
  whenever the stack is up — and then `status` reports `assoc:false, chan:null`
  about an interface with no association, while the real link is fine.
  `airdrop.sh` escapes this only because it resolves the interface before
  creating any vifs.
- **Picking "the station" by taking the first managed vif is wrong.** `iw dev`
  prints roughly reverse creation order, so any second managed vif on the phy
  shadows the real one. `airdropd`'s `sta_iface()` prefers an *associated* vif
  for exactly this reason — a scratch `sta1` left over from a test made the
  daemon report the live, associated `wlp2s0` as mid-roam.
- **`ss` prints its column header even when nothing matches**, so
  `ss -tn ... | grep -q .` is always true. That is what made the mDNS
  re-announce guard believe a transfer was permanently in flight, leaving the
  receiver invisible from ~30 s after arming. Use `ss -Htn`.
- **`ss -tlnp | grep python` finds nothing for opendrop** — its comm name is
  `opendrop`. And `ss -tnp` without `-l` lists established connections only, so
  a live listener looks absent both ways. Use `ss -tlnpH | grep "pid=$PID,"`.
- **`/run/airdrop-owl.log` is not truncated between owl restarts**, so grepping
  it for `add peer` matches stale runs and a dead peer looks alive. Gate on the
  live `STATS ... rx_action` counter instead.
- **`pkill -f airdropd` from an inline shell command kills the caller too** —
  the pattern appears in the calling shell's own command line (exit 144). Put
  such kills in a script file.
- **Two `airdropd` in `pgrep -a` is normal.** The health-watch subshell inherits
  the parent's argv. The `flock` file is the pidfile and already prevents
  genuine duplicates.
- **If a helper's exit is not what produces the answer, do not wait on its
  exit.** `swaynag --button-dismiss-no-terminal` dismisses first and runs the
  button's command from a *detached child*, so `airdrop-confirm` tested for the
  Accept marker ~2 ms before it existed and turned every Accept into a 403 — the
  phone just sat on "Waiting". Wait for the answer, not the process.

### First three things to check when "my phone can't see me"

1. **Is AirDrop still on Everyone?** iOS reverts after ~10 minutes silently.
   This is the most common cause by a distance.
2. `grep re-announcing $XDG_RUNTIME_DIR/airdropd/airdropd.log` — if only
   `deferred` lines appear, it is the `ss` bug class above, not the phone.
3. `airdropd status`, not the bar colour. The module writes its own optimistic
   state on click, so blue only means the click landed.
