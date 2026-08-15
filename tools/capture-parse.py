#!/usr/bin/env python3
"""Parse a pjsip logger trace and answer four questions per answered call.

  1. was a 180 Ringing received before the 200 OK?
  2. who sent the BYE -- our side or the carrier side?
  3. what Q.850 cause came with it?
  4. did RTP flow in BOTH directions?

Written for capture-answered-calls.sh, which supplies the trace, the carrier
IP list and the sampled RTP counters. Read-only: it never touches Asterisk.

The SBC is a B2BUA, so one call is TWO dialogs with different Call-IDs. Legs
are classified by peer address rather than by Call-ID shape: anything talking
to a carrier IP is the carrier leg, anything else is the customer leg. That is
what makes "who sent the BYE" answerable at all.
"""
import argparse, re, sys, collections

# res_pjsip_logger banner, e.g.
#   <--- Received SIP response (700 bytes) from UDP:1.2.3.4:5060 --->
#   <--- Transmitting SIP request (900 bytes) to UDP:5.6.7.8:5060 --->
BANNER = re.compile(
    r"<---\s*(Received|Transmitting)\s+SIP\s+(request|response)"
    r"[^>]*?\s(?:from|to)\s+\w+:(?P<ip>[0-9a-fA-F:.]+):(?P<port>\d+)")
REQ_LINE = re.compile(r"^(INVITE|ACK|BYE|CANCEL|OPTIONS|PRACK|UPDATE|INFO|REGISTER)\s+sip:")
RESP_LINE = re.compile(r"^SIP/2\.0\s+(\d{3})\s*(.*)$")
CALLID = re.compile(r"^(?:Call-ID|i):\s*(.+?)\s*$", re.I)
REASON = re.compile(r"^Reason:\s*(.+?)\s*$", re.I)
CAUSE_IN_REASON = re.compile(r"cause\s*=\s*(\d+)", re.I)
TS = re.compile(r"^\[(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)\.(\d+)\]")


class Msg:
    __slots__ = ("t", "dir", "kind", "ip", "method", "code", "callid",
                 "reason_cause", "has_sdp")

    def __init__(self):
        self.t = None; self.dir = None; self.kind = None; self.ip = None
        self.method = None; self.code = None; self.callid = None
        self.reason_cause = None; self.has_sdp = False


def parse_trace(path):
    msgs = []
    cur = None
    last_ts = None
    in_body = False
    with open(path, "rb") as fh:
        for raw in fh:
            line = raw.decode("utf-8", "replace").rstrip("\r\n")
            m = TS.match(line)
            if m:
                last_ts = "%s.%s" % (m.group(1), m.group(2))
            b = BANNER.search(line)
            if b:
                cur = Msg()
                cur.t = last_ts
                cur.dir = "in" if b.group(1) == "Received" else "out"
                cur.kind = b.group(2)
                cur.ip = b.group("ip")
                msgs.append(cur)
                in_body = False
                continue
            if cur is None:
                continue
            if line.startswith("<---") or line.startswith("--->"):
                cur = None
                continue
            stripped = line.strip()
            if cur.method is None and cur.code is None:
                rq = REQ_LINE.match(stripped)
                if rq:
                    cur.method = rq.group(1)
                    continue
                rs = RESP_LINE.match(stripped)
                if rs:
                    cur.code = int(rs.group(1))
                    continue
            c = CALLID.match(stripped)
            if c and cur.callid is None:
                cur.callid = c.group(1)
                continue
            r = REASON.match(stripped)
            if r:
                cc = CAUSE_IN_REASON.search(r.group(1))
                if cc:
                    cur.reason_cause = int(cc.group(1))
                continue
            if stripped.lower().startswith("content-type:") and "sdp" in stripped.lower():
                cur.has_sdp = True
            if stripped == "":
                in_body = True
    return [m for m in msgs if m.callid]


def load_stats(path):
    """channel -> (max_rx, max_tx) from the sampled channelstats."""
    out = {}
    if not path:
        return out
    try:
        with open(path) as fh:
            for line in fh:
                p = line.split()
                if len(p) != 3:
                    continue
                ch = p[0]
                try:
                    rx = int(p[1].split("=")[1]); tx = int(p[2].split("=")[1])
                except (IndexError, ValueError):
                    continue
                prx, ptx = out.get(ch, (0, 0))
                out[ch] = (max(prx, rx), max(ptx, tx))
    except OSError:
        pass
    return out


