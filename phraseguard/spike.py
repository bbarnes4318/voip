#!/usr/bin/env python3
"""The PhraseGuard channel-mapping spike: does Call-ID -> channel actually work?

Driven by tools/phraseguard-spike.sh, which does the preflight and the arming.
This is the measurement.

THE QUESTION
------------
Everything in PhraseGuard downstream of the matcher depends on one thing: a
Call-ID observed in a packet capture has to resolve to an Asterisk channel
name that `channel request hangup` accepts, quickly enough to matter on a call
that is still up. If it does not, the detector can log and attribute but can
never disconnect, and that changes what this component is.

So this measures, on live traffic:

  coverage   what fraction of Call-IDs seen in an INVITE on the wire resolve
             to a channel at all
  method     how many resolve EXACTLY, via the SBC_CALLID channel variable the
             dialplan already sets, versus via the documented heuristic
  ambiguity  how often more than one channel matches -- the case where
             enforcement would disconnect somebody else's call
  latency    INVITE seen on the wire -> channel name in hand, and separately
             the cost of one resolution call

READ-ONLY. It runs `core show channels concise` and `core show channel`, both
of which are reads. It never hangs anything up unless --prove-hangup is passed,
which is documented in the wrapper as the one destructive option and requires
a live call to be sacrificed deliberately.
"""
import os
import sys
import threading
import time

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

from actuator import (AsteriskCLI, ChannelResolver, ChannelTable,  # noqa: E402
                      Hangup, endpoint_map, probe_ami)
from tap import SipTracker, Tap                                    # noqa: E402


class Observation(object):
    __slots__ = ("call", "first_seen", "resolved_at", "resolution", "attempts")

    def __init__(self, call, first_seen):
        self.call = call
        self.first_seen = first_seen
        self.resolved_at = None
        self.resolution = None
        self.attempts = 0


