# On-demand AirDrop (`airdropd`)

Always-on AirDrop the way macOS actually does it: **idle on Bluetooth, wake on
Wi-Fi**. A Mac does not hold AWDL up permanently either — it scans BLE
continuously, which costs nothing on the Wi-Fi side, and brings AWDL up only
when an iPhone announces (by opening its share sheet) that it wants to send
something.

That is viable here because **the whole AWDL stack comes up in 0.19 s**
(FINDINGS §39): monitor vifs 0.057 s, OWL to ready 0.117 s, `awdl0` 0.015 s.
The ~90 s time-to-advertising in `airdrop.sh` is almost entirely conservative
fixed `sleep`s, not a requirement.

It also sidesteps the §38 dilemma. Instead of choosing once between "no
internet" and "locked to the AP's channel", the radio is only committed while a
transfer is actually happening.

## Pieces

| file | what it does |
|---|---|
| `ble-watch` | Detects Apple Continuity **AirDrop** adverts (company `0x004C`, type `0x05`) by parsing `btmon`. Prints one JSON line per sighting. |
| `airdrop-helper` | The **only** privileged entry point. `up` / `down` / `status` / `ap-channel`. |
| `airdrop-confirm` | Asks the user, via `swaynag`, whether to accept an incoming file. |
| `airdropd` | Orchestrator: BLE trigger → stack up → advertise → confirm → tear down. |
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
| prompt not answered within 45 s | **decline** |

An unaskable question is not consent.

## Install

Two things need root. Everything else runs as you.

**1. The privileged helper.** A wrapper, not an allowlist of commands —
`sudo tcpdump -w <path>` is an arbitrary-file-write-as-root primitive, so
NOPASSWD on `tcpdump` is indistinguishable from NOPASSWD on everything. `iw` and
`ip` are nearly as bad. The wrapper takes a fixed verb and accepts no paths.

Both privileged programs must be installed **root-owned, outside the repo**:

```sh
sudo install -o root -g root -m 755 daemon/airdrop-helper /usr/local/bin/airdrop-helper
sudo install -o root -g root -m 755 daemon/ble-watch     /usr/local/bin/airdrop-ble-watch
```

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
then open the share sheet. That is what emits the BLE advert `airdropd` waits
for.

## Tuning

| env | default | why |
|---|---|---|
| `AIRDROP_MIN_RSSI` | `-70` | Ignore faint adverts. A transfer happens at arm's length; a weak advert is a stranger's phone and waking the radio for it is pure cost. |
| `AIRDROP_WINDOW` | `90` | How long to stay up after a trigger. Also the worst case for how long the radio is committed. |
| `AIRDROP_CONFIRM_TIMEOUT` | `45` | Unanswered prompt → decline. |

## Known-good and not-yet-proven

**Measured working:** BLE detection of real Apple Continuity adverts with RSSI;
correct filtering to type `0x05`; **no self-triggering** from our own
`blewake.sh` advert (verified with the advert registered — btmon shows outgoing
commands too, so this needed an explicit direction filter); helper up/down/status
with the association surviving throughout; all six confirmation paths above;
valid waybar JSON.

**Not yet proven:** an actual end-to-end transfer through `airdropd`. That needs
a phone. The trigger path in particular has never seen a real iPhone share-sheet
advert — only our own emitted one, which it is designed to ignore.

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
