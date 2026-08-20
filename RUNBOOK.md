# RUNBOOK

Deploy, verify, run the customer test, and roll back.

---

## 0. Status of this document

> **The acceptance output in section 5 has not been captured yet.**
>
> This repository was authored on a Windows workstation with no Linux host
> running Asterisk. Every command below is written out exactly as it must be
> run, but **no output has been pasted in, because none has been produced.**
> Nothing in section 5 is claimed to have passed.
>
> `tests/capture-acceptance.sh` runs the whole set on the SBC and writes a
> redacted markdown block ready to paste into section 5. Do that before you
> tell the customer the box is ready.
>
> The build itself is complete: templates, scripts, systemd units and the test
> suite are all here and internally consistent. What is missing is the
> evidence, and evidence you did not gather is not evidence.

### What HAS been verified, off-box

Three things run on a workstation without Asterisk, so they were actually run.
None of them is an acceptance criterion and none of them substitutes for one.

**1. The renderer, against real inputs.** `render.sh` was run with the example
config, the example DID pool and the example blocklist, and separately with
the test config. Both produced a complete `/etc/asterisk` set with no
unresolved placeholders. Its refusal paths were exercised individually and
each stops the render with the offending line number: an OVERFLOW pool below
20, a DID whose NXX starts with 1, a 5-digit DID, a non-numeric rate, and a
blocklist prefix that could never match.

**2. `tools/build-blocklist.py`, against a synthetic deck.** Real command
output, on invented input — `tools/testdata/sample-rate-deck.csv`, which is
tracked. It found the header three rows down, detected the columns, dropped
Alaska/Hawaii/Canada/Caribbean/toll-free/premium under `--scope conus`, kept
the worse of two rates for a duplicated prefix, and refused to write an empty
file when nothing met the threshold. **It has never seen a real deck.** Run it
against yours and check the blocked count before trusting it.

**3. The DID selection arithmetic, by transcription.** The ring-walk
expression and the cap comparison from `[sbc-did]` were transcribed into a
throwaway script and run over the criterion 13 and 14 shapes. No DID exceeded
the cap; within-pool spread was 1 call; the 6th call into a one-DID pool moved
to overflow.

> **That last one is a simulation and it is not a test.** It executes the
> same arithmetic; it does not execute Asterisk. `func_lock`, AstDB
> persistence, real concurrency and Asterisk's own expression evaluator are
> all absent from it. It can catch an off-by-one in a modulo. It cannot tell
> you the dialplan works. **Criterion 13 is not satisfied until
> `run-acceptance.sh` says so on the box.**

The same simulation is the evidence for one design decision worth recording:
across 6 gateways and 600 calls, a per-call rotor used all six at 100 calls
each, while `${UNIQUEID}`-sequence-modulo used **three of six at 200 each** —
because that sequence counts channels, not calls, and an answered call
allocates two. With 5 gateways both approaches look identical, which is
exactly why the bug would have survived a smaller test.

### The dialplan has NOT been loaded by Asterisk

No `dialplan reload`, no `pjsip reload`, no call has ever traversed it. Label
targets were checked statically (40 references, 30 labels, none dangling), but
that is a text check. The first thing to do on the box, before anything else:

```bash
sudo asterisk -rx "dialplan show sbc-customer" | head -40
```

```bash
sudo asterisk -rx "dialplan show sbc-did"
```

```bash
sudo asterisk -rx "core show function LOCK" && sudo asterisk -rx "core show function DB"
```

If `LOCK` or `DB` is missing, the per-DID cap silently stops counting.
`install.sh` checks for both and fails validation if either is absent.

---

## 1. Before you touch the box

Have these in hand. Every one of them is a placeholder in `config.env` and
guessing any of them produces a failed test rather than a working SBC.

- [ ] SBC public IPv4 (the Hetzner box, Ashburn VA)
- [ ] Your admin IP, for SSH
- [ ] FracTEL outbound proxy IPs, **from the new subaccount** — do not reuse
      the list from the `hoppwhistle` box, it is a different subaccount
- [ ] Confirmation from FracTEL that the SBC's public IP is authorized on the
      trunk, and that the trunk is **STATIC** (no registration)
- [ ] The customer's signaling IPs — all of them (`PK_CLIENT_IPS`)
- [ ] Whether the customer sources RTP from those same IPs or from a different
      block (if different: `PK_CLIENT_MEDIA_EXTRA`, or their audio dies at the
      firewall)
- [ ] **The DIDs you own on this subaccount**, with the destination area code
      each should serve. This box asserts caller ID from that list and cannot
      place a call without it. `dids.csv.example` ships 555-01XX fiction
      numbers that no carrier will accept.
- [ ] **At least 20 numbers for the OVERFLOW pool.** `render.sh` refuses to
      render below that and there is no override. Overflow absorbs every
      destination NPA you have not bought numbers in, plus every call whose
      NPA pool has capped out for the day.
- [ ] Confirmation from FracTEL that **these specific numbers are authorized
      as caller ID on this subaccount**. Asserting a DID they have not
      provisioned to you is its own kind of fraud alert. This is a separate
      question from IP authorization and it is easy to assume it is included.
- [ ] The current **ShortDuration rate deck**, exported as CSV, for
      `tools/build-blocklist.py`
- [ ] A decision on `DID_DAILY_CAP` (default 200). Pool size × cap has to
      exceed the daily volume the customer expects into each area code, or
      you will overflow constantly.

Sanity check with FracTEL before test day: *"my SBC is 
`<SBC_IP>`, it will not register, authorize it by IP on subaccount X."*
If they have it as a registering device, calls fail and the failure looks like
a problem on your side.

---