class Spike(object):
    def __init__(self, customer_ips, rtp_lo, rtp_hi, iface="any",
                 asterisk="asterisk", poll_s=0.5, allow_heuristic=True,
                 pcap=None):
        self.customer_ips = customer_ips
        self.cli = AsteriskCLI(asterisk)
        self.table = ChannelTable(self.cli)
        self.resolver = ChannelResolver(self.table, endpoint_map(customer_ips),
                                        allow_heuristic=allow_heuristic)
        self.tracker = SipTracker(customer_ips)
        # SIP only. The spike does not need media and capturing the RTP range
        # on a busy box for no reason is not free.
        self.tap = Tap(customer_ips, customer_ips, rtp_lo, rtp_hi,
                       iface=iface, pcap_path=pcap, tracker=self.tracker)
        self.tap.bpf = lambda: "udp and port 5060"
        self.poll_s = poll_s
        self.observations = {}
        self.stopping = False

    def _on_packet(self, ts, src, _sp, _dst, _dp, _payload):
        del ts, src, _sp, _dst, _dp, _payload

    def _snapshot_calls(self, tries=5):
        """A stable list of (call_id, CallInfo), retried past a concurrent write."""
        for _ in range(tries):
            try:
                return list(self.tracker.calls.items())
            except RuntimeError:
                # "dictionary changed size during iteration" -- the capture
                # thread inserted or _gc popped while we materialised it.
                time.sleep(0.01)
        return []

    def _capture(self):
        try:
            self.tap.run(on_packet=self._on_packet,
                         stop=lambda: self.stopping)
        except Exception as e:                         # noqa: BLE001
            sys.stderr.write("  capture stopped: %s\n" % e)

    def run(self, seconds, on_tick=None, prove_hangup=False):
        t0 = time.time()
        th = threading.Thread(target=self._capture, daemon=True)
        th.start()
        hung_up = None

        while time.time() - t0 < seconds and not self.stopping:
            time.sleep(self.poll_s)
            # The capture thread inserts into tracker.calls and _gc pops from
            # it, neither under any lock, so materialising the dict can raise
            # "dictionary changed size during iteration". A lock here would
            # not help -- the writer does not take one -- and adding locking
            # to SipTracker would put it on the daemon's per-packet path for
            # the benefit of this one measurement tool. Retrying the snapshot
            # is cheap, correct, and keeps the hot path lock-free. Losing the
            # whole 120-second window to a RuntimeError is the alternative.
            for cid, call in self._snapshot_calls():
                if not call.invite_seen:
                    continue
                obs = self.observations.get(cid)
                if obs is None:
                    obs = Observation(call, call.started)
                    self.observations[cid] = obs
                if obs.resolved_at is not None:
                    continue
                obs.attempts += 1
                res = self.resolver.resolve(call)
                obs.resolution = res
                if res.channel or res.ambiguous:
                    obs.resolved_at = time.time()
                    if prove_hangup and hung_up is None and res.ok:
                        h = Hangup(self.cli, enforce=True)
                        acted, detail = h.execute(res)
                        hung_up = (res.channel, acted, detail)
            if on_tick:
                on_tick(self)
        self.stopping = True
        self.tap.close()
        th.join(timeout=5)
        return hung_up

    # -- reporting ----------------------------------------------------------
    def report(self, elapsed, hung_up=None):
        obs = list(self.observations.values())
        resolved = [o for o in obs if o.resolution and o.resolution.ok]
        ambiguous = [o for o in obs if o.resolution and o.resolution.ambiguous]
        unresolved = [o for o in obs
                      if not o.resolution or (not o.resolution.ok
                                              and not o.resolution.ambiguous)]
        exact = [o for o in resolved if o.resolution.how == "callid"]
        heur = [o for o in resolved if o.resolution.how == "heuristic"]

        def pct(a, b):
            return "%5.1f%%" % (100.0 * a / b) if b else "    n/a"

        def pctl(vals, p):
            if not vals:
                return float("nan")
            s = sorted(vals)
            k = min(len(s) - 1, int(round((p / 100.0) * (len(s) - 1))))
            return s[k]

        e2e = [(o.resolved_at - o.first_seen) * 1000.0 for o in resolved
               if o.resolved_at]
        call_ms = [o.resolution.elapsed_ms for o in resolved]

        print()
        print("=" * 74)
        print("PHRASEGUARD CHANNEL-MAPPING SPIKE   %.0fs%s"
              % (elapsed, "  (REPLAY)" if self.tap.pcap_path else ""))
        print("=" * 74)

        ami = probe_ami()
        print("  AMI                  %s"
              % ("ENABLED" if ami["enabled"] else
                 "disabled" if ami["enabled"] is False else "unknown"))
        print("    %s" % (ami["note"] or "manager.conf unreadable"))
        print()
        print("  INVITEs observed     %d" % len(obs))
        print("  resolved             %d   %s" % (len(resolved), pct(len(resolved), len(obs))))
        print("    exact (SBC_CALLID) %d   %s" % (len(exact), pct(len(exact), len(obs))))
        print("    heuristic fallback %d   %s" % (len(heur), pct(len(heur), len(obs))))
        print("  AMBIGUOUS            %d   %s" % (len(ambiguous), pct(len(ambiguous), len(obs))))
        print("  unresolved           %d   %s" % (len(unresolved), pct(len(unresolved), len(obs))))
        print()
        if e2e:
            print("  latency, INVITE on the wire -> channel name in hand")
            print("    p50 %7.0f ms   p90 %7.0f ms   p99 %7.0f ms   max %7.0f ms"
                  % (pctl(e2e, 50), pctl(e2e, 90), pctl(e2e, 99), max(e2e)))
            print("    (floor is the %.1fs poll interval; this is not the"
                  % self.poll_s)
            print("     resolution cost, it is how often we looked)")
            print()
        if call_ms:
            print("  cost of ONE resolve() call")
            print("    p50 %7.1f ms   p90 %7.1f ms   max %7.1f ms"
                  % (pctl(call_ms, 50), pctl(call_ms, 90), max(call_ms)))
            print()
        print("  asterisk -rx calls   %d  (%.1f ms each, %d error(s))"
              % (self.cli.calls,
                 1000.0 * self.cli.seconds / self.cli.calls if self.cli.calls else 0,
                 self.cli.errors))
        print("  channels probed      %d, of which %d exposed SBC_CALLID"
              % (len(self.table.channels), len(self.table.by_call_id)))
        print("  probe failures       %d" % self.table.probe_failures)

        if self.table.layout_warning:
            print()
            print("  LAYOUT WARNING")
            print("    %s" % self.table.layout_warning)

        if hung_up:
            chan, acted, detail = hung_up
            print()
            print("  PROVE-HANGUP         %s on %s" % ("EXECUTED" if acted
                                                       else "FAILED", chan))
            print("    %s" % detail)

        print()
        print("=" * 74)
        print("VERDICT")
        print("=" * 74)
        if not obs:
            print("  No INVITEs were observed. Nothing was measured.")
            print("  The trunk has been paused since 2026-08-12 (HANDOFF.md);")
            print("  re-run this with --arm so it waits for traffic instead of")
            print("  sampling silence.")
            return 3
        cov = len(exact) / float(len(obs))
        if cov >= 0.98 and not ambiguous:
            print("  PASS. %s of Call-IDs resolved EXACTLY via SBC_CALLID, with"
                  % pct(len(exact), len(obs)).strip())
            print("  no ambiguity. Enforcement can be built on this mapping.")
            rc = 0
        elif len(resolved) / float(len(obs)) >= 0.98 and not ambiguous:
            print("  PARTIAL. Everything resolved, but %d relied on the"
                  % len(heur))
            print("  HEURISTIC fallback (endpoint + DNIS + channel age).")
            print("  Enforcement MUST NOT ship on a heuristic: the failure mode")
            print("  is disconnecting a different customer's legitimate call.")
            print("  Find out why SBC_CALLID was not readable first.")
            rc = 1
        else:
            print("  FAIL. Only %s resolved%s."
                  % (pct(len(resolved), len(obs)).strip(),
                     ", and %d were AMBIGUOUS" % len(ambiguous) if ambiguous else ""))
            print("  STOP HERE. The brief is explicit: if Call-ID does not")
            print("  resolve reliably, everything downstream is undeliverable")
            print("  as specified. Report this before building further.")
            rc = 1
        print()
        if unresolved:
            print("  A sample of what did not resolve:")
            for o in unresolved[:5]:
                print("    %-40s %s" % (o.call.call_id[:40],
                                        o.resolution.reason if o.resolution
                                        else "never attempted"))
            print()
        return rc

    def dump(self):
        """Raw CLI output, so the concise field layout is verified not assumed."""
        print()
        print("=" * 74)
        print("RAW  core show channels concise")
        print("=" * 74)
        out = self.cli.rx("core show channels concise")
        for line in out.split("\n")[:20]:
            if line.strip():
                fields = line.split("!")
                print("  [%d fields] %s" % (len(fields), line))
        print()
        print("  ChannelTable expects %d fields, name=%d exten=%d cid=%d "
              "duration=%d uniqueid=%d"
              % (ChannelTable.CONCISE_FIELDS, ChannelTable.F_NAME,
                 ChannelTable.F_EXTEN, ChannelTable.F_CID,
                 ChannelTable.F_DURATION, ChannelTable.F_UNIQUEID))
        chans = self.table.refresh(force=True)
        if chans:
            name = sorted(chans)[0]
            print()
            print("=" * 74)
            print("RAW  core show channel %s" % name)
            print("=" * 74)
            raw = self.cli.rx("core show channel %s" % name)
            print(raw)
            print("  -> SBC_CALLID present in output: %s"
                  % ("YES" if "SBC_CALLID" in raw else "NO"))
            if "SBC_CALLID" not in raw:
                print()
                print("  This is the finding that matters. Either the deployed")
                print("  extensions.conf has no Set(__SBC_CALLID=...) in")
                print("  [sbc-customer], or this build does not print a")
                print("  Variables: block. Exact resolution is unavailable.")
        else:
            print()
            print("  No channels are up, so `core show channel` could not be")
            print("  exercised. Re-run with --arm while traffic is flowing.")
        print()


