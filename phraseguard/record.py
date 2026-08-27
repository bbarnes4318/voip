#!/usr/bin/env python3
"""Evidence output for PhraseGuard: syslog, JSONL, and per-customer counters.

WHAT IS PERSISTED, AND WHAT IS NOT
----------------------------------
Persisted, per event:

    timestamp, Call-ID, customer source IP, ANI, DNIS, matched phrase, tier,
    category, recogniser confidence, and a +/-10 word text window

NOT persisted, ever: audio. There is no code path in this component that
writes PCM, mu-law, a WAV or a capture file to disk. Decoded audio lives in a
bounded ring in tap.py and is discarded as it is consumed.

That is a legal decision as much as a storage one. A recording of a live
consumer call held on a border element is a different regulatory object from
a log line quoting twenty words, in every jurisdiction this trunk touches, and
the twenty words are what a carrier complaint or a commercial conversation
actually needs.

WHY NOT CDR
-----------
The brief rules it out and RUNBOOK.md explains why: cdr_custom.conf needs an
Asterisk restart to take a new column, and the portal shipper parses a fixed
column count, so an extra column risks breaking the thing that bills. Neither
of those is worth a detector's convenience.

So output goes to two places that cost nothing to add:

  syslog, tag sbc-phraseguard  the same channel healthcheck.sh already uses
                               (tag sbc-health), so `journalctl -t` is a
                               timeline without any new infrastructure
  JSONL under /var/log/phraseguard/   append-only, one file per UTC day,
                               machine-readable for the shadow-mode review

syslog is written through the stdlib syslog module rather than by forking
`logger` per event. Same tag, same facility, same journal entry -- and no
fork on a path that can fire several times a second across concurrent
streams. `logger -t sbc-phraseguard` from a shell produces byte-identical
journal records, so nothing downstream can tell the difference.

THE COUNTERS ARE THE POINT
--------------------------
Killing individual calls is whack-a-mole; a floor that loses a call redials in
four seconds. The lever that works is the customer trunk, and pulling it is a
commercial decision that needs evidence: not "we hung up some calls" but "this
source IP produced N Tier A kills across M monitored calls in 24 hours, and
this other one produced none". CustomerCounters is that record. It emits a
RATE, because a floor doing 40,000 calls a day and one doing 400 are not
comparable on raw counts.

There is deliberately NO automatic trunk suspension here. Suspending a
pkclient IP is a commercial decision on the only customer on the trunk. This
surfaces it through the existing sbc-health alert path; a human pulls it.
"""
import json
import os
import syslog
import time

SYSLOG_TAG = "sbc-phraseguard"
HEALTH_TAG = "sbc-health"

DEFAULT_LOG_DIR = "/var/log/phraseguard"
DEFAULT_STATE = "/var/lib/phraseguard/counters.json"


