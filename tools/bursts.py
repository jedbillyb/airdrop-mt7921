#!/usr/bin/env python3
"""Score an AirDrop receive by its burst structure.

Every throughput conclusion in FINDINGS sections 16 to 18 came from splitting the
inbound TCP stream on gaps and looking at the resulting bursts. That analysis was
redone by hand each time, which is how the same channel-confound error got made
three times. This is it as a committed tool, so a run can be scored the moment it
finishes and compared against a stored baseline rather than against memory.

Why bursts and not throughput: AWDL gives a connection a slice of airtime every
availability window and nothing in between. Per-second averages smear that into a
single meaningless number. The burst view separates the two factors that actually
multiply out to the result:

    throughput  =  bytes per availability window  x  windows per second

FINDINGS 18 established that the first factor is fixed at ~22-25 kB and is not
movable from the receiver side (TCP window, socket buffers and application read
speed were all ruled out). So the only lever is the second one, and that is a
question about channel sequence overlap. A run that moves bytes-per-burst but not
bursts-per-second has not improved anything.

Usage:
    tools/bursts.py runs/<run>/receive.pcap
    tools/bursts.py runs/<run>/receive.pcap --baseline runs/<other>/receive.pcap
"""

import argparse
import subprocess
import statistics
import sys

# One AWDL availability window is 64 TU = 65.536 ms, and a 16-slot sequence takes
# 16 of them = 1.049 s. Both show up directly in the gap distribution, so they are
# named here rather than left as magic numbers in the output.
EAW_MS = 65.536
SEQUENCE_MS = EAW_MS * 16

# Gap above which two packets are considered to be in different bursts. Bursts run
# one availability window long, so anything beyond about two windows is a real
# absence rather than jitter inside one.
DEFAULT_GAP_MS = 150.0


def load(pcap, port=None):
    """Return [(timestamp_seconds, payload_bytes)] for inbound TCP data."""
    filt = "tcp and tcp.len > 0"
    if port:
        filt += f" and tcp.srcport == {port}"
    try:
        out = subprocess.run(
            ["tshark", "-r", pcap, "-Y", filt, "-T", "fields",
             "-e", "frame.time_epoch", "-e", "tcp.len", "-e", "tcp.srcport"],
            capture_output=True, text=True, check=True).stdout
    except FileNotFoundError:
        sys.exit("tshark not found - install wireshark-cli")
    except subprocess.CalledProcessError as e:
        sys.exit(f"tshark failed on {pcap}: {e.stderr.strip()}")

    rows = []
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) < 3 or not parts[0] or not parts[1]:
            continue
        # A frame can carry several TCP segments; tshark comma-separates them.
        total = sum(int(x) for x in parts[1].split(",") if x)
        rows.append((float(parts[0]), total, parts[2].split(",")[0]))

    if not rows:
        return []

    # Keep only the busiest source port, so a stray connection cannot dilute the
    # numbers. In a receive run this is the phone's data connection.
    if port is None:
        counts = {}
        for _, n, p in rows:
            counts[p] = counts.get(p, 0) + n
        best = max(counts, key=counts.get)
        rows = [r for r in rows if r[2] == best]

    return [(t, n) for t, n, _ in rows]


def split(packets, gap_ms):
    """Group packets into bursts separated by more than gap_ms of silence."""
    bursts, cur = [], []
    for t, n in packets:
        if cur and (t - cur[-1][0]) * 1000.0 > gap_ms:
            bursts.append(cur)
            cur = []
        cur.append((t, n))
    if cur:
        bursts.append(cur)
    return bursts


def analyse(packets, gap_ms):
    bursts = split(packets, gap_ms)
    span = packets[-1][0] - packets[0][0]
    total = sum(n for _, n in packets)

    sizes = [sum(n for _, n in b) for b in bursts]
    durations = [(b[-1][0] - b[0][0]) * 1000.0 for b in bursts]
    gaps = [(bursts[i + 1][0][0] - bursts[i][-1][0]) * 1000.0
            for i in range(len(bursts) - 1)]

    # In-burst rate only means something for bursts that lasted long enough to
    # measure; a single-packet burst has zero duration and infinite rate.
    rates = [(s * 8 / 1e6) / (d / 1000.0)
             for s, d in zip(sizes, durations) if d > 1.0]

    return {
        "span": span,
        "total": total,
        "throughput": total / span if span > 0 else 0.0,
        "bursts": len(bursts),
        "bursts_per_s": len(bursts) / span if span > 0 else 0.0,
        "bytes_per_burst": statistics.mean(sizes) if sizes else 0.0,
        "burst_ms": statistics.mean(durations) if durations else 0.0,
        "in_burst_mbit": statistics.mean(rates) if rates else 0.0,
        "gap_ms": statistics.mean(gaps) if gaps else 0.0,
        "gap_median": statistics.median(gaps) if gaps else 0.0,
        "gap_max": max(gaps) if gaps else 0.0,
        "gaps": gaps,
    }