def main(argv=None):
    import argparse
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--customer-ips", default=os.environ.get("PK_CLIENT_IPS", ""))
    ap.add_argument("--rtp-lo", type=int, default=int(os.environ.get("RTP_START", 10000)))
    ap.add_argument("--rtp-hi", type=int, default=int(os.environ.get("RTP_END", 20000)))
    ap.add_argument("--iface", default="any")
    ap.add_argument("--asterisk", default="asterisk")
    ap.add_argument("--seconds", type=int, default=120)
    ap.add_argument("--poll", type=float, default=0.5)
    ap.add_argument("--pcap", help="replay instead of tapping live")
    ap.add_argument("--dump", action="store_true",
                    help="print raw CLI output and exit")
    ap.add_argument("--no-heuristic", action="store_true",
                    help="only accept exact SBC_CALLID resolution")
    ap.add_argument("--prove-hangup", action="store_true",
                    help="DESTRUCTIVE: hang up ONE resolved live call")
    a = ap.parse_args(argv)

    cust = [x.strip() for x in a.customer_ips.replace(",", " ").split() if x.strip()]
    if not cust:
        sys.stderr.write("spike: set PK_CLIENT_IPS or pass --customer-ips\n")
        return 2

    s = Spike(cust, a.rtp_lo, a.rtp_hi, iface=a.iface, asterisk=a.asterisk,
              poll_s=a.poll, allow_heuristic=not a.no_heuristic, pcap=a.pcap)
    if a.dump:
        s.dump()
        return 0

    t0 = time.time()
    try:
        hung = s.run(a.seconds, prove_hangup=a.prove_hangup)
    except KeyboardInterrupt:
        s.stopping = True
        hung = None
    return s.report(time.time() - t0, hung)


if __name__ == "__main__":
    sys.exit(main())
