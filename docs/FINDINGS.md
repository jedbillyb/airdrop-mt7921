# AWDL sync on a MediaTek MT7921 (Filogic 330) with OWL — findings

Status: **link-layer sync with a real Apple device works and is reproducible.**
Peer discovery, channel-sequence parsing, and master election are all confirmed.
One open problem remains (peer ages out after ~4 s); it is characterised at the
end of this document.

> **CORRECTION 2026-07-30 — the above is NOT currently reproducible.** On a fresh
> boot of the pinned 6.12.97 kernel, monitor-mode RX on this MT7921 delivers
> **zero frames**, measured three independent ways (see §8). The sync result in
> §5 did happen — `sync-log.txt` is a real transcript — but it cannot be
> reproduced today, and §2's account of *why* 6.18 differs from 6.12.97 is partly
> wrong. Read §8 before trusting §2 or §4.

This document records what was done and what was observed. It is the basis for a
writeup, not a tutorial.

---

## 1. Hardware and platform

| | |
|---|---|
| Adapter | MEDIATEK MT7921 802.11ax PCIe [Filogic 330], PCI ID `14c3:7961` |
| Subsystem | Lenovo `17aa:e0bc` |
| Driver | `mt7921e` (mt76) |
| Interface | `wlp2s0`, MAC `4c:82:a9:17:65:27` |
| OS | Void Linux (runit; `sv` for service control) |
| Kernel | **6.12.97_1 — pinned, see §2** |
| Toolchain | GCC 14.2.1, CMake 4.2.2, Ninja 1.13.2 |
| Regulatory domain | NZ (`iw reg set NZ`) |

The MT7921 is a fully offloaded chip: channel selection, timing, and the TX path
below the radiotap header live in firmware. That matters for the open problem in
§6 — OWL's software channel-hop schedule has to be honoured by a chip that does
its own scheduling.

## 2. The 6.18 mt76 monitor-RX regression

This was the single largest time sink and is worth stating first, because it
makes every other part of the system look broken.

**Symptom on kernel 6.18 (tested: 6.18.32_1, 6.18.33_1):**

- The card **injects fine.** Frames sent through the pcap TX path go out; they
  are visible to other capture devices.
- The card captures **zero frames in monitor mode.** Not "few", not "only
  beacons" — nothing at all reaches the pcap handle, in an RF environment
  saturated with 2.4 GHz and 5 GHz beacons.
- TX power additionally reads stuck at 3 dBm.
  **RETRACTED 2026-07-30:** this is not a 6.18 symptom. `txpower 3.00 dBm` is
  reported on 6.12.97 too, in *managed* mode, while associated and passing
  traffic normally, and it persists after an explicit
  `iw dev wlp2s0 set txpower fixed 2000`. Meanwhile dmesg logs
  `Limiting TX power to 30 (30 - 0) dBm`. So this is a cosmetic mt76 reporting
  quirk with no diagnostic value. Ignore it.

Because AWDL is a receive-driven protocol — OWL learns peers, their channel
sequences, and their election metrics entirely from received action frames — a
silent RX failure presents as "OWL runs, sends PSFs, and never discovers
anything." There is no error. Nothing logs. The daemon looks healthy.

**How it was diagnosed.** The confound is that on Linux, an interface in monitor
mode can be quietly reclaimed or reconfigured by NetworkManager, wpa_supplicant,
or dhcpcd, which produces the same "no frames" outcome for entirely mundane
reasons. So the test had to eliminate userspace interference before blaming the
driver. That is what `monitor-test.sh` does (kept at
`/mnt/shared/downloads/monitor-test.sh`):

1. Stop `NetworkManager` via runit, then `pkill` `wpa_supplicant` and `dhcpcd`,
   and **prove** none survived by listing remaining processes.
2. Set the regulatory domain, bring the interface down, `iw dev … set monitor
   active`, bring it up, and explicitly force `txpower fixed 2000`.
3. Print `iw dev … info` so the *actual* type / txpower / channel the driver
   settled on is on the record, not the type that was requested.
4. `dmesg -C` to clear the ring buffer, hold active monitor for 15 s, then dump
   only the *new* kernel messages — so any firmware or auth/assoc complaint
   during the hold is unambiguous and not archaeology from boot.
5. An `EXIT INT TERM` trap restores managed mode and networking unconditionally,
   including on Ctrl-C or a hang-kill. (Without this, a failed monitor test
   leaves the machine with no network, which is how you lose an evening.)

Running that identical script under 6.12.97 and under 6.18 isolates the variable
to the kernel: same script, same hardware, same RF environment, same regdomain,
same explicit txpower. Under 6.12.97 the capture floods with beacons. Under 6.18
it stays empty. That is the regression.

**Resolution: pin the kernel.** GRUB `saved_entry` is set to
`gnulinux-6.12.97_1-advanced-…`. 6.18.32_1 and 6.18.33_1 remain installed but
are never booted.

> **Failure mode to remember:** if the setup ever "randomly stops working after a
> reboot," check `uname -r` *first*. If it says 6.18, that is the entire
> explanation. Monitor RX dies silently and every downstream symptom is a red
> herring.

## 3. Build on Void Linux

