# PhraseGuard

Real-time scam-script detection on the wholesale trunk, out of band.

PhraseGuard listens to a passive packet tap, transcribes only the customer leg
of calls that carry real speech, matches against a tracked phrase corpus, and —
once enforcement is deliberately enabled — disconnects a call that uses
scam-call-centre script language. Its more important output is the per-customer
record: which source IP produced how many confirmed matches across how many
monitored calls, which is what supports a commercial conversation or a carrier
complaint.

**It is not `killswitch.sh`.** `/opt/sbc/killswitch.sh` is a different,
pre-existing thing that refuses customer traffic wholesale. PhraseGuard does not
call it, wrap it, import it or modify it.

---

## Status

| phase | what | state |
|---|---|---|
| 1 | Call-ID → channel spike | **built, NOT RUN** — needs the box and live traffic |
| 2 | capture and demux | built, proven on fixtures; stream counts need live traffic |
| 3 | ASR sidecar | built; **cores/stream and accuracy unmeasured** — needs a model and real audio |
| 4 | matcher and corpus | built and tested offline |
| 5 | shadow mode | ready to deploy; **no traffic days run** |
| 6 | enforcement | not started, and must not start before phase 5 is reviewed |

Two things block phases 1, 3 and 5, and neither is a code problem:

- **The trunk is paused.** No traffic and no new CDR since 2026-08-12 20:23 UTC
  (`HANDOFF.md` § Trunk is paused). Every remaining measurement needs live calls.
- Production is read-only for analysis, and everything that writes goes to the
  lab box first (`HANDOFF.md` § Standing constraints).

Run `tools/phraseguard-spike.sh --arm` the moment the trunk returns. Nothing
downstream is trustworthy until it passes.

---

## Architecture

```
        the wire
           │
           │  tcpdump -i any -U -w -   "udp and (portrange 10000-20000 or port 5060)"
           │  (a PIPE. no capture file exists, anywhere, ever)
           ▼
    ┌──────────────┐
    │   tap.py     │  pcap stream reader
    │              │
    │  SipTracker  │  Call-ID ── customer IP, ANI, DNIS, SDP m=audio ports
    │  RtpDemux    │  5-tuple + SSRC → per-stream ring buffer
    └──────┬───────┘
           │
           │  FILTER 1  src ∈ PK_CLIENT_IPS  ──────────► carrier leg dropped
           │  FILTER 2  ≥5s of RMS ≥ 200     ──────────► silence dropped
           │
           ▼  decoded PCM16, in memory, discarded as consumed
    ┌──────────────┐
    │   asr.py     │  Vosk, constrained grammar built from the corpus
    │              │  no model / no vosk → NullRecognizer, detector off,
    └──────┬───────┘  calls unaffected
           │  finalised utterances only (never partials)
           ▼
    ┌──────────────┐
    │  matcher.py  │  normalise → inverted index → fuzzy + phonetic
    │              │  Tier X veto → overlap suppression → tier + score
    │  CallWindow  │  rolling 90s transcript, ±10 word context
    │  BScorer     │  distinct B categories − C suppressors
    └──────┬───────┘
           │
    ┌──────┴────────────────────────┐
    │                               │
    ▼ Tier A confident              ▼ Tier B threshold / A-near
┌────────────┐                ┌──────────────┐
│actuator.py │                │  record.py   │
│            │                │              │
│ Call-ID →  │                │ syslog       │  tag sbc-phraseguard
│  SBC_CALLID│                │ JSONL        │  /var/log/phraseguard/
│  → channel │                │ counters     │  per-IP, rolling 24h
│            │                │ sbc-health   │  alerts at configured rates
│ asterisk -rx "channel       └──────────────┘
│  request hangup <chan>"
│  — ONLY if PHRASEGUARD_ENFORCE=1
└────────────┘
```

### What it deliberately does not do

