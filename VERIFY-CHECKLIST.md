# VERIFY checklist

Assumptions this build rests on that have **not** been confirmed on a running
Asterisk. Each entry says what is being established, the exact command, what
output confirms it, and what changes if the answer differs.

Run these on the lab box (Asterisk 20 + SIPp, two floating IPs). None need a
carrier. Nothing here should be run against production.

Status vocabulary, used literally:

| | meaning |
|---|---|
| **VERIFIED** | ran it, output pasted |
| **SOURCE-DERIVED** | established from Asterisk source, file and line cited, not yet run |
| **UNVERIFIED** | could not run it |

---

## Already settled — no action needed

### V0.1 `func_hangupcause` is present and `HANGUPCAUSE()` is registered — **VERIFIED**

Queried read-only on production 2026-08-14:

```
func_hangupcause.so  HANGUPCAUSE related functions and applic  0  Running  core
HANGUPCAUSE(channel,type)
```

### V0.2 `app_dial` exposes ring and elapsed timers — **VERIFIED**

`asterisk -rx 'core show application Dial'` on production returns
`${RINGTIME}`, `${RINGTIME_MS}`, `${DIALEDTIME}`, `${DIALEDTIME_MS}`,
`${ANSWEREDTIME}`, `${PROGRESSTIME}` and their `_MS` variants. `RINGTIME` is
documented as *"the time from creating the channel to the first RINGING"*,
which is exactly the discriminator Phase 0 branches on. Millisecond resolution
is available, so `FAST_REJECT_SECONDS` is compared in ms.

### V0.3 603 Decline produces `DIALSTATUS=CHANUNAVAIL` — **SOURCE-DERIVED**

Supplied in the build directive and not re-derived:

```
603 → ast_sip_hangup_sip2cause(603)   res/res_pjsip.c:3593
    → AST_CAUSE_CALL_REJECTED (21)
    → handle_cause() default:          apps/app_dial.c:940
    → num.nochan++  → DIALSTATUS="CHANUNAVAIL"  apps/app_dial.c:1346
```

Confirmation is V1 below.

---

## V1 — 603 classification, both directions

**Establishes:** that 603 yields `CHANUNAVAIL` whether or not the call rang,
and that ringing is the *only* thing that distinguishes them. Phase 0's entire
split rests on this.

```bash
sipp -sf tests/sipp/uas-fractel-stub-ring-reject.xml -i 127.0.0.20 -p 5080 \
     -nostdin -bg -key code 603 -key reason Decline
```

Then place one call and read the log:

```bash
grep 'SBC-ATTEMPT' /var/log/asterisk/messages | tail -3
```

**Confirms if:** `status=CHANUNAVAIL cause=21 ring_ms=<non-zero>`, exactly one
`SBC-ATTEMPT` line for the call, and one `SBC-NO-RETRY` line.

Repeat with `uas-fractel-stub-reject.xml` (same code, no 180). **Confirms if:**
`status=CHANUNAVAIL cause=21 ring_ms=0`, two or more `SBC-ATTEMPT` lines, and
an `SBC-FAILOVER`.

**If it differs:** if 603-after-ringing reports `BUSY` rather than
`CHANUNAVAIL`, Phase 0 is a no-op for that case (BUSY was never retried) and
the harm is smaller than measured — but the immediate-603 retry path still
matters. If `ring_ms` is `0` even after a 180, the discriminator is wrong;
fall back to `${PROGRESSTIME_MS}` or to parsing 180 receipt, and the fix is in
the failover block of `asterisk/extensions.conf.tpl`.

Covered by acceptance criteria 24 and 25.

---

## V2 — `RINGTIME_MS` is reset per `Dial()` inside a retry loop

**Establishes:** that attempt 2 is not classified using attempt 1's ring time.
This is the one that would silently corrupt the classification rather than
break it visibly.

The dialplan already defends against it by clearing `RINGTIME_MS` and
`DIALEDTIME_MS` before every `Dial()`. This test confirms the defence is
actually needed and actually works.