## 2. Deploy

```bash
git clone https://github.com/bbarnes4318/voip.git && cd voip
```

```bash
cp config.env.example config.env && chmod 600 config.env
```

Fill it in. `config.env` is gitignored and must stay that way.

```bash
$EDITOR config.env
```

Now the two data files. Both are gitignored, both are mandatory, and
`render.sh` refuses to run without either.

```bash
cp dids.csv.example dids.csv && chmod 600 dids.csv && $EDITOR dids.csv
```

Replace every 555-01XX number with a DID you actually own on this subaccount.
Put at least 20 in the `OVERFLOW` pool. Getting this wrong does not fail
quietly — `render.sh` reports the offending line number and stops.

Generate the blocklist from the rate deck rather than editing it by hand:

```bash
python3 tools/build-blocklist.py --deck ~/decks/ShortDuration.csv --out blocklist.csv
```

It prints a summary — rows read, in scope, below threshold, blocked, worst
rate. Sanity-check the blocked count against what you expect from the deck
before continuing. If it is wildly off, the wrong column was detected:

```bash
python3 tools/build-blocklist.py --deck ~/decks/ShortDuration.csv --list-columns
```

Dry run first — it prints what it would do and changes nothing:

```bash
sudo ./install.sh --dry-run
```

Then for real:

```bash
sudo ./install.sh
```

`install.sh` is idempotent. It backs up `/etc/asterisk` to
`/etc/asterisk.bak-<timestamp>`, re-renders every config from `config.env`,
writes the systemd units and logrotate rules, applies the firewall, restarts
Asterisk, and then checks that it came up with zero warnings and both customer
endpoints present.

### 2a. Confirm the firewall — do not skip this

`firewall.sh` arms a 90-second auto-rollback. If the ruleset locked you out,
doing nothing gets your box back.

**Open a second SSH session now** and check you can still get in. Then:

```bash
sudo ./firewall.sh confirm
```

If you cannot get in on the second session: do nothing, wait, fix
`ADMIN_SSH_IP`, re-run `sudo ./install.sh --config-only` and try again.

### 2b. Verify from off-box

The on-box test suite **cannot see your firewall** — see `tests/README.md`.
From a machine that is *not* in `ADMIN_SSH_IP`:

```bash
nmap -sT -p 22,80,443,5038,5060,8088 <SBC_PUBLIC_IP>
```

```bash
nmap -sU -p 5060,10000-10010 <SBC_PUBLIC_IP>
```

Everything must be `filtered`. `closed` is a **failure** — it means the packet
reached the host and got a response, so default-DROP is not in effect. From
your admin IP, 22 should be `open` and nothing else.

### 2c. Run the acceptance suite

On a box not yet carrying customer traffic:

```bash
cp tests/config.test.env.example tests/config.test.env
```

```bash
sudo ./tests/testenv.sh apply && sudo ./tests/capture-acceptance.sh; sudo ./tests/testenv.sh restore
```

Read `RUNBOOK-acceptance.generated.md`, satisfy yourself the redaction is
complete, and paste it into section 5 below.

### 2d. Reboot before the customer sees it

Criterion 11, and the cheapest bug you will ever find:

```bash
sudo reboot
```

```bash
systemctl is-active asterisk nftables && sudo ./firewall.sh status && ./healthcheck.sh
```

`healthcheck.sh` must exit 0. If the firewall is not loaded after a reboot,
stop and fix it — an SBC that comes back unprotected is worse than one that
does not come back at all.

---

## 3. Test-day checklist

Run through this the morning of, in order. Roughly ten minutes.

**Box**

- [ ] `./healthcheck.sh` exits 0
- [ ] `sudo ./firewall.sh status` shows the table loaded and confirmed
- [ ] `./killswitch.sh status` shows `off` and agrees with the live dialplan
- [ ] `df -h /var/log` — under 50%
- [ ] `date` — clock is correct (CDR reconciliation against FracTEL depends
      on it)

**Trunk**

- [ ] `asterisk -rx "pjsip show contacts"` — FracTEL gateways `Avail`
- [ ] One real test call of your own through the trunk, answered, with audio
      both ways

**Customer**

- [ ] `asterisk -rx "pjsip show identifies"` lists both customer IPs, and they
      match what the customer just told you (they change IPs and forget to say)
- [ ] Caps set to what you actually agreed: `grep -E 'MAX_CONCURRENT|MAX_CPS' config.env`
- [ ] `NANP_ONLY=true` and `BLOCK_HIGH_RISK_NPA=true`

**During the test**

- [ ] `./monitor.sh` open on a second screen the entire time
- [ ] Watch **ACD**. Abnormally short average duration on answered calls is
      the leading indicator of a traceback problem, and you want to catch it
      during the test rather than a week later.
- [ ] Watch the rejection counters. `CONCURRENCY_CAP` or `CPS_LIMIT` climbing
      means they are hitting your ceiling — that is a commercial conversation,
      not necessarily a fault.
- [ ] `BLOCKED_NPA` or `NOT_NANP` climbing means their list has destinations
      you are not selling them. Find out why before raising any limit.

**Traceback readiness**

- [ ] `tail -5 /var/log/asterisk/cdr-custom/sbc.csv` — `source_ip` and
      `sip_call_id` populated on every row
- [ ] `ls -la /var/log/asterisk/siptrace/` — capture is rotating

---

## 4. Operations

**Watch it**

```bash
./monitor.sh
```

**Cut the customer off, right now** — new calls refused in under a second,
calls in progress finish cleanly, FracTEL trunk untouched:

```bash
sudo ./killswitch.sh on
```

**Pull the cable** — also drops the customer addresses at the firewall,
stranding calls in progress. For active abuse only:

