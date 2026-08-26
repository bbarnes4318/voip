#!/usr/bin/env python3
"""phraseguardd — PhraseGuard's daemon. Tap -> ASR -> matcher -> record.

  ./phraseguardd.py                     run (shadow mode unless told otherwise)
  ./phraseguardd.py --pcap FILE         replay a capture through the whole
                                        pipeline; never touches Asterisk
  ./phraseguardd.py --self-test         preflight only; changes nothing
  ./phraseguardd.py --status            print what a running instance recorded

SHIPS IN SHADOW MODE
--------------------
PHRASEGUARD_ENFORCE=0 is the default and enforcement requires setting it to 1
explicitly. In shadow mode every stage runs -- the tap, the recogniser, the
matcher, the Call-ID resolution, the per-customer counters -- and the only
thing that does not happen is the hangup. The log says "would hang up" and
names the channel it would have hung up, so the shadow-mode review is a review
of real decisions rather than of a simulation.

Enforcement is a separate, deliberate deploy after the false-positive rate has
been measured on real traffic, and only for Tier A, and only for phrases that
survived the review. That is how the calling-hours gate was introduced on this
box and it is the pattern to copy.

FAIL OPEN IS A STRUCTURAL PROPERTY, NOT A PROMISE
-------------------------------------------------
This process cannot delay, block or gate call setup, because it is not in the
call path at any point. It reads a packet capture and, at most, issues one
`asterisk -rx "channel request hangup"` on a call that has already been up for
seconds. If it crashes, leaks, or is killed, Asterisk does not find out.

The systemd unit is Restart=on-failure with no Requires= on asterisk.service,
so a crash loop here cannot take the trunk with it. It runs at a positive nice
value and under a CPU quota for the same reason.
"""
import argparse
import errno
import os
import signal
import sys
import time

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

from actuator import (AsteriskCLI, ChannelResolver, ChannelTable,  # noqa: E402
                      Hangup, endpoint_map, probe_ami)
from asr import RecognizerFactory, load_script                     # noqa: E402
from matcher import BScorer, CallWindow, Corpus, Matcher, Thresholds  # noqa: E402
from record import CustomerCounters, Recorder, health              # noqa: E402
from tap import RtpDemux, SipTracker, Tap                          # noqa: E402

DEFAULT_LOCK = "/run/phraseguard.pid"


def _bool(v, default=False):
    if v is None or v == "":
        return default
    return str(v).strip().lower() in ("1", "yes", "true", "on")


def _csv(v):
    return [x.strip() for x in (v or "").replace(",", " ").split() if x.strip()]