| not done | why |
|---|---|
| ARI / Stasis | `res_ari*` and `res_stasis*` are not loaded, `http.conf` is off, and the firewall has no rule for 8088. Three independent reasons nothing listens. Adding it back is a config change on a box with a documented history of config changes taking it down. |
| `MixMonitor` in the dialplan | every dialplan change is on the caller-ID path for 100% of calls. |
| any edit to `extensions.conf.tpl` | same reason. PhraseGuard **reads** a variable the dialplan already sets; it adds nothing. |
| a new CDR column | `cdr_custom.conf` needs an Asterisk restart, and the portal shipper parses a fixed column count. |
| an Asterisk restart | nothing here requires one, for install, for config, or for the corpus. |
| automatic trunk suspension | suspending a pkclient IP is a commercial decision on the only customer on the trunk. PhraseGuard surfaces it; a human pulls it. |

---

## The Call-ID → channel mapping

This was the engineering risk, and the answer is better than expected: **the
dialplan already records it.** `asterisk/extensions.conf.tpl`, in
`[sbc-customer]`:

```
same => n,Set(__SBC_CALLID=${CHANNEL(pjsip,call-id)})
```

The double underscore makes it inherited, it is set early — before the
caller-ID rewrite and before the `Dial` — and `core show channel <name>` prints
a `Variables:` block. So the Call-ID is readable from the CLI on a live
channel with no AMI, no ARI, and no config change. The mapping is **exact**: it
is the dialplan's own copy of the same header parsed off the wire.

**The obvious join does not work, and this is worth recording.** The first
design joined on `(endpoint, ANI, DNIS, channel age)` from
`core show channels concise`. `extensions.conf.tpl` line ~428 does
`Set(CALLERID(num)=${SBC_DID})` on the customer-leg channel before the `Dial`,
so by the time a channel is visible to the CLI its `cid_num` is the DID the
pool assigned, not the ANI the customer sent. That join would have matched
nothing — or, worse, matched the wrong call once two floors drew the same DID.

`(endpoint, dialled extension, channel age)` survives the rewrite and remains as
a **fallback**. It is a heuristic, it refuses on ambiguity rather than guessing,
and `PHRASEGUARD_ALLOW_HEURISTIC_MATCH` defaults to `0`. The daemon **refuses to
start** with enforcement and the heuristic both enabled: the failure mode is
disconnecting a different customer's legitimate call.

None of the above is proven until `tools/phraseguard-spike.sh` has run against
live traffic. It measures coverage, method, ambiguity and latency, and exits
non-zero if the mapping does not hold.

### AMI

**AMI is off**, and `asterisk/manager.conf.tpl` says why: `enabled=no`,
`webenabled=no`, because `monitor.sh`, `killswitch.sh` and `healthcheck.sh` all
drive Asterisk through `asterisk -rx` over the local control socket, which file
permissions already restrict to root and the asterisk group. Turning AMI on
would add a TCP listener and a credentials file for no gain.

So hangups fork `asterisk -rx`. That is one fork per Tier A kill — not per
packet, not per call — and Tier A kills are rare by construction.
`actuator.probe_ami()` reads the **live** `manager.conf` at startup and reports
what it finds rather than assuming; if AMI is ever enabled, `Hangup` is the
place a persistent connection goes, and the interface is already shaped for it.

`asterisk -rx` truncates around 490 bytes of total command and returns success
when it does (`RUNBOOK.md`). A hangup is ~60 bytes, so it is not at risk —
nothing here batches, and `Hangup.execute()` refuses a command approaching the
limit rather than issuing one that might silently no-op.

---

## The corpus

`phrases.csv`. Columns: `tier,category,lang,anchor,phrase,notes`. Comments start
`#`; the header starts `> `. Hot-reloaded on mtime change and on `SIGHUP`
(`systemctl reload sbc-phraseguard`). **A failed reload keeps the previously
loaded corpus** — a typo in the CSV must not take the detector down.

| tier | meaning |
|---|---|
| **A** | disconnect on a single confident match, when enforcing |
| **B** | score only. Two distinct B *categories* in a rolling 90s window, or one B plus an A-near, raises a threshold event. Never disconnects. |
| **C** | suppressor. Reduces the B score in the same window. Never fires anything alone. |
| **X** | exclusion. Vetoes any A/B match overlapping its token span. |

`anchor` is the column that makes the brief's rule checkable instead of
remembered — *"a single common token is never a Tier A phrase; every A entry is
either a distinctive brand noun or a phrase of three or more words"*:

