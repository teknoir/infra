#!/usr/bin/env python3
"""sntp-query.py: one SNTP query (RFC 4330), for the VM e2e E12 (node time).

  python3 -I sntp-query.py HOST [--port 123] [--timeout 5] [--tries 3]

Sends an NTPv4 client request to HOST and prints one line:
  stratum=<n> offset=<seconds, server minus local> delay=<seconds> refid=<id> leap=<n>
Exit 0 on a valid server reply (mode 4, stratum 1-15, transmit time set),
1 on no answer or an invalid / kiss-of-death reply, 2 on usage errors.
Run it in the LAN netns (lan-netns.sh exec) against NODE_IP: chrony on the
node serves the LAN from its local stratum-10 reference (or TIME_SOURCE).
"""
import argparse
import socket
import struct
import sys
import time

NTP_EPOCH = 2208988800  # seconds from 1900-01-01 to 1970-01-01


def to_ntp(t):
    sec = int(t) + NTP_EPOCH
    frac = int((t - int(t)) * (1 << 32)) & 0xFFFFFFFF
    return sec, frac


def from_ntp(sec, frac):
    return sec - NTP_EPOCH + frac / float(1 << 32)


def refid_text(stratum, raw):
    if stratum <= 1:
        return raw.rstrip(b"\0").decode("ascii", "replace") or "-"
    return ".".join(str(b) for b in raw)


def query(host, port, timeout):
    """One exchange; returns (stratum, offset, delay, refid, leap) or raises."""
    addr = socket.getaddrinfo(host, port, socket.AF_INET, socket.SOCK_DGRAM)[0][4]
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        s.settimeout(timeout)
        t1 = time.time()
        sec, frac = to_ntp(t1)
        # LI 0, VN 4, mode 3 (client); the transmit timestamp comes back as
        # the reply's originate timestamp
        pkt = struct.pack("!B B b b 11I", 0x23, 0, 0, 0, *([0] * 9), sec, frac)
        s.sendto(pkt, addr)
        data, _ = s.recvfrom(512)
        t4 = time.time()
    if len(data) < 48:
        raise ValueError("short reply (%d bytes)" % len(data))
    f = struct.unpack("!B B b b I I 4s 8I", data[:48])
    li_vn_mode, stratum = f[0], f[1]
    leap, mode = li_vn_mode >> 6, li_vn_mode & 7
    refid = f[6]
    orig = (f[9], f[10])
    t2 = from_ntp(f[11], f[12])
    t3 = from_ntp(f[13], f[14])
    if mode != 4:
        raise ValueError("not a server reply (mode %d)" % mode)
    if stratum == 0:
        raise ValueError("kiss-of-death %s" % refid.decode("ascii", "replace"))
    if stratum > 15:
        raise ValueError("server unsynchronized (stratum %d)" % stratum)
    if orig != (sec, frac):
        raise ValueError("originate timestamp does not match the request")
    if f[13] == 0:
        raise ValueError("no transmit timestamp")
    offset = ((t2 - t1) + (t3 - t4)) / 2.0
    delay = (t4 - t1) - (t3 - t2)
    return stratum, offset, delay, refid_text(stratum, refid), leap


def main():
    ap = argparse.ArgumentParser(description="one SNTP query")
    ap.add_argument("host")
    ap.add_argument("--port", type=int, default=123)
    ap.add_argument("--timeout", type=float, default=5.0)
    ap.add_argument("--tries", type=int, default=3)
    a = ap.parse_args()
    err = None
    for _ in range(max(1, a.tries)):
        try:
            stratum, offset, delay, refid, leap = query(a.host, a.port, a.timeout)
        except (OSError, ValueError) as e:
            err = e
            continue
        print("stratum=%d offset=%.3f delay=%.3f refid=%s leap=%d" % (stratum, offset, delay, refid, leap))
        return 0
    print("sntp-query: no valid answer from %s:%d: %s" % (a.host, a.port, err), file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
