#!/usr/bin/env python3
"""Decode G.711 payloads from a pcap and measure real signal energy per stream.

Packet counters cannot tell audio from silence. A relayed stream of G.711
silence produces identical packet counts, identical RTCP receiver reports and
identical "tx>0" readings to a stream carrying speech -- and the far end hears
dead air either way. The only way to separate them is to decode the payload.

  ./rtp-energy.py capture.pcap                    all streams
  ./rtp-energy.py capture.pcap --local 1.2.3.4    split outbound vs inbound

Discriminators:
  mean_rms    silence ~0-20; comfort noise ~50-150 and FLAT; speech 500-4000
  rms_sd      speech has pauses and peaks, comfort noise does not
  uniq        distinct codepoints in the payload. A silence stream repeats one
              byte (0xFF/0x7F); speech uses most of the 256.
"""
import argparse, collections, math, struct, sys

# ---- G.711 mu-law -> linear PCM -------------------------------------------
_ULAW = []
for _u in range(256):
    _v = ~_u & 0xFF
    _sign = _v & 0x80
    _exp = (_v >> 4) & 0x07
    _man = _v & 0x0F
    _s = (((_man << 3) + 0x84) << _exp) - 0x84
    _ULAW.append(-_s if _sign else _s)

# ---- G.711 A-law -> linear PCM --------------------------------------------
_ALAW = []
for _a in range(256):
    _v = _a ^ 0x55
    _sign = _v & 0x80
    _exp = (_v >> 4) & 0x07
    _man = _v & 0x0F
    if _exp:
        _s = ((_man << 4) + 0x108) << (_exp - 1)
    else:
        _s = (_man << 4) + 8
    _ALAW.append(-_s if _sign else _s)


def rms(payload, table):
    if not payload:
        return 0.0
    t = 0
    for b in payload:
        v = table[b]
        t += v * v
    return math.sqrt(t / len(payload))


def read_pcap(path):
    """Yield (ts, src, sport, dst, dport, payload) for every UDP packet."""
    f = open(path, "rb")
    gh = f.read(24)
    if len(gh) < 24:
        return
    magic = struct.unpack("<I", gh[:4])[0]
    if magic == 0xA1B2C3D4:
        e = "<"
    elif magic == 0xD4C3B2A1:
        e = ">"
    else:
        sys.stderr.write("not a pcap: magic %08x\n" % magic)
        return
    link = struct.unpack(e + "I", gh[20:24])[0]
    while True:
        ph = f.read(16)
        if len(ph) < 16:
            break
        ts, tus, incl, orig = struct.unpack(e + "IIII", ph)
        data = f.read(incl)
        if len(data) < incl:
            break
        if link == 113:
            if len(data) < 16: continue
            proto = struct.unpack("!H", data[14:16])[0]; off = 16
        elif link == 276:
            if len(data) < 20: continue
            proto = struct.unpack("!H", data[0:2])[0]; off = 20
        elif link == 1:
            if len(data) < 14: continue
            proto = struct.unpack("!H", data[12:14])[0]; off = 14
        else:
            continue
        if proto != 0x0800 or len(data) < off + 20:
            continue
        ihl = (data[off] & 0x0F) * 4
        if data[off + 9] != 17:
            continue
        src = ".".join(str(x) for x in data[off + 12:off + 16])
        dst = ".".join(str(x) for x in data[off + 16:off + 20])
        u = off + ihl
        if len(data) < u + 8:
            continue
        sp, dp = struct.unpack("!HH", data[u:u + 4])
        yield ts + tus / 1e6, src, sp, dst, dp, data[u + 8:]
    f.close()