# ---------------------------------------------------------------------------
# Event log
# ---------------------------------------------------------------------------
class Recorder(object):
    """Writes one event to syslog and to the day's JSONL file.

    Every method here swallows its own errors. A full disk, a missing
    directory or a revoked permission must degrade this to "we lost the log
    line", never to "the daemon stopped" and certainly never to anything a
    call can notice.
    """

    def __init__(self, log_dir=DEFAULT_LOG_DIR, tag=SYSLOG_TAG, enabled=True):
        self.log_dir = log_dir
        self.tag = tag
        self.enabled = enabled
        self.written = 0
        self.errors = 0
        self._fh = None
        self._day = None
        self._opened = False

    def _open_syslog(self):
        if self._opened:
            return
        try:
            syslog.openlog(self.tag, syslog.LOG_PID, syslog.LOG_DAEMON)
            self._opened = True
        except Exception:                              # noqa: BLE001
            self.errors += 1

    def _jsonl(self, now):
        day = time.strftime("%Y%m%d", time.gmtime(now))
        if self._fh is not None and day == self._day:
            return self._fh
        if self._fh is not None:
            try:
                self._fh.close()
            except Exception:                          # noqa: BLE001
                pass
            self._fh = None
        try:
            os.makedirs(self.log_dir, exist_ok=True)
            path = os.path.join(self.log_dir, "phraseguard-%s.jsonl" % day)
            # Append-only, line-buffered. O_APPEND means two writers (a daemon
            # and a hand-run replay) cannot interleave a partial line.
            self._fh = open(path, "a", buffering=1, encoding="utf-8")
            self._day = day
        except Exception:                              # noqa: BLE001
            self.errors += 1
            self._fh = None
        return self._fh

    def event(self, kind, level="info", **fields):
        """Emit one structured event. Never raises."""
        if not self.enabled:
            return
        now = fields.pop("ts", None) or time.time()
        rec = {"ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now)),
               "event": kind}
        rec.update({k: v for k, v in fields.items() if v is not None})

        self._open_syslog()
        if self._opened:
            prio = {"crit": syslog.LOG_ERR, "warn": syslog.LOG_WARNING,
                    "info": syslog.LOG_INFO}.get(level, syslog.LOG_INFO)
            try:
                syslog.syslog(prio, self._oneline(rec))
            except Exception:                          # noqa: BLE001
                self.errors += 1

        fh = self._jsonl(now)
        if fh is not None:
            try:
                fh.write(json.dumps(rec, sort_keys=True) + "\n")
                self.written += 1
            except Exception:                          # noqa: BLE001
                self.errors += 1

    @staticmethod
    def _oneline(rec):
        """key=value for the journal. Readable with grep, unlike raw JSON."""
        out = []
        for k in ("event", "tier", "category", "action", "phrase", "score",
                  "conf", "call_id", "src_ip", "ani", "dnis", "channel",
                  "mode", "detail", "context"):
            if k in rec and rec[k] is not None:
                v = rec[k]
                if isinstance(v, str) and (" " in v or not v):
                    v = '"%s"' % v.replace('"', "'")
                out.append("%s=%s" % (k, v))
        for k in sorted(rec):
            if k not in ("ts",) and k not in [o.split("=", 1)[0] for o in out]:
                out.append("%s=%s" % (k, rec[k]))
        return " ".join(out)

    def match(self, match, call, window, action, mode, conf=None,
              channel=None, detail=None, now=None):
        """The record shape the brief specifies, and nothing beyond it."""
        level = "warn" if match.tier == "A" else "info"
        self.event(
            "match", level=level, ts=now,
            tier=match.tier,
            category=match.phrase.category,
            phrase=match.phrase.text,
            lang=match.phrase.lang,
            anchor=match.phrase.anchor,
            how=match.how,
            score=round(match.score, 4),
            conf=conf,
            call_id=(call.call_id if call else None),
            src_ip=(call.customer_ip if call else None),
            ani=(call.ani if call else None),
            dnis=(call.dnis if call else None),
            channel=channel,
            action=action,
            mode=mode,
            detail=detail,
            context=window.context(match) if window else None,
        )

    def close(self):
        if self._fh is not None:
            try:
                self._fh.close()
            except Exception:                          # noqa: BLE001
                pass
            self._fh = None


def health(level, message, tag=HEALTH_TAG):
    """Emit on the sbc-health channel healthcheck.sh already uses.

    A separate openlog would clobber the Recorder's ident for the process, so
    this forks `logger` instead. It runs at alert rates -- a handful of lines
    an hour at most -- not per event.
    """
    import subprocess
    prio = {"crit": "daemon.err", "warn": "daemon.warning"}.get(level, "daemon.info")
    label = {"crit": "CRIT", "warn": "WARN"}.get(level, "OK")
    try:
        subprocess.run(["logger", "-t", tag, "-p", prio,
                        "%s: %s" % (label, message)], timeout=5)
    except Exception:                                  # noqa: BLE001
        pass