- `brand` — 1–2 token proper/product noun, matched **phonetically**
- `pair` — exactly 2 tokens, a distinctive collocation, tighter threshold
- `seq` — 3+ tokens, fuzzy token-sequence match

`tools/phraseguard-lint.py` refuses a Tier A row whose anchor and shape
disagree, or one built only from common English words, and proves every row
matches its own text. Run it after any corpus edit; the test suite runs it too.

### Tier X earns its place

`X1 "last four of your social"` is not decoration. Without it,
*"can I get the last four of your social security number"* — a routine
final-expense qualifier — scores against A7 `"your full social security
number"` at 0.844. The test suite asserts both halves: that the veto suppresses
it, **and** that it would fire without the veto, so the case cannot quietly stop
testing anything.

The `"last four **digits** of your social"` variant needed its own row: it is
one token past the edit budget of the base phrase.

### Demoting, not tuning

Shadow mode will produce Tier A phrases that fire on legitimate insurance
traffic. Change `A` → `B` on that row. **Do not raise a threshold to silence one
phrase** — thresholds are global, and that trades a false positive here for a
miss everywhere else. Three rows already ship marked `DEMOTE-CANDIDATE`
(`log me in`, `quick assist`, `safe account`); the linter lists them on every
run.

### Cross-language

The `ur` seed set is in the file and **is not loaded** (`PHRASEGUARD_LANGS`
defaults to `en`). Every seed row is Tier B, and the linter **rejects** any
non-English row at Tier A: Roman-Urdu has no settled orthography, an English
acoustic model renders it unpredictably, and a wrong Tier A row in a language
nobody reviewing the logs reads disconnects a legitimate call invisibly.
Promotion is a human decision after native-speaker review.

Which categories survive a language switch is not uniform. A1/A2/A3/A7 keep most
of their value because the product and brand nouns embed untranslated — a
Karachi floor still says "gift card", "AnyDesk", "Bitcoin", "OTP", "card
number". **A5 and A6 do not.** Threats and coaching translate cleanly and are
invisible to an English-only model. That is the real gap, and it is a gap in
coverage, not in the code.

Spanish is a separate later addition and matters for US-Hispanic-targeting
floors.

---

## Matching

8 kHz mu-law telephony audio with heavily accented speech runs 25–40% WER. Each
layer buys back a specific class of error:

| layer | catches |
|---|---|
| normalisation | case, punctuation, `don't`→`dont`, and number-word folding so `the 6 digit code` ≡ `the six digit code` |
| edit distance | ≈2 edits per 10 characters, proportional to phrase length |
| Double Metaphone | out-of-vocabulary brand names: `anydesk` ≡ `any desk` ≡ `anydisk` ≡ `any disc` |
| anchoring | stops a single common token from ever being Tier A |
| Tier X veto | legitimate qualifiers that sit inside a Tier A phrase's edit budget |

### Phonetics collapse word boundaries, and that cuts both ways

Stripping whitespace before taking the Double Metaphone code is what makes
`anydesk` ≡ `any desk` ≡ `any disc` one corpus entry instead of four. It also
makes them the same code as **`and ask`**:

```
phonetic_key("any desk") == phonetic_key("and ask") == "ANTSK"
```

*"Come in and ask for the manager"* scored A1 at 1.000 — a Tier A disconnect on
one of the most ordinary phrases in English. Collapsing boundaries is exactly
what buys the accent robustness, so the fix is not to stop doing it: a brand
span must contain at least one token that is **not** an ordinary English word.
That is the brief's own "single common token is never Tier A" rule applied to
the *span that matched* rather than only to the row it matched against.

`COMMON_WORDS` lives in `matcher.py` and the linter imports it, so the rule the
matcher applies at runtime and the rule the linter enforces at edit time cannot
drift. Both halves are regression-tested: ordinary English stays clean, and the
real brand nouns still fire.

**Two thresholds, always.** Above `kill`, a match reports at its own tier.
Between `review` and `kill`, a Tier A phrase reports as **`A-near`**: it logs, it
counts toward the B scorer, and it never disconnects. The gap between them is
where shadow mode does its work.

