# HANDOFF

**Run these two things before believing anything in this file:**

```bash
./verify-deployment.sh --remote root@167.235.206.206
```

```bash
git log --oneline -12 && git tag -n1 -l 'deployed-*'
```

This document is a snapshot written 2026-08-14. The box and the repo are the
authorities; if they disagree with what is below, they are right and this is
stale. `verify-deployment.sh` exists precisely so that question has an answer.

---

## THE MOST IMPORTANT LINE IN THIS FILE

**Phase 0 is live in production and its acceptance criteria 24-26 have never
been executed.**

They are written (`tests/run-acceptance.sh`), they have never run against a
running Asterisk, and there has never been a box to run them on. Phase 0 changes
failover behaviour on every call. The trunk is currently paused, so it is
carrying nothing — but it will be carrying real calls the moment the trunk
returns.

Running 24-26 is the first thing the lab box does. Not V3, not Phase 1.

---

## Production state

Production is `167.235.206.206`, deployed at `/opt/sbc`, running tag
**`deployed-2026-08-14`** (`4f269f0`).

There is **no git checkout on the box** and that is deliberate — credentials and
a `.git` directory on the one host terminating customer traffic is a worse trade
than copying files. Provenance lives in `/opt/sbc/DEPLOYED_COMMIT` instead.

Deployed by hand, and the only three files that matter for runtime:

| file | sha256 (first 12) |
|---|---|
| `render.sh` | `aba50f5411e5` |
| `asterisk/extensions.conf.tpl` | `e6bd47bd4187` |
| `didctl.sh` | `47285fcd628b` |

### What is live

**Phase 0** — failover is classified on ringing rather than on `DIALSTATUS`.
A 603 Decline maps to `AST_CAUSE_CALL_REJECTED`, which `app_dial` reports as
`CHANUNAVAIL` — the same status an unreachable proxy gives — so before this,
every consumer who pressed decline was redialled across the remaining gateways.
Live globals: `SBC_MAX_ATTEMPTS=2`, `SBC_FAST_REJECT_MS=2000`, `SBC_GW_COUNT=5`.

**DID pool reallocation** — 70 moves, no purchases. Donors retain
`max(need+2, ceil(need*1.25))` rather than being drained to their need, because
`need` is the peak of a three-day window whose busiest day was a *partial* one.

**Pools:** 491 active + 3 suppressed = **494** (no numbers created or lost).

| | |
|---|---|
| experiment NPAs | 336: 14, 337: 6, 316: 4, 609: 3 |
| donors | 325: 4, 839: 3, 254: 8, 239: 7 |
| overflow | 236 |
| suppressed | `13364004128`, `13364004559` (336), `13376777439` (337) |
| restored | `13168166005` (316), `16099666107` (609) |

Suppressed numbers are `#SUPPRESSED` comment rows in `dids.csv` — out of
rotation because `render.sh` skips comments, retrievable by deleting the prefix.
**There is no per-DID suppression in the call path.** `[sbc-did]` walks the pool
global and checks the daily cap, nothing else. The `S` flag in `didctl.sh` is
transfer-destination state under `sbc/xfer/...` and has no bearing on DID
selection — an astdb `S` key against a DID would be inert. Building a real
per-DID cooldown is Phase 6.

### What is NOT live

Phase 1 in any form. `lib/routes.sh` is not on the box and would be inert if it
were.

---

## Phase 1 status