# ---------------------------------------------------------------------------
# Per-customer-IP counters
# ---------------------------------------------------------------------------
class CustomerCounters(object):
    """Rolling 24h attribution per customer source IP.

    Tracks, per IP: calls monitored, Tier A confident matches, Tier A-near
    matches, and Tier B threshold events. Emits rates per 1,000 monitored
    calls, because that is the only form in which two floors of different
    sizes can be compared -- and comparing them is the entire commercial
    argument this component exists to support.

    State is persisted so that a daemon restart does not silently reset a
    24-hour record. An evidence log that quietly forgets is worse than no
    evidence log: it produces a clean-looking history for a floor that was
    caught three times before the last deploy.
    """

    KINDS = ("calls", "kill", "near", "b_event")

    def __init__(self, window_s=86400.0, state_path=DEFAULT_STATE,
                 alert_kill_rate=1.0, alert_b_rate=20.0, alert_min_calls=200,
                 alert_interval_s=3600.0):
        self.window_s = window_s
        self.state_path = state_path
        self.alert_kill_rate = alert_kill_rate
        self.alert_b_rate = alert_b_rate
        self.alert_min_calls = alert_min_calls
        self.alert_interval_s = alert_interval_s
        self.events = {}            # ip -> list of (ts, kind)
        self.last_alert = {}        # ip -> ts
        self.load()

    # -- persistence --------------------------------------------------------
    def load(self):
        try:
            with open(self.state_path, "r", encoding="utf-8") as fh:
                data = json.load(fh)
        except Exception:                              # noqa: BLE001
            return
        now = time.time()
        for ip, rows in (data.get("events") or {}).items():
            keep = [(float(t), k) for t, k in rows
                    if now - float(t) <= self.window_s]
            if keep:
                self.events[ip] = keep
        self.last_alert = {k: float(v) for k, v
                           in (data.get("last_alert") or {}).items()}

    def save(self):
        try:
            os.makedirs(os.path.dirname(self.state_path), exist_ok=True)
            tmp = self.state_path + ".tmp"
            with open(tmp, "w", encoding="utf-8") as fh:
                json.dump({"events": {ip: [[t, k] for t, k in rows]
                                      for ip, rows in self.events.items()},
                           "last_alert": self.last_alert}, fh)
            # Atomic: a torn counters file read at startup would silently
            # truncate the 24h record, which is the failure this whole class
            # is trying to avoid.
            os.replace(tmp, self.state_path)
        except Exception:                              # noqa: BLE001
            pass

    # -- counting -----------------------------------------------------------
    def add(self, ip, kind, now=None):
        if not ip or kind not in self.KINDS:
            return
        now = time.time() if now is None else now
        self.events.setdefault(ip, []).append((now, kind))
        self._trim(ip, now)

    def _trim(self, ip, now):
        cutoff = now - self.window_s
        rows = self.events.get(ip)
        if not rows:
            return
        if rows[0][0] >= cutoff:
            return
        self.events[ip] = [r for r in rows if r[0] >= cutoff]

    def snapshot(self, now=None):
        """{ip: {calls, kill, near, b_event, kill_per_1k, b_per_1k}}"""
        now = time.time() if now is None else now
        out = {}
        for ip in list(self.events):
            self._trim(ip, now)
            rows = self.events.get(ip) or []
            c = {k: 0 for k in self.KINDS}
            for _t, k in rows:
                c[k] += 1
            calls = c["calls"]
            c["kill_per_1k"] = round(1000.0 * c["kill"] / calls, 3) if calls else 0.0
            c["b_per_1k"] = round(1000.0 * c["b_event"] / calls, 3) if calls else 0.0
            out[ip] = c
        return out

    def check_alerts(self, recorder=None, now=None):
        """Emit sbc-health alerts for IPs over the configured rates.

        Rate-limited per IP. An alert that repeats every event trains the
        operator to filter the tag out, which is the same as not alerting.
        """
        now = time.time() if now is None else now
        fired = []
        for ip, c in self.snapshot(now).items():
            if c["calls"] < self.alert_min_calls:
                continue
            reasons = []
            if c["kill_per_1k"] >= self.alert_kill_rate:
                reasons.append("Tier A %.2f/1k" % c["kill_per_1k"])
            if c["b_per_1k"] >= self.alert_b_rate:
                reasons.append("Tier B %.2f/1k" % c["b_per_1k"])
            if not reasons:
                continue
            if now - self.last_alert.get(ip, 0) < self.alert_interval_s:
                continue
            self.last_alert[ip] = now
            msg = ("PhraseGuard: customer %s over threshold in 24h -- %s "
                   "across %d monitored call(s) [%d kill, %d near, %d B]. "
                   "Trunk suspension is a COMMERCIAL decision and is not "
                   "automated; this is a notification."
                   % (ip, ", ".join(reasons), c["calls"], c["kill"],
                      c["near"], c["b_event"]))
            health("warn", msg)
            if recorder is not None:
                recorder.event("customer_alert", level="warn", src_ip=ip,
                               detail=", ".join(reasons), **{
                                   "calls_24h": c["calls"],
                                   "kill_24h": c["kill"],
                                   "near_24h": c["near"],
                                   "b_24h": c["b_event"],
                                   "kill_per_1k": c["kill_per_1k"],
                                   "b_per_1k": c["b_per_1k"]})
            fired.append(ip)
        return fired


def main(argv=None):
    """Print the current 24h attribution table."""
    import argparse
    ap = argparse.ArgumentParser(description="PhraseGuard per-customer counters")
    ap.add_argument("--state", default=DEFAULT_STATE)
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args(argv)
    c = CustomerCounters(state_path=a.state)
    snap = c.snapshot()
    if a.json:
        print(json.dumps(snap, indent=2, sort_keys=True))
        return 0
    if not snap:
        print("no counter state at %s (nothing recorded in the last 24h)" % a.state)
        return 0
    print()
    print("%-18s %8s %6s %6s %8s %10s %8s"
          % ("customer IP", "calls", "kill", "near", "B events",
             "kill/1k", "B/1k"))
    print("-" * 74)
    for ip in sorted(snap):
        c2 = snap[ip]
        print("%-18s %8d %6d %6d %8d %10.3f %8.3f"
              % (ip, c2["calls"], c2["kill"], c2["near"], c2["b_event"],
                 c2["kill_per_1k"], c2["b_per_1k"]))
    print()
    print("  Rates are per 1,000 monitored calls. Raw counts across floors of")
    print("  different sizes are not comparable and are shown for context only.")
    return 0


if __name__ == "__main__":
    import sys
    sys.exit(main())