```bash
sudo ./killswitch.sh on --hard
```

**Restore**

```bash
sudo ./killswitch.sh off
```

**Change a limit or the DID pool** (caps, NANP toggle, gateway list,
`dids.csv`) — edit the file, then, **on a box carrying traffic**:

```bash
sudo ./render.sh -o /etc/asterisk && sudo ./didctl.sh sync-globals && ./didctl.sh pools
```

That drops no calls. `install.sh --config-only` also works and is cleaner, but
it restarts Asterisk and **every call in progress dies** — the `--config-only`
flag only skips package installation, not the restart. Use it only during a
drain window (`killswitch.sh on`, wait for channels to reach zero, restart,
`killswitch.sh off`).

> **`dialplan reload` on its own is NOT enough, and it fails silently.**
>
> `extensions.conf` sets `clearglobalvars=no` deliberately — it is what stops a
> reload wiping the killswitch and quietly restoring customer traffic while you
> believe the plug is pulled. The cost is that **`dialplan reload` does not
> apply the `[globals]` section at all**: it neither updates an existing global
> nor creates a new one.
>
> So you can render a new `dids.csv`, run `dialplan reload`, get
> `Dialplan reloaded.` and exit 0, and have Asterisk still serving the **old**
> pool. No error, no warning. Measured on the live box during the 172-DID
> rollout: after render + reload the file had 64 pools and Asterisk had 1.
>
> `didctl.sh sync-globals` reads `[globals]` out of the rendered file and
> applies each changed value with `dialplan set global` — the same runtime
> mechanism `killswitch.sh` uses. It reads every value back and exits non-zero
> if the running dialplan still disagrees with the file.

> **A pool global can be too long for the CLI to carry, and the failure looks
> like success.**
>
> `dialplan set global` goes over the Asterisk control socket, and the whole
> command stops fitting somewhere between 491 and 506 bytes. Past that the CLI
> returns success and the global **keeps its old value**.
>
> `SBC_DID_POOL_OVERFLOW` is the one that reaches it. At ~12 bytes per DID the
> ceiling is about **38 overflow numbers**. A 36-number pool produced a
> 473-byte command and fit with two numbers to spare; 236 numbers is 2,831
> bytes and cannot be applied at runtime at all.
>
> The dangerous part is that it half-applies. `SBC_DID_CNT_OVERFLOW` is short
> and updates fine, so the dialplan believes it has 236 numbers to choose from
> while it can only address 36, and **every selection past the 36th yields an
> empty DID**. Measured on this box during the 494-DID rollout.
>
> `sync-globals` now measures the command first, refuses to send one that
> cannot land, and prints the procedure below. If you see `TOO LONG FOR THE
> CLI`, the running dialplan is still serving the old pool and the only way to
> load the new one is a drain and restart:
>
> ```bash
> sudo ./killswitch.sh on
> asterisk -rx 'core show channels'   # wait for zero
> sudo systemctl restart asterisk
> sudo ./killswitch.sh off
> ```
>
> The last line is not optional: a restart clears `SBC_KILLSWITCH` (the
> dialplan does not declare it), so the persisted state and the live dialplan
> diverge across a restart. `killswitch.sh status` detects and reports that,
> and exits 2.

One thing `sync-globals` **cannot** fix: `clearglobalvars=no` also means a
global for a pool you **deleted** from `dids.csv` survives until a full
restart, so the box keeps asserting numbers you may no longer own. It detects
this and exits 2 with the orphaned NPAs listed — clearing them needs a drain
and restart.

### DID pool size ceilings

There are **three** different limits on how big a `SBC_DID_POOL_*` value can
be, they apply at three different moments, and clearing one tells you nothing
about the next. All three were measured on this box, on Asterisk 20.6.

| # | Ceiling | Applies when | Failure mode |
|---|---|---|---|
| 1 | **~490 bytes** of total command | `didctl.sh sync-globals` sets it at runtime | CLI returns success, global keeps its **old** value |
| 2 | **4095 usable bytes** of the value | **every call**, passing the pool as a `Gosub` argument | value cut **mid-number**; tail unreachable |
| 3 | **≥5999 bytes** — no ceiling found | `systemctl restart`, reading `[globals]` from the file | none observed |

The trap is that they run in that order of severity but the **opposite** order
of visibility. Ceiling 3 is the one everybody tests, and it is the one that
does not bite. Ceiling 2 is invisible to every check that inspects state
rather than behaviour.

**Ceiling 2 is the dangerous one.** `[sbc-did]` is called as

```
Gosub(sbc-did,pick,1(<key>,${GLOBAL(SBC_DID_POOL_<key>)},<count>))
```

and Asterisk expands that argument into a 4096-byte buffer — 4095 usable
characters, then it stops. At ~12 bytes per DID that is **341 numbers**.

Everything you would normally check still looks correct: `dids.csv` is right,
the rendered `extensions.conf` is right, and `dialplan show globals` reads the
value back **byte-for-byte identical to the file**, because the global really
did load. Only `SBC_P_LIST` inside the subroutine is short, and nothing prints
it.

Because `SBC_DID_CNT_<key>` is a short global that always applies cleanly, the
ring keeps walking indices the list can no longer resolve:

* index ≤ 341 — a whole number, works;
* index 342 — the number **cut mid-string**. `CUT()` returns a fragment such
  as `173`, which is non-empty, so `pick` accepts it, counts it against a
  bogus astdb key, and hands it to the caller-ID guard, which rejects the call
  `BAD_SELECTED_DID`;
* index ≥ 343 — empty. `pick` returns no DID, the call falls to overflow, and
  if overflow is the pool that truncated, the call is rejected
  `NO_DID_AVAILABLE`.

