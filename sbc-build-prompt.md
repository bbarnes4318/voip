# SBC build brief — wholesale VOIP, single-customer trunk to FracTEL

> **Provenance.** This file is a **reconstruction**. The original brief was
> pasted directly into an agent session and never committed, so it was not in
> the repository at commit `7957799`. This document was rebuilt from what the
> code actually implements — the assertions in `tests/run-acceptance.sh`, the
> rationale in `README.md` and `tests/README.md`, and the structure of the
> dialplan and renderer. It was reviewed and confirmed correct by the author
> of the original.
>
> It is committed so the next session does not have to derive it again.
>
> **Where this file and `CALLER-ID-ADDENDUM` disagree, the addendum wins.**
> The addendum reverses this document on caller ID, and the reversal is
> deliberate — see "Superseded" at the bottom.

---

## What this is

A standalone Session Border Controller. It accepts outbound call traffic from
one wholesale customer over IP authentication and terminates it to FracTEL
over a dedicated subaccount trunk.

Asterisk 20 LTS with `res_pjsip`, installed on the host. No Kamailio, no
rtpengine, no Docker, no web UI.

```
PK_CLIENT_IPS ──┐  (one endpoint per entry: pkclient1..N)
                 ├──► [ SBC — ONE public IP ] ──► FracTEL (6 outbound proxies)
                 ┘      Asterisk 20 LTS / res_pjsip
                        B2BUA, IP auth both sides
                        full media relay
```

## The constraint it exists to solve

FracTEL authorizes exactly **one** source IP per trunk. The customer has
**two** IPs.

That is not to be solved with NAT tricks or a second trunk. The SBC is a
back-to-back user agent: it terminates the customer's call leg and originates
a brand-new leg toward FracTEL from its own single address. Both customer IPs
converge into one outbound identity.

**This only holds if media actually transits the box.** If RTP flowed directly
from the customer to FracTEL, FracTEL would see media from an address it has
never authorized, and the call would get one-way audio or drop. Hence
`direct_media=no` everywhere, no `bypass_media`, no ICE, no STUN.

## Defence in depth

Three layers, each independently refusing anything not explicitly permitted.

| | Control | Where |
|---|---|---|
| 1 | Host firewall | `firewall.sh` → nftables, `policy drop` on input |
| 2 | SIP ACL | `[sbc-acl]` + `type=identify`, `identify_by=ip` |
| 3 | Dialplan | `[sbc-customer]`, one `Dial()` target, no includes |

## Deliverables

```
config.env.example      every placeholder, documented
render.sh               templates -> /etc/asterisk, no IP hardcoded elsewhere
install.sh              idempotent: packages, config, systemd units, validation
firewall.sh             idempotent nftables with auto-rollback
killswitch.sh           on | on --hard | off | status | restore
monitor.sh              live: channels, per-IP concurrency, CPS, ASR, ACD
healthcheck.sh          exit 0/1/2, runs on a systemd timer
asterisk/*.tpl          rendered configs; only .tpl is tracked
tests/                  SIPp scenarios and a driver
```

## Fraud and traffic controls

- **NANP-only destination allowlist** (`NANP_ONLY`, default on). Only
  `_1NXXNXXXXXX` / `_NXXNXXXXXX`, normalized to 11 digits. Everything else 503.
- **High-risk NANP area code denylist** (`BLOCK_HIGH_RISK_NPA`). NANP-only is
  not sufficient alone: the Caribbean is inside the NANP and is the classic
  IRSF destination. US territories are deliberately not blocked.
- **976 NXX block** — US domestic premium rate.
- **Per-IP concurrency cap** (`MAX_CONCURRENT_PER_IP`), keyed on endpoint name.
- **CPS limit** (`MAX_CPS`), counted across both customer IPs combined.
- **Caller ID validation** — *superseded, see below.*

## CDR

CSV is the system of record, written synchronously. Postgres optional.
`billsec` stays **raw whole seconds** — billing increments are a downstream
calculation, and rounding at the source destroys reconciliation against
FracTEL's own CDR. `source_ip` and `sip_call_id` are set before any check can
reject the call, so even a refused call produces a complete row.

---

## Acceptance criteria 1–11

These are the original eleven. The addendum adds 12–17.

**1. Endpoints and reachability.** `pjsip show endpoints` lists one
`pkclientN` per entry in `PK_CLIENT_IPS` and the FracTEL gateways; `pjsip show contacts` reports the
gateways `Avail`.

**2. Clean load.** A restart produces zero errors, zero warnings and zero
deprecation notices in `/var/log/asterisk/messages`.