def report(name, r):
    print(f"\n{name}")
    print(f"  transferred        {r['total'] / 1e6:.2f} MB in {r['span']:.0f} s")
    print(f"  throughput         {r['throughput'] / 1e3:.1f} kB/s")
    print(f"  bursts             {r['bursts']}  ({r['bursts_per_s']:.2f}/s)")
    print(f"  bytes per burst    {r['bytes_per_burst'] / 1e3:.1f} kB")
    print(f"  burst duration     {r['burst_ms']:.0f} ms"
          f"   ({r['burst_ms'] / EAW_MS:.2f} availability windows)")
    print(f"  in-burst rate      {r['in_burst_mbit']:.2f} Mbit/s")
    print(f"  gap mean/median    {r['gap_ms']:.0f} / {r['gap_median']:.0f} ms"
          f"   ({r['gap_ms'] / EAW_MS:.1f} windows)")
    print(f"  gap max            {r['gap_max']:.0f} ms"
          f"   ({r['gap_max'] / SEQUENCE_MS:.2f} sequence periods)")

    duty = (r["bursts_per_s"] * r["burst_ms"] / 1000.0) * 100.0
    print(f"  duty cycle         {duty:.1f}%"
          f"   (of 16 slots: {duty / 100 * 16:.1f})")

    # The gap histogram is the diagnostic that falsified two separate theories in
    # FINDINGS 16 and 17, so print it rather than only summary statistics.
    if r["gaps"]:
        print("  gap histogram (in availability windows):")
        buckets = {}
        for g in r["gaps"]:
            buckets[round(g / EAW_MS)] = buckets.get(round(g / EAW_MS), 0) + 1
        for slots in sorted(buckets):
            bar = "#" * min(50, buckets[slots])
            print(f"    {slots:3d} ({slots * EAW_MS:6.0f} ms)  {buckets[slots]:4d}  {bar}")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("pcap")
    ap.add_argument("--baseline", help="second capture to compare against")
    ap.add_argument("--gap-ms", type=float, default=DEFAULT_GAP_MS,
                    help=f"burst split threshold (default {DEFAULT_GAP_MS})")
    ap.add_argument("--port", type=int, help="restrict to this TCP source port")
    args = ap.parse_args()

    packets = load(args.pcap, args.port)
    if not packets:
        sys.exit(f"no inbound TCP payload in {args.pcap} - nothing was transferred")
    cur = analyse(packets, args.gap_ms)
    report(args.pcap, cur)

    if args.baseline:
        base_packets = load(args.baseline, args.port)
        if not base_packets:
            sys.exit(f"no inbound TCP payload in {args.baseline}")
        base = analyse(base_packets, args.gap_ms)
        report(args.baseline, base)

        print("\ncomparison (current vs baseline)")
        for key, label, scale, unit in [
            ("throughput", "throughput", 1e3, "kB/s"),
            ("bursts_per_s", "bursts per second", 1, "/s"),
            ("bytes_per_burst", "bytes per burst", 1e3, "kB"),
            ("gap_ms", "mean gap", 1, "ms"),
        ]:
            a, b = cur[key], base[key]
            ratio = (a / b) if b else float("inf")
            print(f"  {label:<20} {a / scale:8.2f} vs {b / scale:8.2f} {unit:<6} "
                  f"({ratio:.2f}x)")
        print("\n  Reminder (FINDINGS 18): bytes per burst is fixed at ~22-25 kB and")
        print("  cannot be moved from the receiver side. Only bursts per second is a")
        print("  real win. A change that moves the first but not the second is noise.")


if __name__ == "__main__":
    main()
