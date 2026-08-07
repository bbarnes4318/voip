# Wholesale VOIP SBC

A standalone Session Border Controller. It accepts outbound call traffic from
one wholesale customer over IP authentication and terminates it to FracTEL
over a dedicated subaccount trunk.

Asterisk 20 LTS with `res_pjsip`, installed on the host. No Kamailio, no
rtpengine, no Docker, no web UI.

```
PK_CLIENT_IP_1 ──┐
                 ├──► [ SBC — ONE public IP ] ──► FracTEL (6 outbound proxies)
PK_CLIENT_IP_2 ──┘      Asterisk 20 LTS / res_pjsip
                        B2BUA, IP auth both sides
                        full media relay
```

## The constraint this exists to solve

FracTEL authorizes exactly **one** source IP per trunk. The customer has
**two** IPs.

That is not a conflict, and it must not be solved with NAT tricks or a second
trunk. The SBC is a back-to-back user agent: it terminates the customer's call
leg and originates a brand-new leg toward FracTEL from its own single address.
Both customer IPs converge into one outbound identity. FracTEL only ever sees
the SBC.

**This only holds if media actually transits the box.** If RTP flowed directly
from Pakistan to FracTEL, FracTEL would see media from an address it has never
authorized, and the call would get one-way audio or drop. So:

- `direct_media=no` on every endpoint, with `disable_direct_media_on_nat=yes`
  and `direct_media_method=invite` as belt and braces
- no `bypass_media` anywhere, no re-INVITE path back to direct media
- ICE and STUN are off, so nothing can advertise a candidate address other
  than the SBC's own
- acceptance criterion 10 asserts that zero RTP packets flow directly between
  the customer address and the carrier address

## Defence in depth

Three layers, each of which independently refuses anything not explicitly
permitted. No single point of failure.

| | Control | Where | Fails closed because |
|---|---|---|---|
| 1 | Host firewall | `firewall.sh` → nftables | `policy drop` on input; four addresses have rules, nothing else does |
| 2 | SIP ACL | `[sbc-acl]` + `type=identify` in `pjsip.conf` | `deny=0.0.0.0/0.0.0.0` first, explicit permits after; `endpoint_identifier_order=ip` and `identify_by=ip` mean a source cannot claim an identity in a header |
| 3 | Dialplan | `[sbc-customer]` in `extensions.conf` | one `Dial()` target, no includes, no `Local/`, and `res_agi`/`app_system`/`func_shell`/`app_originate` are not loaded |

The dialplan checks, in order: killswitch → destination allowlist → caller ID
→ CPS → concurrency → dial. Destination is validated *before* a concurrency
slot is consumed, so a flood of junk destinations cannot starve legitimate
traffic out of the cap.

Every rejection logs `SBC-REJECT reason=<REASON>` with the source IP, caller
ID, destination and Call-ID.

## Fraud controls

**NANP-only destination allowlist** (`NANP_ONLY=true`, default on). Only
`_1NXXNXXXXXX` and `_NXXNXXXXXX` are dialable, normalized to 11 digits.
Everything else gets 503. This is the single most valuable control here: if
the customer's box is ever compromised, it blocks the classic premium-rate
international fraud (+252, +881, satellite ranges) that turns into a
five-figure bill overnight.

**High-risk NANP area codes** (`BLOCK_HIGH_RISK_NPA=true`, default on).

> This is an addition beyond the brief, and it matters. NANP-only is **not**
> sufficient on its own — the entire Caribbean is *inside* the NANP and
> matches `_1NXXNXXXXXX` perfectly while costing dollars a minute. +1-876
> (Jamaica), +1-809/829/849 (Dominican Republic), +1-284 (BVI), +1-649 (Turks
> and Caicos) are *the* classic IRSF and wangiri destinations. A NANP-only
> rule with no NPA denylist looks safe and is not. The default list also
> covers 900 premium and the 976 NXX. US territories — 787/939 Puerto Rico,
> 340 USVI, 671 Guam — are deliberately **not** blocked; they are ordinary US
> destinations. The customer dials US consumers, so this should stay on.

**Per-IP concurrency cap** (`MAX_CONCURRENT_PER_IP`, default 50) via
`GROUP()`/`GROUP_COUNT()`, keyed on the endpoint name so each customer IP has
its own budget. Over-cap gets 503 and a loud NOTICE.

**CPS limit** (`MAX_CPS`, default 10), counted across both customer IPs
combined — FracTEL's fraud system reacts to the aggregate arriving from our
one source address, not per-endpoint.

**Caller ID validation** (`VALIDATE_CALLERID=true`, default on). Rejects
empty, alphabetic, shorter than 10 digits, invalid NPA, or CID identical to
the destination — with **403**, not 503, so a dialer treats it as "fix your
config" rather than "retry later". The CID itself is passed through
byte-for-byte and is never rewritten or invented (`NORMALIZE_CALLERID=false`
by default). It is logged on every call.

On attestation: FracTEL signs, and customer-supplied CID gets **B**
attestation. That is correct and expected — A is only for CID that is a
FracTEL DID. Nothing here attempts to force A, and nothing should.

