#!/usr/bin/env python3
"""Call-ID -> Asterisk channel -> out-of-band hangup.

THIS IS THE ENGINEERING RISK IN THE WHOLE COMPONENT. Everything upstream is
worthless if a Call-ID observed on the wire cannot be turned into a channel
name that `channel request hangup` accepts. tools/phraseguard-spike.sh drives
this module against live traffic and measures it; nothing else should ship
until that has been run.

HOW THE MAPPING WORKS
---------------------
The dialplan ALREADY records it. asterisk/extensions.conf.tpl, in
[sbc-customer], line ~187:

    same => n,Set(__SBC_CALLID=${CHANNEL(pjsip,call-id)})

The double underscore makes it inherited, and it is set early, before the
caller-ID rewrite and before the Dial. `core show channel <name>` prints a
Variables: block, so the Call-ID is readable from the CLI on a live channel
with no AMI, no ARI, and no change to any config file. The mapping is EXACT --
it is the dialplan's own copy of the same header we parsed off the wire, not
an inference.

This is a read of something already there. It is emphatically not a dialplan
change, and it needs none.

WHY THE OBVIOUS JOIN DOES NOT WORK
----------------------------------
The first design for this joined on (endpoint, ANI, DNIS, channel age) out of
`core show channels concise`. It does not work, and the reason is worth
recording so nobody rebuilds it: extensions.conf.tpl line ~428 does

    same => n,Set(CALLERID(num)=${SBC_DID})

on the CUSTOMER-LEG channel, before the Dial. By the time a channel is
visible to the CLI its cid_num is the DID the pool assigned, not the ANI the
customer sent in the INVITE. Joining on ANI would silently match nothing, or
worse, match the wrong call once two floors were assigned the same DID.

(endpoint, dialed extension, channel age) survives the rewrite and is kept
below as a FALLBACK, for the case where SBC_CALLID turns out not to be
readable. It is a heuristic, it is documented as one, and it refuses on
ambiguity rather than guessing.

AMI
---
AMI is OFF on this box, deliberately. asterisk/manager.conf.tpl sets
enabled=no and webenabled=no and explains why: monitor.sh, killswitch.sh and
healthcheck.sh all drive Asterisk through `asterisk -rx` over the local
control socket, which is already root/asterisk-group restricted by file
permissions, and turning AMI on would add a TCP listener and a credentials
file for no gain. probe_ami() below reads the LIVE manager.conf rather than
assuming, because the brief asked for what is actually there.

The consequence: hangups fork `asterisk -rx`. That is one fork per Tier A
kill, not per packet and not per call, and Tier A kills are rare by
construction. If AMI is ever enabled, AmiHangup below is the place to add a
persistent connection; the interface is already the right shape for it.

THE 490-BYTE LIMIT
------------------
RUNBOOK.md §  records that `asterisk -rx` truncates around 490 bytes of total
command, and that the failure mode is a CLI that returns success while the
command did not take effect. A hangup command is ~60 bytes so it is not at
risk -- but that is only true one at a time. Nothing here batches, and
hangup() refuses a channel name long enough to approach the limit rather than
issuing a command that might silently do nothing.

FAIL OPEN, AND FAIL CLOSED ON DOUBT
-----------------------------------
Two different rules, both load-bearing:

  fail open   any error resolving or hanging up is logged and swallowed. A
              broken actuator must never affect a call.
  fail closed on doubt
              an AMBIGUOUS resolution never hangs anything up. Killing the
              wrong call is worse than missing a scam call, because the wrong
              call belongs to a legitimate campaign on the same trunk.
"""
import os
import re
import subprocess
import time

# `asterisk -rx` truncates around here. See RUNBOOK.md. Not a risk for a
# hangup, enforced anyway so it cannot become one.
RX_COMMAND_LIMIT = 490

_VAR_LINE = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$")


def _digits(s):
    return "".join(c for c in (s or "") if c.isdigit())


