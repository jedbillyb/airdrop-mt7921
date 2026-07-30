# AWDL / OWL on MT7921 - project notes

## Status: WORKS - synced with an iPhone, and 9bac866 is validated (2026-07-30)
Peer discovery, channel-sequence parsing, master election AND the
follow-the-peer-sequence fix all confirmed against a live iPhone on the MT7921.
Peer held 9.78 s (old behaviour: evicted at ~2-3 s). Radio verifiably hopped
149 -> 6 following the peer's advertised sequence.

The earlier "BLOCKED / monitor RX is dead" state is RESOLVED. It was two
stacked mt7921 bugs, neither of them the kernel:

1. **runtime PM.** `runtime-pm` and `deep-sleep` default to 1; in monitor mode
   nothing keeps the chip awake so it sleeps and delivers ZERO frames, silently.
   Must be set to 0. NOTE debugfs is not mounted by default:
   `sudo mount -t debugfs none /sys/kernel/debug` first.
2. **in-place type switch never retunes the radio.** `iw dev wlp2s0 set type
   monitor` pins the hardware at 5180 MHz forever while `iw` reports whatever
   channel you asked for. THIS was the real 2026-07-25 "tagged 5180" mystery.
   Fix: use a dedicated vif, `iw phy phy0 interface add mon0 type monitor`.
3. Minor: OWL needs `-N` on a pre-made monitor vif, or its own set-monitor-mode
   call fails with EBUSY and it aborts during init.

Use `./hoptest2.sh` (not hoptest.sh - that one has both bugs). Full detail in
FINDINGS.md §9. Working invocation:

    sudo mount -t debugfs none /sys/kernel/debug
    sudo ip link set wlp2s0 down
    sudo iw phy phy0 interface add mon0 type monitor
    sudo ip link set mon0 up
    sudo sh -c 'echo 0 > /sys/kernel/debug/ieee80211/phy0/mt76/runtime-pm'
    sudo sh -c 'echo 0 > /sys/kernel/debug/ieee80211/phy0/mt76/deep-sleep'
    sudo iw dev mon0 set freq 5745
    sudo ./build/daemon/owl -i mon0 -c 149 -N -vv

## NEW open question: the hop lands, but the dwell is short
Independent 20 Hz radio poller over a 60 s run: ch149 97.3%, ch6 2.7%. The
peer's sequence had 1 of 6 non-zero slots on ch6, so ~16.7% was expected. The
radio reaches the away-channel for about a sixth of its scheduled dwell.
That is the §6 research question answered quantitatively: a fully-offloaded
MT7921 CAN be hopped from userspace at AWDL rates, but firmware switch latency
eats most of the away-channel window. Enough to hold a peer, probably not
enough to carry data. Next: measure per-hop switch latency from radio.log.

## Kernel pin - real, but NOT the current problem
- Kernel 6.18 has a broken mt76 monitor-mode RX path (card injects fine,
  captures nothing). 6.12.97 was believed good.
- The pin now actually holds. It took two attempts; see the two 2026-07-30
  GRUB entries below for why `GRUB_DEFAULT=saved` and the "Advanced options"
  submenu silently defeated it. Verified booting 6.12.97_1 unattended.
- CAVEAT: booting the pinned kernel is necessary but NOT sufficient. You also
  need PM off and a dedicated mon0 vif (see the status section at the top).
  6.12.97 alone gives you nothing.
- Still worth checking `uname -r` first if things look broken. But it is no
  longer the whole explanation it used to be.
- Untested: whether the mon0 + PM-off recipe also rescues 6.18. Plausible that
  the "6.18 regression" was always one of these two bugs and the kernel was
  never the variable. Worth one run on 6.18 before trusting the pin story.
- "TX power stuck at 3 dBm" is RETRACTED as a symptom - it reads 3.00 dBm in
  managed mode too, while passing traffic normally. Cosmetic, ignore it.

## Build
- Repo: seemoo-lab/owl at ~/owl (copied off /mnt/shared - NTFS strips exec bit)
- Builds clean on GCC 14, no source changes. Deps: libev, libnl3, libpcap.
- Build: cmake -G Ninja -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -S . -B build
         cmake --build build --target owl
- Binary: ~/owl/build/daemon/owl

## Run - SUPERSEDED, see the status section at the top of this file
The invocation that used to be here ran OWL directly on wlp2s0 with an in-place
`set type monitor`. That hits BOTH mt7921 bugs: the chip sleeps (zero RX) and the
radio stays pinned at 5180 MHz. It cannot work. Kept only so the old logs make
sense. Use `./hoptest2.sh`, or the mon0 + PM-off recipe at the top.