Upstream is [seemoo-lab/owl](https://github.com/seemoo-lab/owl), at commit
`8e4e840` ("Fix possible buffer overread in wlan string").

**No source changes were required.** It builds clean on GCC 14 with `-Wall
-Wextra`.

Two environment-specific points:

1. **The working copy must live on a real filesystem.** The repo was copied off
   `/mnt/shared` to `~/owl` because that mount is NTFS, which strips the
   executable bit — the build products are unusable in place.
2. **CMake 4 rejects the project's declared minimum.** `CMakeLists.txt` opens
   with `cmake_minimum_required(VERSION 3.5)`, and CMake 4.x refuses
   compatibility with `<3.10`. Rather than patch upstream, override at configure
   time:

```sh
cmake -G Ninja -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -S . -B build
cmake --build build --target owl
```

Dependencies (Void package names differ from the README's Debian/Fedora lists,
but the libraries are the same three): `libpcap` for frame injection and
capture, `libev` for the event loop, `libnl3` for nl80211 interaction.

Binary: `~/owl/build/daemon/owl`.

## 4. Working configuration

Running OWL takes the card away from normal networking for the duration —
expect to lose internet on that interface.

```sh
sudo sv down NetworkManager
sudo pkill -x wpa_supplicant; sudo pkill -x dhcpcd; sleep 1
sudo iw reg set NZ
sudo ip link set wlp2s0 down
sudo ./owl -i wlp2s0 -c 149 -v
```

Restore afterwards:

```sh
sudo ip link set wlp2s0 down
sudo iw dev wlp2s0 set type managed
sudo ip link set wlp2s0 up
sudo sv up NetworkManager
```

**The `-c` flag is the thing that makes or breaks discovery**, and the reason is
structural rather than obvious:

- A lone OWL node does **not** hop. `awdl_state_init()` (`src/state.c:60`) calls
  `awdl_chanseq_init_static(state->channel.sequence, &state->channel.master)`,
  filling all `AWDL_CHANSEQ_LENGTH` (16) slots with a single channel. The
  upstream `awdl_chanseq_init()` call directly above it is commented out.
- The default master channel is **channel 6, i.e. 2.4 GHz**.
- The local environment is entirely 5 GHz, and the Apple device lives there.

So with default settings OWL parks on 2.4 GHz channel 6 and hears nothing,
forever, on a card whose monitor RX is working perfectly. `-c 44` or `-c 149`
moves the static master channel to 5 GHz and discovery starts immediately. OWL
encodes channels with `AWDL_CHAN_ENC_OPCLASS`, and both 44 and 149 have opclass
constants defined (`CHAN_OPCLASS_44`, `CHAN_OPCLASS_149` in `src/channel.h`).

## 5. Sync result

With `-c 149`, OWL synchronises with a real Apple device. Three separate
mechanisms were confirmed working, each observable in `-v` output:

**Peer discovery.** Received action frames are parsed, the peer is inserted into
the hashmap peer table, and `src/peers.c:111` logs `add peer <mac> (<name>)`
with the device's advertised hostname.

**Channel-sequence parsing.** OWL decodes the peer's full 16-slot channel
sequence TLV (`src/rx.c:93`). The Apple device's advertised sequence was read as:

```
149,149,149,149,149,149,36,36,6,149,149,149,149,149,36,36
```

That is a real, correctly-parsed Apple channel sequence: predominantly the
5 GHz social channel 149, with two slots on 36 and one on 2.4 GHz channel 6 —
consistent with a device keeping a foot in the 2.4 GHz social channel for
discovery by legacy peers. Recovering this structure end-to-end (radiotap →
action frame → TLV → per-slot opclass-encoded channels) is the strongest single
piece of evidence that the RX path and the parser are both correct.

**Master election.** `awdl_election_run()` executes on each peer-cleanup tick and
compares `(master_counter, master_metric)`, falling back to sync-tree height and
then MAC address ordering. On adopting a new master it logs the resulting tree
via `src/election.c:118` (`new election tree: …`), formatted as
`self > … > master (met <metric>, ctr <counter>)`. The Apple device won the
election, which is the expected and correct outcome — OWL adopted it as sync
master and slaved its own timing to the peer's.

> **Log evidence — to be pasted in.** The exact `-v` transcript for the run above
> is not archived in this repo. Please drop in the raw lines covering: the `add
> peer` line, the `peer … changed channel sequence to …` line, the `new election
> tree: …` line, and the trailing `remove peer` line ~4 s later. The claims above
> are reconstructed from the source's log-format strings and from the session
> notes; the writeup should quote the real output verbatim.

## 6. Open problem: peer drops after ~4 seconds

The peer is discovered and added, then removed roughly four seconds later, and
the cycle repeats.

**Mechanism.** This is not a bug in discovery — it is the direct consequence of
the static channel sequence described in §4:

1. OWL sits on channel 149 in all 16 slots. It never leaves.
2. The Apple device hops its real sequence: mostly 149, but slots 6, 7, 14, 15
   on channel 36 and slot 8 on channel 6.
3. During the Apple device's excursions to 36 and 6, OWL is on the wrong channel
   and misses those availability windows entirely.
4. The peer's last-seen timestamp goes stale. `awdl_clean_peers()`
   (`daemon/core.c:320`) runs every `PEERS_DEFAULT_CLEAN_INTERVAL` and evicts
   anything older than `PEERS_DEFAULT_TIMEOUT`. Both are declared in
   `src/peers.c:28-29` as `2000000` and `1000000` with a comment reading
   `/* in ms */`, but they are consumed as **microseconds** —
   `cutoff_time = clock_time_us() - state->awdl_state.peers.timeout` — so the
   real values are a **2 s timeout swept by a 1 s cleaner**. Worst-case eviction
   therefore lands between 2 s and 3 s after the last frame, which matches the
   observed ~4 s including the time to first miss. (The `/* in ms */` comment is
   simply wrong; worth noting in the writeup.)

**Direction of the fix.** OWL must adopt and *follow* the discovered peer's
channel sequence instead of remaining static. The machinery is already present:
`awdl_switch_channel()` (`daemon/core.c:279`) computes
`slot = awdl_sync_current_eaw(now, &sync) % AWDL_CHANSEQ_LENGTH`, indexes
`awdl_state->channel.sequence[slot]`, and calls `set_channel()` when the slot's
channel differs from the current one, re-arming itself at
`awdl_sync_next_aw_us()`. It already hops correctly — it is simply hopping over
a sequence with 16 identical entries. Populating `channel.sequence` from the
peer's parsed sequence is the change.

**The actual research question** is not the code change but whether the hardware
can keep up. Each hop calls `set_channel()` down through nl80211 into mt7921
firmware, and AWDL availability windows are short. If mt7921's channel-switch
latency exceeds the window, OWL will arrive on each channel too late to be
useful and the link will not hold no matter how correct the schedule is. Whether
a fully-offloaded MediaTek part can be driven at AWDL hop rates from userspace
is the open question this platform is well placed to answer.

## 7. Scope note: sync is not transfer

Worth stating explicitly so the result is not oversold. Link-layer sync (this
document) and application-layer transfer are separate problems:

- The target iPhone runs iOS 26.5, where AirDrop to a non-contact requires the
  AirDrop-code handshake. OpenDrop does not implement it.
- The contacts path requires a genuine Apple ID Validation Record (VLD) issued
  to a device signed into the same Apple ID. It is Apple-key-signed and cannot
  be forged.

So AirDrop interop is gated on authentication, not on the radio work. The sync
result stands on its own: an open-source AWDL implementation reaching timing and
election agreement with a live Apple device on a fully-offloaded MediaTek chip.

## 8. 2026-07-30: monitor RX on the MT7921 delivers nothing, on the *pinned* kernel

Attempting to re-run the §5 sync against an iPhone (AirDrop sheet open, so AWDL
was actively advertising) produced 1587 log lines of pure TX and **zero received
frames**. Investigating that produced the following, all on kernel 6.12.97_1 on
a fresh boot with the regdomain explicitly set to NZ.

### The radio tunes correctly; that was never the bug

`chansweep.sh` requests channels 36/44/149/6 in turn and records both what `iw`
claims and the radiotap frequency of arriving frames:

```
req_ch=36   iw_claims=36   iw_mhz=5180   frames=0
req_ch=44   iw_claims=44   iw_mhz=5220   frames=0
req_ch=149  iw_claims=149  iw_mhz=5745   frames=0
req_ch=6    iw_claims=6    iw_mhz=2437   frames=0
```

`iw_mhz` tracks `req_ch` exactly in every case, so the 2026-07-25 note about the
radio sitting on 5180 MHz while claiming 149 is **not** a channel-setting bug.
Channel 36 here is a deliberate positive control - the local AP lives there - and
it returned zero frames, which means the control failed and the problem is
upstream of channel selection entirely.

### `iw set channel` is not the culprit either

`monitor-test.sh` (which reported beacons flooding in on 07-25) never sets a
channel, whereas `hoptest.sh` and OWL both do. `rxtest.sh` A/B tests exactly
that, in one session:

```
A_no_channel_set        iw_claims=6    frames=0
B_after_set_ch36        iw_claims=36   frames=0
C_fresh_no_channel_set  iw_claims=36   frames=0
```

RX is dead with and without a channel set, and dead again after tearing monitor
mode down and re-entering it. Set-channel is exonerated.

### The frames never leave the chip

`rxcounters.sh` compares three independent counters over one 10 s monitor window,
parked on channel 2 where the AP was actively serving traffic:

| counter | result |
|---|---|
| mt76 hardware RX (debugfs) | debugfs not present on this build |
| netdev `rx_packets` delta | **0** |
| libpcap frames (tcpdump) | **0** |

The netdev counter sat at 2,002,976 from normal managed-mode use and did not
advance by a single packet. So this is not a pcap, BPF, or filter problem - the
driver hands nothing up at all.

### Probable cause: mt7921 monitor mode is nominal, not functional

`iw phy phy0 info` lists `monitor` under *Supported interface modes*, but the
valid interface combinations are:

```
* #{ managed, P2P-client } <= 2, #{ AP, P2P-GO } <= 1, total <= 2, #channels <= 2
```

**`monitor` appears in no valid combination.** That is consistent with everything
observed: `iw dev wlp2s0 set monitor active` succeeds, the netdev genuinely
enters promiscuous mode (dmesg confirms `entered promiscuous mode` on each
attempt), no firmware error is ever logged, and not one frame is delivered.

Ruled out while narrowing this down:
- **Not a kernel regression from 6.18.** The pin is holding; `uname -r` is
  6.12.97_1 (verified after the GRUB fix, see NOTES.md).
- **Not a firmware update.** `linux-firmware-network-20260410_1`, installed
  2026-05-21, predates the 07-25 working result.
- **Not a suspend/resume wedge.** Fresh boot, no suspend cycle.
- **Not regulatory.** Zero frames on 2.4 GHz ch 6 and ch 2, which no regdomain
  restricts. Under the US rules the card was actually using, ch 149 is 30 dBm
  and not DFS.
- **Not userspace interference.** NetworkManager down, `wpa_supplicant` and
  `dhcpcd` confirmed dead before each test.

### What this means for the project

The §5 sync result is real - `sync-log.txt` is a genuine transcript with a
correctly parsed Apple channel sequence. But it is **not reproducible on this
adapter today**, and the reason it once worked is not yet explained. Until
monitor RX can be recovered, the follow-the-peer-sequence fix (`9bac866`) cannot
be validated, because validating it requires receiving frames.

Three candidate paths, in rough order of promise:

1. **Try the AR9271 USB adapter.** `ath9k_htc` has genuinely solid monitor and
   injection support, unlike a fully-offloaded part. It costs the "can a
   fully-offloaded MediaTek chip be driven at AWDL hop rates" research angle,
   but it would unblock validating `9bac866` immediately. The adapter was not
   plugged in during these tests (`lsusb` showed only the Foxconn Bluetooth
   device).
2. **Try the other installed kernels.** 6.12.90_1 and 6.12.11_1 are both still
   installed. It is worth considering that the kernel which actually worked on
   07-25 was one of those and was recorded as 6.12.97 from memory late in a long
   session. Cheap to test, one reboot each.
3. **Dig into mt7921 monitor support directly.** The missing interface
   combination is the thread to pull - check whether a separately-added monitor
   vif (`iw phy phy0 interface add mon0 type monitor`) behaves differently from
   an in-place type change, and check mt76 upstream for monitor-mode fixes.

### Test harnesses added

`chansweep.sh`, `rxtest.sh`, and `rxcounters.sh` all follow the same safety
pattern: a bash `trap` on EXIT/INT/TERM **plus** an independent `setsid`-detached
watchdog that restores networking even if the script is `kill -9`'d or hangs,
which a trap alone cannot survive. The watchdog mechanism was verified to fire
after a hard kill before being relied on. No test can leave the machine without
wifi.

## 9. 2026-07-30 (later): both bugs found, and `9bac866` is validated

§8 closes. The zero-RX problem was **two independent mt7921 bugs stacked on top of
each other**, and neither is the kernel. With both worked around, OWL synchronised
with an iPhone and the follow-the-peer-channel-sequence fix demonstrably works.

### Bug 1: runtime power management silently kills monitor RX

`runtime-pm` and `deep-sleep` both default to `1`, and `runtime_pm_stats` showed
the chip dozing roughly twice as long as it was awake. In managed mode the
association keeps it awake. In monitor mode nothing does, so it sleeps and
delivers **zero** frames, with no error anywhere.

```
/sys/kernel/debug/ieee80211/phy0/mt76/runtime-pm   -> must be 0
/sys/kernel/debug/ieee80211/phy0/mt76/deep-sleep   -> must be 0
```

Note `debugfs` is **not mounted by default** on this box:
`sudo mount -t debugfs none /sys/kernel/debug` first, or the knobs do not exist.
`pmtest.sh` demonstrates it: PM on = 0 frames, PM off = frames arrive. (The
control phase was not a clean zero, because writing the knob itself wakes the
chip and it stays awake - so treat the knob as "wake and stay awake", not a
clean on/off switch.)

### Bug 2: an in-place interface type switch never retunes the radio

This is the real explanation for the 2026-07-25 "frames tagged 5180 MHz while iw
reports 149" mystery, and it is worse than it looked - the radio never leaves
5180 MHz **at all**.

`iw dev wlp2s0 set type monitor` (what `monitor-test.sh`, `hoptest.sh` and every
earlier harness did) leaves the hardware pinned at 5180 MHz no matter what
channel is requested, while `iw` faithfully reports whatever was asked for. A
**dedicated monitor vif** tunes correctly. `montest.sh`, target 5745 MHz:

| method | dominant RX freq | verdict |
|---|---|---|
| in-place `set type monitor`, 149 set first | 5180 | stuck |
| `set freq 5745` | no frames | - |
| `set freq 5745 HT20` | no frames | - |
| `set channel 149` + link down/up bounce | 5180 | stuck |
| **`iw phy phy0 interface add mon0 type monitor`** | **5745** | **works** |

So the correct setup is:

```sh
sudo mount -t debugfs none /sys/kernel/debug        # if not already mounted
sudo ip link set wlp2s0 down
sudo iw phy phy0 interface add mon0 type monitor
sudo ip link set mon0 up
sudo sh -c 'echo 0 > /sys/kernel/debug/ieee80211/phy0/mt76/runtime-pm'
sudo sh -c 'echo 0 > /sys/kernel/debug/ieee80211/phy0/mt76/deep-sleep'
sudo iw dev mon0 set freq 5745
sudo ./build/daemon/owl -i mon0 -c 149 -N -vv
```

### Bug 3 (minor): OWL needs `-N` on a pre-made monitor vif

OWL calls `set_monitor_mode()` itself (`daemon/io.c:296`). On an interface that is
already a monitor vif **and up**, that nl80211 call fails with `EBUSY` and OWL
aborts before it starts:

```
ERROR: Error while receiving via netlink: Object busy
ERROR: Could not put device in monitor mode: mon0
ERROR: could not initialize core
```

`-N` sets `wlan_no_monitor_mode` and skips the step. The option already existed
upstream; no patch needed.

### Result: sync with an iPhone, and the peer is held

`hoptest2.sh`, 60 s, iPhone with the AirDrop sheet open, OWL on `mon0` at ch 149:

- **2018 frames** captured, including **266 real AWDL action frames** on the AWDL
  BSSID `00:25:00:ff:94:73` from `42:24:66:35:43:0c` at -16 dBm.
- Channel sequence parsed from the phone:
  `149,149,149,0,0,0,0,0,6,149,149,0,0,0,0,0`
- Election resolved correctly, phone winning:
  `new election tree: 4c:82:a9:17:65:27 -> 42:24:66:35:43:c (met 65, ctr 223)`
- **Peer lifetimes: 9.78 s, then a second peer still held when the run ended
  (>= 3.56 s).** Against a 2 s timeout swept by a 1 s cleaner, the old behaviour
  was eviction at ~2-3 s. **`9bac866` is validated.**

### The hop happens - but the dwell is short, and that is the real finding

The independent 20 Hz radio poller (which never reads OWL's state, only the
driver's) recorded the radio on two channels:

| channel | samples | share |
|---|---|---|
| 149 | 1060 | 97.3% |
| 6 | 29 | 2.7% |

So OWL genuinely adopted the peer's sequence and hopped to channel 6, and frames
were captured on both 5745 MHz and 2437 MHz. But the peer's sequence had one
channel-6 slot out of six non-zero slots, i.e. **~16.7% expected against 2.7%
observed** - the radio reaches channel 6 for roughly a sixth of its scheduled
dwell.

That is a direct, quantified answer to the open research question in §6: a
fully-offloaded MT7921 *can* be driven to hop from userspace at AWDL rates, but
firmware channel-switch latency eats most of the availability window on the
away-channel. Enough to hold a peer; probably not enough to carry data reliably
in those slots. Worth measuring properly - per-hop switch latency from the
radio.log timestamps is the obvious next step.

## 10. 2026-07-30: AirDrop is not reachable on the MT7921, and the reason is ACKs

Sync works (§9). Data transfer does not, and the wall is **not** Apple's
authentication - we never got far enough to meet it.

### The measurement: a one-way path

With OWL synced to an iPhone, a peer in the table and an IPv6 neighbour
installed on `awdl0`:

```
ping6 -I awdl0 fe80::4024:66ff:fe35:430c
  5 packets transmitted, 0 received, 100% packet loss
packets on awdl0: total=8  from_peer=0  mdns=2
```

Our mDNS queries went out. Nothing ever came back. So the repeated
"No AirDrop service discovered" was never an auth refusal - no packet from the
phone ever reached us.

### The cause: active monitor mode does not work on this chip

AWDL data frames are unicast, so they must be ACKed. That is what *active*
monitor mode is for, and the OWL README lists it as a hard requirement. The
MT7921 claims to support it:

```
iw phy phy0 info -> "Device supports active monitor (which will ACK incoming frames)"
```

It does not, in any usable sense. `activetest.sh`, parked on channel 3 where the
local AP is, counting all frames over 8 s:

| mon0 created | frames |
|---|---|
| plain | 140 |
| **`flags active`** | **6** |
| plain again | 144 |

Active monitor destroys roughly **96%** of reception. This is the same
nominal-but-not-functional pattern as §8's monitor mode and §9's channel tuning:
the capability is advertised, the call succeeds, no error is logged, and the
hardware quietly fails to do it.

### The consequence: a genuine dead end on this adapter

The two options are mutually exclusive, and neither permits AirDrop:

| mode | RX | ACKs | outcome |
|---|---|---|---|
| plain monitor | works | no | one-way path; AirDrop cannot complete |
| active monitor | ~96% lost | yes | nothing arrives to ACK anyway |

So **AirDrop over the built-in MT7921 is blocked by the adapter**, not by Apple.
The harnesses are therefore set to create `mon0` **plain**: reception is what
makes the sync result in §9 possible, and that result is the valuable part.

This retroactively vindicates the README's hardware requirement. It recommends
an AR9280 (ath9k) precisely because a fully-offloaded chip cannot be trusted to
ACK on a monitor vif. The AR9271 (`ath9k_htc`) on hand is the path to an actual
transfer.

### What is and is not blocked

- **Link-layer sync: works, and is the novel result.** Unaffected by any of this.
- **`9bac866` validation: stands.** It only needed RX, which plain monitor gives.
- **AirDrop transfer on MT7921: blocked at the link layer.** Needs a card with
  working active monitor.
- **AirDrop auth (§7): still untested.** It may well also block, but that is now
  an *unverified* claim - the ACK problem stopped us first, and any future
  attempt should re-measure rather than assume.

## 11. 2026-07-30: confirmed across two kernels - and the 6.18 story was backwards

`activetest.sh` was re-run on **6.18.33_1** to see whether any kernel has a
working mt76 active-monitor path. Channel 3, AP present, all frames counted over
8 s:

| kernel | plain | `flags active` | plain again |
|---|---|---|---|
| 6.12.97_1 | 140 | **6** | 144 |
| 6.18.33_1 | 2000 (hit capture cap) | **9** | 1399 |

### Conclusion 1: active monitor is broken in firmware, not the driver

Two independent kernels, ~5 years of mt76 development apart, produce the same
verdict: enabling active monitor costs 96-99% of reception. This is no longer a
"maybe a newer driver fixes it" situation. **AirDrop over the built-in MT7921 is
not achievable**, and further kernel-hunting is not worth the time.

This is a hard requirement failure, not a tuning problem: OWL's
`set_monitor_mode()` explicitly requests `NL80211_MNTR_FLAG_ACTIVE`
(`daemon/netutils.c:225`), because AWDL data frames are unicast and must be
ACKed. There is no software path around it.

### Conclusion 2: the kernel pin was wrong, and backwards

§2 claimed 6.18 broke mt76 monitor RX and pinned the machine to 6.12.97. That is
now **fully retracted**. 6.18.33 does not merely work - it captures roughly **10x
more frames** than 6.12.97 under identical conditions. The original comparison
was confounded by the runtime-PM bug (§8): both kernels delivered nothing with PM
on, and the difference attributed to the kernel was noise.

So the GRUB pin, and the two-attempt fight to make it stick, addressed a problem
that did not exist. The pin mechanism is correct and documented in NOTES.md, but
6.12.97 is now the *worse* kernel of the two for this work.

**Not yet done:** a full OWL sync run on 6.18.33. Only the RX-path test has been
repeated there. Validate with `./hoptest2.sh` on 6.18 before dropping the pin -
better RX does not automatically mean the rest of the stack behaves.

### Where this leaves the project

| goal | status |
|---|---|
| AWDL link-layer sync | **works** - the novel result, receive-only, unaffected |
| `9bac866` follow-peer-sequence fix | **validated** (§9) |
| Hop-latency characterisation | **measured** (§9) |
| AirDrop transfer on MT7921 | **impossible** - firmware cannot ACK on a monitor vif |
| AirDrop transfer at all | needs ath9k / AR9271; auth (§7) still untested beyond that |


## 12. 2026-07-30: CORRECTION - §10 and §11 were based on an invalid comparison

§10 and §11 concluded that active monitor "destroys 96-99% of RX" and that this
was a firmware limitation confirmed across two kernels. **That conclusion was
not supported by the data.** The test never verified what frequency each phase
was actually on.

`activetest.sh` requested 2422 MHz for every phase. Checking the radiotap
frequency of the captured frames afterwards:

| phase | frames | actual frequency |
|---|---|---|
| plain | 2000 | 2422 (busy 2.4 GHz, AP present) |
| `flags active` | 9 | **5180** (quiet 5 GHz) |
| plain again | 1399 | 2422 |

The active phase silently never left 5180. So a busy channel was compared
against a quiet one and the difference was attributed to ACKs. 9 frames on 5180
is entirely normal here - earlier 5 GHz captures in §9 gave 1-10 frames.

This is the same error as the retracted "the radio tunes correctly" claim in §8:
trusting a frame count without checking which channel produced it. On this chip
`iw`'s reported channel is unreliable, so **the radiotap frequency of received
frames is the only trustworthy indicator** and must be checked in every
comparison.

### Corrected result (`activetest2.sh`, both modes on both frequencies)

| target | mode | actual rx | frames |
|---|---|---|---|
| 2422 | plain | 2422 | 156 |
| 2422 | active | **5180 (off target)** | 7 |
| 5180 | plain | 5180 | 186 |
| 5180 | active | 5180 | **35** |

Two separate findings, neither as previously stated:

1. **Active monitor cannot retune.** It stays on 5180 MHz whatever is requested,
   and `iw dev mon0 info` reports no channel at all for it. This, not reception,
   is the real defect.
2. **At equal frequency, active monitor costs ~81% of reception (186 -> 35) and
   still works.** Degraded, not broken. The "96-99%" figure was an artefact of
   the channel confound.

### What this opens up

5180 MHz is channel 36, which the iPhone was repeatedly observed to favour
(36-dominant sequences in §9 and later runs). So active monitor being pinned
there is not necessarily fatal:

- ACKs work, so unicast AWDL data can be acknowledged - the thing that made the
  path one-way in §10.
- No channel hopping is possible, so OWL must sit statically on ch36 and will
  miss the peer's slots on other channels.

That trade is worth testing: `ACTIVE=1 ./airdrop.sh` now selects active monitor,
skips the channel sweep, and forces ch36. If layer 2.5 reports bidirectional IP,
AirDrop on the built-in MT7921 is back in play.

**§10's "AirDrop is not reachable on the MT7921" and §11's "confirmed in
firmware across two kernels" should both be treated as withdrawn pending that
test.** §11's other finding - that 6.18.33 captures far more than 6.12.97 and the
6.18 monitor-RX regression in §2 is retracted - was measured on same-frequency
captures (2422 in both cases) and still stands.


### 12a. Second same-frequency measurement of the active-monitor RX cost

`awdltest.sh`, 6.18.33, both phases verified on 5180 MHz, back-to-back, 20 s each:

| mode | all frames | AWDL frames |
|---|---|---|
| plain | 401 | 0 |
| active | **10** | 0 |

Combined with `activetest2.sh` (186 vs 35 on 5180), there are now two properly
controlled, same-frequency measurements. Active monitor retains only **2.5-19%**
of plain reception. The direction of §10's claim was right; the "96-99%" figure
it quoted was not, and only these same-frequency numbers should be cited.

The AWDL question itself is **still unanswered**: both phases saw zero AWDL
frames because the phone was not advertising on ch36 during the run, so the run
is void by the script's own guard rather than being read as a result.

**Structural problem this exposes.** Active monitor cannot retune, so it can only
ever listen on 5180 MHz (ch36). The phone's channel usage is not under our
control and was observed on ch6 and ch149 as often as ch36. So even if active
monitor could hear AWDL in principle, it can only do so during the fraction of
time the phone happens to favour ch36 - and it must do that while receiving under
10% of frames. Both constraints have to be satisfied at once.

That makes AirDrop on this chip unlikely rather than merely unproven, but the
honest status is: **not yet established either way.** Confirming it requires a
run where plain monitor sees AWDL frames on ch36 (proving the phone is reachable
there) and active monitor is then given the same opportunity.


## 13. 2026-07-31: the 5180 pin survives every ordering - the built-in chip is out

§10-§12 all rested on active-monitor vifs created with `flags active` **at
creation time**, which then refused to leave 5180 MHz. That left an obvious
untested variable: the *order* of the two operations. If the firmware only
rejects a retune while active mode is already engaged, tuning first and enabling
active afterwards would give both at once - and AirDrop would be back on.

`activelate.sh` tests four orderings against one target frequency. The target is
the busiest 2.4 GHz channel from a scan (2412 MHz here), chosen so there is
always traffic to read a radiotap frequency from and so the result can never be
confused with 5180. Run twice, 15 s per phase, kernel 6.12.97_1:

| ordering | active accepted | `iw` says | **actual freq** | frames |
|---|---|---|---|---|
| A plain, up, set freq | n/a | 2412 | **2412** | 1883 |
| B `flags active` at create, up, set freq | yes | 2412 | **5180** | 13 |
| C plain, up, set freq, **then** `set monitor active` | yes | 2412 | **5180** | 2 |
| D `flags active` at create, set freq while **down**, then up | yes | 2412 | **5180** | 6 |

Ordering makes no difference. The instant the vif is in active mode the radio is
at 5180, whether it got there before tuning, after tuning, or while down. C is
the decisive one: that vif was demonstrably sitting on 2412 and receiving, and
switching it to active moved the radio to 5180 underneath a netdev that kept
reporting 2412.

Two incidental notes:

- `iw dev <vif> set monitor active` on an up monitor vif returns **EBUSY (-16)**;
  it only takes with the link down. The script cycles the link and does not
  re-tune afterwards, which is what makes C a real test.
- **Monitor flags cannot be read back at all.** `iw dev <vif> info` prints
  type/wiphy/addr and nothing else, identically for a vif created with
  `flags active` and a plain one. Any check that greps that output for "active"
  reports `no` unconditionally - the first cut of this script did exactly that
  and produced a wrong verdict line. The only observable is whether the kernel
  *accepted* the request, so that is what the table records. This is a third face
  of the same METHODOLOGY RULE: on this chip, ask the frames, not the tooling.

### Verdict: AirDrop is not reachable on the MT7921  — **RETRACTED, see §14**

> Superseded within the hour by `activelate2.sh`. The premise below - that active
> mode implies 5180 by every available route - was false: no phase here had tried
> creating the active vif *alongside* a plain vif that already owns the channel.
> Everything from "Not 'unlikely'" to the end of this section is withdrawn.

Not "unlikely" - the constraint is now structural and reproduced. OWL requires
`NL80211_MNTR_FLAG_ACTIVE` for unicast ACKs (`daemon/netutils.c:225`), active
mode forces 5180 MHz by every available route, and the phone's channel is not
ours to choose. §12's "not yet established either way" is resolved in the
negative, and it no longer depends on catching the phone on ch36: even a perfect
ch36 run could not produce a general AirDrop path, because the peer is free to
sit on 6 or 149 and we could not follow it.

What still stands, and is the actual result of this project: **AWDL sync works on
the MT7921** (§9 - peer held 9.78 s, 266 action frames, radio observed following
the peer's sequence), and the hop-latency measurement in §9 is the publishable
part. Transfer needs a card with working active monitor - the AR9271
(`ath9k_htc`). The §7 auth wall remains untested; nothing here touches it.


## 14. 2026-07-31: the way out - an active vif that RIDES a plain vif's channel

§13 concluded AirDrop was unreachable because active mode always meant 5180 MHz.
Every phase that produced that conclusion, across every script since §10, had one
thing in common: the active vif was **the only vif on the phy**. Nobody had tried
giving it a companion.

`activelate2.sh`, target 2437 MHz (busiest from a scan), radiotap-verified:

| phase | setup | actual freq | frames |
|---|---|---|---|
| A | plain alone, tuned while up | 2437 | 667 |
| E | plain tuned, **deleted**, then active vif created | 5180 | 17 |
| F | active vif created **alongside** the tuned plain vif | **2437** | **710** |

E rules out the simple explanation (the channel is not remembered across the
vif's lifetime). F is the result: an active monitor vif that comes up on the
channel a plain vif is already holding, **with no reception penalty at all** -
710 frames against the plain baseline's 667.

That reframes every RX number since §10. `flags active` was never costing us
reception; being dumped alone on an empty 5180 MHz was. The "active monitor
retains only 2.5-19% of plain reception" figure from §12/§12a measured a quiet
channel against a busy one one more time - in a different disguise, and after the
METHODOLOGY RULE was already written down.

### It hops, too, and OWL can steer it itself

`activelate3.sh`, two runs (2412/2462 and 2437/2412), capturing on the **active**
vif throughout:

| step | action | active vif lands on |
|---|---|---|
| 1 | pair brought up on f1 | f1 (736 frames) |
| 2 | retune the **plain** vif to f2 | **f2** (1239) |
| 3 | retune the plain vif back to f1 | **f1** (288) |
| 4 | retune the **active** vif itself to f2 | **f2** (938) |

The two vifs share a single channel context: moving either moves both, in both
directions. Step 4 matters for integration - OWL retunes its own interface, so it
can simply be pointed at the active vif and needs no patch.

### Where this leaves AirDrop

Both blockers are gone at the radio level. OWL can have ACKs (`flags active`, for
the unicast AWDL data frames `daemon/netutils.c:225` demands) **and** follow the
peer's channel sequence, at full reception, on the built-in MT7921. §13's verdict
is withdrawn; §12's "not established either way" is the honest status again.

`airdrop.sh` now builds the pair when `ACTIVE=1`: plain `mon0` created and tuned
first, active `mon1` added alongside, OWL run on `mon1`. The channel sweep is no
longer skipped in active mode, since the pair retunes freely.

**Still unproven, and it is the whole question:** that the firmware actually
emits ACKs in this configuration. Monitor flags cannot be read back, so no amount
of local inspection settles it - only a live run does. The test is layer 2.5 of
`airdrop.sh`: `ping6` to the peer's link-local address, where plain monitor
previously gave 100% loss and `from_peer=0` (§10). Bidirectional IP there is the
proof; anything less and the ACK question is still open. Needs an iPhone with the
share sheet open. The §7 auth wall remains untouched beyond that.


## 15. 2026-07-31: AirDrop works on the built-in MT7921

A photo sent from an iPhone arrived on the laptop over the built-in MT7921:
`IMG_8276.JPG`, 4032x3024, 2.06 MB, extracted from the transfer intact. §7's
auth wall - untested since the project started - was never reached, because the
phone accepted us without it.

### The ACK question, settled by letting the phone initiate

§14 left one thing unproven: whether the firmware really ACKs in the pair
configuration. `ping6` could not answer it - 100% loss is equally consistent
with "no ACKs" and "iOS ignores pings from an unknown AWDL peer", and §10 read
that ambiguous result as proof of the former.

`airdrop.sh receive` settles it, because if the **phone** initiates then it must
send unicast to us, and unicast only completes if we ACK:

| run | packets from the peer |
|---|---|
| ping6, we initiate (§10, §14) | 0 |
| receive mode, phone initiates | **481** |

Those 481 included TCP HTTP POSTs to OpenDrop's server. TCP cannot progress
without ACKs, so the chip is ACKing. **Active monitor works on the MT7921** in
the pair configuration, and §10's "active monitor mode does not work on this
chip" is withdrawn along with the dead-end verdicts built on it.

The mt76 core does advertise `NL80211_FEATURE_ACTIVE_MONITOR` for every driver
it supports (`mac80211.c:442`), and no mt76 driver reads `MNTR_FLAG` anywhere -
that is true, and it is not evidence of anything. ACK generation is in hardware
off the address filter; no per-driver flag handling is needed for it to work.

### Three OpenDrop bugs stood between sync and a file

Each surfaced only once the previous one was fixed, and none is a radio problem.
All three are in `patches/opendrop-ios26-airdrop.patch`.

1. `handle_discover`/`handle_ask` read `int(self.headers["Content-Length"])`.
   iOS 26 sends both chunked with no Content-Length -> `TypeError` on None, and
   the connection died before any reply. The phone's sheet showed nothing.
2. `handle_upload` accepted only `application/x-cpio` and answered 406 to iOS
   26's `application/x-dvzip` - after the user had tapped send. That 406 is what
   the phone reports as "Failed".
3. libarchive cannot parse dvzip. It is a run of length-prefixed blocks: 4-byte
   big-endian header, bit 31 = payload is STORED, low 31 bits = payload length,
   otherwise the payload is a zlib stream. Blocks decompress to 128 KiB each
   except the last. The 2.06 MB transfer was 17 blocks consuming the file
   exactly, yielding an ODC cpio ("070707") holding the photo.

### The full working recipe

```sh
sudo iw phy phy0 interface add mon0 type monitor          # plain, FIRST
sudo ip link set mon0 up
sudo iw dev mon0 set freq <target>                        # mon0 owns the channel
sudo iw phy phy0 interface add mon1 type monitor flags active   # alongside
sudo ip link set mon1 up
# PM off on both, then OWL on the ACTIVE vif:
sudo ./build/daemon/owl -i mon1 -c <chan> -N -vv
```

or just `ACTIVE=1 ./airdrop.sh receive`, which does all of it.

### Known rough edges

- **Throughput is ~0.05 MB/s.** A 2 MB photo needs 40-60 s *after* the user taps.
  `RECV_TIME` still defaults to 120 s, which cut one transfer off 370 bytes from
  the end - the saved archive is then genuinely truncated, not mis-decoded. Raise
  the default to ~300 s. This is the one fix identified but not applied.
- Sending *to* the phone (`./airdrop.sh send`) is untested; only receive is proven.
- The slow throughput is probably the §9 hop-latency finding showing up as
  bandwidth - worth measuring against a fixed channel.

## 16. 2026-07-31: the ~50 kB/s ceiling is duty cycle, not rate
> **Read with §17 and §18.** The burst measurement below stands. The *cause* named
> in "The actual cause" is wrong (§17), and the receive-window theory that followed
> is also ruled out (§18).

Answering the last rough edge in §15, entirely from the logs of the successful
2.06 MB receive (`owl-airdrop-20260731-111821`) - no new hardware runs. §15
guessed the cause was §9's hop latency showing up as bandwidth. That guess was
wrong, and so was a second guess made along the way.

### The measurement: the transfer is bursty, and the bursts are one slot long

Splitting the inbound TCP stream on gaps longer than 150 ms:

| quantity | value |
|---|---|
| bursts | 94 |
| mean bytes per burst | 25.2 kB |
| mean burst duration | 68 ms |
| in-burst rate | ~3.0 Mbit/s |
| gap between bursts | 400-550 ms, largest 1049 ms |

A burst is **68 ms long, which is one AWDL slot** (64 TU = 65.536 ms). The
largest gap is **1049 ms, which is exactly one 16-slot sequence period**. The
gaps are quantised to the channel sequence, not to anything in the RF or the
software.

Duty cycle is therefore 68/(68+450) ≈ 13%, and 3.0 Mbit/s × 13% ≈ 0.4 Mbit/s ≈
50 kB/s. The arithmetic closes exactly. Overall, **96% of the transfer is spent
waiting**, 88% of it in gaps longer than 200 ms.

So the radio is not slow. When we are on-channel we move 25 kB in a single
window at 3 Mbit/s. We simply only get one usable window in about seven.

### Two causes ruled out

- **Not RF loss.** Retransmissions were ~4% (66 duplicate sequence numbers out
  of 1743 data segments).
- **Not the blocking `set_channel()`.** This one is worth recording because it
  is a genuine defect that is nevertheless *not* the answer. `set_channel()` in
  `daemon/netutils.c` ends in a synchronous `nl_recvmsgs_default()`, called from
  `awdl_switch_channel()` inside the libev loop, so OWL stops servicing pcap and
  the tun for the duration. Measured over 734 switches: mean 8.5 ms, p50 8.1 ms,
  p90 9.5 ms, max 10.1 ms, uniform across bands (ch 6: 8.1 ms, ch 149: 8.8 ms).
  At 3.5 switches/s that is ~30% of OWL's loop time. Real, worth fixing, and
  entirely incapable of explaining 450 ms gaps. I had most of a case built for
  this before checking the gap distribution; the gap histogram killed it.

### The proposed cause — **WRONG, see §17.** Kept because the error is instructive.

`awdl_adopt_sync_master_chanseq()` adopted the channel sequence of whichever
peer won the *election*. That is right for staying in sync and wrong for being
present when your transfer peer is on air, because in any room with several
Apple devices the election winner is usually a bystander.

In this run the transfer peer was `3a:dd:74:15:95:5c` (the phone,
`fe80::38dd:74ff:fe15:955c`). The sync master was `82:49:5e:10:cf:cc` - a
different device - from 11:18:55 until 11:20:02. The transfer began at 11:20:04,
two seconds after the election happened to swing to the phone. It got going by
luck. Mid-transfer the master wandered to a third device, `76:b9:83:a8:e5:c2`,
and briefly to no master at all.

Corroborating waste: correlating each inbound packet against the 20 Hz radio
poller, data arrived only on channels 149 (1181 packets), 6 (456) and 132 (106).
Channels 36, 44 and 108 took **8.3% of radio time and received zero packets** -
and every visit to them also costs an 8.5 ms switch.

### The fix

Track the last AWDL *data* frame per peer (`peer->last_data_rx`; sync and
election frames do not count, since every peer in earshot sends those) and
prefer the most recent data peer over the elected master when choosing a channel
sequence. Sync accuracy is untouched - `awdl_sync_*` still tracks the elected
master; this only decides which availability windows we try to be present for.

Also removed: the revert-to-static-sequence path no longer fires merely because
we are our own sync master. Being our own master says nothing about whether a
transfer is in flight, and dropping the peer's sequence mid-transfer causes the
exact stall being fixed.

The peer table ages entries out after 2 s and adoption re-runs every 1 s, so the
5 s data-peer window cannot cause flapping - a peer that goes quiet is removed
before the window expires.

**This fix was tested against the phone and made throughput ~6x WORSE. It is
reverted. See §17.**

### Still open

- The blocking `set_channel()` (~30% of loop time) is worth making asynchronous
  regardless.
- Pruning sequence slots that never deliver would recover the 8.3% spent on dead
  channels.
- TX is hardcoded to 12 Mbit/s legacy OFDM (`src/tx.c:312`, under upstream's own
  `TODO Adjust PHY parameters based on receiver capabilities`). This caps the
  *send* direction, which is still untested.

## 17. 2026-07-31: §16's fix was wrong, and it made things 6x worse

The §16 *measurement* stands: the ceiling is duty cycle. The *cause* I attached
to it, and the fix that followed, did not survive contact with the phone.

### The measurement

| | baseline (§16) | with the fix |
|---|---|---|
| transferred | 2.06 MB in 46 s | 1.36 MB in 189 s (then failed) |
| throughput | **45 kB/s** | **7.2 kB/s** |
| bursts per second | 1.84 | 0.37 |
| bytes per burst | 25.2 kB | 19.7 kB |
| burst duration | 68 ms | 67 ms |
| in-burst rate | 3.0 Mbit/s | 2.4 Mbit/s |
| gaps | 350-550 ms | 250-1000 ms, tail to **7.5 s** |
| channel switches | 3.5/s | 4.1/s |

Burst *structure* is unchanged - still one AWDL slot long, still ~2-3 Mbit/s
inside the burst. We simply got far fewer of them. So the duty-cycle diagnosis
was right and the intervention was actively harmful.

### Why: a channel sequence is meaningless without the clock it was written against

`awdl_switch_channel()` picks its slot with

```c
slot = awdl_sync_current_eaw(now, &state->sync) % AWDL_CHANSEQ_LENGTH;
chan_new = awdl_state->channel.sequence[slot];
```

`state->sync` tracks the **elected master** - `awdl_handle_sync_params_tlv()`
returns `RX_IGNORE` for sync params from anyone else. So the slot index is in
the master's phase. Copying a *non-master* peer's sequence array into
`channel.sequence` while indexing it with the master's phase puts us on the
right channels at the wrong times.

The codebase already knew this. `awdl_same_channel_as_peer()` compares against a
peer by explicitly correcting the phase:

```c
peer_slot = awdl_sync_current_eaw(now + peer->sync_offset, &state->sync) % AWDL_CHANSEQ_LENGTH;
```

`awdl_switch_channel()` applies no such correction, because upstream only ever
fed it the master's sequence, where the offset is zero by construction.

### The baseline was a natural experiment, and I misread it

§16 noted that the fast transfer began two seconds after the election swung to
the phone, and called it luck. Re-reading the log, at 11:20:02 it says
`following channel sequence of sync master 3a:dd:74:15:95:5c` - **sync master**.
The phone had won the election, so sequence and clock came from the same device.
That was not luck to be engineered away; it was the precondition for the
transfer being fast. The one configuration that worked was the one I removed.

### Second defect: the source flaps

A second device, `2e:38:e1:a9:db:2c`, was also sending us data frames, so
"most recent data peer" oscillated between it and the phone at the 1 Hz adoption
tick - visible in the log at 12:04:44 -> :50 -> :51 -> :55 -> :56. Each flip
rewrites the whole sequence. Channel switching rose from 3.5/s to 4.1/s.

### Where this leaves it

Reverted; `master` is back to the 45 kB/s behaviour.

The underlying observation from §16 is still real - being on a bystander's
sequence is bad - but acting on it requires **rotating** the adopted sequence
into our own phase, not copying it verbatim:

```
delta = (awdl_sync_current_eaw(now + peer->sync_offset) -
         awdl_sync_current_eaw(now)) % AWDL_CHANSEQ_LENGTH
our_sequence[i] = peer_sequence[(i + delta) % AWDL_CHANSEQ_LENGTH]
```

plus hysteresis so the choice cannot flap. Both need building and *measuring*.
Given that this is the second confident fix in this project to be contradicted by
its own logs, the rule stands: on this hardware, nothing counts until it has been
measured against the phone.

### Method note

Everything above came from `owl.log` and `receive.pcap` of the two runs. Burst
structure is the diagnostic that matters here - per-second averages hid it
completely, and the gap *histogram* is what falsified the blocking-`set_channel`
theory in §16 and the peer-follow theory here.

## 18. 2026-07-31: the receive window was a real pathology but NOT the limit

A clean negative, recorded because it closes off a whole avenue.

### The pathology

Reading the baseline capture's window trace at connection start:

```
64766 64766 64766 528 528 528 528 528 528 528 571 609 631 638 638 ...
```

The advertised receive window opens at 64766 B, collapses to **528 B** - below one
MSS - in a single step, then crawls back at a few bytes per round trip, reaching
only 2.0 MSS by t=10 s and 7.3 MSS by t=45 s. Two zero-window events.

Mechanism: the sender opens with a full 64 kB window and blasts it while OpenDrop
is still between answering `Expect: 100-continue` and its first `read()`. That one
overrun collapses `rcv_ssthresh`. Linux regrows it only as clean data arrives, and
AWDL gives a connection roughly two round trips per 500 ms, so recovery takes ~40 s
- longer than the transfer.

OpenDrop's reader was ruled out first: `HTTPChunkedReader` benchmarks at 2-6 GB/s
in isolation, so the application was never the slow part.

### The fix, and the measurement that killed the theory

Two changes: a 4 MB `SO_RCVBUF` on the listening socket, and answering
`100-continue` only after the output file is open and the reader built.

| | baseline | window fixed |
|---|---|---|
| median advertised window | 2 728 B | **41 462 B** |
| collapse | 64766 -> **528** | none; settles 32782, climbs |
| in-burst rate | 3.0 Mbit/s | 3.57 Mbit/s |
| burst duration | 68 ms | 49 ms |
| bytes per burst | 25.2 kB | **21.9 kB** |
| bursts per second | 1.84 | **1.82** |
| **throughput** | **45 kB/s** | **40 kB/s** |

The fix worked exactly as designed - the window is 15x larger and never collapses -
and **throughput did not improve**. We now move the same ~22 kB in 49 ms instead of
68 ms, and then wait just as long for the next availability window (mean gap 504 ms,
unchanged).

### What this establishes

**Bytes per availability window is fixed at ~22-25 kB, independent of the TCP
receive window.** Since bursts arrive at ~1.8/s, that product *is* the 40-45 kB/s.
Neither factor is TCP's and neither is the PHY's - the burst ends because the
airtime does, not because the window fills or the link runs out of rate.

That rules out the entire receiver-side avenue: TCP tuning, socket buffers,
application read speed. None of it can move this number. The only remaining lever
is **more availability windows per second**, i.e. more overlapping slots with the
peer - which is what §16 was reaching for and §17 showed must be done by rotating
an adopted sequence into our own clock phase, not by copying it.

### Kept anyway

Both changes stay in `patches/`. A 528-byte window is indefensible on its own
terms, the `100-continue` ordering is simply correct, and together they remove a
confound from every future measurement. They are documented as **correctness fixes
that do not affect throughput**, which is exactly what they are.

The `net.core.rmem_max` bump that was briefly in `airdrop.sh` has been removed:
it changes global system state, and it buys nothing measurable.

---

## §19 - The send path: four blockers, and the mDNS backoff that hid the rest

2026-07-31. Sending *to* an iPhone had never once reached discovery. Working
backwards from "No AirDrop service discovered" turned up four separate faults
stacked on top of each other, three of them nothing to do with AirDrop.

### 1-3. Dependency rot (see `patches/opendrop-py314-send.patch`)

OpenDrop 0.13.0 predates Python 3.12, Pillow 10 and current `libarchive-c`, and
each removed something it relies on: `HTTPSConnection`'s `key_file`/`cert_file`/
`check_hostname`, `ArchiveEntry`'s old constructor, and `Image.ANTIALIAS`. The
first killed `find` *and* `send` at construction, so not a single packet went out.

### 4. The discovery report was never written

`opendrop find` blocks forever and writes its report from a `finally:` reached via
`KeyboardInterrupt`. The harness used `timeout`, which sends SIGTERM, and Python
does not turn SIGTERM into `KeyboardInterrupt` - so the report was never written.
That surfaced much later, and very confusingly, as *"No discovery report exists,
please run 'opendrop find' first"* during send. Fixed with `timeout -s INT`.

### The retraction: Control Centre is not enough

An earlier note here advised opening Control Centre to make the phone
discoverable. That was wrong and the measurement says so flatly: with Control
Centre open, **zero AWDL frames on all five social channels** (6, 36, 44, 132,
149). Not "no service" - no AWDL at all.

Apple bootstraps AirDrop over **Bluetooth LE**: the sender's BLE advertisement is
what wakes a receiver's AWDL interface. Neither OWL nor OpenDrop implements it, so
a dormant iPhone cannot be woken by us. **The share sheet is required in both
directions**, because it is what brings AWDL up on the phone.

### The real one: ServiceBrowser's backoff is wrong for AWDL

With all of the above fixed, AWDL synced, the peer was found, ping6 worked - and
a 75 s browse still found nothing. The browse window had never been captured; it
was the one phase not on tape. Capturing it (`find.pcap`) showed:

```
mDNS during browse: total=7  from_peer=0  mentioning _airdrop=7
```

Seven queries in 75 seconds, at t = 0, 1, 3, 7, 15, 31, 63 - `ServiceBrowser`'s
exponential backoff. That schedule assumes a link where a lost query is unusual.
AWDL over a single radio is the opposite: we are co-channel with the peer only a
fraction of each 1.048 s sequence (this phone's sequence put just 2 of 16 slots on
our channel), an mDNS query is one unacknowledged multicast frame, and the answer
runs the same gauntlet back. By 30 s in we were asking **once a minute**.

`patches/opendrop-mdns-repeat.patch` re-asks the PTR question at a steady 1.5 s
(`OPENDROP_QUERY_INTERVAL`). Effect on the very next run:

| | before | after |
|---|---|---|
| mDNS packets in browse | 7 | 68 |
| queries mentioning `_airdrop` | 7 | 54 |
| **replies from the peer** | **0** | **14** |

The phone went from completely silent to answering. Also removed as a confound:
`avahi-daemon`, which was announcing `_sftp-ssh._tcp` and `void-btw.local` out of
`awdl0`, burning the scarce co-channel airtime and holding UDP 5353. It is now
stopped for the run and restored on exit (`AVAHI=keep` to opt out).

### Where it stands: the sender/receiver pincer

Discovery still returns nothing, but the failure is now fully characterised, and
the last capture reframed it. With the share sheet open the phone sends:

```
17:08:10  phone -> ff02::fb  PTR (QM)? _applicationServicePairing._tcp
                             PTR (QM)? _appSvcPrePair._tcp
                             PTR (QM)? _airdrop._tcp.local.
```

It is **querying** `_airdrop._tcp`, not advertising it. An iPhone with the share
sheet open is a *sender*, browsing for receivers - which is exactly why `receive`
mode works, and why the share sheet is the right instruction there. It is the
wrong instruction for sending.

So the two states are a pincer:

| phone state | AWDL | advertises `_airdrop._tcp`? |
|---|---|---|
| share sheet open | awake | **no** - it is a sender, and browses instead |
| share sheet closed | asleep | would, but nothing wakes it |

and the thing that would break the deadlock - the BLE advertisement that wakes a
dormant receiver - is precisely what neither OWL nor OpenDrop implements.

Runs with the sheet closed confirm the second row: the phone is visibly alive on
AWDL (it queries `_spotify-connect._tcp`) and never mentions `_airdrop._tcp` at
all, not even as a query.

### The one untested gap

AWDL does not drop the instant the share sheet closes. If the phone reverts to
receiver mode while AWDL is still up, it should advertise in that window. That
test needs a human to close the sheet mid-run and has not yet been performed
cleanly - three attempts were lost to mistimed coordination. With the browse now
exiting early it costs seconds rather than minutes, so it is cheap to retry.

If that window turns out not to exist, the send direction needs the BLE
bootstrap, which is a substantially larger piece of work than anything here: it
means implementing Apple's Continuity BLE advertisement, not just an mDNS fix.

### What was NOT the problem

Worth recording, because each cost a real amount of time:

- Not TCP, not the PHY, not the receive window (§18).
- Not the channel - the sweep finds the peer reliably and ping6 round-trips.
- Not `FIND_TIME`. Raising the ceiling has never once turned a failure into a
  success; every failure has been categorical. The default is back down to 45 s
  because the only thing a long ceiling buys is a slower failure.

---

## §20 - Where the run time actually went

2026-07-31. A run that should have taken ~2.5 min took ~5, and the artifacts
timestamp every phase, so it can be attributed exactly rather than guessed at:

```
17:33:16  start
17:33:25  channel sweep done   (~9 s - one channel, cache confirmed)
17:33:41  browse starts
17:36:20  browse ends          (150 s ceiling, as configured)
17:38:30  owl finally dies     <-- 2m10s of nothing
```

Two separate things, and only one of them was the ceiling.

### The ceiling was configured badly

`FIND_TIME=150` was set by hand on that run. It is a **ceiling, not a duration** -
the browse stops the instant a receiver appears - so the only thing it governs is
how long a *failure* takes. Every failure here has been categorical: the phone
either advertises `_airdrop._tcp` or it does not, and no run has ever had one turn
up late. Raising the ceiling has never once converted a failure into a success. It
is back to 45 s, and the "try FIND_TIME=150" advice has been removed.

### The real one: an unbounded `wait` after the browse had already finished

The remaining 2m10s came *after* the browse had produced its result. The
early-exit rework sent SIGINT to `opendrop find` and then called plain
`wait $FIND_PID`. `opendrop find` handles the `KeyboardInterrupt` and then calls
`zeroconf.close()`, which tears down threads and sockets and does not reliably
return - so the script sat there until teardown killed it.

This was masked in testing because the stand-in producer was a plain Python
script, which dies on SIGINT immediately. The fix is a **bounded** wait: SIGINT,
up to 5 s to write the discovery report, then SIGKILL. Everything needed from the
browse is already in the log by that point. Verified against a producer that
ignores SIGINT outright: **8 s total against a 45 s ceiling**, where before it
would have hung indefinitely.

`tail -f` also gained `--pid`. Killing a background *pipeline* with `kill $!` only
kills the last stage - the `sed` - which left `tail -f` running against the log
forever.

### Rule of thumb this produced

When a phase is bounded by a timer, check what happens *after* the timer fires.
Both bugs here were in the teardown, not the work: one made failure slow by
configuration, the other made success slow by hanging on cleanup that had nothing
left to clean up.

---

## §21 - The duty-cycle ceiling was a sequence we chose to copy

2026-07-31. §16 measured the ~45 kB/s AirDrop ceiling as a duty-cycle problem
and got the cause wrong. §17 retracted the fix and left a prescription: rotate
the adopted sequence by `peer->sync_offset`, add hysteresis, measure. Following
that prescription turned up why it could never have worked, and then the logs
turned out to contain the actual answer all along.

**Everything below except the last section comes from artefacts that already
existed** - `owl.log` and the channel-locked `scan-*.pcap` files of runs already
performed. No phone was present. The tools are committed as `tools/slotmap.py`
and `tools/bursts.py` so none of it has to be re-derived by hand again.

### `sync_offset` was never assigned

`peers.c` initialised it to 0, `schedule.c` read it in
`awdl_same_channel_as_peer()`, and nothing in the tree ever wrote to it. So:

- §17's prescribed rotation would have computed `delta = 0` for every peer and
  been a **silent no-op**.
- Every phase correction already in the codebase - the one §17 held up as proof
  that "the codebase already knew this" - had been doing nothing since it was
  written.

It is now filled in for every peer from the sync params TLV.
`awdl_sync_error_tu()` is just "the peer's announced phase minus ours", which is
exactly the wanted correction and is not master-specific. Made `int64_t`: a peer
behind us needs a negative offset.

### A zero slot means absent, not "repeat current"

Each AWDL action frame carries the sender's own availability-window counter, so
a channel-locked capture places every frame in the **sender's own** slot index
with no clock of ours involved: `slot = (aw_seq_number / presence_mode) % 16`.

On `scan-149.pcap`, against what each device advertised:

```
3a:dd:74:15:95:5c  seq 132,0,149,0,0,149,0,0,6,0,149,0,0,149,0,0   observed slots 2 5 10 13
2e:38:e1:a9:db:2c  seq 124,0,149,0,0,  0,0,0,6,0,149,0,0,  0,0,0   observed slots 2 10
```

Devices transmit in exactly the slots their sequence names and in no others. So
a `0` entry means the device is **not present** for that window, despite
`fill_channel = 0xffff` ("Repeat Current") suggesting otherwise.

Slot 0 consistently holds a non-social channel - seen as 3, 108, 124, 132 and
134 across runs. This closes the §17-era loose end about channel 3 being a
possible decoding bug: **it is not a bug.** tshark decodes those bytes
identically, and the most likely reading is that slot 0 is where the device
returns to its infra Wi-Fi channel.

### The phone escalates its sequence during a transfer

The important part, and it is visible in every receive log:

| state | advertised sequence | slots on 149 |
|---|---|---|
| idle | `132,0,149,0,0,0,0,0,6,0,149,0,0,0,0,0` | 2 (12.5%) |
| transferring | `149,149,149,0,0,0,0,0,6,149,149,0,0,0,0,0` | 5 (31%) |
| more | `149,149,149,149,149,0,0,0,6,149,149,149,149,0,0,0` | 9 (56%) |
| peak | `149,149,149,149,149,149,6,6,6,149,149,149,149,149,6,6` | 11 (69%) |

An iPhone widens its own availability from 2 slots of 16 to as many as 11 while
a transfer is in flight, and oscillates between those states at about 1 Hz.

### The baseline, re-read

`bursts.py` on the §16 baseline capture reproduces its table (92 bursts vs 94,
25.7 kB vs 25.2, 67 ms vs 68, max gap 1049 ms, 47 kB/s vs 45) and adds one
figure §16 never computed: **duty cycle 12.3%, which is exactly 2.0 slots of
16.**

`slotmap.py` on the same run's log says who was offering what:

```
76:b9:83:a8:e5:c2  (the data peer)    offered 5 to 11 of 16 slots
82:49:5e:10:cf:cc  (a bystander)      offered 2 to 7 of 16 slots
3a:dd:74:15:95:5c  (the sync master)  offered 2 of 16 slots
```

We followed the sync master. We measured exactly its 2 slots. **The 45 kB/s
ceiling is not a radio limit, a PHY limit or a TCP limit - it is the 2-slot
sequence we chose to copy, while the device we were actually transferring with
was offering up to 11.**

This also explains §18's clean null result. That run's peer advertised only
2 slots, so the receive-window fix had no room to help: we were already
capturing essentially every window on offer. §18's conclusion that
bytes-per-window is fixed at ~22-25 kB stands; what was wrong was assuming the
*number* of windows was fixed too.

### What §16 and §17 each got right

- §16 was right that we follow the wrong device's sequence.
- §17 was right that copying a non-master's sequence verbatim breaks the phase,
  because the slot index is computed in the master's clock.

Both are true, and the fix that satisfies both is not rotation.

### PIN: stop hopping

`-S pin` takes the peer's dominant social channel and sits on it in **all 16
slots**. On a monitor vif we have no infra association to service, so there is
nothing to gain by ever leaving:

- Present for every window the peer offers, not a subset.
- No 1 Hz adoption tick needed to notice an escalation from 2 slots to 11.
- **Rotation-invariant by construction.** A constant sequence is unchanged by
  any rotation, so the §17 failure - right channels, wrong times - cannot recur.
  This is asserted as a unit test, not just claimed.
- Zero channel switches, so the blocking `set_channel()` cost goes to zero too.

On offline replay it settles to one channel switch for the whole run, against
verbatim's four per 1.049 s period.

All three strategies are selectable (`-S pin|rotate|verbatim`) so one session
can A/B them against the same phone. `rotate` is §17's fix built properly,
including the requested hysteresis: a delta must appear on two consecutive
ticks before being applied, because a peer whose phase sits near a window
boundary otherwise oscillates between neighbouring deltas.

### The prediction, written down before the measurement

Stated plainly so it can be scored honestly rather than rationalised afterwards:

> Against the same phone in the same room, `-S pin` should raise **bursts per
> second** from ~1.8 to somewhere between 4 and 10, tracking whatever the data
> peer advertises at the time. Bytes per burst should stay at ~22-25 kB (§18
> says it cannot move). Throughput should land between 110 and 250 kB/s.

Falsification conditions, equally explicit:

- If bursts/s does not rise, the model is wrong and this section joins §16 and
  §17 on the retracted pile.
- If bursts/s rises but throughput does not, something downstream is the limit
  and §18's bytes-per-window figure needs revisiting.
- If `slotmap.py --log` shows the data peer never offering more than 2 slots,
  the run is **void** - there was nothing to win, and it proves nothing either
  way. Check this first.

**Nothing here has been measured against a phone. On this hardware that means
nothing here counts yet.** This is the third confident diagnosis in this
project; the previous two were both contradicted by their own logs. The
difference this time is that the prediction is quantified and its failure
conditions are written down in advance.

---

## §22 - The BLE wake is unproven, and AWDL being awake is not enough

2026-07-31, with a phone in the room set to AirDrop → Everyone and **the share
sheet closed**. Two runs, differing only in whether `tools/blewake.sh` was
broadcasting.

### Result: no difference

| | BLE advertising | BLE off (control) |
|---|---|---|
| AWDL frames on ch6 | 31 | 29 |
| peer found | yes, `3a:dd:74:15:95:5c` | yes, `3a:dd:74:15:95:5c` |
| advertised sequence | `36,36,149,0,0,0,0,36,6,36,149,36,0,0,0,36` | identical |
| service UUID | `fdad762f-a86e-429b-9ad7-98e0d5399fec` | identical |
| `_airdrop._tcp` from peer | **none** | **none** |

The phone's AWDL was already awake for reasons of its own, so **the experiment
cannot say whether the BLE advertisement does anything.** It is confounded, not
negative. `blewake.sh` remains untested in the sense that matters.

To test it properly the phone's AWDL has to be verifiably *asleep* first -
confirmed by seeing zero AWDL frames on all social channels, as §19 once did -
and only then should the advertisement be switched on. Getting an iPhone into
that state reliably is itself unsolved.

### The more useful finding: waking AWDL is not sufficient

§19 framed the send blocker as "AWDL is asleep, and only a BLE advertisement
wakes it". That framing is incomplete. Here AWDL was demonstrably awake - a peer
was discovered, with a live channel sequence, over several minutes - and the
phone **still did not advertise `_airdrop._tcp`**. Our 37 mDNS queries went out;
nothing came back (`from_peer=0`).

So there are two separate gates, not one:

1. the AWDL interface being up, and
2. the AirDrop *service* being advertised on it.

Only (1) was ever attributed to the BLE bootstrap. Something else governs (2) -
plausibly the Everyone window having expired (iOS reverts to Contacts Only after
10 minutes, and it is not obvious from the outside when that has happened), or
the service advertisement being gated on the contact-hash match that our
all-zero hashes cannot satisfy.

**Next time, the first thing to check is that Everyone has not silently
expired.** It is the cheapest explanation and nothing downstream can be
interpreted without ruling it out.

### A real bug, caught by having a phone present

The same run exposed a defect in the PIN channel picker. The phone advertised
ch36 in 6 of 16 slots, ch149 in 2, ch6 in 1, while `airdrop.sh` had swept to
channel 6 - it picks by raw frame count, which disagreed with the sequence.

`awdl_chanseq_dominant_chan()` returned the operator's channel whenever it
appeared at all, so it would have pinned to **ch6 for 1 slot of 16 instead of
ch36 for 6** - the peer's worst channel over its best, the exact opposite of the
point of pinning. Now the operator's channel breaks exact ties only. Fixed with
the real sequence as the test case.

Worth noting the sweep and the sequence disagreed at all: frame count on a
channel is not the same as slots-per-sequence, and the sequence is the better
guide. `slotmap.py` reads it directly.

---

## §23 - ping6 is a real test, and the TX regression is ours

2026-07-31, evening. Live testing against the phone, after a session of changes
made without one. Two results: a diagnostic that has been misread since §10, and
a regression introduced by those changes.

### ping6 loss is a real signal, not an ambiguity

§10 measured 100% ping6 loss and read it as a one-way path. §15 retracted that,
reasoning that iOS ignores ICMP6 from devices it has no association with, so the
result was **inconclusive** either way. Every run since has printed that
disclaimer.

It is wrong. Against the same phone, in the same state, on the same channel,
differing only in which OWL binary was running:

| build | ping6 |
|---|---|
| pre-change `0c48db8` | **5 / 5, 0% loss**, rtt 56-227 ms |
| current `HEAD` | **0 / 5, 100% loss** |

**iOS answers pings from strangers perfectly well when the path works.** So
100% loss is a genuine TX failure, and ping6 is a reliable 8-second test of
whether our frames reach the phone - far better than waiting two minutes for a
file transfer that fails for the same reason. `airdrop.sh` no longer prints the
disclaimer, and `tools/txbisect.sh` is built entirely on this.

That also means the §15-era conclusion that "the chip IS ACKing" is untouched -
ACKs were confirmed by the phone sending us 481 packets including TCP - but the
*ping* evidence that was dismissed alongside it should not have been.

### The failure mode, from the capture

While the regression was live, the phone was doing everything right. It resolved
`void-btw.local` (5 queries), asked for our `_airdrop._tcp` instance, and opened
**seven TCP connections** to port 8771. Every one died identically:

```
phone -> us   SYN
us -> phone   SYN-ACK
phone -> us   SYN          (retransmission - it never heard the SYN-ACK)
...
```

**Zero application bytes in either direction**, so the AirDrop `Discover`
request never ran and the phone never displayed us. From the phone's side this
looks like "the Linux box isn't advertising"; from ours, RX was flawless. Any
diagnosis that stops at "it doesn't appear in the share sheet" will look in
entirely the wrong place.

### A latent encoding bug, found while looking for this one

`awdl_same_channel_as_peer()` decoded the **peer's** raw sequence bytes using
**our** `state->channel.enc` instead of `peer->sequence_enc`. Those are separate
fields precisely because the TLV bytes are stored verbatim, and `peers.h`
already carried a comment warning about it.

Upstream never noticed because adopting a peer's sequence also adopted its
encoding, so the two agreed by construction. `-S pin` sets our encoding
independently and breaks that coupling. Modelled as pure logic in
`tests/test_awdl_txgate.cpp`, stepping the sync state one window at a time with
the sequence the phone was actually advertising:

| configuration | co-channel slots per period |
|---|---|
| verbatim adoption | 4 of 16 |
| pin, encodings agree | 2 of 16 |
| **pin, encodings differ** | **0 of 16** |

Zero co-channel slots means `awdl_can_send_unicast_in()` never returns 0 and no
unicast is ever transmitted, while reception continues normally - exactly the
observed symptom.

**But this was NOT the cause of the failure above.** The phone advertised
Opclass in all 165 captured frames and `pin` sets Opclass, so the encodings
agreed and the gate should have opened on 2 slots in 16. Fixed as a real bug on
its own terms; the regression remains open.

### Where it stands

The regression is confirmed ours and bounded to four commits between `0c48db8`
and `HEAD`. `tools/txbisect.sh` sets the radio up once and ping-tests each build
in turn, so naming the culprit costs one run rather than four. Prime suspect is
the asynchronous `set_channel()`, on the grounds that it is the only change that
touches the RF path - `src/tx.c` is untouched, and `channel.current` only gates
MIF frames.

### Method note, again

This is the third time in this project that a confident diagnosis has been
contradicted by its own logs - and tonight added two more: a kernel reboot
recommended on a stale note the owner correctly overruled, and a `sync_offset`
fix asserted as the cause and disproved by the next run. Both were plausible
stories acted on **without a control**. The control - run the old binary,
unchanged, against the same phone - took one run and settled in eight seconds
what two hours of reasoning had not.

Build the control first.

## §24 - The TX gate is innocent, and the bisect named the wrong half of PIN

Answered entirely from the §23 bisect logs
(`runs/txbisect-20260731-195122/`), no new hardware and no phone. The bisect had
already been run; it had not been read.

### The frames were leaving OWL the whole time

§23 set up `STATS tx_unicast` to split the two failure modes: a software gate
that never opens, versus frames that leave and die in the radio. The bisect run
never lived long enough to print a STATS line, so this looked unanswered. It was
not. Every build logs each unicast data frame it hands to the radio, and the
counts are identical:

| build | ping6 | channel switches | unicast frames sent |
|---|---|---|---|
| `0c48db8` base | 20% loss (PASS) | 21 | 4 |
| `c3fc4a4` strategies | 100% loss | 1 | 4 |
| `92a12b8` async set_channel | 100% loss | 1 | 4 |
| HEAD | 100% loss | 1 | 4 |

Four unicast frames in every arm: the four `ping6` packets. The gate opened
everywhere. So `awdl_same_channel_as_peer()`, `awdl_can_send_unicast_in()`, the
`sync_offset` question and the `peer->sequence_enc` decoding bug are **all
cleared as causes of this regression**. They were the entire content of the
§23 suspect list. The `-S verbatim` test the handoff proposed as the fastest
discriminator would have passed and pointed at PIN, which is right, but it would
not have said *which part* of PIN, and this table does.

The surviving correlate is the middle column, and it is perfect: the one build
that switched channels 3.5 times a second passed, and all three that switched
once at startup and never again failed.

### The channel switches were fiction, which makes it stranger and simpler

The base build hopped `3 -> 149 -> 6 -> 149` every ~260 ms, spending about half
its time nominally on 2.4 GHz where a phone on 149 cannot be heard. Its RX was
41 action frames in 6 s against HEAD's 45 in 7 s - the same rate. Had the radio
really gone to channel 3, RX would have roughly halved.

So the retunes never moved the radio. `mon0` holds the 5745 channel context and
`mon1`'s requests are accepted and ignored, which is precisely the pathology
already recorded here: on this chip `iw` reports the requested channel
regardless. **All four builds transmitted on 149 to a phone on 149.** The
channel each build believed it was on is fiction; the only thing that differed
in reality is that one of them was issuing `set_channel` netlink calls
continuously and three were not.

That also disposes of a timing story. The base build sent its unicast frames in
slot 0, which its own sequence calls channel 3 - the slot where the phone should
*not* have been listening - and got replies. HEAD sent in slot 2, the phone's
own 149 slot, where it should have been listening, and got none. Under any
model where slot alignment is what matters, that is backwards.

### Two explanations survive, and PIN confounded them

`c3fc4a4` changed two things at once:

1. the radio stopped being re-tuned, because a pinned sequence is constant and
   `awdl_switch_channel()` only calls `set_channel()` on a transition; and
2. the sequence we **advertise** stopped resembling anything an Apple device
   emits - one channel in all 16 slots, no infra channel in slot 0, none of the
   structure every captured iPhone sequence has.

Either could stop the phone replying, and no amount of re-reading the logs
separates them, because nothing in this data varies one while holding the other
fixed.

### The control: `tools/txarms.sh`

Four arms against one phone in one setup, one binary throughout:

- **A** `-S verbatim` - hops, conformant advertised sequence. Establishes the
  phone is reachable at all. If A fails, every row is void.
- **B** `-S pin` - reproduces the failure.
- **C** `-S pin -K 250` - advertises exactly what B advertises, and re-issues
  `set_channel()` for the channel it is already on every 250 ms, poking the
  radio at roughly A's rate. **This is the whole experiment.**
- **D** `-S pin` again, last. If D does not reproduce B the phone drifted
  mid-run and every row is void. Three run-order confounds in this project
  make the re-test non-optional.

C passes: the driver needs the re-tune, PIN's channel logic is sound, and the
fix is a keepalive rather than a revert. C fails: the phone is refusing our
advertised sequence, and the fix is to sit on one channel while still
advertising a conformant one.

`-K <ms>` is a diagnostic arm, not a feature, and is off by default. Nothing
here is a fix and nothing here has been measured against a phone. Written down
before the run, per the rule below.

### Method note

Two of tonight's three wrong diagnoses were about code that this table now shows
was never involved. The bisect that settled it had already been run and sat
unread while the reasoning continued. Read the control you built before building
another one.

## §25 - The phone refuses our advertised sequence. PIN is dead; verbatim is the default again

`tools/txarms.sh`, one phone, one setup, one binary, four arms, 2026-07-31
20:10 (`runs/txarms-20260731-201044/`). Predictions were written down in §24
before the run.

| arm | ping6 loss | channel switches | unicast frames sent | verdict |
|---|---|---|---|---|
| A `-S verbatim` | 60% | 11 | 5 | **PASS** |
| B `-S pin` | 100% | 1 | 4 | FAIL |
| C `-S pin -K 250` | 100% | 28 | 4 | FAIL |
| D `-S pin` again | 100% | 1 | 4 | FAIL |

D reproduced B, so the phone did not drift and the run stands. A passed, so the
phone was reachable throughout. Both controls held.

### The keepalive hypothesis is dead

Arm C re-issued `set_channel()` 27 times for the channel it was already on,
poking the radio at more than twice arm A's rate, and got nothing through. §24's
first branch is therefore closed: **the driver does not need the re-tune.** The
perfect correlation between channel switches and success in the §23 bisect was
real and was a coincidence of PIN causing both.

`-K` has been removed. It existed to answer this question, it answered it, and a
knob whose hypothesis is disproven is only a trap for the next reader. The
negative result is here and in the history.

### What is left is the sequence we advertise

Everything else is now eliminated by measurement rather than argument. Across A
and B: the radio sat on 149 either way (§24 - `mon0` owns the channel context,
so the switches never moved anything); the TX gate opened either way (4-5
unicast frames left OWL in every arm); the encodings agreed; the peer was the
same peer, seconds apart. The one remaining difference between an arm that works
and an arm that does not is **what we put in the channel sequence TLV.**

Under verbatim we advertise what the phone advertises - here
`149,149,149,0,0,0,0,0,6,149,149,0,0,0,0,0`, five slots of sixteen. Under PIN we
advertise 149 in all sixteen: no empty slots, no infra channel in slot 0, none
of the structure every captured Apple sequence has. The phone appears to reject
it outright. It still talks to us - RX was 68 action frames in arm B, identical
to arm A - it just never sends us a unicast frame again.

That is worth stating plainly because it inverts the §21 model. PIN was designed
to maximise the windows we are present for, and it does, provably, in the unit
tests. It just turns out the windows are worthless if the peer will not
transmit in them. **Availability is not the constraint. Acceptability is.**

### Changes

- `verbatim` is the default again, in both `owl` and `airdrop.sh`.
- `pin` stays selectable, documented as breaking AirDrop against iOS 26.
- `-K` and the keepalive removed.
- `pin_never_loses_windows_to_phase_error` keeps passing and keeps its
  arithmetic; its comment now records that being right about the windows did not
  help.

### What this does and does not settle

It settles the §23 regression: the cause is PIN's advertised sequence, the fix
is not to send it, and unicast TX works again at the §16 baseline. 60% loss is
not health - arm A's 2-of-5 replies are the same marginal path §16 measured at
45 kB/s - but it is the number this project started from, and the regression is
closed.

It does **not** settle where Apple's line is. PIN is one extreme (16 of 16, no
structure) and verbatim is the other (exactly the peer's own sequence). The
duty-cycle work of §21 lives in between, and the next question is the narrow
one: does the phone accept a sequence that is the peer's own with some empty
slots filled in? That is a widening we can test one step at a time, and now
there is a harness that tells us within a minute whether the phone has stopped
answering.

### Method note

The §24 control was built and run and it worked exactly as designed, including
the part that mattered most: arm D. Three of this project's wrong conclusions
came from run-order confounds, and a re-test of the failing arm at the end costs
90 seconds and converts "I think the phone was fine" into a row in the table.
Keep doing that.

## §26 - Widening is accepted; what PIN broke was the sequence's CONTENT, not its width

Three `txarms.sh` runs back to back against the same phone, 2026-07-31 20:21,
20:23, 20:25 (`runs/txarms-2026073 1-2021*`, `-2023*`, `-2025*`). `-S widen -W n`
takes the peer's own sequence and fills up to n of its empty slots with the
peer's dominant channel, copying the peer's own encoded bytes and never touching
slot 0.

| arm | occupancy | ping6 loss |
|---|---|---|
| `verbatim` | 4/16 | 60%, 20%, 20%, 40% |
| `widen -W 2` | 6/16 | 20% |
| `widen -W 6` | 10/16 | 20% |
| `widen -W 8` | 12/16 | 20%, 60% |
| `widen -W 10` | 14/16 | 80% |
| `widen -W 11` | 15/16 | 20%, 20%, 20% |
| `widen -W 12` | 16/16 | **100%**, 80%, 80% |
| `pin` (§25) | 16/16 | 100%, 100%, 100%, 100% |

Controls held in all three runs: the first arm passed and the last arm
reproduced the arm it repeats.

### The hypothesis I formed after run two was wrong

Run two had `-W 11` passing and run one had `-W 12` failing outright, which
reads as a clean boundary: **the phone requires at least one empty slot.** It is
a tidy rule, it explains PIN exactly, and it is false. Run three tested it
directly, `-W 11` against `-W 12`, twice each, and `-W 12` passed both times.
The 100% in run one does not reproduce.

Writing that down because the run that killed it took ninety seconds and existed
only because the rule was written down as a claim to be tested rather than
adopted. That is the same move that has now paid off three times in this
project, and the temptation each time was to skip it.

### What actually holds

PIN is rejected categorically: 100% loss in four arms across two sessions, never
once passing. Widening is accepted at every width tested, up to and including
full 16/16 occupancy, and `-W 12` is the same occupancy as PIN. So **occupancy
is not what the phone objects to.**

The difference is content. `-W 12` keeps the peer's own slot 0 (channel 3 here,
a non-social infra channel) and its channel 6 slot, so what we advertise is
still recognisably the peer's sequence, widened. PIN replaces all sixteen slots
with a single 5 GHz channel: no infra channel, no 2.4 GHz slot, nothing of the
peer's structure left. §25 guessed "no empty slots and no infra channel in slot
0" and named the wrong one of the two.

### The instrument is too blunt for the next question

Five pings per arm, and `verbatim` alone scored 60/20/20/40 across four runs of
an identical configuration. That spread is as large as most of the differences
between widths. So the ranking within the passing rows is not evidence:
`-W 11` at 20% three times and `-W 12` at 80% twice is *suggestive* that full
occupancy costs something, and that is all it is.

`ping6` is a categorical test - does anything get through at all - and it has
been excellent at that. It cannot size an effect. The throughput question needs
a real transfer and `tools/bursts.py`.

### Not changing the default on this

`verbatim` remains the default. Widening looks better and is plainly accepted,
but "looks better on a noisy five-packet test" is exactly the evidence this
project has three times mistaken for a result. The §21 prediction - bursts/s
1.8 to 4-10, throughput 110-250 kB/s - is about a file transfer, so it gets
settled by a file transfer, with `verbatim` as the baseline arm.

---

## §27 The send direction: the phone was always answering, we were never asking

2026-07-31, evening. Everything up to here is the **receive** direction, iPhone
to laptop. The remaining goal is the other way round, and §22 had concluded that
the phone never advertises `_airdrop._tcp` for us to find. That conclusion is
wrong.

### The phone does advertise, and BLE is what makes it

Three consecutive runs, same binary, same `ACTIVE=1 CHAN=149`, same open share
sheet:

| time  | BLE Continuity advert | result                                    |
|-------|-----------------------|-------------------------------------------|
| 20:43 | running               | `Found index 0 ID 21a582faf894 name Jed's iPhone` in ~6 s |
| 20:50 | **expired at 20:49:14** | no receiver, despite 0% ping loss on awdl0 |
| 20:54 | restarted 20:53:32    | `Found index 0 ID 21a582faf894` in ~4 s   |

The middle run is the control that makes this readable: the AWDL link was
*better* there than in either neighbour (0% loss vs 60%), the peer was found,
the IPv6 neighbour was present, and mDNS still turned up nothing. The only
variable that moved is the BLE advertisement.

That settles a question `tools/blewake.sh` has had open since it was written: it
does something. §22's "the phone never advertises" was measured without it, or
after it had timed out - the advert defaults to 600 s and nothing in the harness
made its expiry visible.

**Availability is not the constraint, acceptability is** (§25) has a sibling
here: the phone is not asleep, it is not addressing us. It answers ICMP and
ignores mDNS until Continuity has told it a nearby device wants something.

### Two plumbing bugs stood between discovery and a transfer

Both were invisible until discovery started working, and both produced the same
misleading symptom - a receiver printed on stdout and then
`Receiver does not exist`.

1. **`opendrop find` never wrote its discovery report.** `find()` writes
   `discover.last.json` in a `finally:` block, but *after* `self.browser.stop()`
   - and `stop()` ends in `zeroconf.close()`, which §-earlier already measured
   hanging over two minutes on this link. So the browse printed
   `Found index 0 ...`, hung, got killed, and wrote nothing. `send` then read a
   **13 313 second old** report. Fixed in `patches/opendrop-find-report.patch`:
   write before `stop()`, write on every discovery rather than only at shutdown,
   and write atomically.

   Worth being explicit about why `-r 21a582faf894` did not rescue this:
   `_get_receiver_info()` resolves the ID *inside the report*. The report is not
   a convenience, it is the only path by which `send` learns the receiver's
   address and port. Printing the ID to a terminal carries none of that.

2. **`airdrop.sh` picked the receiver positionally.** It defaulted to index `0`
   against a report that in one run held `[]`, giving
   `TypeError: object of type 'int' has no len()` out of OpenDrop's
   index-then-ID fallback chain. It now parses the ID out of *this run's*
   `find.log` and passes that, falling back to `0` only if nothing parsed.

Neither of these is AWDL. They are the same class of bug as §-py314: OpenDrop's
send path had simply never been run to completion by anyone.

### Status

Discovery is reproducible. The transfer itself is still unproven - no run has
yet got past `_get_receiver_info()` with a good report, because the fix landed
after the last attempt. The next run is the first real test of `send_ask` and
the upload, and it is also the first time the receive-path patches (dvzip, cpio,
icon generation) get exercised in the sending role.

Open, and deliberately not asserted: whether the BLE advert must stay up for the
duration of the transfer or only long enough to provoke the mDNS advertisement.
The three runs above only establish that it must be up during the browse.

---

## §28 The send stalls because our ACKs do not land, and layer 2.5 predicts it

2026-07-31, 21:02 and 21:07. Two send runs, same binary, same command. They
failed at different points, and the difference between them is not in the
AirDrop protocol at all.

| run   | layer 2.5 ping | got as far as                          |
|-------|----------------|----------------------------------------|
| 21:02 | **0% loss**    | `Receiver accepted` - the phone prompted, the tap happened, died on `/Upload` |
| 21:07 | **60% loss**   | died reading the `/Ask` **response**    |

### What the capture shows

`send.pcap` with `SSLKEYLOGFILE` decrypts to a single `POST /Ask`, 333 bytes,
at t=3.868. The phone answered at t=5.397 with a 93-byte segment. Then:

```
5.397  PHONE -> US   93  PSH,ACK
5.437  US -> PHONE    0  ACK
5.566  PHONE -> US   93  [retransmission]
5.828  PHONE -> US   93  [retransmission]
6.446 ... 21.167     93  [retransmission x11, exponential backoff]
23.280 PHONE -> US    0  RST
```

The phone retransmitted the same 93 bytes **thirteen times over eighteen
seconds** and then reset the connection. We ACKed every single one. It received
none of the ACKs.

### It is not a software gate, and it is not the wrong channel

Both of the obvious explanations are dead, and the logs kill them:

- **OWL sent every ACK.** `owl.log` has thirteen `Send data (len 133)` frames to
  the peer at exactly the retransmit timestamps. `awdl_same_channel_as_peer()`
  opened, the frames went to the radio.
- **They were on the right channel.** Eleven of the thirteen went out in slot 0,
  which looks damning against the peer's first advertised sequence
  (`3,0,149,0,...` - slot 0 is channel **3**, a different band). But the phone
  re-advertised four times during the run, and from 21:07:51 its sequence was
  `149,149,149,0,...`, making slot 0 channel 149 - the channel we are pinned to.
  Every stalled ACK was sent after that change.

So: correctly gated, correctly channelled, handed to the radio, and lost on air.
Thirteen consecutive failures is not 50/50 chance; something is systematically
eating our small frames while the phone's frames reach us perfectly.

**RX is flawless and TX is broken, in the same second, on the same channel.**
That is the same asymmetry as the 60% ping loss measured 90 seconds earlier in
the same run.

### The reframing

Layer 2.5 ping loss is not a health readout, it is a **prediction of how far
the transfer will get**. 0% reached the Accept prompt; 60% could not complete a
single request/response round trip. The two failures look like different bugs
and are one.

This also **retires a hypothesis that was never tested**: the `/Upload` failure
in the 21:02 run was written up as possibly chunked-encoding related, on the
strength of our own receiver having needed teaching to accept chunked bodies
(`opendrop-ios26-airdrop.patch` fix 1). That shape-matching was wrong, or at
least wholly unevidenced - `RemoteDisconnected` is what TX loss looks like from
inside `http.client`, and we now have a capture showing exactly that mechanism
on a different request. Do not patch the HTTP layer on this evidence.

### What changed

`airdrop.sh` re-measures the ping up to `PING_TRIES` (3) times when loss exceeds
`PING_MAX_LOSS` (20%), and warns explicitly when it cannot get a good link. The
warning matters because the run costs the user a share sheet, an Accept tap and
two minutes, and 8 seconds of re-measurement can predict that it will be wasted.

### Open

Why our unicast TX fails in sustained bursts while RX is perfect is still the
central unanswered question of this project, now with its cleanest measurement
yet: 13 frames, correctly scheduled, all lost. Note the stalled ACKs cluster at
`tu` 55-61 out of 64 - the first ~5 TU of an availability window - whereas the
frames that got through earlier were spread across the window. That is one
narrow, testable idea (the phone may not be listening at the very start of its
AW) and it has **not** been tested. It is recorded here as a lead, not a cause.

---

## §29 /Upload is refused for what it contains, not how it is delivered

2026-07-31, 21:14 and 21:20. `/Upload` is a **separate bug from §28**: the 21:14
run pinged 0% loss and still failed, so transport is not the cause.

### The exchange, decrypted

```
POST /Ask     333 B  ->  200 OK, chunked
   ReceiverComputerName: Jed's iPhone   ReceiverModelName: iPhone
   IDSSessionID: 445F301A-0DA0-43C7-AA92-0D609D9AB4EE
   SupportsContactExchange: False
POST /Upload  chunked, application/x-cpio, 168 B gzip, 0-length terminator
   ->  TLS close_notify (alert level 1, desc 0). No HTTP status at all.
```

Every byte was ACKed. The phone parsed a complete, correctly framed request and
deliberately hung up. **A server that dislikes a media type answers 406** - ours
does exactly that - so a silent close is not a content-type complaint in the
ordinary sense.

### Round one of arms: four failures, three of them uninterpretable

`reuse-chunked-gzip`, `new-chunked-gzip`, `new-length-gzip`,
`new-length-plain`. All four refused identically.

The result is weaker than it looks and the flaw is mine: arms 2-4 changed the
**connection and the framing together**, so a failure cannot be attributed to
either. Only arm 1 - upstream behaviour, reused connection - was a clean test.
Recorded rather than quietly re-run, because designing an arm that varies two
things at once is exactly the failure this project keeps repeating.

What round one did establish: the phone accepted all three fresh TCP connections
(SYN-ACK on streams 2, 3 and 4). It was not refusing to talk to us.

### Round two: stop theorising, copy the phone

We have watched this iPhone send `/Upload` to **us**, and our receiver had to be
patched twice to cope with what it does:

1. It sets `Expect: 100-continue` (the 100-continue ordering fix).
2. It sends `application/x-dvzip`, not `x-cpio` (the dvzip decoder).

We send neither. That is two concrete, *observed* differences between Apple's
sender and ours, which beats a fifth invented theory. The new arms hold the
connection constant and vary only those:

| arm | container | `Expect` |
|-----|-----------|----------|
| `reuse-chunked-gzip`         | cpio + gzip (control) | no  |
| `reuse-chunked-gzip-expect`  | cpio + gzip | yes |
| `reuse-chunked-dvzip-expect` | dvzip       | yes |
| `reuse-chunked-dvzip`        | dvzip       | no  |

`_cpio_to_dvzip()` is the exact inverse of the `dvzip_to_cpio()` decoder that was
verified against a real 2.06 MB iOS 26 transfer. It round-trips through that
decoder for single-block and multi-block payloads in both STORED and zlib forms,
producing `070707` ODC cpio back - so if a dvzip arm fails, it fails because the
phone rejected a valid container, not because we built a broken one.

**Caveat on the Expect arms:** `http.client` does not implement 100-continue
properly. It sends the header and then the body without waiting for the interim
response. The header is on the wire, which is what the arm tests, but a phone
that requires a genuine wait would still refuse. If an Expect arm fails, that
does not fully clear the hypothesis.

### Where this sits

Send is now: discovery reliable, `/Ask` accepted with a real user tap, `/Upload`
refused. Everything except the payload container is proven working in the send
direction.

---

## §30 Round two failed the same way round one did, and the capture said so

2026-07-31, 21:44. The phone-side reset worked - `/Ask` was accepted with a real
tap after the previous run's ten-minute silence - and all four upload arms
failed.

The result is again worth less than it appears, and this time the capture proves
it rather than leaving it to suspicion:

```
stream 0   POST /Ask -> 200      then  POST /Upload  x-cpio    (arm 1)
stream 1   POST /Upload  x-cpio               (arm 2, NEW connection)
stream 2   POST /Upload  x-dvzip              (arm 3, NEW connection)
stream 3   POST /Upload  x-dvzip              (arm 4, NEW connection)
```

Arms 2, 3 and 4 each opened a **fresh TCP connection**, despite all being named
`reuse-`. The mechanism is simple and was sitting in the code the whole time: a
refused `/Upload` kills the connection, `send_POST()` then finds `http_conn` at
`None`, and opens a new one. "Reuse" silently became "new".

That makes them worse than merely mislabelled. A fresh connection carries no
`/Ask`, so the phone was being asked to accept an upload for a session it had
never agreed to on that socket - which it should refuse, and did. Their failure
says nothing about dvzip or `Expect: 100-continue`.

**Only arm 1 has ever been a valid test, in either round.** What is actually
established after two rounds is exactly one thing, the same thing §29 already
knew: upstream's cpio+gzip chunked upload on the post-`/Ask` connection is
refused with a close_notify.

### The fix costs taps

An arm that tests what its name says needs an accepted session, and an accepted
session needs a prompt. So every arm after the first now re-sends `/Ask` and
waits for the user to tap Accept again. Four arms, four taps.

That is unattractive and it is the honest price. Two rounds of four-arm runs
have now produced two interpretable data points between them; one round of
four *real* arms will produce four. The control runs first and the strongest
candidate (dvzip with `Expect`) second, so a user who abandons the run after two
taps still gets a usable comparison.

### Standing back

Three separate times this project has built an experiment that varied more than
it intended - `-K` in §24, the connection/framing confound in §29, and now the
silent connection-reuse failure. The pattern is the same each time: the arm was
described by what the code was *meant* to do rather than by what it would
actually put on the wire. The capture is what caught it twice. Capture first.

---

## §31 The upload is refused on its HEADERS, and chunked is the only thing left

2026-07-31, 21:49. First round of arms where every arm tested what its name
said: each re-sent `/Ask`, got a real Accept tap, got a 200, and uploaded on
that same connection.

| arm | container | `Expect` | result |
|-----|-----------|----------|--------|
| `reuse-chunked-gzip` (control) | cpio + gzip | no  | close_notify |
| `reuse-chunked-dvzip-expect`   | dvzip       | yes | close_notify |
| `reuse-chunked-dvzip`          | dvzip       | no  | close_notify |

**dvzip and `Expect: 100-continue` are eliminated.** Both were well-motivated -
they are what the phone does when it sends to us - and both are wrong.

### The timing is the finding

```
44.846304  US -> PHONE   POST /Upload (headers)
44.846374  PHONE -> US   TLS close_notify
```

**70 microseconds.** The phone cannot have read, decompressed or inspected the
body. It refused the request on its headers. That kills every hypothesis about
payload format at once, which is why the dvzip result is worth having despite
being negative.

### The control was in our own capture all along

On the same TCP connection, in every run:

| request | framing | result |
|---------|---------|--------|
| `POST /Ask`    | `Content-Length: 333`        | **200 OK**, always |
| `POST /Upload` | `Transfer-Encoding: chunked` | close_notify, always |

Nothing else differs - same headers, same connection, same TLS session. The
cause is not visible in the arm matrix because *every arm so far has been
chunked*. `plistlib.dumps()` returns bytes, so `http.client` computes a length
for `/Ask`; `send_upload()` passed a `BytesIO`, which forces chunked.

Round one did include `Content-Length` arms, but on the bogus connections
described in §30 - no `/Ask`, so they were refused for a different reason and
told us nothing. **Content-Length on a valid session has never been tested.**

The asymmetry to keep hold of: our own receiver had to have chunked support
*added* to `handle_discover` and `handle_ask` (`opendrop-ios26-airdrop.patch`
fix 1), because iOS sends chunked **as a client**. That never implied iOS
accepts chunked **as a server**, and this is the first evidence it does not.

### Round four

| order | arm | framing | container |
|---|-----|---------|-----------|
| 1 | `reuse-chunked-gzip`  | chunked (control) | cpio + gzip |
| 2 | `reuse-length-gzip`   | `Content-Length`  | cpio + gzip |
| 3 | `reuse-length-dvzip`  | `Content-Length`  | dvzip |
| 4 | `reuse-length-plain`  | `Content-Length`  | bare cpio |

If arm 2 succeeds the whole thing was one missing header, and arms 3 and 4 are
unnecessary. If arm 2 fails but 3 or 4 succeeds, framing and container interact.
If all four fail, the refusal is in a header we have not varied at all -
`Connection: keep-alive`, `Accept-Encoding`, or `User-Agent: AirDrop/1.0` - and
the next move is to capture what an Apple device puts in its own `/Upload`
headers rather than guess again.

---

## §32 Framing is eliminated too. Stop guessing headers and go read Apple's.

2026-07-31, 22:00. Round four, four arms, all valid - each re-sent `/Ask`, got a
real Accept tap and a 200, and uploaded on that same connection.

| arm | framing | container | result |
|-----|---------|-----------|--------|
| `reuse-length-gzip`  | `Content-Length: 168` | cpio + gzip | close_notify |
| `reuse-length-dvzip` | `Content-Length: 160` | dvzip       | close_notify |
| `reuse-length-plain` | `Content-Length: 243` | bare cpio   | close_notify |
| `reuse-chunked-gzip` | chunked (control)     | cpio + gzip | close_notify |

**The §31 Content-Length hypothesis is dead.** It was the best-evidenced guess
of the night - on the same connection, `/Ask` with a Content-Length gets 200
every time while `/Upload` with chunked is always refused - and it was still
wrong. Content-Length changes nothing.

What is now eliminated for `/Upload`, all on valid accepted sessions:

- container: cpio+gzip, bare cpio, dvzip
- framing: chunked, Content-Length
- `Expect: 100-continue`, present and absent
- connection: reused post-`/Ask` (and, invalidly, fresh)

The refusal is on the request headers - §31's 70 microsecond close_notify is
unambiguous about that - and it is in a header we have never varied:
`Connection: keep-alive`, `Accept-Encoding: br, gzip, deflate`,
`User-Agent: AirDrop/1.0`, or something absent entirely that Apple requires.

### The move is to stop theorising

Four hypotheses in a row have been plausible, well-motivated, and wrong. Two of
them were motivated by what we had observed the phone do, which is the best kind
of motivation available, and they were still wrong. The pattern says the answer
is not reachable by reasoning from our end of the wire.

We do not have to reason. **The receive direction works.** When the phone sends
us a file it issues its own `/Upload`, and `do_POST()` already logs the complete
request headers at debug level - we have simply never run receive with `-d`.

`airdrop.sh receive` now passes `-d` and prints the phone's request headers at
the end of the run. One receive, one file sent from the phone, and the exact
header set an Apple sender uses is on screen. Then the send path copies it
instead of guessing at it.

That is the whole next step, and it costs one transfer in the direction that has
worked since §15.

---

## §33 Apple sends three headers. We send seven.

2026-07-31, 22:04. `airdrop.sh receive -d` logged what the iPhone puts on its
own requests, and the answer is short:

```
POST /Discover                 POST /Ask
User-Agent: AirDrop/1.0        User-Agent: AirDrop/1.0
Connection: close              Connection: keep-alive
Transfer-Encoding: chunked     Transfer-Encoding: chunked
```

That is the whole header set. **No `Content-Type`, no `Accept`, no
`Accept-Language`, no `Accept-Encoding`, no `Host`.** Upstream OpenDrop sends
all of those:

```
Content-Type: application/octet-stream
Connection: keep-alive
Accept: */*
User-Agent: AirDrop/1.0
Accept-Language: en-us
Accept-Encoding: br, gzip, deflate
Host: [fe80::...]:8770
```

This is a far larger divergence from Apple than anything varied in §29-§32, and
it was invisible for the whole evening because nobody had run the working
direction with `-d`.

### What it does and does not explain

It does **not** straightforwardly explain the `/Upload` refusal, and that has to
be said plainly: our `/Ask` carries every one of those extra headers and is
accepted every time, with a real prompt and a 200. So the extra headers are not
inherently offensive to the phone's HTTP server.

What changes is the prior. Four rounds of arms have excluded container, framing,
`Expect` and connection reuse, and the refusal is on the headers (§31's 70 us
close_notify). The headers we have never touched are precisely the ones Apple
does not send. `Accept-Encoding: br, gzip, deflate` on a request whose response
is a plist is the odd one out, and `handle_upload` is the one endpoint where the
server has to decide how to read a body.

### Still missing: the /Upload headers

The run captured `/Discover` and `/Ask` and then reset before the phone's
`/Upload` (§28 TX loss, the link was at 20-40%). **`/Upload` is the endpoint the
send path fails on, so its headers are the ones that matter**, and they are
still unknown. `airdrop.sh` now says so explicitly at the end of a receive run
rather than letting two-thirds of the answer look like the whole of it.

### Next arms

`minhdr` strips the Accept* set and sends only what the phone sends, keeping
`Content-Type` because our own receiver reads it to choose a decoder - so an
Apple sender must set it on `/Upload` even though it sets none on `/Discover` or
`/Ask`. That last point is an inference, not an observation, and a captured
`/Upload` would settle it.

---

## §34 The /Upload headers, captured at last

2026-07-31, 22:09. A complete 1.23 MB phone-to-laptop transfer, logged with
`-d`. This is what an iOS 26 sender puts on `/Upload`:

```
User-Agent: AirDrop/1.0
TotalBytes: 1303171
Content-Type: application/x-dvzip
SenderPseudonym: pseud:RDUDcHgUEfGhmdJSNF0FmQ
SenderPushToken: 1D0DD878B679E3AA7C9EC13EC596983FA9CF05E3AAEA25F978B5B14D4AB50493
TransferID: 664D3979-F245-4E9E-9EAC-80453E255E31
Connection: keep-alive
Transfer-Encoding: chunked
```

**Four headers we have never sent:** `TotalBytes`, `SenderPseudonym`,
`SenderPushToken`, `TransferID`.

`TransferID` is the one to look at. Without it a receiver has no way to tie an
incoming upload to the session it just accepted at `/Ask` - and "cannot
correlate this request with anything" is exactly the shape of a refusal issued
on the headers alone, before a byte of body is read (§31's 70 microsecond
close_notify).

It also settles two things that four rounds of arms could not:

- **chunked is correct.** Apple uses it. §31's Content-Length hypothesis was not
  merely unhelpful, it was pointing the wrong way.
- **dvzip is correct**, and `Content-Type` *is* set on `/Upload` even though
  `/Discover` and `/Ask` carry none. §33 inferred that; it is now observed.

Both were already tested and both failed, which is the point: they were
necessary and not sufficient, and no amount of varying them was ever going to
work while four required headers were missing.

### The new arm

`applehdr` sends all four alongside dvzip and chunked - a copy of an observed
Apple upload rather than a theory about one. Values:

| header | value |
|--------|-------|
| `TotalBytes` | actual payload length |
| `TransferID` | fresh upper-case UUID4 |
| `SenderPseudonym` | `pseud:` + 22 chars of base64 over 16 random bytes |
| `SenderPushToken` | 32 random bytes, upper-case hex |

Generated once per client so a retried arm reuses them.

**The caveat that matters:** we have no Apple ID, so the pseudonym and push token
cannot be genuine. If the receiver only checks that they are present and well
formed, this works. If it validates them against Apple's identity service, it
cannot, and no amount of header engineering will change that - the answer would
then be that anonymous AirDrop *sending* to iOS 26 is closed, while receiving
stays open. That distinction is worth stating in advance so the result is
readable either way.

Note the phone's `SenderPseudonym` and `SenderPushToken` match the
`ReceiverPseudonym` and `ReceiverPushToken` it returned in its own `/Ask`
response earlier in the evening - they are its stable identity, not per-transfer
values. Only `TransferID` is per-transfer.

---

## §35 applehdr failed, and the capture named the last two differences

2026-07-31, 22:16. All four Apple `/Upload` headers sent, with dvzip and
chunked. Refused, same close_notify. The arm was valid this time - the decrypted
request confirms it:

```
POST /Upload HTTP/1.1
Host: [fe80::38dd:74ff:fe15:955c]:8770      <- Apple sends NO Host
Accept-Encoding: identity                    <- Apple sends NO Accept-Encoding
Transfer-Encoding: chunked
Content-Type: application/x-dvzip
TotalBytes: 160
TransferID: BD0D1E93-524F-48D3-BEFA-CB0E3B84A8DD
SenderPseudonym: pseud:zGKTAi1gF0HF_RlcsHUFGw
SenderPushToken: 66D733785226A9FAA075E7D176C75865E786588CC305371F7BAE724D992F5ECD
User-Agent: AirDrop/1.0
Connection: keep-alive
```

`http.client.request()` inserts `Host` and `Accept-Encoding` unconditionally,
and an iOS 26 sender emits neither. It also reorders the headers, and Apple's
order is fixed. So even a request built to copy Apple exactly did not, and the
copy was never byte-accurate.

### rawhdr

`putrequest(skip_host=True, skip_accept_encoding=True)` suppresses both
insertions, and the chunked framing is then a few bytes to write by hand. The
`rawhdr` arm emits Apple's exact set in Apple's exact order and nothing else.
Verified offline against a local server: no `Host`, no `Accept-Encoding`, order
preserved, chunked body decoded intact, 200 returned.

**This is the last difference under our control.** After it, the request is a
byte-level copy of an observed Apple upload apart from the two values we cannot
forge.

### What a failure would mean

If `rawhdr` is refused, the remaining difference is `SenderPseudonym` and
`SenderPushToken` being well-formed but not genuine - we have no Apple ID and
no push token, and cannot obtain either. The conclusion would then be that iOS
26 validates sender identity on `/Upload`, and that **anonymous AirDrop sending
to iOS 26 is closed while receiving remains open**.

That is a legitimate result rather than a failure to find the bug, and it is
worth stating before the run so it cannot be rationalised afterwards. The
asymmetry would also make sense of everything else: receiving works because we
are the one being chosen, and a receiver that has been tapped by a human needs
no proof of who we are.

---

## §36 The BLE advert cannot be started before a run: it is the same chip

2026-07-31, 22:21. The advert was started at 22:14 with `--duration 2400`, and
by 22:21 `btmgmt advinfo` reported **0 instances**. That is the third time in an
hour, and every time it died around a run rather than at its timer.

The mt7921 is a **combo Wi-Fi/Bluetooth part**. Layer 1 tears the interface
down, adds two monitor vifs, and writes `runtime-pm` and `deep-sleep` on the
shared controller. That resets Bluetooth along with Wi-Fi, and a registered
advertising instance does not survive it.

So the advice in §27 - "start blewake.sh, then run airdrop.sh" - is wrong in a
way that is invisible unless you check `advinfo` rather than `pgrep`. The
process happily survives; the advertisement does not.

`airdrop.sh send` now starts the advert **itself, at layer 3**, after the radio
has settled, waits for the instance to register and gives the phone three
seconds to react. `--duration 600` because it only has to outlive one run.

This also retires a small mystery: several "the phone stopped advertising"
failures earlier in the evening were probably this, not the phone. The `-d`
check added after the second occurrence is what made the pattern visible.

## §37 — the /Upload refusal was our own missing TransferID announcement (written before the test)

Recorded before the run so the result cannot be rationalised afterwards.

Every arm from §29 through §36 sent a `/Upload` whose `TransferID` header the
`/Ask` had never announced. Our `send_ask` body was:

    SenderComputerName, BundleID, SenderModelName, SenderID, ConvertMediaFormats, Files

and `send_upload` then asserted a freshly-minted `TransferID` on `/Upload`. So the
receiver saw an upload for a transfer it had never accepted under that id.

The proof is a real iOS 26 sender's own `/Ask`, captured by our own receiver at
22:09 on 2026-07-31 (`~/.opendrop/debug/receive_ask_request.plist`). Its body
carries what ours never did:

    TransferID   = {'id': '664D3979-F245-4E9E-9EAC-80453E255E31'}   # a DICT
    TransferType = {'files': {}}
    SenderRecordData = <CMS-signed Apple-ID validation record>
    SenderIdentityAuthTag = b'\x0b9\xe6'

and that same phone's `/Upload` header (FINDINGS §34) was `TransferID:
664D3979-F245-4E9E-9EAC-80453E255E31` — **the identical id**. The receiver binds
`/Upload` to the `/Ask` it accepted by this id. Ours matched nothing, which is
why the refusal landed on the headers ~31 microseconds-to-milliseconds in,
before the body was read (§31), on connections the phone had just accepted an
`/Ask` on. Every "container eliminated" and "framing eliminated" conclusion from
the earlier rounds is therefore void: they all shared this one defect, so none of
them could have succeeded regardless of container or framing.

This also corrects §34/§35's read that we had matched the Apple upload. We had
matched its *headers*; we had not matched the *session* those headers referred
to, because we never announced it.

FIX: `send_ask` now declares `TransferID = {'id': self._transfer_id}` and
`TransferType = {'files': {}}` in the `/Ask` body, and `/Upload` repeats the same
`self._transfer_id`. The default arm list collapses to one arm,
`reuse-chunked-dvzip-rawhdr`: reused connection, chunked, dvzip container,
Apple's exact header set and order — now a byte-level copy of the observed Apple
`/Upload` **and** of the session it belongs to, apart from the values we cannot
forge.

THE ONE REMAINING FORGERY-PROOF DIFFERENCE, stated in advance:
`SenderRecordData` — the Apple-signed Apple-ID validation record — and its
companion `SenderIdentityAuthTag`. We have no Apple ID and cannot mint either.

- If this arm is ACCEPTED (200): the file lands on the phone. Anonymous AirDrop
  *sending* to iOS 26 works; the whole evening's wall was one unannounced id.
- If it is refused on the headers *again*, now that the id is announced: the
  refusal can only be `SenderRecordData`. The conclusion is then that iOS 26
  requires a genuine signed sender identity to *receive* an upload it already
  visibly accepted, and anonymous sending is closed while receiving stays open.

These two outcomes are distinguishable on the wire: a header-time close_notify
means the id did not fix it; a `100-continue` or a read of the body means it did.

### §37 RESULT (2026-07-31 22:35) — SENDING WORKS

`run airdrop-20260731-223526`. On the wire, decrypted:

    POST /Ask     -> 200 OK
    POST /Upload  -> 200 OK        (frame 65, ~1 s after /Ask)

The file landed on the iPhone. The single arm `reuse-chunked-dvzip-rawhdr`
was ACCEPTED on its first and only attempt.

So the answer to the pre-registered question is the first branch:
**anonymous AirDrop sending to iOS 26 works.** The entire evening's refusal
was one unannounced `TransferID`. `SenderRecordData` is NOT required to send -
the phone accepted the upload from a sender with no Apple ID, no signed
validation record, and forged pseudonym/push-token. The identity fields are
carried but not verified at the `/Upload` stage; the binding the receiver
actually enforces is that `/Upload`'s `TransferID` was announced in a `/Ask`
it accepted.

Laptop -> iPhone AirDrop over an MT7921 is now end-to-end complete:
link-layer sync (OWL) -> IPv6 over awdl0 -> BLE wake -> /Discover -> /Ask ->
/Upload 200.

## §38 Wi-Fi and AirDrop at the same time: coexistence is free, the channel is not (2026-08-02)

**Question:** must `airdrop.sh` take the card exclusively, or can the machine stay
on Wi-Fi while AWDL runs?

**Measured, against a live association** (`2142-WiFi`, ch36/5180, mt7921):

| step | result |
|---|---|
| `iw phy phy0 interface add mon0 type monitor` with `wlp2s0` UP and associated | **OK** |
| managed link after adding mon0 | Connected, -67 dBm, `ping 1.1.1.1` **0% loss** |
| `iw phy phy0 interface add mon1 type monitor flags active` alongside | **OK**, link still up |
| `echo 0 > mt76/runtime-pm`, `deep-sleep` | link unaffected, 3/3 ping |
| `iw dev mon0 set freq 5745` | **EBUSY (-16), REJECTED** |
| radiotap ground truth on mon0 | 19/20 frames at **5180** = the AP's frequency |

So the `ip link set $IFACE down` at layer 1 was **never about interface
coexistence**. mac80211 creates the monitor vifs happily alongside an associated
managed vif - note that `iw phy phy0 info` lists **no monitor entry at all** in
its interface combinations (`managed/P2P` only, `#channels <= 2`), because
monitor vifs are not counted against them. The teardown was only ever about
freeing the *channel*.

**The real constraint: the monitor vif has no channel context of its own and is
locked to the AP's.** Note this is a *rejected* retune, not the silent-ignore of
§24 where mon1's retunes were accepted and dropped on the floor - here the
kernel says EBUSY out loud.

**Why that is survivable:** §24 already established that OWL's channel hopping
was fiction in every working transfer. mon0 owned the channel context, mon1's
retunes were accepted and ignored, and all four bisect builds transmitted on 149
to a phone on 149. The radio has always been effectively pinned to one channel;
KEEP_WIFI only changes *who picks it*. And `set_channel()` is async with errors
deliberately unreported (`daemon/netutils.h:53`), so OWL swallows the EBUSY.

**Therefore the condition is: the AP must sit on a channel the phone's AWDL
sequence uses.** Not hypothetical - the §"PIN channel-picker" capture had the
phone advertising `36,36,149,0,0,0,0,36,6,36,149,36,0,0,0,36`, ch36 dominant at
**6/16 slots**, and this AP is on ch36. `KEEP_WIFI=1` refuses outright if the AP
is on a non-social channel, because every downstream symptom would look like
anything but the real cause.

**Implemented as `KEEP_WIFI=1`.** It leaves NetworkManager, wpa_supplicant and
the regulatory domain alone, borrows the AP's channel, skips the sweep (which is
impossible, not merely unwise - it works by retuning), replaces it with a single
dwell on the AP's channel, and - importantly - does **not** bounce the interface
during restore. Verified end to end with a concurrent `ping`: **13/13 replies, 0%
loss across a full run**, association held, no leftover vifs afterwards.

**STILL UNPROVEN: that a transfer completes in this mode.** Coexistence is
measured; the transfer is not. It needs a phone and a share sheet:

```sh
KEEP_WIFI=1 ACTIVE=1 ./airdrop.sh receive
```

**VOID CONDITION:** if the layer-0 dwell reports 0 frames the run says nothing -
re-run without `KEEP_WIFI` so the sweep can distinguish "phone asleep" from
"phone on another channel".

**Unconditional fallback:** give AWDL its own radio (the AR9271). Two phys, no
shared channel context, no condition to satisfy.

## §39 On-demand AirDrop: the stack comes up in 0.19 s, so always-on is a BLE problem (2026-08-02)

Investigating a waybar AirDrop module. Three measurements, no phone required.

**1. Time to a working AWDL stack, measured:**

| step | time |
|---|---|
| monitor pair created, PM off | 0.057 s |
| OWL started to "Host device" | 0.117 s |
| `awdl0` present and up | 0.015 s |
| **total** | **0.190 s** |

Every `sleep 2` / `sleep 4` in `airdrop.sh` is a conservative fixed delay, not a
requirement. Its ~90 s time-to-advertising is almost entirely self-imposed.

**2. BLE scanning works.** `btmon` + `btmgmt find -l` sees Apple Continuity
adverts continuously (96 in 10 s), with RSSI, including devices at -40 dBm.

**3. The BT controller survived layer 1 under `KEEP_WIFI`** — still `powered`
after the monitor pair and the runtime-pm/deep-sleep writes. §36's "layer 1
resets the shared BT controller" appears specific to the exclusive path where
the managed interface goes down. Only `powered` was checked, not that a
registered advertising instance survives.

**So always-on AirDrop is not an AWDL problem, it is a BLE problem.** A Mac does
not hold AWDL up either; it scans BLE and wakes AWDL on demand. Implemented as
`daemon/airdropd`. This also dissolves the §38 dilemma: rather than choosing once
between "no internet" and "locked to the AP's channel", the radio is committed
only while a transfer is happening.

### The security hole this exposed

**`handle_ask` in opendrop 0.13.0 accepts unconditionally** — returns 200 with
the machine name, no prompt, no extension point. Fine for a harness driven by
hand; for an always-on receiver it means anyone in range with AirDrop set to
Everyone can write files to the box unattended and unlogged.
`patches/opendrop-ask-confirm.patch` adds a fail-closed hook. Six paths verified,
including "hook unrunnable → decline" and "no Wayland session → decline". An
unaskable question is not consent.

### Gotchas paid for

- **`stdbuf -oL btmon` is load-bearing.** Piped, btmon gets 4 KiB full buffering
  from libc: **zero output over 20 s** into the parser, while the identical parse
  of a captured file succeeded every time. Same fix airdrop.sh needs for OWL.
- **Parse the manufacturer-data bytes, not btmon's labels** — it renders
  unrecognised subtypes as `Type: Unknown (16)` and its label set is bluez-version
  dependent.
- **btmon shows outgoing commands too**, so a naive parser detects our own
  `blewake.sh` type-0x05 advert and triggers against itself. A `<`/`>` direction
  filter is required. Verified with the advert actually registered: 0 detections.
- **Continuity type 1 is REAL** (`4c 00 01 00 …`, btmon "Identifier"), not a
  parse artefact. Only type 0 padding needed suppressing.
- **mt7921 interface autodetect must skip monitor vifs** — they are mt7921-driven
  and `mon0` sorts before `wlp2s0`, so the naive loop picks a monitor vif whenever
  the stack is up and then reports `assoc:false, chan:null` about the wrong
  interface. airdrop.sh escapes it only by resolving before creating vifs.

**NOT YET PROVEN: an end-to-end transfer through `airdropd`.** Needs a phone. The
trigger has never seen a real iPhone share-sheet advert, only our own — which it
is designed to ignore.

## §40 First live test of `airdropd`: BLE trigger PROVEN, blocked by the channel lock (2026-08-02)

Against a real iPhone, share sheet open.

**The BLE trigger works.** 297 Continuity type-`0x05` adverts detected the moment
the share sheet opened, at -26 dBm; `airdropd` fired at **5 s**. Everything §39
predicted about detection holds. Zero type-5 adverts in a 4-minute control run
with the sheet closed, so the discriminator is clean.

**Bug found and fixed: OWL was started unprivileged.** It creates the `awdl0`
tun and cannot do that as the user, so it printed its banner and simply never
produced an interface - surfacing as `awdl0 never appeared`, which reads like a
radio problem rather than the permission problem it is. `airdrop.sh` has
`sudo stdbuf -oL owl`; `airdropd` had dropped the sudo. Fixed by moving OWL
behind `airdrop-helper owl-start`, running a **root-owned copy at a fixed path**
(`/usr/local/bin/airdrop-owl`) - running the user-writable `$OWL_DIR/build/...`
as root would be the same escalation the sudoers rule already avoids.

**THE REAL BLOCKER: the phone's AWDL was on ch149; our AP is on ch36.**

- `add peer` events: **0**. AWDL frames captured on ch36: **0**.
- BLE advert simultaneously live at -26 dBm, so the phone was awake and willing.
- `slotmap.py` on the subsequent exclusive run: every sequence the peer
  advertised was **149**-dominant (`149,149,149,...,6,...`), offering 2-15 of 16.

So §38's condition is sharper than "the AP must be on a social channel". It is
**"the phone must be on the AP's channel"** - and that is not knowable in
advance, not controllable, and observed to drift (6, 36, 149 all seen across
sessions). An AP parked on 36 is no help when the phone picks 149.

**The exclusive path still works end to end.** `ACTIVE=1 ./airdrop.sh receive`
swept to 149, synced, and received **IMG_8263.PNG, 282806 bytes** (matching the
`TotalBytes` header exactly), `/Upload -> 200`. 717 packets from the peer,
45.7 kB/s, duty cycle 11.7%. Note the file's mtime is the PHOTO's, not the
receive time - `find -newermt` will not find it; use `ls -lat`.

**Operator-observed: ~40 s from launch to appearing in the share sheet** on the
exclusive path, dominated by the channel sweep.

### What this means for the on-demand design

Channel-locked operation cannot be the only mode. The per-transfer decision has
to be made from evidence, not from configuration: on a trigger, bring the stack
up on the AP's channel, look for AWDL frames for a second or two, and **fall
back to taking the card exclusively (sweep, transfer, restore) when the phone is
not there**. That keeps the internet up in the lucky case and still works in the
common one. NOT YET IMPLEMENTED.

Also confirmed en route: **avahi is NOT the problem.** avahi and opendrop hold
UDP 5353 concurrently without conflict, and opendrop announced normally
(`port 8771`). The earlier suspicion was wrong; do not stop avahi for this.

### §40b The fix for "keep Wi-Fi up always": move the AP to ch149

The canonical AWDL social channels are **6, 44 and 149**. Channel 36 is not one
of them. §38 accepted 36 because an iPhone had once been seen advertising a
36-heavy sequence, and §40 shows what betting on that costs.

**NZ regulatory permits 149.** The full `iw reg get` for NZ includes
`(5725 - 5875 @ 80), (N/A, 36), (N/A)` — 36 dBm, **no DFS**, i.e. *more* power
and fewer dropouts than ch36 (`5150-5250 @ 80`, 30 dBm). An earlier reading of
these rules that stopped at `5470-5730` and concluded 149 was disallowed was
simply a truncated grep.

So on this network the answer to "can I keep Wi-Fi up permanently?" is **yes,
move the AP's 5 GHz radio from 36 to 149.** Then the AP's channel — which
KEEP_WIFI locks the monitor vifs to — is the phone's own dominant AWDL channel,
which in §40 offered up to **15 of 16 slots** (better than the 11.7% duty cycle
the exclusive run actually achieved). No fallback, no dropped association.

The AP (`2142-WiFi`) has two BSSes: `…:4a` on ch2 and `…:4b` on ch36. Note the
laptop reassociated to the **2.4 GHz** BSS after an `airdrop.sh` restore, so
confirm which BSS you are on before reading anything into the AP channel.

## §41 Why a Mac needs no router config and we do — measured, not assumed (2026-08-02)

Asked whether AirDrop can work alongside Wi-Fi on any channel, the way macOS
manages it, without touching the AP.

**The mechanism macOS uses:** Apple's driver implements AWDL natively. It
time-shares the one radio — announces power-save to the AP so it buffers, hops
to the social channel for the availability window, and returns. That scheduler
lives in the driver.

**Why we cannot copy it on mt7921/mac80211, measured:**

| test | result |
|---|---|
| `iw phy phy0 info` interface combinations | `#{managed,P2P-client} <= 2, #{AP} <= 1, #{P2P-device} <= 1, #channels <= 2` — **monitor appears in NO combination** |
| create `__ap` vif, `set freq 5745` while associated | vif created, **no channel** (an AP vif claims a context only once hostapd starts it) |
| monitor vif `set freq 5745` with that vif present | **EBUSY (-16)** |
| `remain_on_channel` / `frame` in supported commands | **present** |
| `iw dev wlp2s0 offchannel 5745 2000` while associated | **failed, ETIMEDOUT (-110)** |

The card really does support two channel contexts — that is how Wi-Fi Direct
runs alongside infra — but **a monitor vif can never own one**; it always rides
whatever context exists. Linux has no AWDL interface type, so OWL must use
monitor mode, and that is the whole gap.

**Remain-on-channel is not a way out even if it worked.** ROC grants a window
for `NL80211_CMD_FRAME`, i.e. *action* frames. AWDL sync and discovery are
action frames, so ROC could in principle carry those — but the actual transfer
is TCP in AWDL **data** frames, which cannot be sent that way. ROC would buy
discovery and not the payload.

**So there are exactly three ways to have AirDrop and Wi-Fi at once:**

1. **AP on a social channel (6/44/149).** Free, five minutes, works permanently,
   and 149 in NZ is 36 dBm with no DFS — a better Wi-Fi channel than 36 anyway.
   Requires router config.
2. **A second radio.** Config-free, but must do **5 GHz** active monitor to reach
   149. The AR9271 cannot: `ath9k_htc` is 2.4 GHz-only, so it could only ever sit
   on ch6, which the observed phone offered in **1 of 16 slots**.
3. **Driver work** — give monitor vifs their own chanctx, or implement AWDL
   properly with PS signalling. This is the real answer to "how do Macs do it"
   and nobody has it on Linux. It is also the genuinely publishable piece.

There is no fourth option that is only configuration on our side. Upstream OWL's
"you need a specific adapter" requirement is a symptom of exactly this.

## §42 Making the mt7921 do both — what the driver work actually is (2026-08-02)

Constraint: one chip, no router config, no second radio. So it is kernel work.
Scoped by inspection of the shipped modules (decompressed with Python 3.14's
`compression.zstd`, since `zstd(1)` is not installed here).

**The good news — this chip does REAL multi-channel, not emulated:**

- `mt7921-common.ko` links `mt792x_assign_vif_chanctx` / `mt792x_unassign_vif_chanctx`.
- `mt76.ko` exports the full set: `mt76_{add,remove,change}_chanctx`,
  `mt76_{assign,unassign,switch}_vif_chanctx`.
- **No `ieee80211_emulate_*` symbols anywhere**, so mac80211 is not faking
  contexts for this driver.

**The blocker, precisely:**

```
#{managed,P2P-client} <= 2, #{P2P-GO} <= 1, #{P2P-device} <= 1, total <= 3, #channels <= 2
#{managed,P2P-client} <= 2, #{AP}     <= 1, #{P2P-device} <= 1, total <= 3, #channels <= 1
```

Two channels are permitted **only in the P2P-GO combination**, and **monitor
appears in no combination at all**. Measured consequences, all with the managed
vif associated:

| attempt | result |
|---|---|
| `__ap` vif + `set freq 5745` | created, **no channel** (claims a ctx only once it beacons) |
| `__p2pgo` vif + `set freq 5745` | created, **no channel**, same reason |
| monitor `set freq 5745`, either present | **EBUSY (-16)** |

So the EBUSY is `ieee80211_set_monitor_channel()` refusing whenever a non-monitor
vif is up, *and* cfg80211 would reject the combination regardless.

### The patch is therefore two parts

1. **mt76**: add `monitor` to the interface-combination limits that carry
   `num_different_channels = 2`.
2. **mac80211**: relax `ieee80211_set_monitor_channel()` so a monitor vif may take
   its own chanctx when the advertised combinations allow it, instead of
   returning EBUSY on `open_count != monitors`.

### Do this experiment FIRST — it is much cheaper and can invalidate the whole plan

The `#channels <= 2` claim is made for **managed + P2P-GO**. The firmware
implements MCC for that case; nothing says monitor is wired into its channel
scheduler. If it is not, the patch will create a chanctx the firmware quietly
ignores — which is *precisely* this chip's signature failure mode (accepts the
call, logs no error, does not work: §"three mt7921 bugs, all silent").

**So prove MCC works at all before patching:** get a P2P-GO beaconing on 149
while associated on 36, and confirm with radiotap that both channels are really
serviced. Needs a P2P-capable `wpa_supplicant` (this box's has no
`p2p_group_add`) or `hostapd` (not installed).

### Build prerequisites on this box

- Only `linux6.18-headers` is installed; the `linux6.18` source package exists
  but is not. Headers alone are not enough to rebuild mac80211.
- `flex` and `bison` are **missing**; `gcc` and `make` are present.
- mac80211 and mt76 are both modules, so an out-of-tree rebuild of just those
  two is viable and avoids rebuilding the whole kernel.

## §43 — the EBUSY is in cfg80211, and §42's plan was wrong on every point

Kernel work now lives in its own repo: `/mnt/shared/projects/mt7921-awdl-kernel`.

§42 scoped a two-part patch to mt76 and mac80211. Reading the actual 6.18.33
source shows **both parts were unnecessary and neither was the blocker.**

- **Not the interface-combination table.** `mac80211/main.c:1354` puts monitor
  in `wiphy->software_iftypes`, and `ieee80211_check_combinations()` returns 0
  early for software iftypes (`util.c:4186`). mt7921 does not set
  `NO_VIRTUAL_MONITOR` — only mt7996 does. The `#channels <= 2` line is never
  consulted for a monitor vif, so "add monitor to the combination" was moot.
- **Not `ieee80211_set_monitor_channel()`.** The `open_count != monitors` gate
  I remembered is from older kernels. In 6.18 the function calls
  `ieee80211_link_use_channel()` directly.
- **Not the driver.** `mt7921_add_chanctx()` is `dev->new_ctx = ctx; return 0;`
  and `mt792x_assign_vif_chanctx()` is bookkeeping. Neither can fail.

It is **`cfg80211_set_monitor_channel()`**, `net/wireless/chan.c:1550`, calling
`cfg80211_has_monitors_only()` (`core.h:252`):

```c
return rdev->num_running_ifaces == rdev->num_running_monitor_ifaces &&
       rdev->num_running_ifaces > 0;
```

A third module, cfg80211.ko, and a one-line change.

### Why the fix may still not work

mt7921 has one hardware channel: `mt7921_config()` handles
`CONF_CHANGE_CHANNEL` via `mt76_update_channel()`, which programs the whole
PHY. And mt76's generic chanctx code is openly single-channel
(`mt76/channel.c:47`) — if a chanctx already exists it **returns 0 and does
nothing**. Accepting a second chanctx and ignoring it is exactly the silent
failure this chip specialises in.

The one hopeful sign: `mt7921_change_chanctx()` special-cases monitor vifs to
`mt7921_mcu_config_sniffer()` (`mt7921/mcu.c:1161`), which sends the firmware a
sniffer band/bw/control-ch/center-ch of its own, separate from the BSS channel.
Whether that is an independent receive context or just another route to the
global channel is the open question. Note it is reached only from
`change_chanctx`, never from `add_chanctx`/`assign_vif_chanctx`.

### The MCC pre-experiment from §42 is cancelled

It was going to prove firmware MCC via a P2P-GO on 149. Unnecessary: the
combination table is not consulted for monitor, so what P2P-GO can do says
nothing about what a monitor vif can do. It also could not have run — this
box's `wpa_supplicant` has no P2P compiled in (`p2p_group_add` is absent from
the daemon, present only in `wpa_cli`). Testing the patch directly is both
cheaper and more direct.