# ---------------------------------------------------------------------------
# Talking to Asterisk
# ---------------------------------------------------------------------------
class AsteriskCLI(object):
    """`asterisk -rx` with a timeout, and never a shell.

    No shell: channel names come from Asterisk, but the Call-ID they are
    matched against comes off the wire and is attacker-controlled. Nothing
    built from network input should ever reach a shell on this box.
    """

    def __init__(self, binary="asterisk", timeout=5.0):
        self.binary = binary
        self.timeout = timeout
        self.calls = 0
        self.errors = 0
        self.seconds = 0.0

    def rx(self, command):
        if len(command) >= RX_COMMAND_LIMIT:
            raise ValueError("command is %d bytes, at or over the ~%d-byte "
                             "`asterisk -rx` truncation limit (RUNBOOK.md); "
                             "refusing rather than issuing a command that may "
                             "silently no-op" % (len(command), RX_COMMAND_LIMIT))
        self.calls += 1
        t0 = time.time()
        try:
            out = subprocess.run([self.binary, "-rx", command],
                                 stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE,
                                 timeout=self.timeout)
            return out.stdout.decode("utf-8", "replace")
        except Exception:                              # noqa: BLE001
            self.errors += 1
            return ""
        finally:
            self.seconds += time.time() - t0

    def available(self):
        return "Asterisk" in self.rx("core show version")


def probe_ami(manager_conf="/etc/asterisk/manager.conf"):
    """Report what manager.conf actually says. Never assume; the brief asked.

    Returns a dict with enabled/webenabled/bindaddr/port/users and the reason
    it could not tell, if it could not.
    """
    info = {"path": manager_conf, "readable": False, "enabled": None,
            "webenabled": None, "bindaddr": None, "port": None, "users": [],
            "note": ""}
    try:
        with open(manager_conf, "r", encoding="utf-8", errors="replace") as fh:
            text = fh.read()
        info["readable"] = True
    except OSError as e:
        info["note"] = "cannot read %s: %s" % (manager_conf, e)
        return info

    section = None
    for raw in text.split("\n"):
        line = raw.split(";", 1)[0].strip()
        if not line:
            continue
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1].strip()
            if section != "general":
                info["users"].append(section)
            continue
        if "=" not in line:
            continue
        k, v = (x.strip().lower() for x in line.split("=", 1))
        if section == "general":
            if k == "enabled":
                info["enabled"] = v in ("yes", "true", "on", "1")
            elif k == "webenabled":
                info["webenabled"] = v in ("yes", "true", "on", "1")
            elif k == "bindaddr":
                info["bindaddr"] = v
            elif k == "port":
                info["port"] = v
    if info["enabled"] is False:
        info["note"] = ("AMI is disabled. Hangups will fork `asterisk -rx`, "
                        "which is what monitor.sh, killswitch.sh and "
                        "healthcheck.sh already do.")
    elif info["enabled"]:
        info["note"] = ("AMI is ENABLED (bind %s:%s, %d user section(s)). A "
                        "persistent AMI connection would be preferable to "
                        "forking per event -- see AmiHangup."
                        % (info["bindaddr"], info["port"], len(info["users"])))
    return info


# ---------------------------------------------------------------------------
# Channel table
# ---------------------------------------------------------------------------
class Channel(object):
    __slots__ = ("name", "context", "exten", "state", "cid_num", "duration",
                 "uniqueid", "call_id", "endpoint", "probed", "probe_misses")

    def __init__(self, name):
        self.name = name
        self.context = ""
        self.exten = ""
        self.state = ""
        self.cid_num = ""
        self.duration = 0
        self.uniqueid = ""
        self.call_id = None
        self.endpoint = None
        self.probed = False
        self.probe_misses = 0

    def __repr__(self):
        return "<Channel %s callid=%r>" % (self.name, self.call_id)