## Discovery notes
- Lone OWL node sits STATIC on its master channel (chanseq_init_static, all
  16 slots = master chan). Default master = ch6 (2.4GHz).
- Local environment is all 5GHz. Must run -c 44 or -c 149 to hear the Mac.
- Mac's advertised sequence seen: 149,149,149,149,149,149,36,36,6,149,149,149,149,149,36,36

## RESOLVED 2026-07-30 - was: peer dropped after ~4 seconds
Fixed by 9bac866 and validated on 2026-07-30 (peer held 9.78 s, radio observed
hopping 149 -> 6). The analysis below was correct. Kept for the record.
- Peer is discovered and added, then DROPPED after ~4 seconds.
- Cause: OWL stays static on one channel while the Mac hops its full sequence
  (149/36/6). OWL misses the availability windows on 36 and 6, can't maintain
  the link, peer ages out.
- FIX: make OWL adopt and FOLLOW the discovered peer's channel sequence instead
  of sitting static. Lives in awdl_switch_channel() in daemon/core.c (~line 279).
  The switch loop already reads channel.sequence[slot] - needs the sequence to
  become the peer's, and the hop timing tight enough that the offload chip keeps
  up. Whether mt7921 firmware latency allows tight-enough hopping is THE research
  question.

## Transfer reality check (further out)
- iPhone on iOS 26.5 => AirDrop-code handshake for non-contacts. OpenDrop can't
  do it. Contacts auth needs a real Apple ID Validation Record (VLD) from a
  device signed into YOUR Apple ID. Can't forge - it's Apple-key-signed.
- Sync (link layer, done) is separate from transfer (auth, hard/maybe-blocked).
- The SYNC result alone is novel and worth writing up regardless of transfer.

## 2026-07-30: kernel pin was never actually durable, fixed properly
- Machine was running 6.18.33_1 despite this doc saying pinned to 6.12.97.
  First attempt (`grub-editenv ... set saved_entry=...6.12.97...`) did NOT
  survive a reboot - after rebooting, `uname -r` was still 6.18.33_1 and
  `saved_entry` had reverted to `gnulinux-simple-...`.
- Root cause: `/etc/default/grub` had `GRUB_DEFAULT=saved` +
  `GRUB_SAVEDEFAULT=true`. That combo re-saves whatever kernel actually
  booted as the new default every boot. The 6.12.97 entry lives inside the
  "Advanced options" submenu; GRUB apparently didn't resolve the saved
  submenu entry at boot time, fell through to the top-level `simple` entry
  (tracks newest installed kernel = 6.18.x), booted that, then re-saved
  `simple` - silently undoing the pin every single time.
- Real fix: hard-set the default in `/etc/default/grub` instead of relying
  on grubenv:
  `GRUB_DEFAULT="gnulinux-6.12.97_1-advanced-2e859942-2a74-4cf8-81d2-1db8a58693e6"`,
  `GRUB_SAVEDEFAULT=false`, then `sudo grub-mkconfig -o /boot/grub/grub.cfg`.
  Confirmed the regenerated grub.cfg now has a literal
  `set default="gnulinux-6.12.97_1-advanced-..."` fallback, not `saved`.
  Backup of the old config: `/etc/default/grub.bak-20260730`.
- Needs an actual reboot onto 6.12.97 before any further OWL testing - monitor
  RX is silently dead on 6.18, see FINDINGS.md §2. If it ever regresses again,
  suspect a `grub-mkconfig` re-run (e.g. from a kernel package update)
  clobbering `/etc/default/grub` back to `GRUB_DEFAULT=saved` - check that
  file first, not just the running kernel.
- The one existing hoptest run (`/mnt/shared/owl-hoptest-20260725-230110/`)
  has ZERO peer/election events in owl.log - consistent with the channel
  mismatch bug below, not a failure of the follow-sequence fix (9bac866).
  That fix has still never been validated against a real device.

## 2026-07-25: radio channel does not match requested channel
- `iw dev wlp2s0 set channel 149` -> `iw info` reports 149, but every frame
  captured arrives tagged 5180 MHz (= channel 36). Plain iw, not OWL's netlink
  path, so this is below OWL entirely.
- Explains 60s OWL run with 1618 outbound lines and ZERO received frames:
  pcap filter is AWDL BSSID only, Mac advertises on 149, radio was on 36.