### Build facts (correcting §42)

- Running kernel is **6.18.33_1** but installed headers are **6.18.40_1** —
  mismatched. Irrelevant now: we build from a kernel.org 6.18.33 tarball, and
  `CONFIG_LOCALVERSION="_1"` from `/proc/config.gz` makes `make kernelrelease`
  print `6.18.33_1` exactly. No kernel upgrade, no reboot.
- `CONFIG_MODVERSIONS` is **off** → no symbol CRCs, vermagic match is enough.
- `CONFIG_MODULE_SIG_FORCE` is **off** → unsigned modules load, taint only.
- Therefore `KBUILD_MODPOST_WARN=1` is safe: there is no `Module.symvers`
  without a vmlinux build, and the loader resolves the symbols at insert time.
- `/` is at **95%** (2.7 G free). All kernel work goes on `/mnt/shared`.
- `flex`, `bison`, `zstd`, `elfutils-devel` now installed.

Built and verified: `cfg80211.ko`, vermagic `6.18.33_1`, exposing
`monitor_any_chan`. Not yet loaded — loading drops the link.

## §44 — one chip cannot do both. The firmware is the wall.

Kernel work done in `/mnt/shared/projects/mt7921-awdl-kernel`. **Negative
result, verified end to end.**

Three separate gates block monitoring an AWDL social channel while associated.
Each was found only by patching the one above it, because **every one of them
fails by succeeding** — no error, no log, the call returns 0.