**Distinct categories, not distinct phrases.** A floor saying "social security
administration", "office of inspector general" and "badge number" in one breath
has said one thing three ways — one B1 signal. Counting it as three would clear
the threshold on agency impersonation alone, which is exactly the reading that
makes a compliant Medicare agent look like a scammer.

**C1 is weighted separately** (default 1.5 vs 0.5). The
not-affiliated-with-any-government-agency disclaimer is read by floors with a
compliance script and by no scam floor ever, and the categories it coincides
with — B1 agency names, B2 urgency — are precisely the ones a legitimate
Medicare campaign trips.

### Cost

Matching runs per recognised token per concurrent stream. A flat loop over the
corpus is roughly 5 cores at this box's peak; the inverted index in
`_build_index()` takes it to roughly a quarter of one. The trade: a phrase whose
**every** distinctive token is mangled is never woken. Trigger tokens are
indexed under both their spelling and their Double Metaphone code, so a token
must be mangled past phonetic recognition rather than merely misspelled — but it
is a trade, and it is the first thing to check if shadow mode shows a phrase
that should have fired and did not.

---

## Evidence and privacy

Persisted per event: timestamp, Call-ID, customer source IP, ANI, DNIS, matched
phrase, tier, category, recogniser confidence, and a ±10 word text window.

**No audio, ever.** `tcpdump` writes to a pipe; there is no code path in this
component that writes PCM, mu-law, a WAV or a capture file, and no option to add
one. Decoded audio lives in a bounded in-memory ring and is discarded as it is
consumed. The test suite asserts that nothing but `.jsonl` appears under the log
directory and that no record carries an audio field.

That is a legal decision as much as a storage one: a recording of a live
consumer call held on a border element is a different regulatory object from a
log line quoting twenty words, and the twenty words are what a carrier complaint
actually needs.

The constrained grammar helps here too — out-of-grammar speech comes back as
`[unk]`, so the ±10 word context is drawn from corpus vocabulary rather than
being a transcript of a consumer's private conversation.

Confidence is recorded as `null` when the recogniser does not supply it. A
missing confidence is a fact; a fabricated `1.0` is a lie in an evidence log.

### The counters are the point

Killing individual calls is whack-a-mole; a floor that loses a call redials in
four seconds. `record.py` tracks, per customer source IP over a rolling 24h:
calls monitored, Tier A kills, A-near matches, B threshold events — and emits a
**rate per 1,000 monitored calls**, because a floor doing 40,000 calls a day and
one doing 400 are not comparable on raw counts.

State is persisted atomically so a daemon restart does not silently reset a
24-hour record. An evidence log that quietly forgets is worse than none: it
produces a clean-looking history for a floor that was caught three times before
the last deploy.

```
./phraseguard/record.py                    # the 24h attribution table
./phraseguard/phraseguardd.py --status     # matches by tier, category, phrase
```

---

## Known evasions

Documented, not solved. Floors adapt within days of the first disconnect, and
pretending otherwise would be worse than saying so.

| evasion | effect | note |
|---|---|---|
| spelling brand names letter by letter | defeats both edit distance and phonetics — "a n y d e s k" shares no token with `anydesk` | would need a letter-sequence rule that is itself a false-positive source |
| codewords — "the plastic", "the paper", "green" | total. No corpus entry exists for a word the floor invented last week | this is the fundamental limit of a phrase corpus |
| moving to WhatsApp or a callback number early | the scam happens off this trunk entirely | the call that gets monitored is the one that carried no script |
| switching language mid-call | A5 and A6 go invisible; A1/A2/A3/A7 largely survive on embedded nouns | see § Cross-language |
| DTMF instead of speech | card numbers and OTPs never become audio | RTP event payloads are visible to the tap but are not in scope |
| speaking over the disconnect threshold slowly | the 90s B window rolls; a script spread across three minutes never accumulates | widening the window trades against precision |

**A disconnect teaches the floor exactly which phrase tripped it.** That is a
further argument for the shape this already has: log broadly, kill narrowly.
Tier B never disconnects precisely so that the majority of what PhraseGuard
knows is never signalled back to the floor.

**Treat this as a deterrent and an evidence generator, not a gate.** Its highest
value is the per-customer record.

---

## Configuration