- Monitor RX itself is fine (22 pkts, 0 dropped) on 6.12.97.
- txpower read 3.00 dBm on 6.12.97 - FINDINGS §2 lists this as a 6.18 symptom.
  Run did not force `txpower fixed 2000`. §2 claim needs qualifying or dropping.
- RESOLVED 2026-07-30: the radio really was on 5180, and mt76 was NOT
  mislabelling. Cause is the in-place `set type monitor` never retuning the
  hardware - it sits at 5180 forever while iw reports the requested channel.
  A dedicated mon0 vif tunes correctly. See FINDINGS.md §9.

## 2026-07-30: kernel pin fix attempt #2 - GRUB doesn't recurse into submenus for default=<id>
- Attempt #1 (hardcode GRUB_DEFAULT to the entry ID, disable GRUB_SAVEDEFAULT)
  still didn't work - had to manually enter "Advanced options" and pick
  6.12.97 by hand after reboot.
- Real root cause: the 6.12.97 entry lives inside the "Advanced options"
  submenu, and GRUB's `default="<id>"` resolution only searches the
  TOP-LEVEL menu list, not recursively into submenus. So the hardcoded ID
  from attempt #1 never matched anything at boot and GRUB silently fell
  back to the first top-level entry (`simple`, tracks newest kernel).
- Fix: `GRUB_DISABLE_SUBMENU=true` in /etc/default/grub, then
  `sudo grub-mkconfig -o /boot/grub/grub.cfg`. This flattens every kernel
  into its own top-level `menuentry` (no more "Advanced options" submenu),
  so the same `gnulinux-6.12.97_1-advanced-...` ID is now directly
  reachable by GRUB's default matching. Verified in the regenerated
  grub.cfg: `set default="gnulinux-6.12.97_1-advanced-..."` and that same
  ID now appears as a top-level `menuentry`, not nested under a submenu.
- Not yet confirmed by an actual unattended reboot - do that next and check
  `uname -r` without touching the keyboard at boot.

## 2026-07-30: monitor RX is dead on the MT7921 - the real blocker
Tried to reproduce the sync against an iPhone (AirDrop sheet open = AWDL
advertising). 1587 log lines, all TX, zero RX. Chased it down; full writeup in
FINDINGS.md §8. Short version:

- Radio DOES tune correctly. chansweep.sh: iw_mhz tracks the requested channel
  exactly on 36/44/149/6. The 07-25 "radio is on 36 while claiming 149" theory
  is dead - that was never the bug.
- `iw set channel` is NOT the culprit. rxtest.sh A/B: zero frames with a channel
  set, without one, and after re-entering monitor mode fresh.
- Frames never leave the chip. rxcounters.sh: netdev rx_packets delta = 0 over
  10s parked on ch2 where the AP was actively serving. Not a pcap/BPF issue.
- Positive control FAILED: zero frames on the AP's own channel, and on 2.4GHz.
  So it is not "nothing was on 149".
- Probable cause: `iw phy phy0 info` lists monitor under supported modes but
  monitor appears in NO valid interface combination. Monitor mode is nominal,
  not functional: set monitor succeeds, netdev enters promiscuous mode, no
  firmware error is logged, nothing is ever delivered.
- Ruled out: kernel (pin verified 6.12.97_1), firmware (pkg from 2026-05-21,
  predates the working result), suspend wedge (fresh boot), regulatory (zero on
  2.4GHz too), userspace grabbers (all confirmed dead).
- FINDINGS §2's "txpower stuck at 3 dBm" is RETRACTED - it reads 3.00 dBm in
  managed mode too while passing traffic fine. Cosmetic mt76 quirk, ignore it.

So sync-log.txt is real but is NOT reproducible today and we do not yet know why
it once worked. 9bac866 still cannot be validated - that needs received frames.

### Next, in order of promise
1. Plug in the AR9271 USB adapter and run OWL on that. ath9k_htc monitor +
   injection actually works. Costs the "can a fully-offloaded chip hop fast
   enough" angle but unblocks validating 9bac866 today. (Not plugged in during
   these tests - lsusb showed only the Foxconn BT device.)
2. Try 6.12.90_1 or 6.12.11_1 (both still installed). Worth considering the
   kernel that worked on 07-25 was one of these and got written down as 6.12.97
   from memory late in a long session. One reboot each to test.
3. Dig at mt7921 monitor support: does a separately-added vif
   (`iw phy phy0 interface add mon0 type monitor`) behave differently from an
   in-place type change? Check mt76 upstream for monitor fixes.