class Config(object):
    """Everything tunable, from config.env via the environment.

    No thresholds and no phrases are hardcoded in any source file. config.env
    is already how this box is configured and install.sh already sources it,
    so PhraseGuard adds a section rather than a second configuration system.
    """

    def __init__(self, env=None, args=None):
        e = os.environ if env is None else env
        a = args

        self.enforce = _bool(e.get("PHRASEGUARD_ENFORCE"), False)
        if a is not None and getattr(a, "enforce", False):
            self.enforce = True
        if a is not None and getattr(a, "shadow", False):
            self.enforce = False

        self.customer_ips = _csv(e.get("PK_CLIENT_IPS"))
        self.media_extra = _csv(e.get("PK_CLIENT_MEDIA_EXTRA"))
        self.rtp_lo = int(e.get("RTP_START") or 10000)
        self.rtp_hi = int(e.get("RTP_END") or 20000)
        self.iface = e.get("PHRASEGUARD_IFACE") or "any"

        self.corpus_path = (e.get("PHRASEGUARD_CORPUS")
                            or os.path.join(_HERE, "phrases.csv"))
        self.langs = tuple(_csv(e.get("PHRASEGUARD_LANGS") or "en"))
        self.model = e.get("PHRASEGUARD_VOSK_MODEL") or ""

        self.gate_rms = float(e.get("PHRASEGUARD_GATE_RMS") or 200.0)
        self.gate_seconds = float(e.get("PHRASEGUARD_GATE_SECONDS") or 5.0)
        self.window_s = float(e.get("PHRASEGUARD_B_WINDOW_S") or 90.0)
        self.context_words = int(e.get("PHRASEGUARD_CONTEXT_WORDS") or 10)

        self.log_dir = e.get("PHRASEGUARD_LOG_DIR") or "/var/log/phraseguard"
        self.state_path = (e.get("PHRASEGUARD_STATE")
                           or "/var/lib/phraseguard/counters.json")
        self.manager_conf = (e.get("PHRASEGUARD_MANAGER_CONF")
                             or "/etc/asterisk/manager.conf")
        self.asterisk = e.get("PHRASEGUARD_ASTERISK") or "asterisk"

        self.allow_heuristic = _bool(e.get("PHRASEGUARD_ALLOW_HEURISTIC_MATCH"),
                                     False)
        self.max_streams = int(e.get("PHRASEGUARD_MAX_STREAMS") or 200)
        # Test facility. See asr.ScriptedRecognizer; refused with --enforce.
        self.script_path = (getattr(a, "script", None)
                            or e.get("PHRASEGUARD_SCRIPT") or "")

        self.thresholds = Thresholds.from_env(e)
        self.bscorer = BScorer.from_env(e)
        self.counters_kw = dict(
            alert_kill_rate=float(e.get("PHRASEGUARD_ALERT_KILL_PER_1K") or 1.0),
            alert_b_rate=float(e.get("PHRASEGUARD_ALERT_B_PER_1K") or 20.0),
            alert_min_calls=int(e.get("PHRASEGUARD_ALERT_MIN_CALLS") or 200),
        )

    @property
    def media_ips(self):
        return self.customer_ips + self.media_extra

    @property
    def mode(self):
        return "enforce" if self.enforce else "shadow"


