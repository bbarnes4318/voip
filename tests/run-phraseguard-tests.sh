#!/usr/bin/env bash
#
# run-phraseguard-tests.sh — everything about PhraseGuard that can be proven
# without the box.
#
#   ./run-phraseguard-tests.sh          run everything
#   ./run-phraseguard-tests.sh -v       show each case
#
# WHAT THIS COVERS AND WHAT IT CANNOT
# -----------------------------------
# Covered here, offline, every run: the phonetic matcher, the corpus and its
# rules, phrase matching in all four tiers, the exclusion veto, the Tier B
# scorer and its suppressors, duplicate suppression, corpus hot reload, the
# pcap reader, RTP demux, call attribution, the RMS gate at each of its
# boundaries, the daemon's refusal conditions, and the evidence log and
# counters end to end.
#
# NOT covered here, and not coverable here:
#
#   Call-ID -> channel resolution   needs a live Asterisk with live calls.
#                                   tools/phraseguard-spike.sh measures it.
#   ASR accuracy and CPU cost       needs a speech model and hand-labelled
#                                   audio off this trunk. phraseguard/asr.py
#                                   --bench measures the cost.
#   false-positive rate             needs five days of real traffic in shadow
#                                   mode. That is the whole of phase 5.
#
# A green run here means the logic is sound. It does not mean the component is
# ready to enforce, and nothing in this file should be read as saying so.
#
# NO ASTERISK IS CONTACTED and no configuration is read from /etc.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PG="$ROOT/phraseguard"
TOOLS="$ROOT/tools"
VERBOSE=0
[[ "${1:-}" == "-v" || "${1:-}" == "--verbose" ]] && VERBOSE=1

B=$'\033[1m'; R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; D=$'\033[2m'; N=$'\033[0m'
[[ -t 1 ]] || { B=""; R=""; G=""; Y=""; D=""; N=""; }