def secs(a, b):
    """Seconds between two 'YYYY-MM-DD HH:MM:SS.mmm' stamps."""
    import datetime
    if not a or not b:
        return None
    f = "%Y-%m-%d %H:%M:%S.%f"
    try:
        return (datetime.datetime.strptime(b, f)
                - datetime.datetime.strptime(a, f)).total_seconds()
    except ValueError:
        return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--trace", required=True)
    ap.add_argument("--max-billsec", type=float, default=5.0)
    ap.add_argument("--carrier-ips", default="")
    ap.add_argument("--stats", default="")
    ap.add_argument("--count-only", action="store_true")
    a = ap.parse_args()

    carrier = set(x.strip() for x in a.carrier_ips.split() if x.strip())
    msgs = parse_trace(a.trace)

    legs = collections.defaultdict(list)
    for m in msgs:
        legs[m.callid].append(m)

    calls = []
    for cid, ms in legs.items():
        ms.sort(key=lambda x: (x.t or ""))
        ok = next((m for m in ms if m.code == 200 and m.method is None), None)
        bye = next((m for m in ms if m.method == "BYE"), None)
        if not ok or not bye:
            continue
        dur = secs(ok.t, bye.t)
        if dur is None or dur > a.max_billsec:
            continue
        ring = [m for m in ms if m.code == 180]
        prog = [m for m in ms if m.code == 183]
        ring_before = [m for m in ring if m.t and ok.t and m.t < ok.t]
        peer = ms[0].ip
        side = "carrier" if peer in carrier else "customer"
        # Who sent the BYE: a BYE we RECEIVED came from the peer on that leg.
        if bye.dir == "in":
            byefrom = "carrier" if bye.ip in carrier else "customer"
        else:
            byefrom = "us"
        calls.append(dict(callid=cid, side=side, peer=peer, dur=dur,
                          ring_before=len(ring_before), ring=len(ring),
                          prog=len(prog), byefrom=byefrom, byedir=bye.dir,
                          cause=bye.reason_cause, ok_sdp=ok.has_sdp,
                          t=ok.t))

    if a.count_only:
        # One call is two dialogs, so counting every qualifying leg would stop
        # the capture at half the requested sample. Count carrier-side legs:
        # one per INVITE we sent, and the side the BYE question is about.
        if carrier:
            print(sum(1 for c in calls if c["side"] == "carrier"))
        else:
            print(len(calls))
        return

    stats = load_stats(a.stats)

    print()
    print("=" * 78)
    print("2-SECOND ANSWER CAPTURE -- %d qualifying dialog(s), billsec <= %g"
          % (len(calls), a.max_billsec))
    print("=" * 78)
    if not calls:
        print("\nNo answered call with a short billsec appeared in this trace.")
        print("If traffic was flowing, check that logger.conf routes verbose to")
        print("a file -- pjsip logger output is emitted on the verbose channel.")
        return

    for i, c in enumerate(calls, 1):
        print()
        print("--- call %d ---------------------------------------------------" % i)
        print("  Call-ID        : %s" % c["callid"])
        print("  leg            : %s (peer %s)" % (c["side"], c["peer"]))
        print("  answered at    : %s" % c["t"])
        print("  200 -> BYE     : %.3fs" % c["dur"])
        print("  180 before 200 : %s   (180 seen: %d, 183 seen: %d)"
              % ("YES" if c["ring_before"] else "NO", c["ring"], c["prog"]))
        print("  200 OK had SDP : %s" % ("yes" if c["ok_sdp"] else "no"))
        who = {"carrier": "CARRIER sent BYE", "customer": "CUSTOMER sent BYE",
               "us": "WE sent BYE"}[c["byefrom"]]
        print("  BYE            : %s (%s)" % (who, c["byedir"]))
        print("  Q.850 cause    : %s"
              % (c["cause"] if c["cause"] is not None else "not signalled"))

    print()
    print("=" * 78)
    print("SUMMARY")
    print("=" * 78)
    nb = collections.Counter(c["byefrom"] for c in calls)
    print("  BYE origin      : %s" % dict(nb))
    nr = sum(1 for c in calls if c["ring_before"])
    print("  180 before 200  : %d of %d" % (nr, len(calls)))
    cz = collections.Counter(str(c["cause"]) for c in calls)
    print("  Q.850 causes    : %s" % dict(cz))

    if stats:
        print()
        print("  RTP, sampled while the channels were up:")
        both = one = none = 0
        for ch, (rx, tx) in sorted(stats.items()):
            tag = "both" if rx > 0 and tx > 0 else ("one-way" if rx or tx else "silent")
            if tag == "both":
                both += 1
            elif tag == "one-way":
                one += 1
            else:
                none += 1
            print("    %-28s rx=%-7d tx=%-7d %s" % (ch, rx, tx, tag))
        print("    -> both directions: %d, one-way: %d, silent: %d"
              % (both, one, none))
    else:
        print()
        print("  RTP: no channelstats samples were collected.")

    print()
    print("  READING THIS: a 200 OK with no preceding 180, RTP flowing from the")
    print("  carrier, and a BYE from the carrier side at ~2s is an intercept")
    print("  announcement -- the answer rate is not a real answer rate. A BYE")
    print("  from US on the same shape means the teardown is ours to fix.")


if __name__ == "__main__":
    sys.exit(main())