class PhraseGuard(object):
    def __init__(self, cfg, pcap=None):
        self.cfg = cfg
        self.pcap = pcap
        self.stopping = False
        self.reload_requested = False

        self.corpus = Corpus(cfg.corpus_path, cfg.langs)
        self.corpus.load()
        self.matcher = Matcher(self.corpus, cfg.thresholds)
        self.scorer = cfg.bscorer

        self.recorder = Recorder(cfg.log_dir)
        self.counters = CustomerCounters(state_path=cfg.state_path,
                                         **cfg.counters_kw)

        script = load_script(cfg.script_path) if cfg.script_path else None
        self.asr = RecognizerFactory(cfg.model, self.corpus, script=script)
        self.asr.load()

        self.cli = AsteriskCLI(cfg.asterisk)
        self.table = ChannelTable(self.cli)
        self.resolver = ChannelResolver(
            self.table, endpoint_map(cfg.customer_ips),
            allow_heuristic=cfg.allow_heuristic)
        self.hangup = Hangup(self.cli, enforce=cfg.enforce)

        self.tracker = SipTracker(cfg.customer_ips)
        self.demux = RtpDemux(cfg.media_ips, gate_rms=cfg.gate_rms,
                              gate_seconds=cfg.gate_seconds)
        self.tap = Tap(cfg.customer_ips, cfg.media_ips, cfg.rtp_lo, cfg.rtp_hi,
                       iface=cfg.iface, pcap_path=pcap,
                       demux=self.demux, tracker=self.tracker)

        # Per-stream state. Keyed by the RTP 5-tuple+SSRC, because that is what
        # the demux hands us and it is stable for the life of the stream.
        self.sessions = {}
        self.counted_calls = set()
        self.stats = {"utterances": 0, "matches": 0, "kills": 0,
                      "would_kill": 0, "b_events": 0, "unresolved": 0}
        self._last_housekeeping = 0.0

    # -- signals ------------------------------------------------------------
    def install_signals(self):
        signal.signal(signal.SIGTERM, self._sig_stop)
        signal.signal(signal.SIGINT, self._sig_stop)
        signal.signal(signal.SIGHUP, self._sig_reload)

    def _sig_stop(self, *_a):
        self.stopping = True

    def _sig_reload(self, *_a):
        # Set a flag only. Loading a CSV from inside a signal handler means
        # parsing a file the operator may be halfway through saving, on a
        # thread that cannot safely take a lock. The main loop picks this up.
        self.reload_requested = True

    # -- the pipeline -------------------------------------------------------
    def on_audio(self, stream, pcm, call):
        key = stream.key
        sess = self.sessions.get(key)
        if sess is None:
            if len(self.sessions) >= self.cfg.max_streams:
                # Refusing a new recogniser is the correct overload behaviour:
                # it costs detection on one stream. Accepting it past the CPU
                # budget costs latency on every stream, and eventually costs
                # Asterisk the core it needs to relay media.
                self.stats.setdefault("refused_streams", 0)
                self.stats["refused_streams"] += 1
                return
            sess = {"rec": self.asr.new(),
                    "win": CallWindow(self.cfg.window_s, self.cfg.context_words),
                    "since": 0, "call_id": stream.call_id}
            self.sessions[key] = sess
            if call is not None and call.call_id not in self.counted_calls:
                self.counted_calls.add(call.call_id)
                self.counters.add(call.customer_ip, "calls")

        out = sess["rec"].accept(pcm)
        if not out:
            return
        text, conf = out
        self.stats["utterances"] += 1

        win = sess["win"]
        first_new = win.add(text)
        matches = self.matcher.match(win.tokens, since=first_new)
        for m in matches:
            # A match that re-reports a span already reported for this call is
            # the same words said once. See CallWindow.accept().
            if not win.accept(m):
                self.stats.setdefault("duplicates", 0)
                self.stats["duplicates"] += 1
                continue
            self.handle_match(m, call, win, conf, stream)

    def handle_match(self, match, call, window, conf, _stream):
        self.stats["matches"] += 1
        window.record(match)
        src_ip = call.customer_ip if call else None

        if match.tier == "A":
            res = self.resolver.resolve(call) if call else None
            channel = res.channel if res else None
            if res is None:
                action, detail = "no_call", "no Call-ID for this stream"
                self.stats["unresolved"] += 1
            else:
                acted, detail = self.hangup.execute(res)
                if acted:
                    action = "hangup"
                    self.stats["kills"] += 1
                elif res.ok:
                    action = "would_hangup"
                    self.stats["would_kill"] += 1
                else:
                    action = "unresolved"
                    self.stats["unresolved"] += 1
                detail = "%s (resolve %.1fms via %s)" % (
                    detail, res.elapsed_ms, res.how or "none")
            self.counters.add(src_ip, "kill")
            self.recorder.match(match, call, window, action, self.cfg.mode,
                                conf=conf, channel=channel, detail=detail)
            return

        if match.tier == "A-near":
            self.counters.add(src_ip, "near")
        self.recorder.match(match, call, window, "log", self.cfg.mode,
                            conf=conf)

        fired, score, contributing, suppressing = self.scorer.should_fire(window)
        if fired:
            self.stats["b_events"] += 1
            self.counters.add(src_ip, "b_event")
            self.recorder.event(
                "b_threshold", level="warn",
                call_id=(call.call_id if call else None),
                src_ip=src_ip, ani=(call.ani if call else None),
                dnis=(call.dnis if call else None),
                score=round(score, 3),
                categories=",".join(sorted(contributing)),
                suppressors=",".join(sorted(suppressing)) or None,
                mode=self.cfg.mode, action="log",
                detail="B threshold reached; Tier B never disconnects")

    # -- housekeeping -------------------------------------------------------
    def housekeeping(self):
        now = time.time()
        if now - self._last_housekeeping < 15:
            return
        self._last_housekeeping = now

        if self.reload_requested:
            self.reload_requested = False
            ok, msg = self.corpus.reload_if_changed(force=True)
            if msg:
                self.recorder.event("corpus_reload", level="info" if ok else "warn",
                                    detail=msg)
        else:
            ok, msg = self.corpus.reload_if_changed()
            if msg:
                self.recorder.event("corpus_reload", level="info" if ok else "warn",
                                    detail=msg)

        # Drop sessions whose stream the demux has already closed or forgotten.
        live = set(self.demux.streams)
        for key in [k for k in self.sessions if k not in live]:
            sess = self.sessions.pop(key)
            try:
                sess["rec"].close()
            except Exception:                          # noqa: BLE001
                pass

        # counted_calls exists only to count each call once. Left to grow it is
        # ~864k Call-IDs a day at 10 CPS, forever, on a daemon meant to run for
        # weeks -- against tap.py's own rule that bounded memory is a
        # correctness property here. The SIP tracker has already expired
        # anything finished, so anything it no longer knows about is done.
        if len(self.counted_calls) > 10000:
            self.counted_calls &= set(self.tracker.calls)

        self.counters.check_alerts(self.recorder)
        self.counters.save()

    # -- run ----------------------------------------------------------------
    def preflight(self):
        lines = []
        cfg = self.cfg
        lines.append(("mode", cfg.mode.upper() +
                      ("  (ENFORCING -- calls will be disconnected)"
                       if cfg.enforce else "  (logging only, nothing is hung up)")))
        lines.append(("corpus", "%d phrase(s) %s from %s"
                      % (len(self.corpus.phrases), self.corpus.counts(),
                         cfg.corpus_path)))
        lines.append(("languages", ",".join(cfg.langs)))
        lines.append(("customer IPs", ",".join(cfg.customer_ips) or "NONE SET"))
        lines.append(("media IPs", ",".join(cfg.media_ips) or "NONE SET"))
        lines.append(("bpf", self.tap.bpf()))
        lines.append(("gate", "RMS >= %.0f for %.1fs"
                      % (cfg.gate_rms, cfg.gate_seconds)))
        lines.append(("thresholds", "kill=%.2f review=%.2f pair=%.2f/%.2f "
                                    "edit_ratio=%.2f"
                      % (cfg.thresholds.kill, cfg.thresholds.review,
                         cfg.thresholds.pair_kill, cfg.thresholds.pair_review,
                         cfg.thresholds.edit_ratio)))
        lines.append(("B scorer", "threshold=%.1f window=%.0fs C1=%.1f C2=%.1f"
                      % (self.scorer.threshold, cfg.window_s,
                         self.scorer.c1_weight, self.scorer.c2_weight)))
        lines.append(("ASR", self.asr.status))

        ami = probe_ami(cfg.manager_conf)
        lines.append(("AMI", ("ENABLED" if ami["enabled"] else
                              "disabled" if ami["enabled"] is False
                              else "unknown") + " -- " + (ami["note"] or "")))
        if not self.pcap:
            up = self.cli.available()
            lines.append(("asterisk CLI", "reachable" if up else
                          "NOT REACHABLE -- hangups impossible, detection only"))
        lines.append(("log dir", cfg.log_dir))
        lines.append(("counters", cfg.state_path))
        lines.append(("heuristic resolve",
                      "ALLOWED" if cfg.allow_heuristic else
                      "refused (exact SBC_CALLID only)"))

        problems = []
        if not cfg.customer_ips:
            problems.append(
                "PK_CLIENT_IPS is empty. Without it the customer-leg filter "
                "cannot tell the customer from the carrier, and that is the "
                "one filter that must not fail open permissively.")
        if not self.pcap and not _which("tcpdump"):
            problems.append("tcpdump is not on PATH; the tap cannot start.")
        if cfg.enforce and cfg.script_path:
            problems.append(
                "PHRASEGUARD_ENFORCE=1 with a scripted recogniser (%s). A "
                "script that can disconnect live calls has no legitimate use. "
                "Refusing." % cfg.script_path)
        elif cfg.enforce and self.asr.model is None:
            problems.append(
                "PHRASEGUARD_ENFORCE=1 with no working recogniser. Enforcement "
                "without ASR cannot disconnect anything and only creates the "
                "impression of coverage. Refusing.")
        if cfg.enforce and cfg.allow_heuristic:
            problems.append(
                "PHRASEGUARD_ENFORCE=1 together with "
                "PHRASEGUARD_ALLOW_HEURISTIC_MATCH=1. Enforcement must not run "
                "on a heuristic Call-ID resolution -- the failure mode is "
                "disconnecting a different customer's legitimate call.")
        return lines, problems

    def run(self):
        lines, problems = self.preflight()
        for k, v in lines:
            sys.stderr.write("  %-18s %s\n" % (k, v))
        if problems:
            for p in problems:
                sys.stderr.write("\n  REFUSING: %s\n" % p)
            return 1

        self.recorder.event("start", mode=self.cfg.mode,
                            detail="corpus=%d phrases asr=%s"
                                   % (len(self.corpus.phrases),
                                      "vosk" if self.asr.model else "none"))
        if self.cfg.enforce:
            health("warn", "PhraseGuard started in ENFORCE mode: Tier A "
                           "matches will disconnect calls.")
        else:
            health("info", "PhraseGuard started in shadow mode (no hangups).")

        try:
            self.tap.run(on_audio=self.on_audio,
                         stop=self._stop_check)
        except KeyboardInterrupt:
            pass
        except Exception as e:                         # noqa: BLE001
            # Fail open, loudly. The tap dying must be visible, and must not
            # be the last thing this process does silently.
            self.recorder.event("fatal", level="crit", detail=str(e))
            health("crit", "PhraseGuard tap stopped: %s. Calls are unaffected; "
                           "detection is OFF until it is restarted." % e)
            self.shutdown()
            return 1
        self.shutdown()
        return 0

    def _stop_check(self):
        self.housekeeping()
        return self.stopping

    def shutdown(self):
        for sess in self.sessions.values():
            try:
                sess["rec"].close()
            except Exception:                          # noqa: BLE001
                pass
        self.sessions.clear()
        self.counters.save()
        self.recorder.event("stop", mode=self.cfg.mode, **self.stats)
        self.recorder.close()
        self.tap.close()


