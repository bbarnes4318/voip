# SBC acceptance tests

Fixtures and a driver for acceptance criteria 1–17.

```
run-acceptance.sh              driver, PASS/FAIL/SKIP per criterion
testenv.sh                     swap between production and test config
capture-acceptance.sh          run the suite and emit REDACTED output for RUNBOOK.md
config.test.env.example        test configuration (loopback everything)

dids.test.csv                  DID pool: 8 NPAs x 40, one 1-DID NPA, 24 overflow
blocklist.test.csv             5 high-cost prefixes, incl. a longest-match pair

sipp/uac-invite.xml            customer dialer, holds the call  crit 4, 6, 7, 8, 10, 12
sipp/uac-invite-fast.xml       answers and releases at once     crit 13, 14, 15, 17
sipp/uac-expect-reject.xml     unauthorized source is refused   crit 3a
sipp/uac-expect-503.xml        dialplan refuses the call        crit 5, 6, 9, 16
sipp/uac-expect-403-badcid.xml malformed caller ID is refused   (only when
sipp/uac-empty-cid.xml         absent caller ID is refused       VALIDATE_CALLERID=true)
sipp/uas-fractel-stub.xml      the FracTEL trunk, 2s ring, RTP echo
sipp/uas-fractel-stub-fast.xml the FracTEL trunk, instant answer, volume only

sipp/destinations.csv           valid NANP destinations
sipp/destinations-badnanp.csv   non-NANP, malformed, and high-risk NANP
sipp/destinations-badcid.csv    alpha / short / self-dial / bad-NPA caller IDs
sipp/destinations-cidrewrite.csv  crit 12  — CID 2125551234, must not leak
sipp/destinations-cidbad.csv      crit 12b — CID 0000000000, must be replaced
sipp/destinations-cap.csv         crit 14  — NPA 989, which has ONE DID
sipp/destinations-overflow.csv    crit 15  — NPA 505, which has NO pool
sipp/destinations-blocked.csv     crit 16  — blocklisted, incl. longest-match
sipp/destinations-volume.csv      crit 13/17 — 40 destinations over 8 NPAs
sipp/uac-invite-timed.xml         hold time set by -d      crit 19, 20, 21, 23
sipp/destinations-transfer-tf.csv      crit 18 — 844, toll-free
sipp/destinations-transfer-learn.csv   crit 19/23 — learned then suppressed
sipp/destinations-transfer-short.csv   crit 20 — never long enough to track
sipp/destinations-transfer-twice.csv   crit 21 — long enough, not often enough
sipp/destinations-transfer-blocked.csv crit 22 — toll-free AND blocklisted
```

Every phone number in the fixtures is in the **555-01XX** range that NANPA
reserves for fiction and testing. If a fixture ever escapes onto a live trunk
it cannot reach a real subscriber, and no carrier would accept one as caller
ID either.

---

## The suite mutates state that persists

Two things are different from a normal test run and you should know about both
before running it on anything you care about.

**It zeroes the per-DID daily counters and all learned transfer state.** Both
live in the Asterisk database and survive restarts *by design* — that is what
makes the cap a daily cap and what keeps a buyer line recognised across days.
Which means a second run of the suite would inherit the first run's state, and
criteria 14 and 19–21 would each behave differently the second time. So the
driver calls `didctl.sh reset --all --force` and
`didctl.sh transfers reset --force` at startup.

Transfer state is the more disruptive of the two to lose on a live box: every
buyer line then needs three answered calls to re-learn, and during that window
their transfers go out with a pool DID and the buyer sees a stranger.

On a box carrying customer traffic that would let every number carry another
full day's allowance on top of what it has already sent. The driver only gets
that far after the preflight has confirmed the trunk points at the local stub,
but do not run this suite against production config.

**It starts and stops six SIPp processes.** One stub per gateway, swapped for
the fast variant during the volume phase and swapped back. `pkill -f
uas-fractel-stub` on exit. If the suite dies hard, check for strays.

---

## THIS SUITE CANNOT VERIFY YOUR FIREWALL

Read this part even if you skip the rest.

The suite runs **on-box**. Traffic it generates originates on the SBC itself
and is delivered over loopback — it never crosses the WAN interface where the
nftables rules live. Those rules are therefore never consulted.

