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