Every overrun then walks *forward* to the head of the ring, so the first ~50
numbers absorb several times their share and cap out early while most of the
pool sits idle.

Measured in production on 2026-08-20 with a 500-member OVERFLOW pool (5999
bytes), inside one traffic day: 200 `NO_DID_AVAILABLE`, 17
`BAD_SELECTED_DID`, an astdb counter keyed on the **empty string**, lock
contention on `did_` (empty), and a 3.7× selection pile-up on indices 1–50.
The `NO_DID_AVAILABLE` burst stopped on its own after exactly 200 — the daily
cap — because once the empty-string key reached `DID_DAILY_CAP` the ring
treated the unresolvable slot as capped and skipped it. **It self-heals at the
cost of `DID_DAILY_CAP` rejected calls, and it does so again every day**, when
the counters roll at 00:00 UTC.

`render.sh` now hard-fails on ceiling 2 (`DID_POOL_ARG_MAX`, default 4096) and
names how many numbers would actually be reachable. Raising that variable does
not raise the buffer — it only re-enables the silent truncation.

If you are ever caught with a pool already loaded that is over the limit, the
runtime stopgap is to shrink the **count**, not the pool. It is short enough
to clear ceiling 1, needs no restart, and drops no calls:

```bash
asterisk -rx "dialplan set global SBC_DID_CNT_OVERFLOW 335"
asterisk -rx "database del sbc/didcnt/$(date -u +%Y%m%d) \"\""   # drop the empty-string key
```

That is a patch, not a fix: a runtime global does not survive a restart, so
any unplanned restart silently reinstates the truncation. Re-render `dids.csv`
under the limit and restart at the next quiet window.

### Add a customer signaling IP

The customer brings up a new switch and it has to reach this box. Everything
downstream is generated from one line in `config.env`, but it lands in three
separate systems — Asterisk, nftables and the billing portal — and **all three
are required**. An address that clears the firewall and Asterisk but is unknown
to the portal produces calls that are carried, completed, and billed to nobody.

**1. The list.** In `config.env`, append to `PK_CLIENT_IPS`:

```bash
PK_CLIENT_IPS=<ip1>,<ip2>,<ip3>
```

Append. Never reorder, never delete from the middle. Entry 1 is `pkclient1`,
entry 2 is `pkclient2`, and that name is the CDR's `customer_endpoint` column,
the concurrency group and the transfer-state key. Reordering the list silently
re-attributes history to the wrong address; `render.sh` warns when a render
would move an existing `pkclientN`, and that warning is not advisory.

**2. Asterisk.** Render, push the globals, then reload PJSIP — on a box
carrying traffic, in this order:

```bash
sudo ./render.sh -o /etc/asterisk && sudo chown asterisk:asterisk /etc/asterisk/*.conf && sudo ./didctl.sh sync-globals && sudo asterisk -rx "pjsip reload"
```

`render.sh` installs as `asterisk:asterisk 0640` itself when run as root and
verifies the asterisk user can read every file — the explicit `chown` is belt
and braces for the case where something else wrote into `/etc/asterisk` since
the last render. Root-owned config there is what took this box down for nine
hours.

`pjsip reload` is the step the DID-pool procedure above does not need. A new
endpoint and identify only enter the running config on a PJSIP reload; without
it `render.sh` reports success, the file on disk is correct, and the new
address still gets no response. Transports set `allow_reload=no`, so the
listening sockets are untouched and calls in progress do not notice.

**3. The firewall.** nftables holds its own copy of the customer set:

```bash
sudo ./firewall.sh apply
```

Then, from a **second** SSH session, confirm within 90 seconds or the ruleset
auto-reverts:

```bash
sudo ./firewall.sh confirm
```

**4. The portal.** Add the address as an identifier on the customer, or their
calls arrive with a `source_ip` the billing side has never seen and attribute
to nobody:

```sql
INSERT INTO portal.customer_identifiers (customer_id, kind, value, note)
VALUES (<customer id>, 'source_ip', '<ip>', '<why, and the date>');
```

`source_ip` is what this deployment attributes on — it is tried first, it is
populated at the top of the dialplan before any check can reject the call, and
it is therefore present even on refused calls. `customer_endpoint` and `did`
identifiers exist as fallbacks and are not in use here; adding one is harmless
but it is not what makes the call bill.

Confirm the portal resolves it before sending traffic:

```
GET /api/v1/balance/by/source_ip/<ip>   ->  {"customer_id":"3", ...}
```

If calls already landed unattributed, the admin **Re-attribute** action
(`POST /admin/ingest/reattribute`) back-fills them against the new identifier
and re-rates.

**5. Prove it.** All four in one pass:

```bash
sudo ./healthcheck.sh                      # endpoint pkclientN configured
asterisk -rx "pjsip show identifies"       # the new IP maps to the new endpoint
sudo nft list set inet sbc pk_clients      # the new IP is in the set
./didctl.sh distribution                   # after real traffic: CDRs from the new IP
```

Then wait for a real call from the new address and confirm it lands in the CDR
with the right `source_ip` and `customer_endpoint`, and that the portal
resolves it to the right customer.

### The DID pool

**How the numbers are doing today** — usage against the cap, how close
anything is to falling out of rotation, and the overflow rate:

```bash
./didctl.sh status
```

**Which pools Asterisk actually loaded** — not what `dids.csv` says, what is
in the running dialplan:

```bash
./didctl.sh pools
```

**Prove distribution from the CDR** — this is the artefact to hand over if
anyone asks whether traffic is concentrated on one number:

```bash
./didctl.sh distribution
```

**One number's history:**