class ChannelTable(object):
    """Live channels, with their SIP Call-IDs, cached.

    Two-level caching, because the two facts age at very different rates:

      the channel LIST changes constantly and is refreshed on a short TTL
      with one `core show channels concise`.

      a channel's Call-ID never changes for the life of the channel, so it is
      probed once with `core show channel <name>` and kept until the channel
      goes away. Steady-state cost is therefore one fork per NEW call, not one
      per lookup -- which is what makes this affordable at 10 CPS.
    """

    # `core show channels concise` is '!'-separated. The field order has been
    # stable for many major versions, but this parses by count and exposes
    # the raw line through spike --dump rather than trusting the layout: a
    # silently shifted column here is a resolver that matches nothing.
    # How many times a channel may answer `core show channel` without an
    # SBC_CALLID before it is written off. A few passes covers the setup race;
    # beyond that the dialplan does not set it and retrying is pure cost.
    MAX_PROBE_MISSES = 4

    CONCISE_FIELDS = 14
    F_NAME, F_CONTEXT, F_EXTEN, F_PRIO, F_STATE = 0, 1, 2, 3, 4
    F_CID = 7
    F_DURATION = 11
    F_UNIQUEID = 13

    def __init__(self, cli, list_ttl=1.0, channel_prefix="PJSIP/",
                 endpoints=None):
        self.cli = cli
        self.list_ttl = list_ttl
        self.channel_prefix = channel_prefix
        # Only these endpoints are worth probing. `__SBC_CALLID` is set in
        # [sbc-customer], so the carrier legs either never carry it or carry a
        # copy we have no use for -- the channel PhraseGuard hangs up is always
        # the customer leg.
        #
        # The first live spike showed the cost: 10 channels probed, 5 with no
        # SBC_CALLID, and each of those burns MAX_PROBE_MISSES forks before it
        # is written off. Filtering removes that entirely. None means probe
        # everything, which is what the spike does when it has no endpoint map.
        self.endpoints = frozenset(endpoints) if endpoints else None
        self.channels = {}
        self.by_call_id = {}
        self.last_list = 0.0
        self.probe_failures = 0
        self.layout_warning = None

    def refresh(self, force=False):
        now = time.time()
        if not force and now - self.last_list < self.list_ttl:
            return self.channels
        self.last_list = now
        out = self.cli.rx("core show channels concise")
        seen = set()
        for line in out.split("\n"):
            line = line.strip()
            if not line or "!" not in line:
                continue
            f = line.split("!")
            if len(f) < self.CONCISE_FIELDS:
                if self.layout_warning is None:
                    self.layout_warning = (
                        "`core show channels concise` returned %d fields, "
                        "expected %d. Field indices in ChannelTable are wrong "
                        "for this Asterisk build; run "
                        "tools/phraseguard-spike.sh --dump and fix them before "
                        "trusting any resolution." % (len(f), self.CONCISE_FIELDS))
                continue
            name = f[self.F_NAME]
            if not name.startswith(self.channel_prefix):
                continue
            seen.add(name)
            ch = self.channels.get(name)
            if ch is None:
                ch = Channel(name)
                self.channels[name] = ch
            ch.context = f[self.F_CONTEXT]
            ch.exten = f[self.F_EXTEN]
            ch.state = f[self.F_STATE]
            ch.cid_num = f[self.F_CID]
            try:
                ch.duration = int(f[self.F_DURATION] or 0)
            except ValueError:
                ch.duration = 0
            ch.uniqueid = f[self.F_UNIQUEID]
            # PJSIP/pkclient2-000027a1 -> pkclient2
            body = name[len(self.channel_prefix):]
            ch.endpoint = body.rsplit("-", 1)[0] if "-" in body else body

        for name in [n for n in self.channels if n not in seen]:
            ch = self.channels.pop(name)
            if ch.call_id and self.by_call_id.get(ch.call_id) == name:
                self.by_call_id.pop(ch.call_id, None)
        return self.channels

    def probe(self, channel):
        """Read SBC_CALLID off one channel. One fork per channel, until it works.

        `probed` is set only on a SUCCESSFUL read, never before the CLI call.
        Marking it up front looked like cheap loop protection and was a trap:
        AsteriskCLI.rx swallows every error and returns "", so one transient
        failure -- or, far more likely, a probe that lands in the window
        between the channel appearing in `core show channels` and the dialplan
        reaching Set(__SBC_CALLID=...) -- marked the channel unreadable for its
        entire life. That silently corrupts the spike's coverage number, which
        is the measurement the whole project is gated on.
        """
        ch = self.channels.get(channel)
        if ch is None or ch.probed:
            return ch
        out = self.cli.rx("core show channel %s" % channel)
        if not out:
            # No output at all: the CLI failed, or the channel is already
            # gone. Either way this says nothing about SBC_CALLID, so leave
            # the channel unprobed and try again on the next pass.
            return ch
        in_vars = False
        for raw in out.split("\n"):
            s = raw.strip()
            if s.lower().startswith("variables:"):
                in_vars = True
                continue
            if not in_vars:
                continue
            if not s or s.startswith("-- "):
                continue
            m = _VAR_LINE.match(s)
            if not m:
                continue
            if m.group(1) == "SBC_CALLID":
                ch.call_id = m.group(2) or None
                break
        if ch.call_id:
            ch.probed = True
            self.by_call_id[ch.call_id] = channel
        else:
            # The channel answered but carries no SBC_CALLID. Retry a bounded
            # number of times -- the variable may simply not be set yet -- then
            # stop, so a box whose dialplan genuinely lacks the Set() does not
            # fork `asterisk -rx` once per channel per pass forever.
            ch.probe_misses += 1
            if ch.probe_misses >= self.MAX_PROBE_MISSES:
                ch.probed = True
                self.probe_failures += 1
        return ch

    def probe_all(self, limit=None):
        """Probe every unprobed channel. Returns how many were probed."""
        self.refresh()
        n = 0
        for name, ch in list(self.channels.items()):
            if ch.probed:
                continue
            if self.endpoints is not None and ch.endpoint not in self.endpoints:
                ch.probed = True          # not ours; never worth a fork
                continue
            self.probe(name)
            n += 1
            if limit and n >= limit:
                break
        return n