`lib/routes.sh` is committed at **`8a7039d`** and **wired into nothing**. It
parses and validates the route model and is fully unit-tested locally (the
spec's own three-route example, plus twelve failure modes), but no consumer
calls it, so it changes no behaviour.

Everything else in Phase 1 is **unbuilt**:

- `render.sh` integration — transports, endpoints, route globals
- `asterisk/pjsip.conf.tpl` — per-route transports and endpoints
- dialplan route loop in `asterisk/extensions.conf.tpl`
- the 7 new CDR columns (`route_name`, `carrier`, `deck`, `sip_response`,
  `dialed_seconds`, `routes_attempted`, `explore_flag`)
- `netroutes.sh` — source-based policy routing for RTP
- per-route `firewall.sh`
- `DID_ROUTE_AFFINITY` (`shared` | `pinned`)

---

## Order of work when the lab box arrives

The lab is a throwaway Hetzner instance with **two floating IPs**, Asterisk 20
and SIPp, in the production region. Install the toolchain yourself.

**1. Acceptance criteria 24-26.** Phase 0 is the only thing in this workstream
carrying live calls, and it has never been tested. Everything else on this list
gates code that has not shipped; this gates code that has. Drive them with
`tests/sipp/uas-fractel-stub-ring-reject.xml` and `-reject.xml` at the same
response code (603) — identical code, opposite retry behaviour, and the only
difference is whether a 180 was sent.

**2. VERIFY item V3** (`VERIFY-CHECKLIST.md`). Whether Asterisk 20 will bind a
`0.0.0.0:5060` transport alongside address-specific transports on the same port.
It is the only VERIFY item that can force a *redesign* rather than a config
change: the customer transport binds the wildcard so the acceptance suite can
reach it over loopback, and the spec's own `ROUTE_2` binds a specific address on
the same port. That is `EADDRINUSE` unless pjproject sets `SO_REUSEADDR`, and it
cannot be reasoned out.

**3. V4** — RTP source address per route, with packet capture. The reason the lab
has two IPs. `media_address` controls what SDP *advertises*, not what the kernel
*sends from*, and getting this wrong presents as a carrier fault.

**4. Phase 1 integration**, in the order in the spec.

`VERIFY-CHECKLIST.md` has the exact command and the "what changes if the answer
differs" for every item.

---

## Trunk is paused

No traffic and no new CDR since **2026-08-12 20:23 UTC**. The trunk is paused
while compliance is proven to the carrier. **This is deliberate, not a fault.**

`RUNBOOK.md` §9 holds the evidence that the stoppage was not our side: 32,291
packets logged dropped by the firewall with **not one from a customer IP** (the
sources being dropped are SIP scanners), zero conntrack flows from customer IPs,
an empty Asterisk security log, killswitch off, all three customer identifies
loaded and matching, and 5/5 carrier gateways `Avail` throughout.

The `SBC-DROP-IN` log rule at handle 24 is what makes that provable — without
it, "we were accepting and they weren't sending" and "we were silently dropping
them" produce identical evidence. **Do not remove that rule to quiet the kernel
log.**

Also on the record: the 2026-08-12 window ran with `DID_DAILY_CAP=600`, set and
reverted deliberately. Every refusal figure measured in that window therefore
*understates* normal operation, because fleet capacity that day was 296,400/day
rather than 98,800.

---

## Open: the vendor order

**625 DIDs across 322 NPAs, ready and unsent.** Generated from production CDR
2026-08-10..12, in provision priority order. Sum the `quantity` column — it is
net of reallocation, so it is the order and nothing else.

**Priority 1-4 are the 5 experiment replacements** (336 ×2, 337 ×1, 316 ×1,
609 ×1), flagged `EXPERIMENT - provision first`.

Projected refusals at cap 200 against measured demand (236,999 offered calls):

| fleet | refused | |
|---|---|---|
| current | 66,189 | 27.9% |
| **after reallocation (where we are now)** | **33,398** | **14.1%** |
| after purchase | 0 | — |

**Reallocation halved refusals and did not clear them.** 33,398 calls are
refused until the purchase lands, and the trunk returning does not change that.
Numbers take time to provision — this is the long pole.

Regenerate with:

```bash
python3 tools/analyze-did-capacity.py --cdr <cdr> --dids dids.csv --project-refusals
```

---

## The burn experiment

Hypothesis: the worst-answering NPAs are the ones whose two or three numbers are
burned. 336 was running **1,572 calls per number per day** against a standing cap
of 200; it now runs 14 numbers at ~224.

| NPA | reading |
|---|---|
| **336** | **clean, and the primary signal** — largest load reduction |
| **337** | clean |
| 316 | carries one restored incumbent (`13168166005`) — subtract it |
| 609 | carries one restored incumbent (`16099666107`) — subtract it |

316 and 609 keep an incumbent deliberately. Suppressing every incumbent left all
four below their need, so all four still spill to overflow; 316 and 609 were
spilling 19% and 28%. A restored incumbent is *one identifiable number with a
usage history* that can be subtracted out afterwards. Overflow blending lands on
whichever shared numbers the pool hands out at whatever load they carry, and
cannot be separated after the fact. The trade was an unmeasurable contaminant
for a measurable one.

**What a null result does and does not mean.** The numbers moved into 336 are
`1-325-758-xxxx`, so calls to 336 present a **325 caller ID**. The reallocation
reduced load per number; it did **not** restore local presence.

- 336's ASR **lifts** → load was the problem, hypothesis holds.
- 336's ASR **flat** → **not evidence against the hypothesis.** Local presence is
  still absent and still untested. Only the purchase tests that.

Do not let a flat result close this question. `RUNBOOK.md` carries the same
warning next to the projection.

---

## Before touching the box

```bash
./verify-deployment.sh --remote root@167.235.206.206
```

Read-only. Three modes: on the box, `--remote` over ssh, and `--repo` to confirm
the recorded commit still hashes as recorded (which catches a rewritten branch or
a moved tag — drift can come from either end).

| exit | meaning | what to do |
|---|---|---|
| **0** | every deployed file matches `DEPLOYED_COMMIT` | proceed |
| **1** | **drift** — a file on the box differs from the record | **stop.** Reconcile first. A deploy from a clean checkout will silently revert whatever the box has that the recorded commit does not — including Phase 0, whose only symptom would be a slow rise in INVITE volume toward the carrier |
| **2** | cannot check — missing/unreadable stamp, host unreachable, bad args | **stop.** A box with no provenance record must not be deployed over blind. Reconstruct with `--write <sha>` against the commit you believe is running and confirm the hashes before trusting it |

Acceptance criterion 27 runs this, so a deploy that skips the stamp fails the
suite rather than passing quietly. A passing run still prints unexecuted
criteria as a warning.

**After any deploy**, regenerate the stamp:

```bash
DEPLOY_HOST=167.235.206.206 ./verify-deployment.sh --write <sha> > /tmp/DEPLOYED_COMMIT
```

It marks the stamp `(WORKING TREE DIRTY AT WRITE TIME)` if generated from
uncommitted work, so a stamp taken mid-edit says so.

---

## Standing constraints

- **Production is read-only for analysis.** Measure freely — `tcpdump`,
  `asterisk -rx` show commands, CDR and log reads. Everything that writes goes to
  the lab first and then gets scheduled.
- **Never raise `DID_DAILY_CAP` above 200.** The load figures are an argument for
  lowering it once fleet size allows. The lever is number count, not cap.
  `tools/analyze-did-capacity.py` refuses to model a higher one.
- **Do not weaken** `NANP_ONLY`, `BLOCKED_NPAS`, `BLOCK_976`, the CPS limit, the
  per-endpoint concurrency cap, or the killswitch.
- **Never set `direct_media=yes`.** The SBC exists because media must transit
  the box.
- **Single-route operation must keep working.** It is the rollback path.

---

## Commit map

| commit | what |
|---|---|
| `571c60e` | Phase 0 — ring-aware failover split, `MAX_ROUTE_ATTEMPTS`, parameterised SIPp stubs, criteria 24-26 |
| `8a7039d` | `lib/routes.sh` + `VERIFY-CHECKLIST.md` |
| `120541c` | `tools/analyze-did-capacity.py` |
| `cb52afe` | reallocation split from purchase in the plan CSV, `--load-report` |
| `ba6ed57` | `--project-refusals`; fixed overflow being over-drained |
| `3760e74` | `didctl.sh reallocate` |
| `260d5f6` | donor headroom, incumbent suppression |
| `4f269f0` | **← production runs this** (tag `deployed-2026-08-14`) |
| `4204b02` | `verify-deployment.sh` + criterion 27 |
| `a89003a` | `ssh -n` fix in the checker |

Rollback paths for everything applied on 2026-08-14 are in `RUNBOOK.md`, and the
box holds timestamped backups of `dids.csv`, `render.sh`,
`asterisk/extensions.conf.tpl`, `didctl.sh` and `/etc/asterisk`.