Everything lives in `config.env` under `# PhraseGuard`. Nothing is hardcoded —
no phrases in source, no thresholds in source. See `config.env.example` for the
annotated list. The ones that matter most:

| variable | default | |
|---|---|---|
| `PHRASEGUARD_ENFORCE` | `0` | **shadow mode.** `1` disconnects calls. |
| `PHRASEGUARD_LANGS` | `en` | corpus languages to load |
| `PHRASEGUARD_VOSK_MODEL` | *(empty)* | model path. Empty → detector off, calls unaffected |
| `PHRASEGUARD_KILL_SCORE` | `0.86` | Tier A disconnect threshold |
| `PHRASEGUARD_REVIEW_SCORE` | `0.72` | below this, no match at all |
| `PHRASEGUARD_B_THRESHOLD` | `2.0` | distinct B categories to raise an event |
| `PHRASEGUARD_ALLOW_HEURISTIC_MATCH` | `0` | refused together with enforcement |

---

## Install

### From Windows

Do **not** double-click the `.sh` file — Windows will ask you which app to open
it with, because a bash script is not a Windows program. Open a terminal.

**Git Bash** (ships with Git for Windows, so you probably already have it).
Right-click inside the checkout → *Git Bash Here*, or find *Git Bash* in the
Start menu and `cd` to the folder:

```bash
./tools/deploy-phraseguard.sh --remote root@167.235.206.206 --dry-run
./tools/deploy-phraseguard.sh --remote root@167.235.206.206 --install
./tools/deploy-phraseguard.sh --remote root@167.235.206.206 --check
```

**PowerShell**, if you would rather not install anything. Windows 10 (1803+)
and Windows 11 already ship `ssh.exe`, `scp.exe` and `tar.exe`:

```powershell
.\tools\deploy-phraseguard.ps1 -Remote root@167.235.206.206 -Action DryRun
.\tools\deploy-phraseguard.ps1 -Remote root@167.235.206.206 -Action Install
.\tools\deploy-phraseguard.ps1 -Remote root@167.235.206.206 -Action Check
```

If PowerShell refuses with *"running scripts is disabled on this system"*:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\deploy-phraseguard.ps1 -Remote root@167.235.206.206 -Action DryRun
```

The `.ps1` is only a courier: it packages the checkout, copies it over, and runs
the same `.sh` on the box. Prefer Git Bash — it is one less wrapper between you
and the result, and it is the path that gets exercised.

### From macOS or Linux

```bash
./tools/deploy-phraseguard.sh --remote root@167.235.206.206 --dry-run
./tools/deploy-phraseguard.sh --remote root@167.235.206.206 --install
./tools/deploy-phraseguard.sh --remote root@167.235.206.206 --check
```

### On the box itself

One command, from a checkout on the box:

```bash
sudo ./tools/deploy-phraseguard.sh --dry-run    # see every action first
sudo ./tools/deploy-phraseguard.sh --install
sudo ./tools/deploy-phraseguard.sh --check      # is it working?
sudo ./tools/deploy-phraseguard.sh --uninstall  # take it back off
```

It runs the preflight, fetches the speech model and the `vosk` module, copies
the files, appends a settings block to `config.env` (backing it up first, and
never editing a line that is already there), runs the daemon's own self-test,
and only then installs and starts the unit. It is idempotent — re-running it is
safe.

**It never restarts or reloads Asterisk, and never touches anything under
`/etc/asterisk`.** That is why it is a separate script and not part of
`install.sh`, which ends in `systemctl restart asterisk`.

If the preflight refuses, nothing has been installed and nothing has changed.
A missing speech model is a warning, not a failure: PhraseGuard still runs, still
correlates calls and still keeps the per-customer counters — it just matches
nothing until a model is present.

Doing it by hand instead:

```bash
# a speech model — only the SMALL models carry the grammar FST (Gr.fst)
mkdir -p /opt/vosk && cd /opt/vosk
curl -LO https://alphacephei.com/vosk/models/vosk-model-small-en-us-0.15.zip
unzip vosk-model-small-en-us-0.15.zip
python3 -m pip install vosk

install -m 0644 /opt/sbc/phraseguard/sbc-phraseguard.service \
        /etc/systemd/system/sbc-phraseguard.service