class Resolution(object):
    __slots__ = ("channel", "how", "candidates", "ambiguous", "elapsed_ms",
                 "reason")

    def __init__(self, channel=None, how=None, candidates=(), ambiguous=False,
                 elapsed_ms=0.0, reason=""):
        self.channel = channel
        self.how = how                  # "callid" | "heuristic"
        self.candidates = list(candidates)
        self.ambiguous = ambiguous
        self.elapsed_ms = elapsed_ms
        self.reason = reason

    @property
    def ok(self):
        return bool(self.channel) and not self.ambiguous

    def __repr__(self):
        return ("<Resolution %s how=%s ambiguous=%s %.1fms %s>"
                % (self.channel, self.how, self.ambiguous, self.elapsed_ms,
                   self.reason))


class ChannelResolver(object):
    """Call-ID -> channel name, exactly where possible and never by guess."""

    def __init__(self, table, endpoint_for_ip=None, allow_heuristic=True,
                 age_tolerance_s=8.0):
        self.table = table
        self.endpoint_for_ip = endpoint_for_ip or {}
        self.allow_heuristic = allow_heuristic
        self.age_tolerance_s = age_tolerance_s
        self.stats = {"exact": 0, "heuristic": 0, "ambiguous": 0, "miss": 0}

    def resolve(self, call, now=None):
        """call is a tap.CallInfo. Returns a Resolution, always."""
        t0 = time.time()
        now = t0 if now is None else now
        self.table.refresh()

        # --- exact: the dialplan's own copy of the Call-ID ------------------
        name = self.table.by_call_id.get(call.call_id)
        if name is None:
            # Probe channels we have not looked at yet. Bounded so a burst of
            # new calls cannot turn one lookup into sixty forks.
            self.table.probe_all(limit=32)
            name = self.table.by_call_id.get(call.call_id)
        if name is not None:
            self.stats["exact"] += 1
            return Resolution(name, "callid", [name],
                              elapsed_ms=(time.time() - t0) * 1000.0,
                              reason="SBC_CALLID matched")

        if not self.allow_heuristic:
            self.stats["miss"] += 1
            return Resolution(elapsed_ms=(time.time() - t0) * 1000.0,
                              reason="no channel carries this Call-ID")

        # --- fallback: endpoint + dialed number + channel age ---------------
        # ANI is NOT usable: extensions.conf.tpl rewrites CALLERID(num) to the
        # assigned DID before the Dial. See the module docstring.
        endpoint = self.endpoint_for_ip.get(call.customer_ip)
        dnis = _digits(call.dnis)
        cands = []
        for ch_name, ch in self.table.channels.items():
            if endpoint and ch.endpoint != endpoint:
                continue
            if dnis and _digits(ch.exten) not in (dnis, dnis.lstrip("1"),
                                                  "1" + dnis.lstrip("1")):
                continue
            if call.started:
                age = now - call.started
                if abs(ch.duration - age) > self.age_tolerance_s:
                    continue
            cands.append(ch_name)

        elapsed = (time.time() - t0) * 1000.0
        if len(cands) == 1:
            self.stats["heuristic"] += 1
            return Resolution(cands[0], "heuristic", cands, elapsed_ms=elapsed,
                              reason="endpoint+DNIS+age, unique")
        if len(cands) > 1:
            self.stats["ambiguous"] += 1
            return Resolution(None, "heuristic", cands, ambiguous=True,
                              elapsed_ms=elapsed,
                              reason="%d channels match; refusing to guess"
                                     % len(cands))
        self.stats["miss"] += 1
        return Resolution(elapsed_ms=elapsed,
                          reason="no channel matched Call-ID or endpoint+DNIS+age")