```bash
./didctl.sh show 12125550101
```

**Add numbers to a pool.** Edit `dids.csv`, then re-render. The daily counters
are in the Asterisk database, not the dialplan, so they are not disturbed:

```bash
sudo ./install.sh --config-only
```

**After a rate deck update** — regenerate and reload. Do this monthly:

```bash
python3 tools/build-blocklist.py --deck ~/decks/ShortDuration-<month>.csv --out blocklist.csv && sudo ./install.sh --config-only
```

**Overflow rate is climbing.** Not an error and nothing is broken: an NPA pool
is undersized for the traffic going into it. Find which one, then buy numbers
for it.

```bash
./didctl.sh distribution | sed -n '/selection reason/,$p'
```

**`NO_DID_AVAILABLE` in the log.** Every DID in the destination's NPA pool
*and* every DID in overflow is at its daily cap, and calls are being refused
with 503. This needs a decision, not a restart:

```bash
grep NO_DID_AVAILABLE /var/log/asterisk/messages | tail
```

```bash
./didctl.sh today | sort -k2 -rn | head -20
```

Either raise `DID_DAILY_CAP`, or add numbers. Raising the cap concentrates
more traffic on the same numbers, which is the thing the cap exists to
prevent — prefer adding numbers. `didctl.sh reset` exists but zeroing counters
mid-day lets every number carry another full allowance on top of what it has
already sent, so it is a deliberate act and it requires `--force`.

### Transfer legs

**Are transfers being detected at all** — the number to watch is the transfer
share. On this traffic it should be a fraction of a percent (15–30 legs out of
~53,000 calls):

```bash
./didctl.sh transfers stats
```

**What has been learned:**

```bash
./didctl.sh transfers list
```

**"The buyer says they're seeing a strange number."** That is a transfer leg
that was not detected — it went out as a prospect dial with a pool DID. Find
it, confirm, then pin the buyer number so it never happens again:

```bash
grep 'SBC-DIAL' /var/log/asterisk/messages | grep 'dst=<BUYER_NUMBER>' | tail -5
```

```bash
./didctl.sh transfers add <BUYER_NUMBER>
```

Pinning takes effect on the next call and never expires. This is also the fix
for the accepted warm-up cost: a new non-toll-free buyer needs three answered
calls before rule 2 fires, and pinning skips it entirely.

**"A prospect got our customer's caller ID instead of ours."** The reverse —
rule 2 has over-fired on a destination that is not a buyer. Un-flag it:

```bash
./didctl.sh transfers remove <NUMBER>
```

That suppresses it permanently rather than deleting the counters, so the next
three calls cannot silently re-learn it. If this happens more than once,
`TRANSFER_MIN_CALLS` is too low — it should be 3 and never lower.

**Transfer state is not date-keyed and does not reset at midnight.** That is
deliberate: a buyer line has to stay recognised across days. Learned entries
expire after `TRANSFER_EXPIRE_DAYS` of inactivity, handled by the weekly
prune timer. Pins and suppressions never expire.

Do **not** run `transfers reset` on a live box to "clear something up" — every
buyer line then needs three answered calls to re-learn, and during that window
their transfers go out with a pool DID. Use `transfers remove` on the one
destination instead.

**Find one call** (for a traceback, or a customer complaint):

```bash
grep '<CALL_ID>' /var/log/asterisk/cdr-custom/sbc.csv /var/log/asterisk/messages
```

```bash
ls /var/log/asterisk/siptrace/ && tcpdump -nr /var/log/asterisk/siptrace/<file>.pcap 'port 5060' | grep '<CALL_ID>'
```

**Why was a call rejected**

```bash
grep 'SBC-REJECT' /var/log/asterisk/messages | tail -50
```

---

## 5. Acceptance criteria

> **NOT YET CAPTURED.** See section 0. Run
> `sudo ./tests/capture-acceptance.sh` on the SBC and paste its redacted
> output over this section. Do not mark anything below as passed until you
> have its actual output in hand.

Redact before committing: real IPs become `<SBC_IP>`, `<PK_IP_1>`,
`<PK_IP_2>`, `<FRACTEL_IP>`; Call-IDs become `<CALL_ID>`; phone numbers become
`<NUMBER>`. `capture-acceptance.sh` does this, best effort — read its output
before you paste it.