```bash
# gateway 1 rings then declines, gateway 2 refuses instantly
# (run different scenarios on different stub ports)
grep 'SBC-ATTEMPT' /var/log/asterisk/messages | tail -5
```

**Confirms if:** the `ring_ms` on the attempt against the non-ringing gateway
is `0`, not the previous attempt's value.

**If it differs:** app_dial is not overwriting the variable on a path that
returns early. The clear-before-dial already handles it; if it does *not*, the
classification must move to a per-attempt uniqueid-scoped variable instead.

---

## V3 — a `0.0.0.0:5060` transport alongside address-specific transports on the same port

**This is the one that shapes Phase 1's transport design, and it is currently
UNVERIFIED.** Spec 1.3.

**Establishes:** whether Asterisk 20 will bind a wildcard transport and a
specific-address transport on the same port simultaneously.

Why it matters, concretely. `pjsip.conf.tpl` binds the customer transport to
`0.0.0.0:5060`, and the comment explaining why is load-bearing: the acceptance
suite runs on-box over loopback, and a transport bound only to a public address
is unreachable from `127.0.0.0/8`. But the spec's own three-route example puts
`ROUTE_2` on `bind_ip=203.0.113.11|bind_port=5060`. At the socket layer, a
`bind()` to `203.0.113.11:5060` after a wildcard `bind()` on `:5060` returns
`EADDRINUSE` unless both sockets set `SO_REUSEADDR`. Whether pjproject sets it
on transport sockets is the question, and it cannot be reasoned out — different
pjproject versions differ.

```bash
# add a second address, then render two routes on the same port with
# different bind_ip, and start Asterisk in the foreground
asterisk -C /etc/asterisk/asterisk.conf -cvvv 2>&1 | grep -iE 'transport|bind|addr'
asterisk -rx 'pjsip show transports'
```

**Confirms if:** every transport shows as bound, and `pjsip show transports`
lists both the wildcard and the address-specific ones with no
`Unable to bind` / `EADDRINUSE` in the startup output.

**If it differs — the fallback, which is a config change and not a code
change:** bind the customer transport to its own address and add a separate
loopback transport for the acceptance suite. Phase 1 therefore carries
`CUSTOMER_BIND_IP` (default `0.0.0.0`) rather than hardcoding the wildcard, so
the fallback is one edit to `config.env`. `tests/README.md` needs updating in
that case, because the suite's assumption about reaching the box over loopback
changes.

**Do this one first.** It is the only VERIFY item that can force a redesign
rather than a parameter change.

---

## V4 — RTP egresses from the correct source address per route

**The item the lab exists for.** Spec 1.4. Cannot be established any other way:
it is a kernel routing question, not an Asterisk one.

**Establishes:** that with two bound addresses, media toward a route's proxies
actually leaves from that route's `bind_ip` — not merely that SDP advertises it.

`media_address` controls what Asterisk *advertises* in SDP. It does not control
what the kernel *sends from*. `rtp.conf` sets no `rtpbindaddr`, so media binds
`0.0.0.0` and the kernel picks a source by route — which is the primary IP for
every route. Signalling would arrive from an authorised address while RTP
arrived from an unauthorised one, and the carrier would report it as one-way
audio or drop the call.

```bash
tcpdump -nni any -c 200 'udp and portrange 10000-20000' -w /tmp/rtp.pcap
tcpdump -nnr /tmp/rtp.pcap | awk '{print $3}' | cut -d. -f1-4 | sort | uniq -c
```

**Confirms if:** every RTP packet toward route N's proxy carries route N's
`bind_ip` as source, and no packet toward it carries any other local address.
Same assertion for the SIP leg on the signalling ports.

**If it differs:** `netroutes.sh` (source-based policy routing, `ip rule from
<bind_ip> lookup <table>`) is mandatory rather than optional, and `rtp.conf`
may additionally need per-route media binding. Do not deploy multi-route
without this passing — a route whose RTP leaves from the wrong address looks
exactly like a carrier fault and will be debugged as one.

