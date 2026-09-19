#!/usr/bin/env python3
"""Decode what the phone actually puts on awdl0's mDNS group.

The send path fails with "no AirDrop service discovered" while the run
reports dozens of mDNS packets coming FROM the peer. Those two statements
can both be true in two very different ways, and they need different fixes:

  - the phone is only QUERYING (it wants to find receivers, it is not one),
  - or it IS announcing and our browse is failing to register it.

This joins ff02::fb on awdl0 and prints the question/answer sections, so
the difference is visible instead of inferred. Unprivileged: joining a
multicast group and binding 5353 with SO_REUSEPORT needs no root.
"""
import socket
import struct
import sys
import time

GROUP = "ff02::fb"
PORT = 5353


def name_at(buf, off):
    """DNS name, following compression pointers."""
    parts, seen = [], 0
    while True:
        if off >= len(buf) or seen > 64:
            break
        ln = buf[off]
        if ln == 0:
            break
        if ln & 0xC0 == 0xC0:                      # pointeur de compression
            off = ((ln & 0x3F) << 8) | buf[off + 1]
            seen += 1
            continue
        parts.append(buf[off + 1:off + 1 + ln].decode("utf-8", "replace"))
        off += 1 + ln
    return ".".join(parts)


def skip_name(buf, off):
    while off < len(buf):
        ln = buf[off]
        if ln == 0:
            return off + 1
        if ln & 0xC0 == 0xC0:
            return off + 2
        off += 1 + ln
    return off


def main():
    iface = sys.argv[1] if len(sys.argv) > 1 else "awdl0"
    seconds = int(sys.argv[2]) if len(sys.argv) > 2 else 45
    idx = socket.if_nametoindex(iface)

    s = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    except OSError:
        pass
    s.bind(("", PORT))
    s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_JOIN_GROUP,
                 socket.inet_pton(socket.AF_INET6, GROUP) + struct.pack("@I", idx))
    s.settimeout(2)

    print(f"ecoute mDNS sur {iface} pendant {seconds}s", flush=True)
    end = time.time() + seconds
    seen = {"q": 0, "a": 0, "pkt": 0}
    while time.time() < end:
        try:
            data, addr = s.recvfrom(9000)
        except socket.timeout:
            continue
        src = addr[0]
        mine = src.startswith("fe80::7a46") or src.startswith("fe80::7846")
        if len(data) < 12:
            continue
        qd, an, ns, ar = struct.unpack(">HHHH", data[4:12])
        off = 12
        qs = []
        for _ in range(qd):
            nm = name_at(data, off)
            off = skip_name(data, off) + 4
            qs.append(nm)
        ans = []
        for _ in range(an + ns + ar):
            nm = name_at(data, off)
            off = skip_name(data, off)
            if off + 10 > len(data):
                break
            rtype, _cls, _ttl, rdlen = struct.unpack(">HHIH", data[off:off + 10])
            off += 10 + rdlen
            ans.append("%s/%d" % (nm, rtype))
        seen["pkt"] += 1
        seen["q"] += len(qs)
        seen["a"] += len(ans)
        tag = "NOUS " if mine else "PHONE"
        if any("airdrop" in x.lower() for x in qs + ans):
            print(f"[{tag}] {src}", flush=True)
            for q in qs:
                print(f"    QUESTION {q}", flush=True)
            for a in ans:
                print(f"    REPONSE  {a}", flush=True)
    print(f"-- {seen['pkt']} paquets, {seen['q']} questions, {seen['a']} reponses",
          flush=True)


if __name__ == "__main__":
    main()