| # | Criterion | How | Status |
|---|---|---|---|
| 1 | Both customer endpoints and all FracTEL gateways listed; FracTEL reachable | `asterisk -rx "pjsip show endpoints"` / `"pjsip show contacts"` | not captured |
| 2 | Config loads, zero errors, zero deprecation warnings | restart + scan `/var/log/asterisk/messages` | not captured |
| 3a | Unauthorized source IP rejected (Asterisk ACL) | SIPp from `127.0.0.99` | not captured |
| 3b | Unauthorized source IP rejected (host firewall) | **`nmap` from another machine** — see 2b | not captured |
| 4 | Authorized customer IP reaches the FracTEL gateway | SIPp → local UAS stub | not captured |
| 5 | Non-NANP destination rejected | SIPp with `destinations-badnanp.csv` | not captured |
| 6 | Concurrency cap: with cap 3, the 4th call gets 503 | SIPp holds 3, places a 4th | not captured |
| 7 | CPS limit throttles | SIPp burst at 4× the cap | not captured |
| 8 | CDR row has source_ip, caller_id, destination, billsec, sip_call_id | inspect `sbc.csv` | not captured |
| 9 | `killswitch.sh on` blocks new calls in under 1s; `off` restores | timed, then SIPp | not captured |
| 10 | RTP never flows directly customer↔carrier | `tcpdump` + endpoint readback | not captured (on-box half only — see below) |
| 11 | Everything returns after a reboot, firewall intact | `sudo reboot` then check | not captured |
| 12 | Customer CID `2125551234` appears nowhere in the outbound INVITE; our DID is in `From`, `P-Asserted-Identity` and `Remote-Party-ID` | SIPp + stub `-trace_msg` | not captured (on-box half only — see 6) |
| 12b | Customer CID `0000000000` is **replaced**, not refused; call completes; WARN logged | SIPp + log scan | not captured |
| 13 | 1000 calls, mixed NPAs: no DID over its cap, even distribution per pool | from the CDR alone | not captured |
| 14 | Cap 5: the 6th call that would use a DID selects a different one | NPA 989 has one DID | not captured |
| 15 | Destination NPA with no pool selects from overflow and logs WARN | NPA 505 | not captured |
| 16 | Blocklisted prefix refused with 503, longest prefix wins | `destinations-blocked.csv` | not captured |
| 17 | 600+ calls spread across all six gateways | from the CDR alone | not captured |
| 18 | 844 destination: customer CID intact in all three headers, no pool DID, tagged `transfer_leg_tollfree` | SIPp + stub `-trace_msg` | not captured |
| 19 | Same destination 3× answered over the ACD threshold; the 4th is tagged `transfer_leg_learned` and passes CID through | SIPp + log scan | not captured |
| 20 | Same destination 5× answered *below* the threshold: NOT flagged, full rewrite | guards the ACD condition | not captured |
| 21 | Destination dialled twice, both long: NOT flagged | guards the `>=3` count | not captured |
| 22 | Toll-free *and* blocklisted destination still refused with 503 | ordering test | not captured |
| 23 | `didctl.sh transfers remove` un-flags, and 3 more long calls do not re-learn it | suppression, not deletion | not captured |

Criteria 18–23 run with `TRANSFER_MIN_ACD` scaled to 3 seconds so the suite
does not spend four and a half minutes waiting on 90-second calls.
`TRANSFER_MIN_CALLS` stays at 3 — that is the validated value and criteria 19
and 21 exist to prove the boundary either side of it.

Criteria 13 and 17 are measured from the same 1000-call run — two questions
about one mechanism. Criterion 17's important half is **all six** gateways
taking traffic: a rotation that buckets by wall clock still produces a
plausible even split across a subset.

### 5a. Commands, for pasting output against

```bash
asterisk -rx "pjsip show endpoints"
```

```bash
asterisk -rx "pjsip show contacts"
```

```bash
asterisk -rx "pjsip show identifies"
```

```bash
sudo ./tests/run-acceptance.sh
```

```bash
./didctl.sh pools
```

```bash
./didctl.sh distribution
```

**Counting available gateways.** Use the Status *field*, not a substring:

```bash
asterisk -rx "pjsip show contacts" | awk '$1=="Contact:" && $4=="Avail"{n++} END{print n+0}'
```

Do **not** use `pjsip show endpoints | grep -ci avail`. Case-insensitively,
`avail` matches `Unavail` and the `Unavailable` that `pjsip show endpoints`
reports for the IP-auth customer legs — those legs have no AOR and no qualify,
so `Unavailable` is their normal steady state and says nothing about health.
That one-liner reported **7** on a box with **5** gateways, and the number
drifts as endpoint state changes rather than as gateways go up and down.

```bash
sudo nft list table inet sbc
```

```bash
systemctl is-enabled asterisk nftables sbc-healthcheck.timer sbc-killswitch.service
```

---

## 6. What cannot be tested here, and how to verify it by hand

Stated plainly, because a green test suite that quietly skipped these is how
an SBC gets to test day broken.

### The host firewall — criterion 3b

The suite runs on-box. Its traffic never crosses the WAN interface where the
nftables rules live, so those rules are never consulted. **The whole suite can
pass green with port 5060 open to the internet.** Probe it from another
machine, per section 2b. Reported as SKIP by the driver, never PASS.

### Reboot persistence — criterion 11

A test run cannot reboot the host it is running on. Section 2d.

### Real two-way audio

The SIPp stub echoes RTP; it does not prove a human can hear a human. Needs
the real customer and the real FracTEL trunk. On the first live call:

1. Answer it on a real handset and talk in both directions.
2. While it is up, on the SBC:

   ```bash
   sudo tcpdump -ni any -c 200 'udp portrange 10000-20000'
   ```

3. Every packet on the **trunk-facing** side must show the SBC's own address
   as both source and destination of the flow toward FracTEL. A customer IP
   appearing there means `direct_media` leaked and FracTEL will drop the
   audio.

### What FracTEL sees as the RTP source — criterion 10, carrier half

The on-box test proves no RTP flows directly between the customer address and
the carrier address. It cannot show what FracTEL observes on the real
internet. Ask FracTEL, on the first live call, to confirm the media source
address they see is the SBC's public IP. If they report a Pakistan address,
stop taking traffic and fix it before doing anything else.

### One-way audio caused by NAT

Only relevant if the SBC's public IP is not bound directly to its interface —
it should be, on Hetzner. If `install.sh` warns that `SBC_PUBLIC_IP` is not on
any interface, set `SBC_NAT_LOCAL_NET` and re-run. Setting it when it is not
needed *causes* the problem it is meant to fix.

### Caller ID on the wire — criterion 12, carrier half

The suite proves the INVITE **leaving this box** carries our DID in `From`,
`P-Asserted-Identity` and `Remote-Party-ID`, and that the customer's value
appears nowhere in it. It cannot prove what FracTEL does with that.

Two things to confirm on the first live call, and neither is optional:

**1. FracTEL accepts these numbers as caller ID on this subaccount.** IP
authorization and caller-ID authorization are separate provisioning steps and
it is easy to assume the first covers the second. Asserting a DID they have
not provisioned to you is its own fraud alert. Ask them directly, by number.

**2. The headers arrive intact.** Place one call and capture it:

```bash
sudo tcpdump -ni any -s0 -A 'port 5060' | grep -iE '^(INVITE|From|P-Asserted-Identity|Remote-Party-ID):'
```

All three must show the same DID. Cross-check against what the SBC believed
it sent:

```bash
grep SBC-DIAL /var/log/asterisk/messages | tail -1
```

That line carries both `custcid=` (what the customer sent, discarded) and
`did=` (what was asserted). If `custcid` ever appears in the captured INVITE,
stop taking traffic — that is the failure this whole version exists to
prevent.

### STIR/SHAKEN attestation

Nothing on this box signs or attests. FracTEL signs.

This changed with carrier-assigned caller ID. Previously the CID was
customer-supplied and **B** attestation was correct and expected. Now the
asserted number is a FracTEL DID, which is the condition for **A**.

Whether FracTEL actually grants A depends on their provisioning, not on
anything here. **Confirm it on the first live call rather than assuming it** —
and do not treat B as a fault until you have checked that the numbers in
`dids.csv` are provisioned to this subaccount. B on a DID they have not
associated with you is a provisioning gap, not a signing bug.

### Transfer detection against real traffic

The suite proves the state machine reaches the right states. It cannot tell
you whether the rules match *your customer's actual buyers*, because the stub
answers anything and the fixtures are invented.

Rule 1 needs no validation — toll-free is toll-free. Rule 2 does. On the first
full production day:

```bash
./didctl.sh transfers stats
```

```bash
./didctl.sh transfers list
```

Two failure modes, opposite directions, and both are visible here:

**Over-firing** — the transfer share is more than a fraction of a percent, or
`transfers list` shows destinations that are obviously consumer numbers. Every
false positive is a prospect dial that kept the customer's caller ID instead
of ours, which is the failure this whole build exists to prevent, arriving
through the back door. Remove them individually and check `TRANSFER_MIN_CALLS`
is still 3.

**Under-firing** — buyers report seeing unfamiliar numbers. Those transfers
went out with a pool DID. Expected for the first three calls to a new
non-toll-free buyer; not expected after that. Pin the number.

You will not get a buyer list from the customer — the call centres are two or
three steps removed — so `transfers list` after a day of real traffic is the
closest thing to one you will have. Read it.

### The blocklist misses ported numbers

The rate deck is LRN-rated: the charge follows where a number has been ported
to. This box performs no LNP dip and matches the number dialled, so it catches
numbers natively in expensive prefixes and misses numbers ported into them.

There is no on-box test for this and no fix that does not involve buying LNP
dips. Manage it by reconciliation instead — monthly, compare FracTEL's rated
CDR against `blocklist.csv` and add whatever cost more than it should:

```bash
./didctl.sh distribution | head -20
```

Then re-run `tools/build-blocklist.py` against the new deck. Treat the
blocklist as reducing exposure, not eliminating it.

---

## 7. Rollback

### A call fails and you need the customer off, now

```bash
sudo ./killswitch.sh on
```

Under a second, in-progress calls unaffected, trunk untouched. This is almost
always the right first move — it stops the bleeding without destroying the
evidence you will need to work out what happened.

### Bad config change

`install.sh` backs up `/etc/asterisk` on every run.

```bash
ls -dt /etc/asterisk.bak-* | head -5
```

```bash
sudo systemctl stop asterisk && sudo rm -rf /etc/asterisk && sudo cp -a /etc/asterisk.bak-<STAMP> /etc/asterisk && sudo systemctl start asterisk
```

Better, if `config.env` is still good — re-render rather than restore, so what
you end up with is exactly what `config.env` describes:

```bash
sudo ./install.sh --config-only
```

### Locked out by the firewall

If you are still within the 90-second rollback window: do nothing. The table
removes itself.

If you confirmed and then lost access, you need the Hetzner rescue console:

```bash
sudo ./firewall.sh clear
```

That removes the table and leaves the box **unprotected**. Fix `ADMIN_SSH_IP`
and re-apply immediately.

### Stuck in test configuration

```bash
sudo ./tests/testenv.sh status
```

```bash
sudo ./tests/testenv.sh restore
```

`restore` re-renders from `config.env`, so it is safe even if the test config
was modified.

### Full teardown

```bash
sudo systemctl stop asterisk sbc-siptrace sbc-healthcheck.timer && sudo ./firewall.sh clear
```

Traffic stops immediately, including in progress. The box is then unprotected
— only do this if you are done with it.

---

## 8. If you get a traceback request

You have 24 hours.

1. Get the Call-ID, the calling and called numbers, and the date/time.
2. Find the call:

   ```bash
   grep -i '<CALL_ID_OR_NUMBER>' /var/log/asterisk/cdr-custom/sbc.csv
   ```

3. The CDR row gives you `source_ip` (which customer IP originated it),
   `customer_endpoint`, the caller ID **as the customer sent it**, the
   destination, raw `billsec`, and the SIP Call-ID.
4. The SIP trace has the full ladder:

   ```bash
   grep -l '<CALL_ID>' /var/log/asterisk/siptrace/*.pcap
   ```

5. Your answer is: this traffic originated from `<source_ip>`, which is
   customer X, and here is the CDR and the signaling.

Retention is `CDR_RETAIN_DAYS` (default 90) for CDR and `SIP_TRACE_KEEP` files
of `SIP_TRACE_FILE_MB` each (default 20 × 100MB) for traces. If tracebacks
start arriving, raise both **before** you need them — you cannot retroactively
retain what you already rotated away.