| # | layer | gate | patch |
|---|---|---|---|
| 1 | cfg80211 | `cfg80211_has_monitors_only()` (`chan.c:1550`) | `monitor_any_chan` |
| 2 | mac80211 | virtual monitor created only when `open_count == 0` (`iface.c:1403`) | `monitor_concurrent` |
| 3 | mt7921 | `mcu_config_sniffer()` reachable only from `->change_chanctx` | call on `->assign_vif_chanctx` |

After gate 1, `iw set freq` returned 0 instead of EBUSY — and ftrace showed **no
driver function ran at all**. That was gate 2: with no `monitor_sdata`,
`ieee80211_set_monitor_channel()` takes `goto done`, records the channel and
returns success without touching hardware.

With all three patched, ftrace confirms the whole chain runs:

```
ieee80211_set_monitor_channel <-cfg80211_set_monitor_channel
ieee80211_new_chanctx         <-_ieee80211_link_use_channel
mt7921_add_chanctx            <-ieee80211_add_chanctx
mt7921_assign_vif_chanctx     <-drv_assign_vif_chanctx
mt7921_mcu_config_sniffer     <-mt7921_assign_vif_chanctx
```

`MCU_UNI_CMD(SNIFFER)` **returns success**. The radio does not move.

**Measured:** associated on ch2 (2417 MHz), monitor requested on ch149 (5745
MHz). **593 of 593 captured frames were 2417 MHz, zero on 5745.** Association
survived throughout at 0% packet loss.