systemctl daemon-reload
systemctl enable --now sbc-phraseguard.service
```

`After=asterisk.service` **without** `Requires=` is the most important line in
the unit: a `Requires=` would let a crash-looping detector drag the trunk with
it. `Nice=10`, `CPUQuota=200%` and `OOMScoreAdjust=500` all say the same thing —
PhraseGuard must never be why Asterisk cannot get a core.

Size `CPUQuota` from the **measured** figure `asr.py --bench` reports on this
box, not from the default.

Removal is `systemctl disable --now sbc-phraseguard` and deleting the unit.
Neither touches Asterisk.

---

## Operating

```bash
./phraseguard/phraseguardd.py --self-test        # preflight; starts nothing
./tools/phraseguard-lint.py                      # after any corpus edit
systemctl reload sbc-phraseguard                 # SIGHUP: reload phrases.csv
journalctl -t sbc-phraseguard -f                 # live
journalctl -t sbc-health | grep PhraseGuard      # per-customer alerts
./phraseguard/phraseguardd.py --status           # shadow-mode review input
./phraseguard/record.py                          # 24h per-customer table
./phraseguard/tap.py --report --seconds 300      # stream counts, no ASR
./phraseguard/asr.py --bench                     # cores per concurrent stream
```

Replay a saved capture through the whole pipeline without touching Asterisk:

```bash
./phraseguard/phraseguardd.py --pcap incident.pcap
```

Offline test suite — no Asterisk, no trunk, no model, no network:

```bash
./tests/run-phraseguard-tests.sh
```

---

## Order of work

Stop and report at each checkpoint rather than proceeding on assumption.

1. **Channel-mapping spike.** `tools/phraseguard-spike.sh --self-test`, then
   `--dump` to verify the CLI field layout, then `--arm`. Exit 0 means exact
   resolution with no ambiguity. **Anything else stops the workstream.**
2. **Capture and demux.** `tap.py --report` over a real traffic window. Report
   stream counts and what fraction of answered calls carry customer-leg speech —
   that number sizes the ASR fleet.
3. **ASR sidecar.** `asr.py --bench` for cores per concurrent stream and latency.
   Accuracy needs a hand-labelled sample of real calls off this trunk. If it does
   not fit in the headroom left *after* Asterisk's relay load at peak, move the
   recogniser to a sidecar.
4. **Matcher and corpus.** Done, and offline-tested.
5. **Shadow mode.** `PHRASEGUARD_ENFORCE=0`, minimum five full traffic days.
   Report total matches by tier and category, per-phrase hit counts, and a
   hand-reviewed sample of **every distinct Tier A phrase that fired**.
6. **Enforcement.** Separate deploy, only after the review, only for Tier A, and
   only for phrases that survived it.

Every phase: no Asterisk restart, no dialplan change, no CDR change, fail-open
on every error path, and `verify-deployment.sh` clean with `DEPLOYED_COMMIT`
re-stamped before the phase is called done.

---

## Files

| file | |
|---|---|
| `phrases.csv` | the corpus. The only place phrases exist. |
| `metaphone.py` | Double Metaphone. `python3 metaphone.py` self-tests. |
| `matcher.py` | normalisation, index, fuzzy + phonetic matching, tiers, B scorer |
| `tap.py` | pcap stream, SIP/SDP correlation, RTP demux, RMS gate |
| `asr.py` | Vosk + constrained grammar, null fallback, `--bench` |
| `actuator.py` | AMI probe, Call-ID → channel, out-of-band hangup |
| `record.py` | syslog + JSONL evidence log, per-customer counters |
| `phraseguardd.py` | the daemon |
| `spike.py` | the phase 1 measurement |
| `sbc-phraseguard.service` | systemd unit, installed by hand |
| `../tools/phraseguard-spike.sh` | operator wrapper for the spike |
| `../tools/phraseguard-lint.py` | corpus linter |
| `../tools/testdata/make-phraseguard-pcap.py` | synthetic SIP+RTP fixtures |
| `../tests/run-phraseguard-tests.sh` | offline suite |
| `../tests/phraseguard-cases.py` | behavioural assertions |

Stdlib only, except Vosk — which is optional, and whose absence degrades the
detector rather than stopping the daemon.