## 9. Evidence: the box was accepting traffic throughout the 2026-08 trunk pause

Recorded because it is what a carrier compliance conversation needs, and
because the drop-log rule that produced it is easy to remove as "noise" by
someone who does not know it is the only thing that can prove this.

The customer's traffic stopped after **2026-08-12 20:23 UTC** while compliance
was proven to the carrier. That is a deliberate pause, not a fault. Established
read-only on 2026-08-14:

**No customer SIP packet reached the box, and nothing here refused one.**

| Check | Result |
|---|---|
| `SBC-DROP-IN` kernel log, 08-13 onward | 32,291 packets logged dropped, **zero from any customer IP** |
| Sources actually being dropped | SIP scanners: `192.161.49.2` (2,356), `5.61.209.224` (1,128), the `194.180.49.0/24` block |
| nft `@pk_clients udp dport 5060` accept counter | 0 packets since counters reset at 08-12 20:23 |
| conntrack flows from customer IPs | none |
| Asterisk security log | empty — no unidentified requests, so not a changed source IP either |
| `SBC_KILLSWITCH` | 0, state file `off` |
| Customer identifies | all three loaded, matching the configured addresses |
| Carrier gateways | 5/5 `Avail`, RTT 87–144ms — egress healthy throughout |
| Asterisk | up since 08-12 21:55, `NRestarts=0` |

**The drop log is what makes this provable.** Rule handle 24 in
`chain inet sbc input` logs at 10/minute before the default drop. Without it,
"we were accepting and they were not sending" and "we were silently dropping
them" produce identical evidence: an accept counter at zero. With it, the
absence of any customer IP in the log is positive proof that no packet from
them was discarded. Do not remove that rule to quiet the kernel log.

**What this does not prove.** Only that nothing arrived *here*. Blackholing
upstream of this box — their provider, a route change, their own dialer being
off — is outside what this box can see. The claim is bounded to: from the SBC
inward, nothing was refused.

Two facts to state plainly rather than let a reader infer them:

- **The 08-12 window ran with `DID_DAILY_CAP=600`**, set and reverted
  deliberately. Fleet capacity that day was 296,400 calls rather than the
  98,800 that cap 200 gives, so the 36,683 `NO_DID_AVAILABLE` refusals measured
  in that window **understate** what normal operation produces. See
  `tools/analyze-did-capacity.py --project-refusals`.
- Traffic on 08-12 tapered out naturally at 19:00, its usual end of window. The
  21:55 Asterisk restart happened *after* that and interrupted nothing.

### What the reallocation experiment can and cannot prove

Read this before treating a flat result as a settled question.

The reallocation moves existing numbers into 336, 337, 316 and 609 — the four
worst per-DID loads among the ten NPAs that answered 0% on ShortDuration. It
reduces **load per number**. It does **not** restore local presence.

The numbers moving into 336 are `1-325-758-xxxx`. Calls to 336 will present a
325 caller ID. That is still strictly better than what those calls get today —
a dedicated number at low load beats a shared overflow number pinned at the
ceiling — but it means the experiment tests one variable and not the other.

| Result | What it means |
|---|---|
| 336's ASR **lifts** | Load per number was the problem. The burn hypothesis holds. |
| 336's ASR **does not move** | **NOT evidence against the hypothesis.** Local presence is still absent and still untested. Only provisioning real 336 numbers tests that, and that is the purchase. |

The incumbents are retired rather than left in the pool for the same reason:
at 2 dead numbers out of 16, they would have contributed roughly 12% of 336's
measured ASR permanently, and a blended signal answers neither question. They
are commented out in `dids.csv` as `#SUPPRESSED` rows, not deleted — if the
hypothesis holds they are the cleanest evidence that reputation damage is real
and persistent, and they can be restored by deleting the prefix.

**There is no per-DID suppression in the call path.** `[sbc-did]` walks the pool
global and checks the daily cap; nothing else. The `S` flag elsewhere in
`didctl.sh` is transfer-destination state under `sbc/xfer/...` and has no
bearing on DID selection. Removing a number from the pool is the only thing that
takes it out of rotation today. Building a real per-DID cooldown is Phase 6.

#### 316 and 609 carry one incumbent each — interpret their readings with it

The four experiment NPAs are **not** equally clean, and the difference is
deliberate.

Suppressing the incumbents left all four below their need, so all four still
exceed the 200 cap and spill to overflow. Two contaminants were available and
they are not symmetric:

- **A restored incumbent is a known quantity.** One identifiable number with a
  usage history. ASR can be measured with and without it and the number
  subtracted out afterwards.
- **Overflow blending is not.** Those calls land on whichever shared numbers the
  pool hands out, at whatever load those numbers happen to be carrying. The
  effect cannot be separated after the fact.

So 316 and 609 — which were spilling 19% and 28% to overflow on 3 and 2 numbers
— had their incumbents restored, trading an unmeasurable contaminant for a
measurable one. 609 at 3 numbers against 559 calls is still 186/number and still
spills at peak, but the spill is small enough to reason about.

| NPA | pool | incumbent restored | spill | reading |
|---|---|---|---|---|
| 336 | 14 | no | ~11% | **primary** — 1,572 → 224 calls/number |
| 337 | 6 | no | ~2% | **primary** |
| 316 | 4 | yes (`13168166005`) | reduced | subtract the incumbent |
| 609 | 3 | yes (`16099666107`) | reduced | subtract the incumbent |

**336 is the experiment.** It is the largest load reduction, the cleanest
signal, and the one to read first. 316 and 609 are corroboration, not evidence
on their own.