def _which(prog):
    for d in (os.environ.get("PATH") or "").split(os.pathsep):
        if d and os.path.exists(os.path.join(d, prog)):
            return True
    return False


def _lock(path):
    """Single instance. Two taps would double every count in the evidence log."""
    try:
        fd = os.open(path, os.O_CREAT | os.O_RDWR, 0o644)
    except OSError:
        return None
    import fcntl
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError as e:
        os.close(fd)
        if e.errno in (errno.EACCES, errno.EAGAIN):
            return False
        return None
    os.ftruncate(fd, 0)
    os.write(fd, ("%d\n" % os.getpid()).encode())
    return fd


def _status(cfg):
    import glob
    import json as _json
    files = sorted(glob.glob(os.path.join(cfg.log_dir, "phraseguard-*.jsonl")))
    if not files:
        print("no JSONL under %s -- nothing has been recorded" % cfg.log_dir)
        return 0
    tiers = {}
    phrases = {}
    total = 0
    for path in files[-7:]:
        try:
            with open(path, "r", encoding="utf-8") as fh:
                for line in fh:
                    try:
                        r = _json.loads(line)
                    except ValueError:
                        continue
                    if r.get("event") != "match":
                        continue
                    total += 1
                    key = "%s/%s" % (r.get("tier"), r.get("category"))
                    tiers[key] = tiers.get(key, 0) + 1
                    p = r.get("phrase")
                    if p:
                        phrases[p] = phrases.get(p, 0) + 1
        except OSError:
            continue
    print()
    print("PhraseGuard matches across %d file(s): %d" % (len(files[-7:]), total))
    print()
    print("  by tier/category")
    for k in sorted(tiers, key=lambda x: -tiers[x]):
        print("    %-12s %6d" % (k, tiers[k]))
    print()
    print("  per-phrase hit counts (top 25) -- every DISTINCT Tier A phrase")
    print("  below must be hand-reviewed before enforcement ships")
    for p in sorted(phrases, key=lambda x: -phrases[x])[:25]:
        print("    %6d  %s" % (phrases[p], p))
    print()
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--pcap", help="replay a capture; never touches Asterisk")
    ap.add_argument("--self-test", action="store_true",
                    help="preflight only; starts nothing")
    ap.add_argument("--status", action="store_true",
                    help="summarise what has been recorded")
    ap.add_argument("--enforce", action="store_true",
                    help="override PHRASEGUARD_ENFORCE=0. Think first.")
    ap.add_argument("--shadow", action="store_true",
                    help="force shadow mode regardless of the environment")
    ap.add_argument("--script",
                    help="TEST ONLY: read utterances from this file instead of "
                         "decoding audio. Refused with --enforce.")
    ap.add_argument("--config", help="source this config.env before starting")
    ap.add_argument("--lock", default=DEFAULT_LOCK)
    a = ap.parse_args(argv)

    if a.config:
        _source_env(a.config)

    cfg = Config(args=a)
    if a.status:
        return _status(cfg)

    sys.stderr.write("\nphraseguardd  %s\n\n" % time.strftime("%Y-%m-%dT%H:%M:%SZ",
                                                              time.gmtime()))
    try:
        pg = PhraseGuard(cfg, pcap=a.pcap)
    except Exception as e:                             # noqa: BLE001
        sys.stderr.write("  REFUSING: %s\n\n" % e)
        return 1

    if a.self_test:
        lines, problems = pg.preflight()
        for k, v in lines:
            sys.stderr.write("  %-18s %s\n" % (k, v))
        sys.stderr.write("\n")
        for p in problems:
            sys.stderr.write("  REFUSING: %s\n" % p)
        if not problems:
            sys.stderr.write("  Preflight passed. Nothing was started and "
                             "nothing was changed.\n")
        sys.stderr.write("\n")
        return 1 if problems else 0

    if not a.pcap:
        held = _lock(a.lock)
        if held is False:
            sys.stderr.write("  another phraseguardd holds %s\n\n" % a.lock)
            return 1
        if held is None:
            # Could not open or flock the file at all. Refusing rather than
            # running unlocked: two taps double every count in the evidence
            # log, and those counts are what argue for suspending a customer
            # trunk. A lock that cannot be taken is not a lock that is free.
            sys.stderr.write(
                "  REFUSING: cannot take the single-instance lock %s.\n"
                "  Running unlocked risks a second instance double-counting\n"
                "  every match. Fix the path or pass --lock elsewhere.\n\n"
                % a.lock)
            return 1
    pg.install_signals()
    rc = pg.run()
    sys.stderr.write("\n")
    return rc


def _source_env(path):
    """Read KEY=VALUE out of a config.env into the environment.

    Deliberately not a shell source: config.env is read by root-run scripts on
    a border element and this process should not execute it.
    """
    try:
        with open(path, "r", encoding="utf-8") as fh:
            for raw in fh:
                line = raw.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                k = k.strip()
                v = v.strip().strip('"').strip("'")
                if k and k not in os.environ:
                    os.environ[k] = v
    except OSError as e:
        sys.stderr.write("  cannot read %s: %s\n" % (path, e))


if __name__ == "__main__":
    sys.exit(main())