### Conclusion

The mt7921 firmware's sniffer channel is not independent of the associated BSS
channel, so gate 4 is the firmware and no kernel patch reaches it. This closes
"one chip, both at once" — the §42 plan and everything after it.

What remains true and working is the existing userspace path: AirDrop succeeds
when the phone's AWDL lands on the channel the AP already uses. The options are
unchanged from §38 — accept that constraint, drop the association for the
duration of a transfer, or add a second radio.

Stock stack restored on the box; nothing was written to `/lib/modules`.

## §45 — the firmware CAN time-slice two channels; the sniffer just isn't wired to it

Analysis of `/lib/firmware/mediatek/WIFI_RAM_CODE_MT7961_1.bin.zst` (792 KB
decompressed). This refines §44's conclusion in an important way.

- **Not encrypted.** Debug strings, format strings and MediaTek's internal build
  paths are readable, e.g.
  `build/csp/7961/asic2.0/projects/wifi_mobile_ram_ccn16/.../hal_cal_flow.c`.
- **RAM code, re-uploaded from disk every boot.** Nothing is flashed, so a bad
  firmware patch **cannot brick the card**: the driver fails to init and
  restoring the file fixes it. The risk here is low; the *effort* is the
  problem.
- Trailer: `____010000` + build date `20260224110949` + 4-byte CRC
  (`8a a4 75 57`), matching the driver's probe output. A CRC, not obviously a
  cryptographic signature. Whether the ROM enforces one is untested.