---

## V5 — Hetzner address type detection

**Establishes:** which of the two Hetzner address models this box uses, so
`netroutes.sh` installs the right route.

```bash
ip -4 -o addr show
```

**Confirms if:** an address configured `/32` on the primary interface is a
Hetzner **Cloud floating IP** and needs an explicit on-link route to the
gateway; an address inside the interface's own subnet is a **Robot single IP**
and does not. `netroutes.sh` detects this rather than asking, and logs which it
found — so this entry is really "confirm the detection logged the right one".

**If it differs:** neither pattern matching, the detection has hit a third
model. Read what `ip -4 -o addr show` printed and extend the detection.

---

## V6 — `HANGUPCAUSE()` returns a usable SIP response string

**Establishes:** the mechanism behind the Phase 1 `sip_response` CDR column.

```
Set(SBC_HCK=${HANGUPCAUSE_KEYS()})
NoOp(keys=${SBC_HCK} tech=${HANGUPCAUSE(<chan>,tech)})
```

**Confirms if:** it returns something of the form `SIP 603` for the dialled
channel, so the numeric part can be parsed out.

**Watch for:** `HANGUPCAUSE_KEYS()` accumulating one key per `Dial()` across a
retry loop. If it does, the column must take the **last** key, not the first,
or every retried call reports its first attempt's response. This is why Phase 0
logs the Q.850 cause (`cause=21`) rather than the SIP string — cause is
unambiguous per attempt and needs no parsing. Establish the accumulation
behaviour before the CDR column depends on it.

**If it differs:** keep `sip_response` populated from the Q.850 cause with a
fixed cause→SIP mapping (21→603, 34→503, 17→486, 16→200), and say so in the
column comment so nobody reads it as the literal response.

---

## V7 — longest-prefix match in a generated context (Phase 3)

**Establishes:** that Asterisk's extension matcher prefers the more specific
pattern, so `[sbc-route]` gets variable-length prefixes for free the way
`[sbc-lrn-blocklist]` does.

```bash
asterisk -rx 'dialplan show sbc-route' | head -20
```

with both an NPA-level entry (`_1212.`) and an NPANXX-level entry
(`_1212555.`) present for the same NPA, then place a call to `12125551234`.

**Confirms if:** the narrower pattern wins and the logged route list is the
NPANXX one.

**If it differs:** the generated context must emit only fixed-length patterns,
padding shorter prefixes out — which multiplies the row count and needs
measuring before it ships.

---

## Open items that are not VERIFY items

**INVITE amplification is measured, but the 603 *share* is not.** The
amplification ratio is VERIFIED from production logs (2.48x on 2026-08-11 at
ring depth 7, 1.67x on 08-12 at depth 6). The claim that ~33% of traffic is
declines is **UNVERIFIED**: SIP logging is off on the box (`logger.conf` has no
SIP trace, `siptrace/` is empty) and there was no live traffic to sample when
this was checked. `hangup_cause` in the CDR does not answer it either — columns
16/34 are the dialplan's own `Hangup()` calls, not the carrier's response,
which is exactly why Phase 1 adds a `sip_response` column. The Phase 0
`SBC-ATTEMPT` log line closes this gap going forward: after one production day
with Phase 0 deployed, `cause=21` counts give the real decline share.

**`NO_DID_AVAILABLE` is the largest single rejection reason and is not part of
this build.** Over 2026-08-10..14, 36,683 calls were refused for it — 14,891 on
2026-08-12 alone, against 101,048 CDR rows that day. Every DID in the
destination NPA pool *and* every DID in overflow was at its daily cap. Route
diversity does not address this; it is pool capacity. Flagged because the
business objective of the whole build is connect rate, and this is currently a
larger leak than routing. The fix is more numbers, not a higher
`DID_DAILY_CAP`.