## Repo layout

```
config.env.example      every placeholder, documented. Copy to config.env.
render.sh               templates -> /etc/asterisk. No IP is hardcoded anywhere else.
install.sh              idempotent: packages, config, systemd units, validation
firewall.sh             idempotent nftables, with auto-rollback so you cannot lock yourself out
killswitch.sh           on | on --hard | off | status | restore
monitor.sh              live: channels, per-IP concurrency, CPS, ASR, ACD
healthcheck.sh          exit 0/1/2 on trunk and box health; runs on a systemd timer

asterisk/*.tpl          rendered configs. Only .tpl is tracked; rendered .conf is gitignored.
tests/                  SIPp scenarios + driver. Read tests/README.md first.
```

## Quick start

```bash
cp config.env.example config.env && chmod 600 config.env && $EDITOR config.env
```

```bash
sudo ./install.sh
```

Then, **from a second SSH session**, once you have confirmed you still have
access:

```bash
sudo ./firewall.sh confirm
```

Full procedure, test-day checklist and rollback are in
[RUNBOOK.md](RUNBOOK.md).

## CDR

CSV is the system of record at `/var/log/asterisk/cdr-custom/sbc.csv`, written
synchronously (no batching — a CDR lost to a crash is a call that cannot be
reconciled or traced). Postgres is mirrored in addition if `PG_DSN` is set;
CSV alone is sufficient to run the test.

Column order, defined in `asterisk/cdr_custom.conf.tpl`:

```
timestamp_start, timestamp_answer, timestamp_end, source_ip,
customer_endpoint, caller_id, destination, duration, billsec,
disposition, hangup_cause, fractel_gateway_used, sip_call_id,
reject_reason, uniqueid
```

`billsec` is **raw whole seconds**. It is deliberately not pre-rounded to 6-
or 12-second billing increments — rounding is a downstream calculation, and
doing it at the source destroys the ability to reconcile against FracTEL's own
CDR.

`source_ip` and `sip_call_id` are set at the very top of the dialplan, before
any check can reject the call, so even a refused call produces a complete row.
Those two columns are what gets handed over on a traceback request, and there
is a 24-hour clock on answering one.

Rejected calls produce CDR rows (`unanswered=yes`, `congestion=yes`) with
`reject_reason` populated. Every field is `CSV_QUOTE`d, because caller ID is
attacker-controlled text that will eventually contain a comma.

## Decisions where safety beat convenience

These are flagged because each one is a deviation, a cost, or a thing a future
reader will want to undo without knowing why it is there.

**AMI is off entirely, not bound to loopback.** The brief allowed loopback.
Nothing needs it — `monitor.sh`, `killswitch.sh` and `healthcheck.sh` all use
`asterisk -rx` over the local control socket. Turning it off removes a TCP
listener, a credentials file and a whole class of incident.

**`killswitch.sh on` is soft by default.** The brief asked for "disable the
endpoints and drop their firewall rules". Dropping the firewall rules also
drops in-dialog BYEs and the RTP of calls already up, so every live call hangs
until timeout instead of tearing down — which on the FracTEL side looks like a
burst of abandoned calls, exactly the pattern a carrier's fraud system reacts
to. So `on` sets a dialplan global that refuses new INVITEs with 503 in well
under a second while in-progress calls finish normally, and `on --hard` does
the full firewall cut for when you genuinely need the cable pulled. Both
persist across reboot.

**`autoload=yes` with a denylist, not `autoload=no` with an allowlist.** The
allowlist is the stronger posture and also the one that breaks the box at 3am
over a missed transitive dependency. The denylist closes every path the threat
model cares about — command execution, remote-control APIs, alternate channel
drivers — and nothing loaded is network-reachable anyway. Moving to a curated
allowlist is the right hardening follow-up once the deal closes.

**Transports bind `0.0.0.0`, not the public IP.** A transport bound only to
the public address cannot be reached over loopback, and the entire on-box
acceptance suite would be impossible. Exposure is unchanged: layer 1
default-DROPs and layer 2 denies by default.

**`firewall.sh apply` arms an auto-rollback.** It refuses to load a ruleset
that would drop the SSH session you are running it from, and tears the table
down again after 90 seconds unless you run `firewall.sh confirm` from a second
session. Locking yourself out of a remote Hetzner box on test-day eve is a
real failure mode.

**Failover does not retry BUSY or NOANSWER.** Only `CONGESTION` and
`CHANUNAVAIL` walk to the next gateway. Retrying a busy signal on another
proxy dials the same consumer twice, and that generates complaints.

## Isolation from `hoppwhistle`

Nothing here reads, imports from, or writes to that repo. Separate box,
separate FracTEL subaccount, separate public IP. The isolation is the point:
it keeps wholesale traceback exposure off the address carrying your own
campaigns. Do not merge configuration between them, and do not reuse the
FracTEL proxy list from that box — this is a different subaccount and the
proxy set can differ.

## Not built, on purpose

Billing portal, rating engine, web UI, multi-tenancy, Kamailio, rtpengine,
HA/floating IP, Docker orchestration, migrations framework, CI. Those come
later if the deal closes.