The decisive strings are a **channel manager with time-slicing**:

```
CnmFastChReqQuotaInUs      CnmGOAbsenceMarginInUs
EnCnmDoubleWFDCHtime       EnCnmSyncTBTT
fgCnmForceEarlyAbortCH     Check CNM minimum quota time:
```

Quota, absence margin, TBTT sync, early channel abort — and the `GO`/`WFD`
naming ties it to P2P Group Owner and Wi-Fi Direct, i.e. precisely the driver's
advertised `#{managed} + #{P2P-GO}, #channels <= 2`.

There are **zero sniffer strings** in the firmware.

So §44's "one chip cannot do both" is too broad. Correctly stated: **the chip
can service two channels, but the sniffer is not a client of the scheduler that
does it.** That is why `mt7921_mcu_config_sniffer()` returned success and
changed nothing — there was never a code path to honour it.

Note `DBDC band :%d not support in MT7961` also appears. That rules out two
*bands* at once (two RF chains), not CNM time-slicing on one chain.

### Next avenue (not started)

Put AWDL on a vif CNM will schedule — a **P2P-GO** — instead of a monitor vif.
No firmware work required. Experiment: P2P-GO beaconing on ch149 while
associated on ch36, confirmed by capture that both channels are really serviced.
Needs `hostapd` or a P2P-capable `wpa_supplicant` (this box's daemon has no P2P;
`p2p_group_add` exists only in `wpa_cli`).

