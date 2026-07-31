#!/usr/bin/env python3
"""Where in the AWDL sequence does each peer actually transmit, and what does it claim?

Two questions, from artefacts a run already produces:

  1. From a channel-locked monitor capture (runs/<run>/scan-<chan>.pcap): which of
     the 16 slots did each device actually transmit in? Every AWDL action frame
     carries the sender's own availability-window counter, so each frame can be
     placed in the sender's own slot index without any clock of ours being
     involved: slot = (aw_seq_number / presence_mode) % 16.

  2. From owl.log: which channel sequences did each peer advertise over the run,
     and how many of the 16 slots did each one put on our operating channel?

Comparing the two settles what a 0 entry in a channel sequence means. Measured
2026-07-31: devices transmit in exactly the slots their sequence names and in no
others, so 0 means the device is absent for that window -- it is NOT "repeat the
current channel", which is what the fill_channel = 0xffff field would suggest.

That matters because the number of slots a peer puts on our channel is an upper
bound on our throughput, and an iPhone changes it dynamically -- from 2 of 16
when idle to as many as 11 during a transfer. Reading that escalation off the log
is the difference between chasing a receiver-side ceiling that does not exist
(FINDINGS 18) and fixing the one that does.

Usage:
    tools/slotmap.py runs/<run>/scan-149.pcap
    tools/slotmap.py --log runs/<run>/owl.log --chan 149
"""

import argparse
import collections
import re
import subprocess
import sys

CHANSEQ_LENGTH = 16


def slots_from_pcap(pcap):
    """Observed transmit slots per source address, in each sender's own phase."""
    try:
        out = subprocess.run(
            ["tshark", "-r", pcap, "-T", "fields",
             "-e", "wlan.sa",
             "-e", "awdl.syncparams.awseqcounter",
             "-e", "awdl.syncparams.presencemode"],
            capture_output=True, text=True, check=True).stdout
    except FileNotFoundError:
        sys.exit("tshark not found - install wireshark-cli")
    except subprocess.CalledProcessError as e:
        sys.exit(f"tshark failed on {pcap}: {e.stderr.strip()}")

    seen = collections.defaultdict(collections.Counter)
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) < 3 or not parts[0] or not parts[1] or not parts[2]:
            continue
        addr = parts[0].split(",")[0]
        aw = int(parts[1].split(",")[0])
        pm = int(parts[2].split(",")[0]) or 4
        seen[addr][(aw // pm) % CHANSEQ_LENGTH] += 1
    return seen


def report_pcap(pcap):
    seen = slots_from_pcap(pcap)
    if not seen:
        print(f"{pcap}: no AWDL action frames with sync params")
        return

    print(f"\n{pcap}")
    print("  Observed transmit slots, in each sender's own availability-window phase.")
    print("  A device present in only a few slots is following its advertised sequence;")
    print("  one present in all 16 is awake continuously (an iPhone does this while its")
    print("  share sheet is open and it is acting as a sender).\n")
    print(f"  {'address':<20} {'frames':>6}  {'slots':>5}  occupancy")
    for addr, counter in sorted(seen.items(), key=lambda kv: -sum(kv[1].values())):
        total = sum(counter.values())
        bar = "".join("#" if i in counter else "." for i in range(CHANSEQ_LENGTH))
        used = sorted(counter)
        print(f"  {addr:<20} {total:>6}  {len(used):>5}  {bar}  {used}")


SEQ_RE = re.compile(
    r"peer ([0-9a-f:]{17}).*changed channel sequence to ((?:\d+,){15}\d+)")


def report_log(logpath, chan):
    """Which sequences each peer advertised, and how much of our channel each offered."""
    per_peer = collections.defaultdict(collections.Counter)
    order = collections.defaultdict(list)
    with open(logpath) as fh:
        for line in fh:
            m = SEQ_RE.search(line)
            if not m:
                continue
            addr, seq = m.group(1), m.group(2)
            per_peer[addr][seq] += 1
            if seq not in order[addr]:
                order[addr].append(seq)

    if not per_peer:
        print(f"{logpath}: no channel sequences logged (run owl with -v)")
        return

    print(f"\n{logpath}  (offering of channel {chan})")
    print("  Each distinct sequence a peer advertised, with how many of the 16 slots it")
    print("  places on our channel. That count is a hard ceiling on our duty cycle: we")
    print("  can never exchange data in a window the peer is not present for.\n")

    for addr, counter in sorted(per_peer.items(), key=lambda kv: -sum(kv[1].values())):
        offers = []
        print(f"  {addr}")
        for seq in order[addr]:
            chans = [int(x) for x in seq.split(",")]
            n = chans.count(chan)
            offers.append(n)
            bar = "".join("#" if c == chan else ("o" if c else ".") for c in chans)
            pct = 100.0 * n / CHANSEQ_LENGTH
            print(f"    {bar}  {n:2d}/16 ({pct:4.1f}%)  x{counter[seq]:<3d}  {seq}")
        if offers:
            print(f"    -> offered between {min(offers)} and {max(offers)} of 16 slots"
                  f" ({100.0 * min(offers) / 16:.1f}% - {100.0 * max(offers) / 16:.1f}%)")
    print("\n  Legend: # = our channel, o = some other channel, . = absent")
    print("  With -S pin we sit on our channel in all 16 slots, so we are present for")
    print("  every # above. With -S verbatim we copy one peer's row and get only the")
    print("  slots where that row and the data peer's row happen to coincide.")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("pcap", nargs="?", help="channel-locked monitor capture")
    ap.add_argument("--log", help="owl.log to read advertised sequences from")
    ap.add_argument("--chan", type=int, default=149, help="our operating channel")
    args = ap.parse_args()

    if not args.pcap and not args.log:
        ap.error("give a pcap, --log, or both")
    if args.pcap:
        report_pcap(args.pcap)
    if args.log:
        report_log(args.log, args.chan)


if __name__ == "__main__":
    main()