**The entire suite can pass green while port 5060 is open to the internet.**

That is not a hypothetical. It is the single most common way a "tested" SBC
turns out to be an open relay: the dialplan and the Asterisk ACL are proven,
everyone reads green, and nobody checks layer 1.

The firewall must be probed **from a separate machine**, from an address that
is *not* in `ADMIN_SSH_IP`:

```bash
nmap -sU -p 5060,5080,10000-10010 <SBC_PUBLIC_IP>
```

```bash
nmap -sT -p 22,80,443,5038,5060,8088 <SBC_PUBLIC_IP>
```

Expected: **everything `filtered`**. Not `closed` — `closed` means the packet
reached the host and got an RST or an ICMP unreachable, which means your
default-DROP is not in effect. From your admin IP, port 22 should be `open`
and nothing else should be.

Then confirm SSH is genuinely restricted, from a non-admin machine:

```bash
timeout 5 nc -vz <SBC_PUBLIC_IP> 22; echo "exit=$?"
```

That must time out, not connect and not refuse.

The driver reports criterion 3b as **SKIP**, never PASS, for exactly this
reason. A skip is not a pass.

---

## What each layer actually gets tested by

| Layer | Control | Tested by |
|---|---|---|
| 1 — host firewall | nftables default DROP | **nothing here.** `nmap` from off-box, by hand |
| 2 — SIP ACL | `[sbc-acl]` + `type=identify` | crit 3a, on-box from an unpermitted loopback address |
| 3 — dialplan | NANP allowlist, NPA denylist, LRN blocklist, caps, DID assignment | crit 5, 6, 7, 9, 12–17 |

Criterion 3a is a real test of layer 2 — `127.0.0.99` is not in the rendered
ACL, so `res_pjsip_acl` refuses it exactly as it would refuse a stranger on
the internet. It just says nothing about layer 1.

---

## Running it

Install the tooling:

```bash
sudo apt install -y sip-tester tcpdump
```

Create the test config:

```bash
cp tests/config.test.env.example tests/config.test.env
```

Then, **on a box that is not carrying customer traffic**:

```bash
sudo ./tests/testenv.sh apply && sudo ./tests/run-acceptance.sh; sudo ./tests/testenv.sh restore
```

`testenv.sh apply` replaces the running Asterisk configuration with one whose
trunk points at six local SIPp stubs, whose caps are small (concurrency 10,
CPS 20) so the capacity criteria prove themselves in seconds, and whose DID
pool is the fake one in `dids.test.csv` with `DID_DAILY_CAP=5`. It backs up
`/etc/asterisk` first. `restore` re-renders production config from
`config.env` — it does not merely copy the backup back, so what you end up
with is always exactly what `config.env` describes.

Budget about four minutes. Criteria 13 and 17 place 1000 calls at 12/s, which
is roughly 90 seconds of that; the rest is qualify waits and the 20-second
holds in the concurrency and media tests.

Running the suite against the **live FracTEL trunk** would put test INVITEs on
a brand-new subaccount. That is a good way to have the carrier's fraud system
take an interest in you on day one. Don't.

### Addressing

Everything lives in `127.0.0.0/8`, which Linux binds in its entirety to `lo`,
so each of these is a distinct bindable source address:

| Address | Role |
|---|---|
| `127.0.0.1:5060` | the SBC (Asterisk binds `0.0.0.0`) |
| `127.0.0.11` | customer 1 → matches `pkclient1` (entry 1 of `PK_CLIENT_IPS`) |
| `127.0.0.12` | customer 2 → matches `pkclient2` (entry 2) |
| `127.0.0.20:5080` … `127.0.0.25:5080` | six FracTEL stubs, one per gateway |
| `127.0.0.99` | unauthorized third party |

Six gateway addresses rather than six ports on one address: `render.sh` emits
one `type=identify` per gateway matching on **IP**, and six identify sections
all matching `127.0.0.1` is undefined behaviour — whichever endpoint wins is
an implementation detail and a test built on it proves nothing.

Criterion 17 is the reason there are six at all. With a single gateway the
round-robin is unprovable, and a broken one would sail through every other
criterion in this file.

SIPp binds `-p 5061`…`5065` rather than 5060, because Asterisk holds
`0.0.0.0:5060` and that covers every loopback address.