**Caveat:** even if CNM services ch149, OWL still needs raw injection and
reception there, and a monitor vif follows the sniffer channel — the thing §44
proved is tied to the BSS. That gap is a second unknown. Maybe-promising, not
likely.

This is the experiment §42 proposed and §43 cancelled. §43's reasoning (the
interface-combination table is not consulted for monitor vifs) was correct but
beside the point: the blocker is the unwired sniffer, not the combination table.

## §46 — SOLVED: Wi-Fi + AWDL on one MT7921, stock kernel, via a P2P-GO chanctx (2026-08-03)

**§38's "the AP owns the channel" and §40b's "move the router to ch149" are both
obsolete.** A P2P-GO vif holds a real channel context on a channel *we* choose,
while the station stays associated elsewhere. Measured on ch149 (5745) while
associated on ch52 (5260), 0% uplink packet loss throughout:

| | monitor vif (§43-§45) | P2P-GO vif |
|---|---|---|
| radio actually moves | **no** — 593/593 on the AP's chan | **yes** |
| RX on 149 | 0 | **222 frames, 75 from external devices** |
| TX on 149 | never reached | **82 solicited probe responses, 5 APs** |
| AWDL | — | **4 peers, sync locked; iPhone replied to ping6 (460 ms)** |

The ping6 reply is an ICMPv6 packet over `awdl0`, i.e. an 802.11 **data** frame
with the AWDL header — so the data path, not just management, is proven.