# ---------------------------------------------------------------------------
# Hangup
# ---------------------------------------------------------------------------
class Hangup(object):
    """`channel request hangup <channel>`, one at a time, never batched.

    enforce=False is the shipping default and the whole of shadow mode: every
    decision is made and logged, and execute() returns without touching
    Asterisk. Turning enforcement on is a separate deliberate deploy after the
    false-positive rate has been measured, exactly as the calling-hours gate
    was introduced.
    """

    def __init__(self, cli, enforce=False):
        self.cli = cli
        self.enforce = enforce
        self.attempted = 0
        self.executed = 0
        self.refused = 0
        self.failed = 0

    def execute(self, resolution):
        """Returns (acted, detail). Never raises."""
        self.attempted += 1
        if not resolution.ok:
            self.refused += 1
            return (False, "unresolved: %s" % resolution.reason)
        chan = resolution.channel
        # Channel names are Asterisk-generated and short, but this is the last
        # gate before a command that must not silently no-op.
        cmd = "channel request hangup %s" % chan
        if len(cmd) >= RX_COMMAND_LIMIT:
            self.refused += 1
            return (False, "command too long (%d bytes)" % len(cmd))
        if not self.enforce:
            return (False, "SHADOW MODE: would hang up %s" % chan)
        try:
            out = self.cli.rx(cmd)
        except Exception as e:                         # noqa: BLE001
            self.failed += 1
            return (False, "hangup failed: %s" % e)
        self.executed += 1
        return (True, out.strip() or ("requested hangup on %s" % chan))


def endpoint_map(pk_client_ips):
    """{ip: pkclientN}, positional, matching lib/pk-clients.sh exactly.

    ORDER IS AN IDENTITY on this box: entry 1 is pkclient1 and that name is
    what the CDR bills on. This mirrors pk_client_endpoints() rather than
    reimplementing a different opinion of it.
    """
    return {ip: "pkclient%d" % (i + 1) for i, ip in enumerate(pk_client_ips)}


def main(argv=None):
    """Standalone probe: what does this box actually offer?"""
    import argparse
    import json
    ap = argparse.ArgumentParser(description="PhraseGuard actuator probe")
    ap.add_argument("--manager-conf", default="/etc/asterisk/manager.conf")
    ap.add_argument("--asterisk", default="asterisk")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args(argv)

    ami = probe_ami(a.manager_conf)
    cli = AsteriskCLI(a.asterisk)
    up = cli.available()
    table = ChannelTable(cli)
    chans = table.refresh(force=True) if up else {}
    probed = table.probe_all() if up else 0

    if a.json:
        print(json.dumps({
            "ami": ami, "asterisk_reachable": up,
            "channels": len(chans), "probed": probed,
            "with_call_id": len(table.by_call_id),
            "probe_failures": table.probe_failures,
            "layout_warning": table.layout_warning,
        }, indent=2))
        return 0

    print()
    print("AMI            %s" % ("ENABLED" if ami["enabled"] else
                                 ("disabled" if ami["enabled"] is False
                                  else "unknown")))
    print("  %s" % (ami["note"] or "manager.conf not readable"))
    print()
    print("Asterisk CLI   %s" % ("reachable" if up else "NOT REACHABLE"))
    if not up:
        print("  Nothing below could be measured.")
        return 1
    print("channels       %d (prefix %s)" % (len(chans), table.channel_prefix))
    print("probed         %d" % probed)
    print("with SBC_CALLID %d" % len(table.by_call_id))
    print("probe failures %d" % table.probe_failures)
    if table.layout_warning:
        print()
        print("LAYOUT WARNING: %s" % table.layout_warning)
    if chans and not table.by_call_id:
        print()
        print("  NO channel exposed SBC_CALLID. Either the deployed dialplan")
        print("  predates the Set(__SBC_CALLID=...) line in [sbc-customer], or")
        print("  `core show channel` on this build does not print a Variables:")
        print("  block. Exact resolution is unavailable; only the documented")
        print("  heuristic fallback remains, and enforcement MUST NOT ship on")
        print("  a heuristic. Stop and report.")
    return 0


if __name__ == "__main__":
    import sys
    sys.exit(main())