def classify(mean, sd, uniq):
    if mean < 30:
        return "SILENCE"
    if uniq <= 8:
        return "CONSTANT-FILL"
    if mean < 200 and sd < 60:
        return "comfort-noise"
    return "REAL AUDIO"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("pcap")
    ap.add_argument("--local", default="", help="this box's IP, to split directions")
    ap.add_argument("--min-packets", type=int, default=10)
    ap.add_argument("--top", type=int, default=20)
    a = ap.parse_args()

    streams = collections.defaultdict(
        lambda: {"n": 0, "rms": [], "bytes": set(), "t0": None, "t1": None,
                 "pt": set(), "ssrc": set(), "seq": []})
    npkt = 0
    for ts, src, sp, dst, dp, p in read_pcap(a.pcap):
        npkt += 1
        if len(p) < 13:
            continue
        if (p[0] >> 6) != 2:
            continue
        pt = p[1] & 0x7F
        if pt not in (0, 8):          # PCMU / PCMA only
            continue
        seq = struct.unpack("!H", p[2:4])[0]
        ssrc = struct.unpack("!I", p[8:12])[0]
        audio = p[12:]
        if not audio:
            continue
        s = streams[(src, sp, dst, dp)]
        s["n"] += 1
        s["pt"].add(pt)
        s["ssrc"].add(ssrc)
        if s["t0"] is None:
            s["t0"] = ts
        s["t1"] = ts
        if len(s["rms"]) < 500:
            s["rms"].append(rms(audio, _ULAW if pt == 0 else _ALAW))
            s["bytes"].update(audio[:80])
        if len(s["seq"]) < 500:
            s["seq"].append(seq)

    print("packets in pcap: %d    RTP audio streams: %d" % (npkt, len(streams)))
    print()

    def sd(v):
        if len(v) < 2:
            return 0.0
        m = sum(v) / len(v)
        return math.sqrt(sum((x - m) ** 2 for x in v) / len(v))

    rows = []
    for (src, sp, dst, dp), s in streams.items():
        if s["n"] < a.min_packets:
            continue
        m = sum(s["rms"]) / len(s["rms"])
        dur = (s["t1"] - s["t0"]) if s["t0"] else 0
        rate = s["n"] / dur if dur > 0.2 else 0
        codec = "ulaw" if 0 in s["pt"] else "alaw"
        rows.append(dict(src=src, sp=sp, dst=dst, dp=dp, n=s["n"], mean=m,
                         sd=sd(s["rms"]), uniq=len(s["bytes"]), dur=dur,
                         rate=rate, codec=codec, nssrc=len(s["ssrc"]),
                         verdict=classify(m, sd(s["rms"]), len(s["bytes"]))))
    rows.sort(key=lambda r: -r["n"])

    groups = [("ALL STREAMS", rows)]
    if a.local:
        groups = [("OUTBOUND  (from %s -- what WE send)" % a.local,
                   [r for r in rows if r["src"] == a.local]),
                  ("INBOUND   (to %s -- what we RECEIVE)" % a.local,
                   [r for r in rows if r["dst"] == a.local])]

    for label, grp in groups:
        print("=" * 100)
        print("%s   streams=%d" % (label, len(grp)))
        print("=" * 100)
        if not grp:
            print("  (none)\n")
            continue
        print("  %-16s %-6s %-16s %-6s %6s %6s %8s %7s %5s %5s %5s %s"
              % ("src", "sport", "dst", "dport", "pkts", "dur_s", "mean_rms",
                 "rms_sd", "uniq", "pps", "ssrc", "verdict"))
        for r in grp[:a.top]:
            print("  %-16s %-6d %-16s %-6d %6d %6.1f %8.0f %7.0f %5d %5.0f %5d %s"
                  % (r["src"], r["sp"], r["dst"], r["dp"], r["n"], r["dur"],
                     r["mean"], r["sd"], r["uniq"], r["rate"], r["nssrc"],
                     r["verdict"]))
        if len(grp) > a.top:
            print("  ... %d more" % (len(grp) - a.top))
        v = collections.Counter(r["verdict"] for r in grp)
        mm = sum(r["mean"] for r in grp) / len(grp)
        print("  ---- verdicts: %s" % dict(v))
        print("  ---- aggregate mean_rms=%.0f   codecs=%s   streams with >1 SSRC=%d"
              % (mm, dict(collections.Counter(r["codec"] for r in grp)),
                 sum(1 for r in grp if r["nssrc"] > 1)))
        print()

    if a.local:
        out = [r for r in rows if r["src"] == a.local]
        inn = [r for r in rows if r["dst"] == a.local]
        if out and inn:
            om = sum(r["mean"] for r in out) / len(out)
            im = sum(r["mean"] for r in inn) / len(inn)
            print("=" * 100)
            print("VERDICT")
            print("=" * 100)
            print("  inbound  mean_rms = %7.0f" % im)
            print("  outbound mean_rms = %7.0f" % om)
            if im > 300 and om < 30:
                print("  -> WE ARE RELAYING SILENCE. Real audio arrives and dead air leaves.")
            elif im > 300 and om > 300:
                print("  -> Outbound carries real audio. The relay is intact.")
            else:
                print("  -> Inconclusive: not enough signal on the inbound side either.")


if __name__ == "__main__":
    sys.exit(main())