PASS=0; FAIL=0
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ok()   { PASS=$((PASS+1)); (( VERBOSE )) && printf '  %s OK %s  %s\n' "$G" "$N" "$1"; return 0; }
bad()  { FAIL=$((FAIL+1)); printf '  %sFAIL%s  %s\n' "$R" "$N" "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; return 0; }
head_() { printf '\n%s%s%s\n' "$B" "$1" "$N"; }

# run <label> <expected-exit> <cmd...>
run() {
  local label="$1" want="$2"; shift 2
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  if [[ "$rc" == "$want" ]]; then ok "$label"; else
    bad "$label" "exit $rc, wanted $want"
    (( VERBOSE )) && sed 's/^/        | /' <<< "$out"
  fi
}

# expect <label> <needle> <cmd...>   — command output must contain needle
expect() {
  local label="$1" needle="$2"; shift 2
  local out
  out="$("$@" 2>&1)"
  if grep -qF -- "$needle" <<< "$out"; then ok "$label"; else
    bad "$label" "output did not contain: $needle"
    (( VERBOSE )) && sed 's/^/        | /' <<< "$out"
  fi
}

# reject <label> <needle> <cmd...>   — command output must NOT contain needle
reject() {
  local label="$1" needle="$2"; shift 2
  local out
  out="$("$@" 2>&1)"
  if grep -qF -- "$needle" <<< "$out"; then
    bad "$label" "output unexpectedly contained: $needle"
    (( VERBOSE )) && sed 's/^/        | /' <<< "$out"
  else ok "$label"; fi
}

echo
echo "${B}PhraseGuard offline test suite${N}   $ROOT"
command -v python3 >/dev/null || { echo "  python3 is required" >&2; exit 2; }

# ---------------------------------------------------------------------------
head_ "1. phonetics"
run "double metaphone self-test" 0 python3 "$PG/metaphone.py"

# ---------------------------------------------------------------------------
head_ "2. corpus"
run "phrases.csv lints clean (en)" 0 \
    python3 "$TOOLS/phraseguard-lint.py" --quiet
run "phrases.csv lints clean with the ur seed set" 0 \
    python3 "$TOOLS/phraseguard-lint.py" --quiet --langs en,ur

# A linter that never fails is not a linter. Each of these breaks one rule.
cat > "$WORK/bad-short.csv" <<'EOF'
> tier,category,lang,anchor,phrase,notes
A,A1,en,seq,call me,two tokens at anchor=seq
EOF
run "lint rejects a Tier A seq phrase under 3 tokens" 1 \
    python3 "$TOOLS/phraseguard-lint.py" --quiet --corpus "$WORK/bad-short.csv"

cat > "$WORK/bad-common.csv" <<'EOF'
> tier,category,lang,anchor,phrase,notes
A,A2,en,pair,the you,two common words at Tier A
EOF
run "lint rejects a Tier A pair of common words" 1 \
    python3 "$TOOLS/phraseguard-lint.py" --quiet --corpus "$WORK/bad-common.csv"

cat > "$WORK/bad-lang.csv" <<'EOF'
> tier,category,lang,anchor,phrase,notes
A,A5,ur,seq,warrant nikal gaya hai,SEED unreviewed
EOF
run "lint rejects an unreviewed non-English row at Tier A" 1 \
    python3 "$TOOLS/phraseguard-lint.py" --quiet --corpus "$WORK/bad-lang.csv" --langs en,ur

expect "the ur seed set is NOT loaded by default" "languages  en=" \
    python3 "$TOOLS/phraseguard-lint.py"
reject "the ur seed set is NOT loaded by default (no ur)" "ur=" \
    python3 "$TOOLS/phraseguard-lint.py"

# ---------------------------------------------------------------------------
head_ "3. matching, tiers, veto and scoring"
out="$(python3 "$HERE/phraseguard-cases.py" 2>&1)"; rc=$?
if [[ "$rc" == 0 ]]; then
  ok "$(tail -1 <<< "$out")"
  PASS=$((PASS + $(sed -n 's/.*  \([0-9]*\) passed.*/\1/p' <<< "$out") - 1))
else
  bad "behavioural cases"
  sed 's/^/      /' <<< "$out"
fi

# ---------------------------------------------------------------------------
head_ "4. capture, demux and the RMS gate"
GEN="$TOOLS/testdata/make-phraseguard-pcap.py"
CUST=116.202.146.131

python3 "$GEN" "$WORK/speech.pcap" --voiced-seconds 12 >/dev/null 2>&1
python3 "$GEN" "$WORK/comfort.pcap" --kind comfort >/dev/null 2>&1
python3 "$GEN" "$WORK/silence.pcap" --kind silence >/dev/null 2>&1
python3 "$GEN" "$WORK/short.pcap" --voiced-seconds 3 >/dev/null 2>&1

tap() { python3 "$PG/tap.py" --pcap "$1" --customer-ips "$CUST" --report; }

expect "SIP is parsed and the call is seen" "calls seen            1" tap "$WORK/speech.pcap"
expect "the call is attributed to its RTP stream" "attributed to call  1" tap "$WORK/speech.pcap"
expect "no customer stream is left unattributed" "UNATTRIBUTED        0" tap "$WORK/speech.pcap"
expect "the carrier leg is dropped before decoding" "other leg (drop)  600" tap "$WORK/speech.pcap"
expect "speech opens the RMS gate" "gate opened         1" tap "$WORK/speech.pcap"
expect "comfort noise does NOT open the gate" "gate opened         0" tap "$WORK/comfort.pcap"
expect "silence does NOT open the gate" "gate opened         0" tap "$WORK/silence.pcap"
expect "speech shorter than the gate window does NOT open it" \
       "gate opened         0" tap "$WORK/short.pcap"

# REGRESSION: streams that never open their gate must still be expired. The
# GC sweep used to sit at the END of feed(), after every early return, so it
# ran only for streams already past the gate -- which the class docstring
# itself says are the minority. The silent majority accumulated forever on a
# daemon meant to run for weeks, and pinned the daemon's Vosk recognisers with
# them.
python3 - "$PG" <<'PY' && ok "silent streams are garbage-collected" \
    || bad "silent streams are garbage-collected"
import struct, sys
sys.path.insert(0, sys.argv[1])
from tap import RtpDemux
d = RtpDemux(["1.2.3.4"], idle_timeout=1.0)
silence = bytes([0xFF]) * 160
for i in range(300):
    pkt = struct.pack("!BBHII", 0x80, 0, 1, 160, 0x1000 + i) + silence
    d.feed(1000.0 + i * 10, "1.2.3.4", 40000 + i, "5.6.7.8", 10000, pkt)
sys.exit(0 if len(d.streams) < 10 else 1)
PY

# REGRESSION: RTP routinely beats the SDP answer through the pipe. Resolving a
# stream's Call-ID once at stream creation left it unattributable for the whole
# call -- no channel to hang up, and a null customer IP that silently dropped
# every count from the per-customer evidence.
python3 - "$PG" <<'PY' && ok "call attribution is retried, not attempted once" \
    || bad "call attribution is retried, not attempted once"
import struct, sys
sys.path.insert(0, sys.argv[1])
from tap import RtpDemux
class LateTracker:
    def __init__(self): self.n = 0; self.calls = {}
    def call_for_media(self, ip, port):
        self.n += 1
        if self.n < 3:
            return None                       # SDP not parsed yet
        class C: call_id = "abc@floor"; streams = set()
        return C
d = RtpDemux(["1.2.3.4"]); tr = LateTracker()
silence = bytes([0xFF]) * 160
for i in range(10):
    pkt = struct.pack("!BBHII", 0x80, 0, i, i * 160, 0x99) + silence
    d.feed(1000.0 + i * 0.02, "1.2.3.4", 40000, "5.6.7.8", 10000, pkt, tr)
st = list(d.streams.values())[0]
sys.exit(0 if st.call_id == "abc@floor" else 1)
PY

# ---------------------------------------------------------------------------
head_ "4b. the 8 kHz -> 16 kHz rate bridge"
# REGRESSION: every general-purpose Vosk English model is 16 kHz and this trunk
# is 8 kHz G.711. Feeding 8 kHz PCM to a 16 kHz recogniser does not degrade, it
# throws "Sampling frequency mismatch, expected 16000, got 8000" on the FIRST
# frame -- so with the shipped model PhraseGuard could not process one packet.
python3 - "$PG" <<'PY' && ok "8 kHz audio is bridged to a 16 kHz model" \
    || bad "8 kHz audio is bridged to a 16 kHz model"
import array, sys
sys.path.insert(0, sys.argv[1])
from asr import upsample_2x, resample_to
src = array.array("h", [0, 1000, 2000, 1000, 0, -1000, -2000, -1000] * 20)
pcm = src.tobytes()
up = upsample_2x(pcm)
out = array.array("h"); out.frombytes(up)
# Twice the samples for the same wall-clock duration, originals preserved.
assert len(up) == len(pcm) * 2, "not 2x"
assert list(out[1::2]) == list(src), "original samples not preserved"
assert resample_to(pcm, 8000, 8000) == pcm, "8k->8k should pass through"
try:
    resample_to(pcm, 8000, 44100)
except ValueError:
    pass
else:
    raise AssertionError("an unsupported rate must be refused, not mangled")
sys.exit(0)
PY

python3 - "$PG" <<'PY' && ok "the model's native rate is read, not assumed" \
    || bad "the model's native rate is read, not assumed"
import os, sys, tempfile
sys.path.insert(0, sys.argv[1])
from asr import model_sample_rate
d = tempfile.mkdtemp(); os.makedirs(os.path.join(d, "conf"))
with open(os.path.join(d, "conf", "mfcc.conf"), "w") as fh:
    fh.write("--use-energy=false\n--sample-frequency=8000\n")
assert model_sample_rate(d) == 8000, "did not read the model rate"
assert model_sample_rate("/no/such/model") == 16000, "wrong default"
sys.exit(0)
PY

# REGRESSION: Vosk drops grammar words the model's lexicon lacks and reports it
# through Kaldi's C++ logger straight to fd 2, where sys.stderr and
# redirect_stderr never see it. On the first real run that was 16 Tier A brand
# nouns silently removed from the grammar. The first fix read the model's word
# list off disk and found nothing, because vosk-model-small-en-us-0.15 has no
# graph/words.txt. Asking the library what it decided is the robust route.
python3 - "$PG" <<'PY' && ok "Vosk's dropped-vocabulary warnings are captured from fd 2" \
    || bad "Vosk's dropped-vocabulary warnings are captured from fd 2"
import os, sys
sys.path.insert(0, sys.argv[1])
from asr import capture_c_stderr, _drain, parse_oov
sample = (b"WARNING (VoskAPI:UpdateGrammarFst()) Ignoring word missing in vocabulary: 'anydesk'\n"
          b"WARNING (VoskAPI:UpdateGrammarFst()) Ignoring word missing in vocabulary: 'teamviewer'\n"
          b"WARNING (VoskAPI:UpdateGrammarFst()) Ignoring word missing in vocabulary: 'anydesk'\n")
with capture_c_stderr() as cap:
    os.write(2, sample)          # the DESCRIPTOR, as a C++ library writes it
assert parse_oov(_drain(cap)) == ["anydesk", "teamviewer"], "OOV not parsed/deduped"
sys.exit(0)
PY

python3 - "$PG" <<'PY' && ok "a real Vosk error is NOT swallowed with the noise" \
    || bad "a real Vosk error is NOT swallowed with the noise"
import io, sys
sys.path.insert(0, sys.argv[1])
from asr import passthrough_non_oov
buf = io.StringIO(); real = sys.stderr; sys.stderr = buf
try:
    passthrough_non_oov(
        "WARNING (VoskAPI) Ignoring word missing in vocabulary: 'anydesk'\n"
        "ERROR (VoskAPI) a real problem\n")
finally:
    sys.stderr = real
out = buf.getvalue()
assert "a real problem" in out, "the real error was swallowed"
assert "anydesk" not in out, "the benign warning was not suppressed"
sys.exit(0)
PY

head_ "5. the daemon, end to end, with a scripted recogniser"
cat > "$WORK/script.txt" <<'EOF'
hello sir am i speaking with the homeowner today
this is officer martinez badge number four four seven
your social security number has been suspended due to suspicious activity
do not tell the bank tell them it is for a home renovation
i need you to go to the store and buy a gift card
EOF
python3 "$GEN" "$WORK/long.pcap" --voiced-seconds 30 >/dev/null 2>&1

dmn() {
  PK_CLIENT_IPS="$CUST" \
  PHRASEGUARD_LOG_DIR="$WORK/logs" \
  PHRASEGUARD_STATE="$WORK/counters.json" \
  PHRASEGUARD_MANAGER_CONF="$ROOT/asterisk/manager.conf.tpl" \
  python3 "$PG/phraseguardd.py" "$@"
}

rm -rf "$WORK/logs" "$WORK/counters.json"
run "the daemon replays a capture to completion" 0 \
    dmn --pcap "$WORK/long.pcap" --script "$WORK/script.txt"

JSONL="$(cat "$WORK"/logs/*.jsonl 2>/dev/null)"
grepj() { grep -qF -- "$1" <<< "$JSONL"; }

if grepj '"tier": "A"'; then ok "Tier A matches reach the JSONL log"; else bad "Tier A matches reach the JSONL log"; fi
if grepj '"phrase": "social security number has been suspended"'; then
  ok "the A5 phrase is recorded verbatim"; else bad "the A5 phrase is recorded verbatim"; fi
if grepj '"event": "b_threshold"'; then ok "a Tier B threshold event is recorded"; else bad "a Tier B threshold event is recorded"; fi
if grepj '"mode": "shadow"'; then ok "records are stamped shadow mode"; else bad "records are stamped shadow mode"; fi
if grepj '"context"'; then ok "every match carries its +/-10 word context"; else bad "every match carries its +/-10 word context"; fi

# THE NO-AUDIO-RETENTION RULE. Not a style point: it is the storage decision
# and the legal one. Nothing under the log directory may be audio, and no
# record may carry a payload field.
if grepj '"pcm"' || grepj '"audio"' || grepj '"payload"'; then
  bad "no audio field appears in any record"
else ok "no audio field appears in any record"; fi
if find "$WORK/logs" -type f ! -name '*.jsonl' 2>/dev/null | grep -q .; then
  bad "the log directory holds ONLY jsonl" "$(find "$WORK/logs" -type f ! -name '*.jsonl')"
else ok "the log directory holds ONLY jsonl"; fi

# One utterance is one event -- the duplicate-suppression regression.
DUPES="$(grep -o '"phrase": "[^"]*"' <<< "$JSONL" | sort | uniq -d)"
if [[ -z "$DUPES" ]]; then ok "no phrase is reported twice for one utterance"
else bad "no phrase is reported twice for one utterance" "$DUPES"; fi

expect "the counters attribute the call to the customer IP" "$CUST" \
    python3 "$PG/record.py" --state "$WORK/counters.json"
expect "the counters report a rate, not just a count" "kill/1k" \
    python3 "$PG/record.py" --state "$WORK/counters.json"

# ---------------------------------------------------------------------------
head_ "6. shadow mode and the refusal conditions"
expect "shadow mode is the default" "SHADOW" dmn --self-test
reject "shadow mode does not hang anything up" '"action": "hangup"' \
    bash -c "cat '$WORK'/logs/*.jsonl"

expect "enforce + a scripted recogniser is REFUSED" "REFUSING" \
    dmn --self-test --enforce --script "$WORK/script.txt"
expect "enforce with no recogniser is REFUSED" "REFUSING" \
    dmn --self-test --enforce
expect "enforce + heuristic Call-ID resolution is REFUSED" \
    "must not run on a heuristic" \
    env PK_CLIENT_IPS="$CUST" PHRASEGUARD_ALLOW_HEURISTIC_MATCH=1 \
        PHRASEGUARD_SCRIPT="$WORK/script.txt" \
        PHRASEGUARD_LOG_DIR="$WORK/logs" PHRASEGUARD_STATE="$WORK/counters.json" \
        python3 "$PG/phraseguardd.py" --self-test --enforce
expect "an empty PK_CLIENT_IPS is REFUSED" "REFUSING" \
    env PK_CLIENT_IPS= PHRASEGUARD_LOG_DIR="$WORK/logs" \
        python3 "$PG/phraseguardd.py" --self-test

# REGRESSION: a capture that never starts must be a LOUD FAILURE.
# Reported from the first real install: tcpdump died instantly, the tap read an
# empty stream, treated it as a clean end-of-capture, logged start then stop and
# exited 0 -- so systemd said "Deactivated successfully" and nothing anywhere
# said why. tcpdump's stderr was being discarded, so there was nothing to read.
mkdir -p "$WORK/shim"
cat > "$WORK/shim/tcpdump" <<'SH'
#!/bin/bash
echo "tcpdump: Couldn't change to 'tcpdump' uid=123 gid=123: Permission denied" >&2
exit 1
SH
chmod +x "$WORK/shim/tcpdump"
rm -rf "$WORK/deadlogs"; mkdir -p "$WORK/deadlogs"
out="$(PATH="$WORK/shim:$PATH" PK_CLIENT_IPS="$CUST" \
       PHRASEGUARD_LOG_DIR="$WORK/deadlogs" PHRASEGUARD_STATE="$WORK/dead.json" \
       PHRASEGUARD_MANAGER_CONF="$ROOT/asterisk/manager.conf.tpl" \
       python3 "$PG/phraseguardd.py" --lock "$WORK/dead.pid" 2>&1)"
rc=$?
if [[ "$rc" != 0 ]]; then ok "a capture that never starts exits NON-ZERO"
else bad "a capture that never starts exits NON-ZERO" "exited 0 -- systemd would call this success"; fi
if grep -qF "CAPTURE FAILED" <<< "$out"; then ok "the failure says CAPTURE FAILED"
else bad "the failure says CAPTURE FAILED" "$out"; fi
if grep -qF "Permission denied" <<< "$out"; then
  ok "tcpdump's own stderr is surfaced, not discarded"
else bad "tcpdump's own stderr is surfaced, not discarded" "$out"; fi
if grep -qF '"event": "fatal"' "$WORK"/deadlogs/*.jsonl 2>/dev/null; then
  ok "the capture failure is recorded in the evidence log"
else bad "the capture failure is recorded in the evidence log"; fi

# And the flag that stops it happening again on Ubuntu.
if grep -qF '"-Z", "root"' "$PG/tap.py"; then
  ok "tcpdump is told not to drop privileges (-Z root)"
else bad "tcpdump is told not to drop privileges (-Z root)"; fi

# ---------------------------------------------------------------------------
head_ "7. AMI and the actuator"
expect "the AMI probe reads manager.conf rather than assuming" "disabled" \
    python3 "$PG/actuator.py" --manager-conf "$ROOT/asterisk/manager.conf.tpl"
expect "AMI-off is explained, not just reported" "asterisk -rx" \
    python3 "$PG/actuator.py" --manager-conf "$ROOT/asterisk/manager.conf.tpl"

python3 - "$PG" <<'PY' && ok "the hangup command is refused at the ~490-byte CLI limit" \
    || bad "the hangup command is refused at the ~490-byte CLI limit"
import sys
sys.path.insert(0, sys.argv[1])
from actuator import AsteriskCLI, Hangup, Resolution
h = Hangup(AsteriskCLI("/bin/false"), enforce=True)
acted, detail = h.execute(Resolution("PJSIP/" + "x" * 600, "callid", [], False))
sys.exit(0 if (not acted and "too long" in detail) else 1)
PY

python3 - "$PG" <<'PY' && ok "an ambiguous resolution never hangs anything up" \
    || bad "an ambiguous resolution never hangs anything up"
import sys
sys.path.insert(0, sys.argv[1])
from actuator import AsteriskCLI, Hangup, Resolution
h = Hangup(AsteriskCLI("/bin/false"), enforce=True)
r = Resolution(None, "heuristic", ["PJSIP/a-1", "PJSIP/b-2"], ambiguous=True)
acted, detail = h.execute(r)
sys.exit(0 if (not acted and "unresolved" in detail) else 1)
PY

# REGRESSION: probe() used to set probed=True BEFORE the CLI read, so a
# transient failure -- or a probe landing before the dialplan reaches
# Set(__SBC_CALLID=...) -- marked a channel unreadable for its whole life.
# That silently corrupts the spike's coverage number, which gates the project.
python3 - "$PG" <<'PY' && ok "a failed probe is retried, not written off" \
    || bad "a failed probe is retried, not written off"
import sys
sys.path.insert(0, sys.argv[1])
from actuator import ChannelTable
CONCISE = "PJSIP/pkclient1-0001!sbc-customer!13365551212!1!Up!Dial!x!13255551234!!!3!12!!abc"
class FlakyCLI:
    calls = 0; errors = 0; seconds = 0.0
    def __init__(self): self.n = 0
    def rx(self, cmd):
        if cmd.startswith("core show channels"):
            return CONCISE + "\n"
        self.n += 1
        if self.n == 1:
            return ""                          # transient CLI failure
        return "Variables:\nSBC_CALLID=live@floor\n"
t = ChannelTable(FlakyCLI(), list_ttl=0)
t.probe_all()                                  # first probe fails
t.probe_all()                                  # must try again
sys.exit(0 if t.by_call_id.get("live@floor") == "PJSIP/pkclient1-0001" else 1)
PY

python3 - "$PG" <<'PY' && ok "a channel that never exposes SBC_CALLID stops being probed" \
    || bad "a channel that never exposes SBC_CALLID stops being probed"
import sys
sys.path.insert(0, sys.argv[1])
from actuator import ChannelTable
CONCISE = "PJSIP/pkclient1-0001!sbc-customer!13365551212!1!Up!Dial!x!13255551234!!!3!12!!abc"
class NoVarCLI:
    calls = 0; errors = 0; seconds = 0.0
    def __init__(self): self.probes = 0
    def rx(self, cmd):
        if cmd.startswith("core show channels"):
            return CONCISE + "\n"
        self.probes += 1
        return "Variables:\nSOMETHING_ELSE=1\n"
cli = NoVarCLI()
t = ChannelTable(cli, list_ttl=0)
for _ in range(50):
    t.probe_all()
# Bounded retries, then written off -- not one fork per pass forever.
sys.exit(0 if cli.probes <= ChannelTable.MAX_PROBE_MISSES else 1)
PY

# ---------------------------------------------------------------------------
head_ "8. the spike harness"
run "spike syntax" 0 bash -n "$TOOLS/phraseguard-spike.sh"
expect "the spike refuses its preflight without Asterisk" "Preflight refused" \
    env CONF=/dev/null PK_CLIENT_IPS="$CUST" "$TOOLS/phraseguard-spike.sh" --self-test

head_ "8b. the deploy script"
run "deploy syntax" 0 bash -n "$TOOLS/deploy-phraseguard.sh"
# It must refuse rather than half-install when the box is not ready. A deploy
# script that presses on through a failed preflight on a border element is the
# thing that takes the trunk down.
mkdir -p "$WORK/fakesbc"
printf 'PK_CLIENT_IPS=%s\nRTP_START=10000\nRTP_END=20000\n' "$CUST" > "$WORK/fakesbc/config.env"
expect "deploy refuses a preflight it cannot pass" "NOTHING was installed" \
    "$TOOLS/deploy-phraseguard.sh" --install --sbc-dir "$WORK/fakesbc"
if [[ -d "$WORK/fakesbc/phraseguard" ]]; then
  bad "a refused deploy left files behind"
else
  ok "a refused deploy left nothing behind"
fi
# Comments are stripped first: the script TALKS about not restarting Asterisk,
# and grepping the raw file for "render.sh" matches the comment that promises
# it never runs one. What matters is whether any executable line does it.
CODE="$WORK/deploy-code.sh"
sed 's/[[:space:]]*#.*$//' "$TOOLS/deploy-phraseguard.sh" > "$CODE"
for forbidden in "systemctl restart asterisk" "systemctl reload asterisk" \
                 "pjsip reload" "module reload" "render.sh" "install.sh" \
                 "nft " "killswitch"; do
  if grep -qF -- "$forbidden" "$CODE"; then
    bad "deploy must never invoke: $forbidden" "$(grep -nF -- "$forbidden" "$CODE" | head -2)"
  else
    ok "deploy never invokes: $forbidden"
  fi
done

# /etc/asterisk may be READ -- the preflight checks the live dialplan for
# __SBC_CALLID, which is the whole point of reading it. It must never be
# WRITTEN: no redirect into it, no cp/mv/install/sed -i/tee targeting it.
if grep -nE '(>>?[[:space:]]*/etc/asterisk|(cp|mv|install|tee|touch|rm|chmod|chown)[^|]*[[:space:]]/etc/asterisk|sed[^|]*-i[^|]*/etc/asterisk)' "$CODE"; then
  bad "deploy must never WRITE to /etc/asterisk"
else
  ok "deploy reads /etc/asterisk but never writes to it"
fi

# ---------------------------------------------------------------------------
head_ "9. shell and python syntax"
for f in "$TOOLS/phraseguard-spike.sh"; do
  run "bash -n $(basename "$f")" 0 bash -n "$f"
done
for f in "$PG"/*.py "$TOOLS"/phraseguard-lint.py "$TOOLS"/testdata/make-phraseguard-pcap.py; do
  run "compile $(basename "$f")" 0 python3 -m py_compile "$f"
done

# ---------------------------------------------------------------------------
echo
echo "----------------------------------------------------------------------"
if (( FAIL )); then
  printf '  %s%sFAILED%s  %d passed, %d failed\n' "$R" "$B" "$N" "$PASS" "$FAIL"
  echo
  exit 1
fi
printf '  %s%sPASSED%s  %d checks\n' "$G" "$B" "$N" "$PASS"
echo
echo "  ${D}This proves the logic. It does not prove the component is ready to${N}"
echo "  ${D}enforce: Call-ID resolution, ASR cost and the false-positive rate${N}"
echo "  ${D}all need the box and live traffic. See README.md \"Order of work\".${N}"
echo
exit 0