**3. Unauthorized sources refused.**
 - **3a** an INVITE from an address in neither the ACL nor any `type=identify`
   is refused by Asterisk (403 from `res_pjsip_acl`, not 401 — a 401 means the
   ACL did not match and only one layer is holding).
 - **3b** the same address is dropped by the **host firewall**. *Not testable
   on-box* — loopback traffic never traverses the WAN interface. Must be
   probed with `nmap` from a separate machine. Reported SKIP, never PASS.

**4. Happy path.** An INVITE from an authorized customer IP is answered end to
end, having been bridged to a FracTEL gateway.

**5. Destination allowlist.** Non-NANP destinations (+252, +881, +44,
011-prefixed), N11 service codes, 900, 976 and the high-risk Caribbean NPAs
are each refused with **503**, with the matching `SBC-REJECT reason=` notice.

**6. Concurrency cap.** With `MAX_CONCURRENT_PER_IP=N`, the N+1th simultaneous
call from one customer IP is refused with 503 and `reason=CONCURRENCY_CAP`.
 - **6b** the other customer IP is unaffected while the first is at its cap —
   if it is not, the cap is global and one IP can take the other down.

**7. CPS limit.** A burst well above `MAX_CPS` results in *both* at least one
`SBC-DIAL` and at least one `reason=CPS_LIMIT`. Asserted on the log, not on
SIPp's exit code: a blanket block is as wrong as no limit at all.

**8. CDR completeness.** An answered call produces a row with `source_ip`
matching the originating customer IP, and non-empty `customer_endpoint`,
`caller_id`, `destination` and `sip_call_id`. `billsec` is a raw whole-second
integer.

**9. Killswitch.** `killswitch.sh on` takes effect in **under one second** and
new customer INVITEs get 503 with `reason=KILLSWITCH`; in-progress calls are
not torn down. `killswitch.sh off` restores service.

**10. Media path.** `direct_media` reads false on both legs and **zero** RTP
packets flow directly between the customer address and the carrier address.
What this cannot show is what FracTEL sees as the RTP source on the real
internet — that needs the live trunk.

**11. Reboot persistence.** After a reboot, Asterisk, nftables, the health
check timer and the killswitch state all come back. *Not testable from inside
a test run.* Reported SKIP.

---

## Non-goals

Billing portal, rating engine, web UI, multi-tenancy, Kamailio, rtpengine,
HA/floating IP, Docker orchestration, migrations framework, CI.

## Secrets

`config.env` is gitignored; only `config.env.example` is committed. Real IPs
and phone numbers are redacted from README, RUNBOOK and any pasted output. A
secret committed by mistake stays in history and the credential has to be
rotated — the fix is rotation, not a follow-up commit.

## Isolation

Nothing here reads from, imports from or writes to the `hoppwhistle` repo.
Separate box, separate FracTEL subaccount, separate public IP. Do not reuse
the FracTEL proxy list from that box; the subaccount differs.

---

## Superseded

**Caller ID.** This document specified that the customer's caller ID is passed
through byte-for-byte and never rewritten, on the reasoning that rewriting or
inventing CID is what makes a traceback unanswerable.

That is **reversed**. A customer's ViciDial put 50,864 calls on a single DID
in one afternoon and triggered a carrier fraud alert: it matched caller ID to
destination area code and silently fell back to one default number when no
match existed. The SBC now assigns caller ID from a pool of DIDs we own, with
NPA matching, an overflow pool and a per-DID daily cap. The customer's value is
discarded and recorded in the CDR.

The traceback argument still holds and is satisfied differently: the number
asserted is one of ours, so a traceback resolves to this box, and the CDR
records both what was asserted and what the customer asked for.

Also changed by the addendum:

- `VALIDATE_CALLERID` now defaults to **false**. The customer's CID is
  discarded either way, so refusing the call over it costs revenue and
  protects nothing. A malformed value is logged at WARNING instead. The 403
  path is retained and still works when the flag is true.
- Gateway selection is **round-robin per call** across all six FracTEL
  proxies, not failover-with-a-rotating-start. Failover on 503/504/timeout is
  retained as retry behaviour.
- A **high-cost LRN prefix blocklist**, generated from the carrier rate deck,
  is the primary cost control. The NPA denylist above is now the second layer.
- Five columns are **appended** to the CDR (16–20). Columns 1–15 keep their
  positions.
- **Transfer legs are exempt from the rewrite.** When an agent bridges a live
  prospect to the US buyer, the buyer must see the prospect's number — their
  callback path and CRM record — and ViciDial already sets it correctly.
  Detected on the destination (toll-free NPA, or a learned destination with
  >=3 answered calls and ACD > 60s), never on caller ID. On those calls the
  customer's caller ID passes through untouched, no DID is drawn and no daily
  cap is consumed. The NANP allowlist, NPA denylist and blocklist still apply.
  Acceptance criteria 18–23.