### Test harness safety
chansweep.sh / rxtest.sh / rxcounters.sh all use a bash trap PLUS a
setsid-detached watchdog that restores networking even if the script is kill -9'd
or hangs (a trap cannot survive SIGKILL). Watchdog was verified to fire after a
hard kill before being relied on. Do not add a test here without that pattern -
an earlier ad-hoc monitor-mode command with no trap did drop wifi.

## 2026-07-31: active monitor is pinned at 5180 no matter what - MT7921 is done
New script `activelate.sh`. Every previous active-monitor test created the vif
with `flags active` at creation; nobody had varied the ORDER. Four orderings,
one target frequency (2412, busiest from a scan), radiotap-verified, run twice:

  A plain, tuned after up                          -> 2412  (1883 frames)
  B flags active at create, tuned after up         -> 5180  (13)
  C plain + tuned, THEN set monitor active         -> 5180  (2)
  D flags active at create, tuned while link down  -> 5180  (6)

C is the one that mattered: a vif provably sitting on 2412 and receiving jumps
to 5180 the moment active mode engages, while `iw` keeps saying 2412.

Two gotchas worth remembering:
- `iw dev <vif> set monitor active` returns EBUSY on an up vif; link must be down.
- Monitor flags are NOT readable. `iw dev <vif> info` prints nothing about them,
  so grepping it for "active" always says no. Judge by accepted-or-refused, and
  by the frames.

So AirDrop on the built-in chip is settled in the negative (FINDINGS §13): OWL
needs active mode for ACKs, active mode means 5180 only, and the phone's channel
is not ours to pick. Sync still works and remains the real result.

### Next, in order of promise
1. AR9271 USB adapter for an actual transfer (still not plugged in - lsusb shows
   no Atheros device). Only remaining path to AirDrop, and the only way to reach
   the untested §7 auth wall.
2. One hoptest2.sh run on 6.18.33, then drop the kernel pin (6.18 captures ~10x
   more; only its RX path has been retested so far).
3. Write up the §9 hop-latency result - away-channel dwell 45 ms/visit but hops
   fire ~14x less often than the 16-slot sequence dictates. That is the
   publishable answer to FINDINGS §6.

## 2026-07-31 (later): the pair - active monitor CAN leave 5180
Same day, retracting the entry above. Every test that produced "active mode means
5180" had the active vif alone on the phy. Give it a companion and it behaves:

  plain mon0, tuned to 2437, THEN add mon1 with flags active alongside
  -> mon1 comes up on 2437 with 710 frames (plain alone: 667). No RX penalty.

They share one channel context, so retuning either moves both, both directions -
and retuning mon1 itself works, so OWL needs no patch, just -i mon1 -N.

So the "active monitor retains only 2.5-19% of RX" number was the busy-vs-quiet
channel confound AGAIN, third time, after the methodology rule was written down.
Active mode never cost reception; sitting alone on an empty 5180 did.

airdrop.sh now builds the pair under ACTIVE=1 and no longer skips the sweep.

STILL UNPROVEN: that the firmware really ACKs like this. Flags can't be read
back, so only a live run tells us - layer 2.5's ping6 to the peer link-local
(100% loss, from_peer=0 under plain monitor). Needs the iPhone, share sheet open.

## 2026-07-31 (later still): AIRDROP WORKS ON THE BUILT-IN CHIP
Photo off an iPhone landed on the laptop: IMG_8276.JPG, 4032x3024, 2.06 MB.
Never even reached the §7 auth wall - the phone accepted us.

The ACK question was settled by letting the PHONE initiate. ping6 could never
answer it (100% loss reads the same whether we don't ACK or iOS just ignores
pings from strangers - and §10 took it as proof we don't ACK). In receive mode
the phone sent us 481 packets including TCP POSTs, and TCP cannot progress
without ACKs. So active monitor DOES work here, in the pair config.

Then three OpenDrop bugs, each hidden behind the last, none of them radio:
  1. Discover/Ask read Content-Length; iOS 26 sends them chunked -> TypeError.
  2. Upload only accepted x-cpio; iOS 26 sends x-dvzip -> 406 = "Failed" on phone.
  3. libarchive can't parse dvzip. It's length-prefixed blocks: 4-byte BE header,
     bit 31 = stored, low 31 bits = length, else zlib. 128 KiB per block.
All three in patches/opendrop-ios26-airdrop.patch (venv is gitignored; Void has
no patch(1), use git apply).

Received files go to ~/Downloads.

LEFT UNDONE: RECV_TIME still defaults to 120s. Throughput is only ~0.05 MB/s so
that truncated one transfer 370 bytes from the end. Bump it to ~300.
Also untested: sending TO the phone.