### Two mechanisms (kernel work in /mnt/shared/projects/mt7921-awdl-kernel)

1. **`#channels <= 2` is offered ONLY in the P2P-GO interface combination**;
   plain AP is `#channels <= 1`. hostapd unconditionally forces iftype AP, so
   stock hostapd fails with `nl80211: Beacon set failed: -16`. A one-line
   env-gated patch (`HOSTAPD_P2P_GO=1`) keeps the iftype as P2P-GO.
   `is_ap_interface()` already accepts P2P_GO, so nothing else changes.
2. **Monitor TX borrows another vif's chanctx by MAC.**
   `ieee80211_monitor_start_xmit()` (`net/mac80211/tx.c:~2377`) matches an
   injected frame's `addr2` against running **non-monitor** vifs and uses that
   sdata's chanctx. Monitor vifs are skipped by the loop, so **aliasing mon0's
   MAC to the GO's is the whole integration trick** — that is how OWL's frames
   reach ch149.

### THE SILENT-DROP TRAP

While associated, monitor-vif injection is dropped inside mac80211 with
`tx_packets`, `tx_dropped` **and** `tx_errors` all staying 0 and `send()`
returning success. The first TX test read as "MCC TX doesn't work"; the
**no-GO control also gave zero**, which is what identified the monitor-TX path
rather than MCC as the fault. Injecting with the GO's MAC then gave 82
responses vs **0** for an invented MAC. Run the control first.

### THE COST — the remaining design problem

Uplink to the gateway: **~2.6 ms avg baseline → ~40 ms median, 280-590 ms max**
while the GO holds a second channel. 0% loss, pure latency. Fine for browsing,
bad for VC/gaming. macOS pays the same cost (one radio, same physics) and hides
it by not keeping AWDL up — which is exactly §39's BLE-triggered model.

**Zero-cost plan, NOT yet tested:** if the GO sits on the *AP's own* channel
there is no time-slicing at all. Enabling fact from our own captures — **slot 8
is always the 2.4 GHz social slot**:

```
112,112,149,0,0,0,0,112,6,112,149,112,0,0,0,112
 36, 36,149,0,0,0,0, 36,6, 36,149, 36,0,0,0, 36
```

So park the GO on ch6 with the AP's 2.4 GHz BSS also on ch6: zero cost, AWDL up
24/7, but only 1/16 slots (~6% duty, ~22 kB/s extrapolated). Then use hostapd
`chan_switch` (CSA) to hop to the phone's dominant channel for the duration of
a real transfer. CSA on a GO is untested on this chip.

### Still open

- **No file transfer has been done in GO mode.** ping6 was 1/5 (categorical PASS
  per §23/§26, but ping6 cannot size an effect). The 80% loss is explained: the
  phone offered ch149 only 2/16 slots that run (112 was dominant at 6/16).
- `.venv-opendrop` is missing from this repo and must be rebuilt with the three
  patches before any transfer test.
- **`handle_ask` still unconditionally accepts** (§39) — blocks anything
  always-on. `patches/opendrop-ask-confirm.patch` is not applied.
- Active-monitor ACKs against a GO-held chanctx: untested. If unicast fails,
  try the §14 PAIR with both vifs MAC-aliased.

## §47 — the always-on waybar toggle, end to end: five bugs, a new strategy, and a 99.1% photo (2026-08-03 evening)

Starting point: the bar toggle existed (§46) but "turn it on and my phone never
shows me". Ending point: a 666 KB photo arriving 99.1% intact at ~73 kB/s, with
Wi-Fi up throughout. Five separate bugs were stacked, each of which alone was
enough to break it. They are listed in the order they had to be peeled off,
because each one hid the next.

### 1. The re-announce never ran once (`fc075a1`)

The guard meant to skip re-announcing mid-transfer was

    ss -tn state established "( sport = :8771 or sport = :8772 )" | grep -q .

and **`ss` prints its column header even when nothing matches**, so `grep -q .`
was always true. Every tick logged `re-announce deferred - transfer in flight`
with nothing transferring — fourteen in a row in the first capture. Since
python-zeroconf announces once at registration and the iPhone never polls, the
receiver was invisible from ~30 s after arming. Fix: `ss -Htn`.

**Diagnostic:** `grep re-announcing $XDG_RUNTIME_DIR/airdropd/airdropd.log`. If
only `deferred` lines appear, it is this class of bug, not the phone.

### 2. The bar lied about being on (`fc075a1`)

`status` trusted a state file that outlives the daemon. Toggle off then
straight back on: the new `run` loses the flock race against the old instance's
cleanup, exits silently, and leaves the click's nudged `waking` behind — bar
reads "drop on" with no airdropd, no owl, no awdl0. `status` now treats a free
lock as `off` regardless of the file.

### 3. "Re-announce" was implemented as killing opendrop (`02b6619`)

    19:41:19 re-announcing (30s since last)
    19:41:19 opendrop exited - respawning
    19:41:21 Starting HTTPS server

Every `REANNOUNCE` seconds the service deregistered and nothing listened on
8771 for ~1.5 s. **This is what "it appears then disappears" actually was** — a
30-second flap, not a phone problem. A transfer starting near a boundary lost
its socket outright.

Fixed by `patches/opendrop-mdns-reannounce.patch`: opendrop re-sends its own
records from a daemon thread (`OPENDROP_ANNOUNCE_INTERVAL`, default 5 s)
without touching the registration or the listener. Verified 6 announces in
32 s, one PID, zero restarts. The kill loop is gone.

### 4. OWL's channel switching is a silent no-op under P2P-GO

The measurement that reframed everything. In one 15 s capture on `mon0`:

| what | count |
|---|---|
| frames on 5180 MHz | 2425 |
| frames on any other frequency | 0 |
| channel switches OWL logged in that window | 10 to ch149, 10 back to ch36 |

`go0` owns the chanctx and `set_channel()` on the MAC-aliased monitor vif
cannot move it. OWL believes it is hopping to follow the phone; the radio never
leaves the GO's channel. **This is the structural cost of P2P-GO**: the thing
that keeps the Wi-Fi association alive is exactly the thing that pins us to one
channel while the phone ranges over 36/149/6 plus empty slots.

Nor can the GO retune in place. `hostapd_cli chan_switch` returns FAIL for
every parameter form tried, including a same-subband 149→153 hop:

    chan_switch 5 5180 center_freq1=5180 bandwidth=20 ht   -> FAIL
    chan_switch 5 5180                                     -> FAIL
    chan_switch 5 5180 bandwidth=20                        -> FAIL
    chan_switch 5 5180 center_freq1=5210 bandwidth=80 vht  -> FAIL
    chan_switch 5 5765 center_freq1=5765 bandwidth=20 ht   -> FAIL

hostapd logs `chanswitch: invalid frequency settings provided`; the phy
advertises no channel-switch support. **Changing the GO's channel requires a
full teardown and bring-up.**

### 5. The strategy was one OWL's own header says iOS rejects

`airdrop-helper` defaulted to `-S pin`, while `owl/src/channel.h` records PIN as
measured *rejected* by iOS 26 (§25: same phone, same binary, verbatim 60% ping
loss against pin 100%) because one channel in all 16 slots with no empty slots
looks like nothing an Apple device emits. The helper default contradicted the
finding it was documented against.

**New strategy: INTERSECT** (`owl` `fa2e6b1`, helper default in `e5d215d`).
Advertise the peer's own slots that sit on our channel; blank the rest. Both
existing options lie in opposite directions — VERBATIM claims we follow the peer
onto channels we are deaf on, PIN claims all 16 slots. The intersection is the
only honest sequence for a radio that cannot hop, and empty slots are ordinary
in every captured Apple sequence, so the structure §25 found to matter survives.
Bytes are copied from the peer's sequence, never constructed.

### What INTERSECT revealed: the phone widens for transfers

The single most useful log line of the evening. The phone's sequence is not
static and the idle figure is not the transfer figure:

    20:33:07  intersect:  2/16 slots overlap        <- phone idle
    20:33:08  peer -> 149,149,149,...,149 (x15)     <- phone WIDENS to send
    20:33:08  intersect: 15/16 slots overlap        <- tracked instantly
    20:33:13  peer narrows                          -> intersect:  5/16
    20:33:19  peer narrows to idle row              -> intersect:  2/16

`rx_data` went 205 → 689 in those ten seconds: ~484 AWDL data frames, ~660 KB,
roughly **73 kB/s** against `airdrop.sh`'s proven 45–67 kB/s.

Also note slot 0 is the device's **infra** channel — it read 36 while the phone
was on the 5 GHz AP and 2 after it roamed to the 2.4 GHz one. That is why
discovery works when the GO sits on the phone's slot-0 channel, and why a
hardcoded GO channel is wrong in principle: it is right for one phone state,
not for the phone.

### 6. iOS keep-alive wedged the HTTP server completely (`87a7483`)

The phone sat on "Waiting…" indefinitely:

    Recv-Q 1496 on [fe80::...]%awdl0:8771, and no opendrop log line for 12 min

opendrop's server was the stock single-threaded `HTTPServer`. iOS sends
`Connection: keep-alive` and holds the connection open idle, so the server
stayed parked in `handle_one_request()` on that idle socket and never got back
to `accept()` — the connection actually carrying the file was never read.
`patches/opendrop-threaded-server.patch` makes it `ThreadingHTTPServer` with
`daemon_threads`.

This is the same bottleneck that made one slow consent prompt fill the listen
backlog with iOS validation connects (§46), which `airdropd` worked around by
cutting the prompt timeout to 15 s. **That workaround is now solving a problem
that no longer exists and should be relaxed** — a 15 s window to notice and
answer a consent prompt is too short, and it auto-declines.

### Wrong-channel watch (`e5d215d`)

Zero overlap was the silent-failure state: owl alive, awdl0 up, opendrop
listening, mDNS provably leaving the radio, and not one slot able to carry a
frame to the phone. Every health signal green, nothing working.

owl now logs it at INFO naming the channel the peer wants
(`NO OVERLAP with 42:c7:… on ch 36 - peer wants ch 149`), and `airdropd`'s
health watcher acts after `AIRDROP_WRONGCHAN_AFTER` (20 s) of it: either
rebuilds the GO there (`AIRDROP_GO_FOLLOW=1`, default) or turns the bar red
saying which channel we should be on. Rebuild because retune is impossible
(above). State is compared by the timestamps of owl's own lines, not by a byte
window over the log, because `-vv` trace makes any fixed window cover anywhere
from a second to a minute.

Detection logic verified against synthetic owl logs for four cases: overlapping
(never fires), wrong channel (fires at 20 s naming 149), peer wants the channel
we are already on, peer advertising nothing usable. **Not yet exercised against
a real mid-session channel move.**

### WHAT IS STILL BROKEN

1. **The tail of a transfer is lost.** 660,490 of 666,346 bytes arrived — 99.1%,
   dying in the last 5,856. The phone collapsed its window 15/16 → 5/16 → 2/16
   *during* the transfer. Why it narrows is **unknown**. One hypothesis, not a
   diagnosis: INTERSECT mirrors the peer downward, so a brief dip by the phone
   narrows our advertisement, which may make it dip further — a feedback
   collapse. If so the fix is to stop mirroring downward mid-transfer. We are
   physically on the GO channel in all 16 slots regardless, so advertising more
   of them is true rather than a lie, and `awdl_chanseq_widen()` already exists
   to do it. Needs two or three more transfers watched before changing anything.

2. **opendrop crashes on a truncated stream** instead of salvaging it:
   `ValueError: invalid literal for int() with base 16: b''` out of
   `_next_chunk()` on EOF. The 660 KB survived only because the ios26 patch
   buffers the body to disk first. It should catch EOF, report bytes received
   against `TotalBytes`, and keep what arrived.

3. **The 15 s consent timeout auto-declines** and no longer needs to be tight
   (see 6 above).

4. **2.4 GHz is unusable.** `stack_up` refuses when the STA is on 2.4 GHz,
   because a GO alongside it provably drops the association. So the toggle
   simply cannot work on a 2.4 GHz AP, and says so. Unresolved as a UX question.

5. **The wrong-channel watch is untested live** — committed, but the running
   daemon predates it.

### Environment notes for whoever picks this up

- Phone: iPhone, iOS 26, AirDrop must be **Everyone** (opendrop has no Apple ID
  validation record); iOS reverts to Contacts Only after ~10 min.
- `~/owl/.venv-opendrop` is **not version controlled**. Every opendrop fix lives
  in `patches/` and must be reapplied after a venv rebuild.
- `pkill -f opendrop` from an inline shell command matches the calling shell and
  kills the caller (exit 144). Put such kills in a script file.
- `/run/airdrop-owl.log` is **not** truncated between owl restarts, so grepping
  it for `add peer` matches stale runs. Gate on the live `STATS ... rx_action`
  counter instead.
- owl logs `STATS` every 10 s: `tx_unicast` frozen while `tx_multicast` climbs
  means the unicast gate is shut; `rx_action` at 0 means the phone is not
  talking to us at all and no measurement on this box is meaningful.

## §48 — the channel policy was backwards, and every "Accept" was a 403 (2026-08-03 late)

Two unrelated faults, both of which presented as "AirDrop is unreliable".

### The consent prompt lost a race with itself, every time

`swaynag --button-dismiss-no-terminal` **dismisses first and runs the button's
command from a detached child**. `airdrop-confirm` waited on swaynag and then
tested for the Accept marker — a file that did not exist yet. It lost by two
milliseconds, reproducibly:

    /run/user/1000/airdrop-accept.LQtoEz  mtime 21:42:48.416265
    opendrop logged "user declined"       at    21:42:48.418

So every accept became a 403 on `/Ask`, and the phone sat on "Waiting" forever.
Because the marker was written *after* the check it was never cleaned up
either, so four orphaned markers in `XDG_RUNTIME_DIR` were the only evidence
the button had ever been pressed. The single `declined or timed out` message
is what made this look like a slow user rather than a bug — it conflated three
different outcomes, one of which was "the code is wrong".

Both buttons now write their own marker and the answer is whichever appears,
polled, with the timeout as the outer bound and a second of grace after
swaynag exits. Three outcomes, three messages.

**The general lesson:** if a helper's exit is not the thing that produces the
answer, do not wait on the helper's exit. Wait for the answer.

### Diagnosing it: three checks that all lied

The reported symptom was "opendrop is running but not listening", from:

    ss -tlnp | grep -i python    -> empty
    ss -tnp  | grep 8771         -> empty

Both are wrong for different reasons, and the socket was up the whole time:

- `-p` prints the **comm name**, which for the venv console script is
  `opendrop`, not `python`.
- `ss -tnp` without `-l` or `-a` lists **established connections only**, so a
  listener with no live connection can never appear.

`ss -tlnpH | grep "pid=$PID,"` is the form that answers the question.

Two `airdropd` processes in `pgrep -a` are also not two daemons: a forked
subshell keeps the parent's argv, so the health watch looks identical to its
parent. The `flock` on `$RUNDIR/lock` already prevents duplicates, and that
lock file *is* the pidfile — it holds the daemon's pid.

### The station decides the channel, not the peer

The wrong-channel watch let the peer's dominant channel win outright and wrote
it into `GO_CHAN`, which permanently replaced `auto` with one number — so
after the first correction the station was never consulted again. Inverted:
station first, peer only when the station is unreadable or unbuildable, and
`GO_CHAN` is policy that is never rewritten (the built channel is tracked
separately). See daemon/README.md for the measurement.

A failed rebuild used to `break` out of `serve_forever` and end the daemon,
with the switch reading "drop off" and nothing running. It now validates the
target *before* any teardown, refuses for free with a distinct `unreachable`
state, and retries bring-up with backoff instead of exiting.

### Still open

1. **A real transfer has still not completed.** Every accept was a 403 all
   evening, so the upload path past `/Ask` remains unproven from `airdropd`.
   This is the next thing to test.
2. **No roam detection.** The GO tracks the station at bring-up only. A
   station roaming between 5 GHz channels is undetected; roaming to 2.4 GHz is
   now caught by a guard that tears the GO down and waits, which protects the
   association but does not follow.
3. **A station on a 5 GHz channel outside `6/36/44/149`** (40, 48, 157, 161 …)
   cannot host a GO at all, so the switch stays red and retries. Widening the
   set means re-testing which pairings hold the association, DFS included.
4. §47's "wrong-channel watch is untested live" is now partly answered: it
   fires and logs correctly, but under station-first precedence it declines to
   rebuild in the common case, which is intended and mostly untested.

## §49 — iOS never sends a bare file; what lands on disk is a staging directory (2026-08-14)

Three receives that had all "worked" left `~/Downloads` looking like this:

    NSIRD_AirDrop_Hjuudm/  ._IMG_8370.PNG  IMG_8370.PNG
    NSIRD_AirDrop_W8k6Qi/  ._IMG_8371.PNG  IMG_8371.PNG
    NSIRD_AirDrop_wvB8nv/  ._IMG_8372.PNG  IMG_8372.PNG

Nothing was wrong with the transfers - all three photos were byte-intact 828x1792
PNGs. This is simply what an iPhone puts in the cpio. **A single photo is still
packed inside a directory**, alongside an AppleDouble sidecar carrying the
resource fork and Finder flags.

`NSIRD` is NSItemProvider ReceiveDirectory, macOS's staging name for an incoming
item. Two things follow that are worth writing down, because both are the
opposite of what you would guess:

1. **The suffix is regenerated per transfer**, so it is not a session or device
   identifier and cannot be used to group a multi-file drop. It carries no
   information at all on the receiving side.
2. **The sidecar is not optional and not an error.** It is there for a Finder
   that is going to read it. On Linux it is a 1.6 KB file that image viewers
   list next to every photo as something broken.

opendrop extracts the archive faithfully, so it reproduces both. That is correct
behaviour for a tool that should not guess, but it is not what anyone wants on
this end, so `tools/airdrop-tidy` undoes the packaging after the fact rather
than patching the extraction.

**The one non-obvious constraint is when it is safe to run.** `server.py`
buffers the *entire* archive to disk and only then extracts it, so during a
transfer the wrapper directory exists and is being filled. Flattening it at the
wrong moment moves out a partial file and the transfer looks corrupt. There is
no completion hook to hang off, so the tidy skips any directory that changed
within the last couple of seconds, and the two callers that run *after* opendrop
has exited pass `AIRDROP_TIDY_SETTLE=0` because at that point nothing can be
writing and the guard would only skip the last transfer - the one they exist to
sweep.
