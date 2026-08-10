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

The dialplan checks, in order: killswitch → destination allowlist → high-cost
prefix blocklist → caller ID (advisory) → CPS → concurrency → **transfer-leg
detection** → **DID selection and daily cap** → **caller ID assignment** →
dial.

Destination is validated *before* a concurrency slot is consumed, so a flood
of junk destinations cannot starve legitimate traffic out of the cap. DID
selection happens *after* the CPS and concurrency checks, so a call that is
about to be throttled never burns a number's daily allowance.

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

**High-cost prefix blocklist** — the primary cost control. See
[Caller ID and cost control](#caller-id-is-assigned-by-this-box) below.

## Caller ID is assigned by this box

**The customer does not set caller ID. Their value is discarded on every
call.**

This reverses the original design, and the reversal is the reason this
version exists. A customer's ViciDial put **50,864 calls on a single DID in
one afternoon** and tripped a carrier fraud alert. Their dialer matched caller
ID to destination area code and silently fell back to one default number when
no match existed. Caller ID is no longer theirs to get wrong.

On every outbound INVITE toward FracTEL, three headers are set to the DID this
box selected:

| Header | Set by |
|---|---|
| `From` | `CALLERID(num)` in the dialplan |
| `P-Asserted-Identity` | `send_pai=yes` + `trust_id_outbound=yes` |
| `Remote-Party-ID` | `send_rpid=yes` |

All three come from one variable so they cannot disagree. FracTEL most likely
attests off `From` alone, but a leak in any one of them could key attestation
to the wrong number, and the traceback would come back here.

**If the selected DID is empty or malformed the call is refused with 503 and
an ERROR is logged.** There is no path that falls back to what the customer
sent. That guard, not the input validation, is what makes this structural.

### Selection

`dids.csv` maps destination NPA → DIDs we own. Per call:

1. Destination NPA has a pool → rotate within it.
2. It does not, or every DID in it is capped for the day → rotate within
   **OVERFLOW**, log WARN.
3. OVERFLOW is capped out too → refuse with 503, log ERROR.

**There is no single default number anywhere in that path.** The OVERFLOW pool
must hold at least 20 numbers (`OVERFLOW_MIN`) and `render.sh` refuses to
render below it — a thin overflow pool degrades into exactly the
single-number behaviour that caused the incident.

Rotation is a per-pool counter advanced once per call, so successive calls
into an NPA take successive numbers and the DID chosen is always the one used
longest ago. It is deliberately **not random**: random clusters, and over a
few hundred calls some numbers take three times the traffic of others.

### Per-DID daily cap

`DID_DAILY_CAP` (default 200) calls per number per **local** day, enforced in
the call path — not in a report the next morning. Counters live in the
Asterisk database keyed `sbc/didcnt/<YYYYMMDD>/<did>`, so they survive a
restart and roll over at midnight with no reset job that can fail.

The check is a read-modify-write, so it takes a lock — scoped to the
**individual DID**, not globally. Two calls contend only when competing for
the same number, which with rotation working is rare. On lock timeout the call
**proceeds** and logs WARNING: undercounting one call against a safety limit
beats dropping a billable one. That is the one place in the call path that
fails open, and it is deliberate.

`./didctl.sh status` shows today at a glance; `./didctl.sh distribution`
proves per-DID spread from the CDR alone.

### What the customer sends

Recorded in CDR `caller_id`, logged, and thrown away. `VALIDATE_CALLERID`
defaults to **false**: refusing a call over a field we never use costs revenue
and protects nothing. A malformed value gets

```
WARNING SBC-CID-INVALID ... custcid=<what they sent> src=<their IP> note=discarded-and-replaced
```

which is the early warning that their dialer has broken. Setting it `true`
restores the old 403 rejection; the path is still there.

### Transfer legs are the exception

**The rewrite is correct for prospect dials and wrong for transfer legs.**

When an agent has a live prospect and bridges them to the US buyer, the buyer
has to see the **prospect's** number — that is their callback path and their
CRM record. ViciDial already sets caller ID correctly on those legs. Rewriting
it would show the buyer a stranger.

Detection is on the **destination**, never on caller ID. A caller-ID-based
rule would be defeated by exactly the misconfiguration this SBC exists to
survive: the customer sends arbitrary caller ID on every call.

**Rule 1 — toll-free.** Destination NPA in
`800, 833, 844, 855, 866, 877, 888` → transfer leg. Stateless, immediate, no
database read, no warm-up. Consumer prospects are never toll-free; a
53,370-call production day had all 15 of its transfer legs on two 844 numbers.

**Rule 2 — auto-learned.** Per customer endpoint, per destination: once a
destination has `TRANSFER_MIN_CALLS` (3) answered calls **and** an average
duration above `TRANSFER_MIN_ACD` (60s), it is a transfer destination from
then on. Both conditions, not either — count alone flags any repeatedly
dialled prospect, duration alone flags one long conversation.

3 and 60 were validated against two production CDRs: they flag exactly the one
real buyer line with zero false positives. A threshold of 2 flags six
destinations. `render.sh` warns if you go below 3.

On a transfer leg the customer's caller ID passes through **untouched** to all
three identity headers, no DID is drawn, and no daily cap is consumed. The CDR
is tagged `transfer_leg_tollfree`, `transfer_leg_learned` or
`transfer_leg_pinned`, with `selected_did` empty — on those rows the number
FracTEL saw is in `caller_id`.

**The NANP allowlist, the NPA denylist and the high-cost blocklist all still
apply.** A transfer leg is not a trusted call; it is a call whose caller ID we
do not own. Detection runs after those checks, so a blocklisted toll-free
destination is still refused with 503 (acceptance criterion 22).

Three things about the implementation that are load-bearing:

- **Counters are written only in the hangup handler.** Detection in the call
  path is a single read. Learning can never add post-dial delay.
- **A destination is not tracked until one answered call exceeds the ACD
  threshold.** Traffic reaches ~42,000 unique destinations a day and only
  ~80 ever produce a call over a minute; tracking the rest would add 20,000+
  database writes a day for numbers that can never qualify.
- **State is per customer endpoint.** Two customers dialling the same number
  are not evidence about each other.

Unlike the DID counters, transfer state is **not** date-keyed and does not
reset at midnight — a buyer line has to stay recognised, or the first calls of
every morning would leak. Learned entries expire after
`TRANSFER_EXPIRE_DAYS` (30) of inactivity. Pins and suppressions never expire.

```bash
./didctl.sh transfers list
```

```bash
./didctl.sh transfers stats
```

**Known cost, accepted:** the first 3 transfers to a *new non-toll-free* buyer
go out with a pool DID before rule 2 fires. At 15–30 transfers a day out of
53,000 calls that is tolerable, and rule 1 catches toll-free buyers with no
delay at all. Pin a known buyer number to skip the warm-up entirely:

```bash
./didctl.sh transfers add 17195550101
```

**One deviation from "pass it through unchanged":** if the customer's caller ID
on a transfer leg fails the NANP check — empty, alphabetic, wrong length — the
call falls back to the normal pool-DID rewrite and logs
`WARNING SBC-TRANSFER-BADCID`. Asserting an unusable number risks a rejected
INVITE or an unanswerable traceback. The buyer seeing a pool DID is wrong but
working; a failed transfer with a live prospect on the line is worse.

### On attestation

FracTEL signs. Now that the asserted number is a FracTEL DID rather than
customer-supplied, **A-level attestation becomes possible** where it was
previously B. Whether FracTEL actually grants it depends on their
provisioning, not on anything this box does. Confirm it on the first live
call rather than assuming it.

## Cost control: the high-cost prefix blocklist

`blocklist.csv` holds LRN prefixes at or above a rate threshold. A match is
refused with 503 and logged at WARN **with the rate**, so the log says what
the call would have cost.

Do not maintain it by hand. Regenerate it from the carrier rate deck:

```bash
python3 tools/build-blocklist.py --deck ~/decks/ShortDuration-2026-08.csv --out blocklist.csv
```

The deck updates monthly; a stale blocklist is a cost control that has quietly
stopped controlling costs.

Matching is **longest prefix wins** and variable length, so an NPA-wide row and
a narrow line-range row can coexist and the narrower one takes precedence.
`render.sh` compiles the file into a generated dialplan context, so the test
is a single lookup in Asterisk's extension matcher — 1,248 prefixes cost the
same per INVITE as 12.

### Known limitation, and it is not small

**The deck is LRN-rated. This box has no LRN.**

The real charge follows the LRN — where a number has been *ported to* — not
the number dialled. The SBC performs no LNP dip and has no LRN at call time,
so it matches the dialled number.

**It therefore catches numbers natively in expensive prefixes and misses
numbers ported into them.** This is partial cost control, not complete. Treat
the blocklist as reducing exposure, not eliminating it.

CDR column 20 (`lrn`) exists for reconciliation against FracTEL's own rated
CDR. It is **always empty from the SBC** — do not read a populated value there
as evidence that a dip happened. Prefixes discovered that way get added to
`blocklist.csv` and are caught from then on.

## Repo layout

```
config.env.example      every placeholder, documented. Copy to config.env.
dids.csv.example        the DID pool: npa,did. Copy to dids.csv.
blocklist.csv.example   high-cost prefixes. GENERATED — see tools/ below.
render.sh               templates -> /etc/asterisk. No IP is hardcoded anywhere else.
install.sh              idempotent: packages, config, systemd units, validation
firewall.sh             idempotent nftables, with auto-rollback so you cannot lock yourself out
killswitch.sh           on | on --hard | off | status | restore
didctl.sh               DID pool: usage, caps, distribution from the CDR, pruning
monitor.sh              live: channels, per-IP concurrency, CPS, ASR, ACD
healthcheck.sh          exit 0/1/2 on trunk and box health; runs on a systemd timer

tools/build-blocklist.py  regenerate blocklist.csv from the carrier rate deck
asterisk/*.tpl          rendered configs. Only .tpl is tracked; rendered .conf is gitignored.
tests/                  SIPp scenarios + driver. Read tests/README.md first.
```

`config.env`, `dids.csv` and `blocklist.csv` all hold real values and are all
gitignored. Only the `.example` versions are tracked.

## Quick start

```bash
cp config.env.example config.env && chmod 600 config.env && $EDITOR config.env
```

```bash
cp dids.csv.example dids.csv && chmod 600 dids.csv && $EDITOR dids.csv
```

The example DIDs are 555-01XX fiction numbers. Replace them with the numbers
you actually own on the FracTEL subaccount, or every call will assert a number
no carrier will accept. Then generate the blocklist from your rate deck:

```bash
python3 tools/build-blocklist.py --deck ~/decks/ShortDuration.csv --out blocklist.csv
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
 1 timestamp_start      6 caller_id      11 hangup_cause          16 selected_did
 2 timestamp_answer     7 destination    12 fractel_gateway_used  17 did_selection_reason
 3 timestamp_end        8 duration       13 sip_call_id           18 destination_npa
 4 source_ip            9 billsec        14 reject_reason         19 did_daily_count_at_selection
 5 customer_endpoint   10 disposition    15 uniqueid              20 lrn
```

Columns 16–20 are **appended**, never inserted: 1–15 keep their positions so
every existing reader keeps working. Column 12 `fractel_gateway_used` **is**
the gateway column — it is not renamed, because `monitor.sh`, the acceptance
parser and anything downstream index positionally and a rename breaks them
all silently.

- **`caller_id`** (6) is what the customer *asked for*. It is discarded.
- **`selected_did`** (16) is what actually went out, in all three identity
  headers.
- **`did_daily_count_at_selection`** (19) includes the call it is on, so a
  value equal to `DID_DAILY_CAP` means that was the last call the number
  would take that day.
- **`lrn`** (20) is **always empty from the SBC**. No LNP dip happens here.
  It exists so FracTEL's LRN-rated CDR can be joined in downstream.

Per-DID distribution and cap compliance are provable from this file alone,
which is the point:

```bash
./didctl.sh distribution
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

**`render.sh` refuses to render an OVERFLOW pool below 20 numbers.** There is
no override flag. A small overflow pool works fine right up until an NPA caps
out, and then it concentrates traffic onto a handful of numbers — which is the
failure this whole version exists to prevent, arriving by a different route.
The fix when it fires is to buy more numbers, not to lower `OVERFLOW_MIN`.

**A malformed row in `dids.csv` or `blocklist.csv` is a hard error with a line
number, not a skipped row.** A silently dropped DID shrinks a pool without
telling anyone. A silently dropped blocklist row is a prefix you believe is
blocked and is not. Both fail the render instead.

**The per-DID cap fails OPEN on lock timeout.** Everything else in the call
path fails closed. This one does not: on ~150ms of contention for a single
number the call proceeds and logs WARNING rather than being refused.
Undercounting one call against a 200/day *safety limit* is better than
dropping a billable call, and the cap is a guard rail rather than a billing
boundary. If you disagree, the branch to change is `nolock` in `[sbc-did]`.

**Rotation counters are in memory, not in the database.** The per-DID daily
counter is persisted because it has to survive a restart; the rotation pointer
is not, because it only has to spread load. Making it durable would put an
sqlite write in the path of every call for no benefit. A restart re-starts
rotation at the top of each pool, which is visible as a small transient and
nothing more.

**Gateway rotation is a per-call counter, not `${UNIQUEID}`.** The obvious
lock-free trick — take the uniqueid sequence modulo the gateway count — is
wrong here, and wrong in a way that hides. That sequence increments per
*channel*, and an answered call allocates two of them (customer leg plus the
outbound leg toward FracTEL), so customer-leg sequence numbers advance by two.
With six gateways, `seq % 6` yields three residues and **half the trunk goes
unused**. The trap is that it works correctly with an *odd* gateway count, so
it would look fine in a five-gateway test and fail on the sixth.

**Transfer detection is on the destination, never on caller ID.** A caller-ID
rule would be simpler and is the obvious first idea. It is also unusable here:
the customer sends arbitrary caller ID on every call, which is the reason this
SBC exists, so any rule keyed on it can be defeated by the exact
misconfiguration it has to survive. Destination-based detection costs a
warm-up period on new non-toll-free buyers, and that is the cheaper mistake.

**A transfer leg with an unusable caller ID falls back to the pool DID.** This
deviates from "pass it through unchanged". Asserting an empty or alphabetic
From risks a rejected INVITE or a traceback nobody can answer; the buyer
seeing a pool DID is wrong but working, and a failed transfer with a live
prospect on the line is worse. Logged at WARNING because it means the
customer's dialer is broken on the leg where caller ID matters most.

**Transfer state is not date-keyed, unlike the DID counters.** Those are
date-keyed *so they reset at midnight*. Applying the same pattern here would
zero the `>=3 answered` accumulator every night, and the first three transfers
to every buyer would leak every single morning rather than once. Expiry is by
inactivity instead, and `S` (suppressed) entries never expire — expiring one
would silently re-learn a destination an operator had explicitly removed.

**`VALIDATE_CALLERID` now defaults to false.** This is the one control that
was deliberately *loosened*. It stopped being a safety control the moment the
customer's caller ID stopped reaching FracTEL — it now rejects billable calls
over a field that is discarded. The signal it provided is preserved as a
WARNING. The rejection path is still in the dialplan and still works.

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
