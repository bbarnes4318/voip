# SBC acceptance tests

Fixtures and a driver for acceptance criteria 1–11.

```
run-acceptance.sh              driver, PASS/FAIL/SKIP per criterion
testenv.sh                     swap between production and test config
capture-acceptance.sh          run the suite and emit REDACTED output for RUNBOOK.md
config.test.env.example        test configuration (loopback everything)

sipp/uac-invite.xml            customer dialer, happy path      crit 4, 6, 7, 8, 10
sipp/uac-expect-reject.xml     unauthorized source is refused   crit 3a
sipp/uac-expect-503.xml        dialplan refuses the call        crit 5, 6, 9
sipp/uac-expect-403-badcid.xml malformed caller ID is refused
sipp/uac-empty-cid.xml         absent caller ID is refused
sipp/uas-fractel-stub.xml      stands in for the FracTEL trunk

sipp/destinations.csv          valid NANP destinations
sipp/destinations-badnanp.csv  non-NANP, malformed, and high-risk NANP
sipp/destinations-badcid.csv   alpha / short / self-dial / bad-NPA caller IDs
```

Every phone number in the fixtures is in the **555-01XX** range that NANPA
reserves for fiction and testing. If a fixture ever escapes onto a live trunk
it cannot reach a real subscriber.

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
| 3 — dialplan | NANP allowlist, NPA denylist, caps, CID validation | crit 5, 6, 7, 9 and the CID tests |

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
trunk points at a local SIPp stub and whose caps are tiny (concurrency 3, CPS
5) so the capacity criteria prove themselves in seconds. It backs up
`/etc/asterisk` first. `restore` re-renders production config from
`config.env` — it does not merely copy the backup back, so what you end up
with is always exactly what `config.env` describes.

Running the suite against the **live FracTEL trunk** would put test INVITEs on
a brand-new subaccount. That is a good way to have the carrier's fraud system
take an interest in you on day one. Don't.

### Addressing

Everything lives in `127.0.0.0/8`, which Linux binds in its entirety to `lo`,
so each of these is a distinct bindable source address:

| Address | Role |
|---|---|
| `127.0.0.1:5060` | the SBC (Asterisk binds `0.0.0.0`) |
| `127.0.0.11` | customer 1 → matches `pkclient1` |
| `127.0.0.12` | customer 2 → matches `pkclient2` |
| `127.0.0.20:5080` | the FracTEL stub |
| `127.0.0.99` | unauthorized third party |

They are all different on purpose. Two `type=identify` sections matching the
same source address is undefined behaviour — whichever endpoint wins is an
implementation detail, and a test built on it proves nothing.

SIPp binds `-p 5061`…`5064` rather than 5060, because Asterisk holds
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

---

## What SKIPs and why

| | Why it cannot run here |
|---|---|
| **crit 3b** — host firewall | on-box traffic never reaches the WAN interface. `nmap` from elsewhere. |
| **crit 11** — reboot | a test run cannot reboot the host it is running on. |
| **two-way audio** | needs the real customer and the real carrier. The stub echoes RTP; it does not prove a human can hear a human. |
| **STIR/SHAKEN attestation** | FracTEL signs. Customer-supplied CID gets **B** attestation, which is correct and expected — A is only for CID that is a FracTEL DID. Nothing on this box changes that. |

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