---

## How the assertions are built

A few of these are deliberately not "did SIPp exit zero".

**Criterion 7 (CPS)** is asserted on what the dialplan logged, not on SIPp's
exit code. A working throttle lets some calls through and refuses the rest —
so neither "all answered" nor "all refused" is the expected result. The test
requires *both* `SBC-REJECT reason=CPS_LIMIT` and at least one `SBC-DIAL` in
the same window. A blanket block would be just as wrong as no limit at all,
and asserting on the exit code alone would call that a pass.

**Criterion 6** pre-fills the cap with `MAX_CONCURRENT_PER_IP` held calls and
then places exactly one more, which is the criterion as written ("with cap set
to 3, the 4th simultaneous call gets 503"). It also checks that `pkclient2`
still works while `pkclient1` is capped — if that fails, the cap is global
rather than per-IP, and one customer IP saturating the box would take the
other down with it.

**Criteria 5, 6, 7 and 9** all cross-check the `SBC-REJECT reason=` notice, not
just the response code. Every one of those paths returns 503, so a 503 alone
does not tell you the call was refused for the reason you were testing.

**Rejection scenarios cannot pass on a 2xx.** Each ends in a *mandatory*
`<recv>` for the expected 4xx/5xx. A 200 does not match it, SIPp records an
unexpected message, and the run fails. There is no branch in any of these
scenarios where a completed call is treated as success.

**Criterion 10** asserts that zero RTP packets flowed *directly* between the
customer address and the carrier address. If `direct_media` ever leaked, that
flow would exist and the capture would see it. It also reads back
`direct_media` from both endpoints. What it cannot show is what FracTEL sees
as the RTP source on the real internet — that is manual, in RUNBOOK.md.

**Criterion 12 reads the stub's received INVITE, not the CDR.** The CDR
records what the SBC *intended* to assert. The only place to see what it
actually put on the wire is the message the carrier received, which is why
every stub runs with `-trace_msg`. The assertion is not merely "our DID is in
`From`" — it is that the customer's value (`2125551234`) appears **zero
times** anywhere in the outbound INVITE. A rewrite that set `From` correctly
but left the original in `Remote-Party-ID` would pass the first check and fail
this one.

**Criterion 12b is the inverse of the old caller-ID tests.** It sends
`0000000000` and requires the call to **complete**. Before, that was a 403 and
a lost call; now it completes on one of our DIDs with a WARNING logged. The
test asserts all three: the call answered, a DID was asserted, and
`SBC-CID-INVALID` was logged. Dropping the warning would be as much a failure
as dropping the call.

**Criterion 14 is literal.** `dids.test.csv` gives NPA 989 exactly one number
and the test config sets `DID_DAILY_CAP=5`, so "the 6th call that would use
that DID selects a different one" is reachable in six calls rather than 201.
The test reads the `did=` field from six consecutive `SBC-DIAL` lines and
requires the first five to be identical and the sixth to differ.

**Criterion 16 checks longest-prefix-wins, not just rejection.**
`blocklist.test.csv` deliberately contains both `1712555` ($0.270) and
`1712555012` ($1.410). A call to `17125550123` matches both, and the test
requires the log to report the **longer** one. If Asterisk's matcher preferred
the shorter pattern, every narrow expensive row in a real rate deck would be
shadowed by a broad cheap one and the blocklist would quietly under-report.
Rejection alone would not catch that.

**Criteria 13 and 17 are measured from the same 1000-call run**, entirely from
the CDR. They are two questions about one mechanism and placing 1600 calls to
answer them separately would only add time.

- **13** asserts no DID exceeded `DID_DAILY_CAP` and that within each NPA pool
  the busiest and quietest DID differ by at most 1 call. Round-robin over an
  uncapped pool should differ by exactly 0 or 1; the assertion allows 3.
- **17** asserts all six gateways took traffic and the spread is within 5% of
  the mean. **The "all six" half is the important one** — a broken rotation
  that buckets by wall-clock second, or one derived from `${UNIQUEID}`, still
  produces a plausible-looking even split across a *subset* of gateways.

**Criteria 18–23 run with `TRANSFER_MIN_ACD=3`, not 60.** Criterion 19 as
written is "3 calls at 90s each, the 4th is flagged" — 270 seconds of waiting
to exercise an integer comparison. The test config scales the *threshold* down
so the suite can place 6-second calls through the identical branch. Criteria
20 and 21 scale with it: "5 short calls" become 1-second calls, still below
the threshold, and "2 long calls" stay long enough to be tracked but too few
to qualify.

`TRANSFER_MIN_CALLS` is **not** scaled. It stays at 3, because 3 is the value
validated against production CDRs and criteria 19 and 21 exist specifically to
prove the boundary between 2 and 3. Scaling that would test nothing.

**Criterion 22 is an ordering test, not a rejection test.** NPA 855 is
toll-free, so rule 1 would call `18555550111` a transfer leg — but
`blocklist.test.csv` also lists `1855555`, and the blocklist runs first in the
dialplan. The test requires both that the call is refused with
`HIGH_COST_PREFIX` *and* that `SBC-TRANSFER-LEG` was never logged for it. A
transfer leg is not a trusted call; it is a call whose caller ID we do not
own. (A generated blocklist would never contain a toll-free row —
`build-blocklist.py` excludes those NPAs — so that row is hand-added purely to
prove the ordering holds if one ever did.)

**Criterion 23 requires suppression, not deletion.** After
`didctl.sh transfers remove`, the test places three *more* long answered calls
and requires the destination to still be un-flagged. A `remove` implemented as
a plain delete would pass the first half and fail here, because the next three
calls would silently re-learn it.

The volume phase swaps in `uas-fractel-stub-fast.xml` and
`uac-invite-fast.xml`. The normal fixtures hold each call for 20 seconds
against a concurrency cap of 10; 1000 of those would take over half an hour
and spend most of it refused with `CONCURRENCY_CAP`. Note that sipp's `-d`
only affects `<pause>` elements that have **no** `milliseconds` attribute of
their own, so it cannot shorten `uac-invite.xml` — hence a separate scenario
rather than a flag.

---

## What SKIPs and why

| | Why it cannot run here |
|---|---|
| **crit 3b** — host firewall | on-box traffic never reaches the WAN interface. `nmap` from elsewhere. |
| **crit 11** — reboot | a test run cannot reboot the host it is running on. |
| **two-way audio** | needs the real customer and the real carrier. The stub echoes RTP; it does not prove a human can hear a human. |
| **cid / cid-empty** | those test the 403 rejection path, which is no longer the default. They SKIP while `VALIDATE_CALLERID=false` and tell you how to run them. Criteria 12 and 12b cover the behaviour that *is* default. |
| **STIR/SHAKEN attestation** | FracTEL signs, and this suite has no FracTEL. Now that the asserted number is one of our DIDs rather than customer-supplied, **A-level attestation becomes possible** where it was previously B — but whether FracTEL grants it depends on their provisioning, not on this box. Confirm on the first live call. |
| **FracTEL accepting our DIDs** | the stub answers anything. Whether the carrier accepts these specific numbers as caller ID on this subaccount is a provisioning question and only the live trunk answers it. |
| **LRN-based cost control** | the blocklist matches the number *dialled*. Whether a given number has been ported into an expensive prefix cannot be known without an LNP dip, which this box does not do. See README.md. |

---

## Reading failures

- `results/*.msg` — the full SIP ladder SIPp saw. Start here.
- `results/*.err` — SIPp error traces.
- `results/media.pcap` — the criterion 10 capture.
- `grep SBC- /var/log/asterisk/messages` — every dial, failover and rejection
  with its reason.
- `asterisk -rvvv` then `pjsip set logger on` — live SIP ladder from Asterisk's
  side.

Common results and what they mean:

| Symptom | Cause |
|---|---|
| `408` everywhere | the stub is not running, or the trunk still points at the real carrier |
| `401` on crit 3a | `[sbc-acl]` did not match; you are relying on one layer instead of two |
| `403` where you expected `503` | the caller ID check fired before the check you were testing |
| `404` on a short destination | fewer than 2 digits matches no extension pattern, so Asterisk refuses before the dialplan runs. Still a refusal, just not a dialplan one. |
| crit 1 fails on `Avail` | qualify has not completed a round yet — the driver waits `FRACTEL_QUALIFY_FREQ`, raise it if your box is slow |
