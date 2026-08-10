#!/usr/bin/env bash
#
# run-acceptance.sh — drives the acceptance criteria against a running SBC.
#
#   sudo ./tests/testenv.sh apply        <- point the trunk at the local stub
#   sudo ./tests/run-acceptance.sh
#   sudo ./tests/testenv.sh restore      <- put production config back
#
# Reports PASS / FAIL / SKIP per criterion and exits non-zero if anything
# failed. Nothing is reported as a pass unless it was actually observed:
# criteria that cannot be exercised from on-box SKIP loudly. Read
# tests/README.md for what this suite structurally cannot prove.
#
# Requires root: it restarts Asterisk (criterion 2), reads
# /var/log/asterisk/messages, and drives the killswitch.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CONF="${CONF:-$HERE/config.test.env}"
SIPP_DIR="$HERE/sipp"
LOGDIR="$HERE/results"
AST_LOG="${AST_LOG:-/var/log/asterisk/messages}"

[[ -f "$CONF" ]] || { echo "missing $CONF — cp tests/config.test.env.example tests/config.test.env"; exit 1; }
# shellcheck disable=SC1090
set -a; source "$CONF"; set +a

SBC="${SBC_PUBLIC_IP:-127.0.0.1}:${SIP_PORT:-5060}"
PK1="${PK_CLIENT_IP_1:?}"
PK2="${PK_CLIENT_IP_2:?}"
UNAUTH="${TEST_UNAUTHORIZED_IP:-}"
# First entry of FRACTEL_PROXY_IPS, as ip[:port]. Falls back to 5060 when the
# test config omits the port, rather than silently using the address as a port.
_STUB="${FRACTEL_PROXY_IPS%%,*}"
STUB_IP="${_STUB%%:*}"
STUB_PORT="${_STUB##*:}"
[[ "$STUB_PORT" == "$_STUB" ]] && STUB_PORT=5060
CAP="${MAX_CONCURRENT_PER_IP:-3}"
CPS="${MAX_CPS:-5}"
CDR_CSV_PATH="${CDR_CSV_PATH:-/var/log/asterisk/cdr-custom/sbc.csv}"
DID_CAP="${DID_DAILY_CAP:-200}"
VOL_CALLS="${ACCEPT_VOLUME_CALLS:-1000}"
VOL_CPS="${ACCEPT_VOLUME_CPS:-12}"

# Every gateway, as ip[:port]. Criterion 17 needs one stub per entry — with a
# single gateway the round-robin is unprovable and could be silently broken.
GW_LIST=()
IFS=',' read -r -a _gwraw <<< "${FRACTEL_PROXY_IPS:-}"
for _g in "${_gwraw[@]}"; do
  _g="$(echo "$_g" | tr -d '[:space:]')"
  [[ -n "$_g" ]] && GW_LIST+=("$_g")
done
GW_COUNT="${#GW_LIST[@]}"

mkdir -p "$LOGDIR"
rm -f "$LOGDIR"/*.out "$LOGDIR"/*.err "$LOGDIR"/*.msg 2>/dev/null

PASS=0; FAIL=0; SKIP=0
GREEN=$'\033[32m'; RED=$'\033[31m'; YEL=$'\033[33m'; DIM=$'\033[2m'; NC=$'\033[0m'
[[ -t 1 ]] || { GREEN=""; RED=""; YEL=""; DIM=""; NC=""; }

pass() { printf '  %sPASS%s  %-6s %s\n' "$GREEN" "$NC" "$1" "$2"; PASS=$((PASS+1)); }
fail() { printf '  %sFAIL%s  %-6s %s\n' "$RED"   "$NC" "$1" "$2"; FAIL=$((FAIL+1)); }
skip() { printf '  %sSKIP%s  %-6s %s\n' "$YEL"   "$NC" "$1" "$2"; SKIP=$((SKIP+1)); }
note() { printf '        %s%s%s\n' "$DIM" "$1" "$NC"; }

# --- log helpers ----------------------------------------------------------
# A mark is a wall-clock second; log lines are "YYYY-MM-DD HH:MM:SS.mmm ...",
# so a lexicographic compare on the first 19 characters is a valid ordering.
mark()      { sleep 1.1; date '+%F %T'; }
since()     { awk -v m="$1" 'substr($0,1,19) >= m' "$AST_LOG" 2>/dev/null; }
count_rej() { since "$1" | grep -c "SBC-REJECT reason=$2" 2>/dev/null || true; }
count_dial(){ since "$1" | grep -c "SBC-DIAL " 2>/dev/null || true; }

# --- sipp helpers ---------------------------------------------------------
sipp_run() { # sipp_run <tag> <scenario> <csv|-> <src_ip> <local_port> [extra...]
  local tag="$1" sf="$2" inf="$3" src="$4" lp="$5"; shift 5
  local args=(-sf "$SIPP_DIR/$sf" -i "$src" -p "$lp"
              -nostdin -timeout 45 -timeout_error
              -trace_err  -error_file   "$LOGDIR/$tag.err"
              -trace_msg  -message_file "$LOGDIR/$tag.msg")
  [[ "$inf" != "-" ]] && args+=(-inf "$SIPP_DIR/$inf")
  sipp "${args[@]}" "$@" "$SBC" >"$LOGDIR/$tag.out" 2>&1
}

# Pull the final response code SIPp actually received, for evidence.
seen_code() {
  grep -oE '^SIP/2\.0 [0-9]{3}' "$LOGDIR/$1.msg" 2>/dev/null \
    | awk '{print $2}' | grep -v '^100$' | tail -1
}

# --- FracTEL stub farm ----------------------------------------------------
# One stub per gateway. -trace_msg on every one of them is what makes
# criterion 12 possible: the INVITE the SBC actually sent toward the carrier
# is the only place the rewritten From / PAI / RPID can be observed, and it
# is not visible from the customer side at all.
start_stubs() { # start_stubs <scenario> [extra sipp args...]
  local sf="$1"; shift
  local i=0 g ip port
  rm -f "$LOGDIR"/stub*.msg "$LOGDIR"/stub*.out 2>/dev/null
  for g in "${GW_LIST[@]}"; do
    i=$((i + 1))
    ip="${g%%:*}"; port="${g##*:}"
    [[ "$port" == "$g" ]] && port=5060
    sipp -sf "$SIPP_DIR/$sf" -i "$ip" -p "$port" -nostdin -bg \
         -trace_msg -message_file "$LOGDIR/stub$i.msg" \
         "$@" >"$LOGDIR/stub$i.out" 2>&1
  done
  sleep 2
  pgrep -fc 'uas-fractel-stub' 2>/dev/null || echo 0
}

stop_stubs() {
  pkill -f 'uas-fractel-stub' 2>/dev/null
  sleep 1
  return 0
}

# The INVITE block the SBC sent toward a given destination. sipp's message
# file separates messages with a rule of dashes.
outbound_invite() { # outbound_invite <destination-number>
  cat "$LOGDIR"/stub*.msg 2>/dev/null | awk -v want="INVITE sip:$1" '
    /^-{5,}/ { if (buf ~ want) last=buf; buf=""; next }
    { buf = buf $0 "\n" }
    END { if (buf ~ want) last=buf; printf "%s", last }'
}

# Which DID the dialplan says it selected for a destination, from SBC-DIAL.
did_for() { # did_for <mark> <destination-number>
  since "$1" | grep 'SBC-DIAL ' | grep -F "dst=$2 " \
    | sed -n 's/.*[ ]did=\([0-9]\{1,\}\).*/\1/p' | tail -1
}

cleanup() {
  [[ -n "${STUB_PID:-}" ]] && kill "$STUB_PID" 2>/dev/null
  [[ -n "${HOLD_PID:-}" ]] && kill "$HOLD_PID" 2>/dev/null
  [[ -n "${VOL_PID:-}"  ]] && kill "$VOL_PID"  2>/dev/null
  pkill -f 'uas-fractel-stub' 2>/dev/null
  "$ROOT/killswitch.sh" off >/dev/null 2>&1
  wait 2>/dev/null
  return 0
}
trap cleanup EXIT

# ===========================================================================
echo
echo "SBC acceptance suite"
echo "  target        $SBC"
echo "  customer IPs  $PK1 (pkclient1)  $PK2 (pkclient2)"
echo "  fractel stub  $STUB_IP:$STUB_PORT"
echo "  caps          concurrency=$CAP  cps=$CPS"
echo "  logs          $LOGDIR"
echo "==========================================================================="

# --- preflight ------------------------------------------------------------
[[ "$(id -u)" -eq 0 ]] || { echo "must run as root"; exit 1; }
command -v sipp >/dev/null || { echo "sipp not installed: apt install -y sip-tester"; exit 1; }
asterisk -rx "core show version" >/dev/null 2>&1 || { echo "Asterisk is not running"; exit 1; }

if ! asterisk -rx "pjsip show identifies" 2>/dev/null | grep -q "$PK1"; then
  echo
  echo "${RED}Test configuration is not applied.${NC}"
  echo "This suite needs the trunk pointed at the local stub, not FracTEL."
  echo
  echo "    sudo $HERE/testenv.sh apply"
  echo
  exit 1
fi
[[ -r "$AST_LOG" ]] || { echo "cannot read $AST_LOG"; exit 1; }

# --- DID counters ---------------------------------------------------------
# Per-DID daily counters live in the Asterisk database and persist across
# restarts BY DESIGN — that is the whole point of the cap. Which means a
# second run of this suite would start with the first run's counts still
# there, and criterion 14 (drive one DID to its cap in 6 calls) would behave
# differently every time.
#
# So the suite zeroes them. This is safe here and nowhere else: the preflight
# above has already established that the trunk points at the local stub, so
# this is not a box carrying customer traffic.
if [[ -x "$ROOT/didctl.sh" ]]; then
  "$ROOT/didctl.sh" reset --all --force >/dev/null 2>&1
  note "DID daily counters cleared for today (test config only)"
fi

# --- start the FracTEL stub farm -----------------------------------------
UP="$(start_stubs uas-fractel-stub.xml -rtp_echo)"
if [[ "${UP:-0}" -lt "$GW_COUNT" ]]; then
  echo "${RED}only ${UP:-0} of $GW_COUNT FracTEL stubs started${NC} — see $LOGDIR/stub*.out"
  echo "each gateway in FRACTEL_PROXY_IPS needs its own bindable address"
  exit 1
fi
note "$GW_COUNT fractel stub(s) up: ${GW_LIST[*]}"
sleep "${FRACTEL_QUALIFY_FREQ:-15}"   # let one qualify round land so crit 1 can see Avail
echo

# ===========================================================================
# Criterion 1 — endpoints present, FracTEL reachable
# ===========================================================================
EP="$(asterisk -rx 'pjsip show endpoints' 2>/dev/null)"
MISSING=""
for e in pkclient1 pkclient2 fractel1; do
  grep -q "$e" <<< "$EP" || MISSING+="$e "
done
CONTACTS="$(asterisk -rx 'pjsip show contacts' 2>/dev/null | grep 'fractel' || true)"
AVAIL="$(grep -c 'Avail' <<< "$CONTACTS" || true)"
if [[ -n "$MISSING" ]]; then
  fail "crit 1" "missing endpoint(s): $MISSING"
elif [[ "${AVAIL:-0}" -lt 1 ]]; then
  fail "crit 1" "endpoints present but no FracTEL gateway is Avail"
  note "$(head -3 <<< "$CONTACTS")"
elif [[ "${AVAIL:-0}" -lt "$GW_COUNT" ]]; then
  # Not fatal for criteria 1-11, but criterion 17 measures distribution across
  # all of them and would silently measure a smaller set.
  fail "crit 1" "only $AVAIL of $GW_COUNT FracTEL gateways are Avail"
  note "criterion 17 cannot measure distribution across gateways that are down"
  note "$(head -3 <<< "$CONTACTS")"
else
  pass "crit 1" "pkclient1, pkclient2 and all $GW_COUNT fractel gateways present and Avail"
fi

# ===========================================================================
# Criterion 2 — config loads with zero errors and zero warnings
# ===========================================================================
M="$(mark)"
systemctl restart asterisk >/dev/null 2>&1
for _ in $(seq 1 30); do asterisk -rx "core show version" >/dev/null 2>&1 && break; sleep 1; done
sleep 4
PROBLEMS="$(since "$M" | grep -E 'WARNING|ERROR' | grep -v 'SBC-REJECT' || true)"
DEPRECATED="$(since "$M" | grep -iE 'deprecat|no longer supported|has been removed' || true)"
if [[ -n "$PROBLEMS" || -n "$DEPRECATED" ]]; then
  fail "crit 2" "config load produced warnings/errors"
  sed 's/^/        /' <<< "${PROBLEMS}${DEPRECATED}" | head -20
else
  pass "crit 2" "restart produced zero errors, zero warnings, zero deprecation notices"
fi
# The stub survives the Asterisk restart, but give qualify time to recover.
sleep "${FRACTEL_QUALIFY_FREQ:-15}"

# ===========================================================================
# Criterion 3a — unauthorized source rejected at the Asterisk layer
# ===========================================================================
if [[ -z "$UNAUTH" ]]; then
  skip "crit 3a" "TEST_UNAUTHORIZED_IP is unset"
else
  if sipp_run unauth uac-expect-reject.xml destinations.csv "$UNAUTH" 5063 -m 1; then
    CODE="$(seen_code unauth)"
    pass "crit 3a" "INVITE from unauthorized $UNAUTH refused with ${CODE:-4xx} (Asterisk ACL layer)"
    [[ "$CODE" == "401" ]] && note "got 401 not 403 — [sbc-acl] did not match; you are down to one layer, investigate"
  else
    fail "crit 3a" "unauthorized source was NOT refused — STOP, this box is an open relay"
    note "see $LOGDIR/unauth.msg"
  fi
fi

# ===========================================================================
# Criterion 3b — unauthorized source rejected by the HOST FIREWALL
# ===========================================================================
# Structurally untestable from on-box: loopback traffic never traverses the
# WAN interface where the nftables rules live. Reported as SKIP, never PASS.
skip "crit 3b" "host firewall CANNOT be tested from on-box — must be probed from another machine"
note "from a host that is NOT in ADMIN_SSH_IP:"
note "  nmap -sU -p 5060,10000-10010 <SBC_IP>"
note "  nmap -sT -p 22,5038,5060,8088 <SBC_IP>"
note "everything except SSH-from-admin must report filtered. See tests/README.md."

# ===========================================================================
# Criterion 4 — authorized call reaches the FracTEL gateway
# ===========================================================================
M="$(mark)"
if sipp_run happy uac-invite.xml destinations.csv "$PK1" 5061 -m 1 -d 4000; then
  GW="$(since "$M" | grep -o 'gw=fractel[0-9]*' | head -1)"
  pass "crit 4" "authorized INVITE from pkclient1 answered end to end via ${GW:-fractel?}"
else
  fail "crit 4" "authorized call did not complete — see $LOGDIR/happy.err"
  note "$(since "$M" | grep 'SBC-REJECT' | head -2)"
fi

# ===========================================================================
# Criterion 5 — non-NANP and high-risk destinations rejected with 503
# ===========================================================================
if [[ "${NANP_ONLY:-true}" != "true" ]]; then
  skip "crit 5" "NANP_ONLY is false in $CONF — the allowlist is disabled"
else
  M="$(mark)"
  ROWS="$(($(grep -vc '^SEQUENTIAL' "$SIPP_DIR/destinations-badnanp.csv")))"
  if sipp_run badnanp uac-expect-503.xml destinations-badnanp.csv "$PK1" 5061 -m "$ROWS" -r 3; then
    N1="$(count_rej "$M" NOT_NANP)"; N2="$(count_rej "$M" BLOCKED_NPA)"
    pass "crit 5" "all $ROWS non-NANP/high-risk destinations refused with 503"
    note "NOT_NANP=$N1  BLOCKED_NPA=$N2 (includes +252, +881, +44, 011-prefixed, N11, 900, 976, and Caribbean IRSF area codes)"
  else
    fail "crit 5" "a non-NANP destination was NOT refused — premium-rate fraud exposure"
    note "see $LOGDIR/badnanp.msg"
  fi
fi

# ===========================================================================
# Criterion 6 — per-IP concurrency cap
# ===========================================================================
M="$(mark)"
sipp -sf "$SIPP_DIR/uac-invite.xml" -inf "$SIPP_DIR/destinations.csv" \
     -i "$PK1" -p 5064 -m "$CAP" -r 2 -d 30000 -nostdin \
     >"$LOGDIR/hold.out" 2>&1 &
HOLD_PID=$!
sleep 6

LIVE="$(asterisk -rx 'group show channels' 2>/dev/null | awk '$3=="cust" && $2=="pkclient1"' | wc -l)"
if [[ "$LIVE" -ne "$CAP" ]]; then
  fail "crit 6" "expected $CAP calls holding for pkclient1, found $LIVE — cannot test the cap"
else
  if sipp_run overcap uac-expect-503.xml destinations.csv "$PK1" 5061 -m 1; then
    R="$(count_rej "$M" CONCURRENCY_CAP)"
    if [[ "$R" -ge 1 ]]; then
      pass "crit 6" "with cap=$CAP, call $((CAP+1)) refused with 503 (CONCURRENCY_CAP x$R)"
    else
      fail "crit 6" "got a 503 but no CONCURRENCY_CAP notice — rejected for the wrong reason"
    fi
  else
    fail "crit 6" "call $((CAP+1)) was NOT refused with cap=$CAP"
  fi

  # The cap must be per customer IP, not global — otherwise one customer IP
  # saturating the box would silently take the other one down with it.
  if sipp_run other uac-invite.xml destinations.csv "$PK2" 5062 -m 1 -d 3000; then
    pass "crit 6b" "pkclient2 unaffected while pkclient1 is at its cap (per-IP, not global)"
  else
    fail "crit 6b" "pkclient2 was refused while only pkclient1 was at its cap — the cap is global"
  fi
fi
kill "$HOLD_PID" 2>/dev/null; wait "$HOLD_PID" 2>/dev/null; HOLD_PID=""
sleep 3

# ===========================================================================
# Criterion 7 — CPS limit throttles
# ===========================================================================
# Deliberately NOT asserted on sipp's exit code. A working throttle lets some
# calls through and refuses the rest, so neither "all answered" nor "all
# refused" is the expected outcome — the assertion is on what the dialplan
# logged. A blanket block would be just as wrong as no limit at all.
M="$(mark)"
BURST=$((CPS * 4))
sipp -sf "$SIPP_DIR/uac-invite.xml" -inf "$SIPP_DIR/destinations.csv" \
     -i "$PK1" -p 5061 -m "$BURST" -r "$BURST" -rp 1s -d 1000 -nostdin -timeout 30 \
     >"$LOGDIR/cps.out" 2>&1
sleep 3
THROTTLED="$(count_rej "$M" CPS_LIMIT)"
ALLOWED="$(count_dial "$M")"
if [[ "$THROTTLED" -ge 1 && "$ALLOWED" -ge 1 ]]; then
  pass "crit 7" "burst of $BURST/s against cap ${CPS}/s: $ALLOWED dialled, $THROTTLED refused with CPS_LIMIT"
elif [[ "$THROTTLED" -eq 0 ]]; then
  fail "crit 7" "burst of $BURST/s produced no CPS_LIMIT rejections — the limit is not engaging"
else
  fail "crit 7" "burst of $BURST/s was refused entirely ($THROTTLED) — that is a block, not a throttle"
fi
sleep 3

# ===========================================================================
# Criterion 8 — CDR row is complete
# ===========================================================================
# Columns per asterisk/cdr_custom.conf.tpl:
#   1 start 2 answer 3 end 4 source_ip 5 endpoint 6 cid 7 dest 8 duration
#   9 billsec 10 disposition 11 cause 12 gateway 13 call-id 14 reject 15 uniqueid
M="$(mark)"
sipp_run cdrcall uac-invite.xml destinations.csv "$PK1" 5061 -m 1 -d 5000 >/dev/null 2>&1
sleep 3
if [[ ! -s "$CDR_CSV_PATH" ]]; then
  fail "crit 8" "no CDR file at $CDR_CSV_PATH"
else
  ROW="$(tail -n 40 "$CDR_CSV_PATH" | awk '
    function csvsplit(line, arr,   i,n,c,f,q,L) {
      n=0; f=""; q=0; L=length(line)
      for (i=1;i<=L;i++) { c=substr(line,i,1)
        if (q) { if (c=="\"") { if (substr(line,i+1,1)=="\"") { f=f "\""; i++ } else q=0 } else f=f c }
        else { if (c=="\"") q=1; else if (c==",") { arr[++n]=f; f="" } else f=f c } }
      arr[++n]=f; return n }
    { n=csvsplit($0,f); if (n>=15 && f[10]=="ANSWERED") last=$0 }
    END { print last }')"
  if [[ -z "$ROW" ]]; then
    fail "crit 8" "no ANSWERED row in $CDR_CSV_PATH"
  else
    read -r SRC EPN CID DST BSEC CID_SIP <<< "$(awk -v r="$ROW" '
      function csvsplit(line, arr,   i,n,c,f,q,L) {
        n=0; f=""; q=0; L=length(line)
        for (i=1;i<=L;i++) { c=substr(line,i,1)
          if (q) { if (c=="\"") { if (substr(line,i+1,1)=="\"") { f=f "\""; i++ } else q=0 } else f=f c }
          else { if (c=="\"") q=1; else if (c==",") { arr[++n]=f; f="" } else f=f c } }
        arr[++n]=f; return n }
      BEGIN { n=csvsplit(r,f)
              printf "%s %s %s %s %s %s\n",
                (f[4]==""?"-":f[4]), (f[5]==""?"-":f[5]), (f[6]==""?"-":f[6]),
                (f[7]==""?"-":f[7]), (f[9]==""?"-":f[9]), (f[13]==""?"-":f[13]) }')"
    MISS=""
    [[ "$SRC"     == "-" || "$SRC" != "$PK1" ]] && MISS+="source_ip "
    [[ "$EPN"     == "-" ]] && MISS+="customer_endpoint "
    [[ "$CID"     == "-" ]] && MISS+="caller_id "
    [[ "$DST"     == "-" ]] && MISS+="destination "
    [[ ! "$BSEC" =~ ^[0-9]+$ ]] && MISS+="billsec "
    [[ "$CID_SIP" == "-" ]] && MISS+="sip_call_id "
    if [[ -z "$MISS" ]]; then
      pass "crit 8" "CDR row complete"
      note "source_ip=$SRC endpoint=$EPN caller_id=$CID destination=$DST billsec=$BSEC call_id=$CID_SIP"
      note "billsec is a raw whole-second integer, not rounded to a billing increment"
    else
      fail "crit 8" "CDR row missing/wrong: $MISS"
      note "row: $ROW"
    fi
  fi
fi

# ===========================================================================
# Criterion 9 — killswitch
# ===========================================================================
M="$(mark)"
T0="$(date +%s.%N)"
"$ROOT/killswitch.sh" on >/dev/null 2>&1
T1="$(date +%s.%N)"
ELAPSED="$(awk -v a="$T0" -v b="$T1" 'BEGIN{printf "%.3f", b-a}')"

if sipp_run killed uac-expect-503.xml destinations.csv "$PK1" 5061 -m 1; then
  K="$(count_rej "$M" KILLSWITCH)"
  UNDER1="$(awk -v e="$ELAPSED" 'BEGIN{print (e<1.0)?"yes":"no"}')"
  if [[ "$K" -ge 1 && "$UNDER1" == "yes" ]]; then
    pass "crit 9a" "killswitch on in ${ELAPSED}s (<1s); new customer calls refused with 503 (KILLSWITCH)"
  elif [[ "$K" -ge 1 ]]; then
    fail "crit 9a" "killswitch worked but took ${ELAPSED}s (requirement is under 1s)"
  else
    fail "crit 9a" "call refused but not by the killswitch — check the rejection reason"
  fi
else
  fail "crit 9a" "killswitch is ON but the call was not refused"
fi

"$ROOT/killswitch.sh" off >/dev/null 2>&1
sleep 1
if sipp_run restored uac-invite.xml destinations.csv "$PK1" 5061 -m 1 -d 3000; then
  pass "crit 9b" "killswitch off restores service"
else
  fail "crit 9b" "service did NOT come back after killswitch off"
fi

# ===========================================================================
# Criterion 10 — media path
# ===========================================================================
# What this proves on-box: no RTP flows directly between the customer address
# and the carrier address. If direct_media ever leaked, that flow would exist
# and this test would see it.
#
# What it does NOT prove: what FracTEL sees as the source of RTP on the real
# internet. That needs the live trunk — RUNBOOK.md has the manual steps.
if ! command -v tcpdump >/dev/null; then
  skip "crit 10" "tcpdump not installed — cannot inspect the media path"
else
  DM_CUST="$(asterisk -rx 'pjsip show endpoint pkclient1' 2>/dev/null | grep -ci 'direct_media.*false' || true)"
  DM_GW="$(asterisk -rx 'pjsip show endpoint fractel1' 2>/dev/null | grep -ci 'direct_media.*false' || true)"

  timeout 20 tcpdump -i lo -n -c 400 -w "$LOGDIR/media.pcap" \
      "udp portrange ${RTP_START:-10000}-${RTP_END:-20000}" >/dev/null 2>&1 &
  TCPD=$!
  sleep 1
  sipp_run media uac-invite.xml destinations.csv "$PK1" 5061 -m 1 -d 8000 >/dev/null 2>&1
  wait "$TCPD" 2>/dev/null

  DIRECT=0
  if [[ -s "$LOGDIR/media.pcap" ]]; then
    DIRECT="$(tcpdump -nr "$LOGDIR/media.pcap" 2>/dev/null \
      | grep -cE "($PK1\.[0-9]+ > $STUB_IP\.|$STUB_IP\.[0-9]+ > $PK1\.)" || true)"
    RELAY="$(tcpdump -nr "$LOGDIR/media.pcap" 2>/dev/null | wc -l)"
  else
    RELAY=0
  fi

  if [[ "$DM_CUST" -ge 1 && "$DM_GW" -ge 1 && "$DIRECT" -eq 0 && "$RELAY" -gt 0 ]]; then
    pass "crit 10" "direct_media=false on both legs; $RELAY relayed RTP packets, 0 direct customer<->carrier"
    note "this is the on-box half. The FracTEL-side check is manual — see RUNBOOK.md"
  elif [[ "$DIRECT" -gt 0 ]]; then
    fail "crit 10" "$DIRECT RTP packets flowed DIRECTLY between $PK1 and $STUB_IP — direct media leaked"
  elif [[ "$RELAY" -eq 0 ]]; then
    fail "crit 10" "no RTP captured at all — media is not flowing"
  else
    fail "crit 10" "direct_media is not false on both legs (customer=$DM_CUST gateway=$DM_GW)"
  fi
fi

# ===========================================================================
# Criterion 11 — reboot persistence
# ===========================================================================
skip "crit 11" "reboot persistence cannot be tested from inside a test run"
note "reboot the host, then: systemctl is-active asterisk nftables; ./firewall.sh status; ./healthcheck.sh"
note "RUNBOOK.md has the full checklist."

# ===========================================================================
# Caller ID REJECTION (the old behaviour, now off by default)
# ===========================================================================
# VALIDATE_CALLERID=false is the production default: the customer's caller ID
# is discarded and replaced on every call, so refusing traffic over it costs
# revenue and protects nothing. Criteria 12 and 12b below test what happens
# instead. These two tests exercise the 403 path that is still in the
# dialplan for operators who want it, and they SKIP rather than pass when it
# is not the configured behaviour.
if [[ "${VALIDATE_CALLERID:-false}" != "true" ]]; then
  skip "cid" "VALIDATE_CALLERID=false — malformed caller ID is logged, not refused"
  note "that is the default and criteria 12/12b prove the replacement works."
  note "to exercise the 403 path instead:"
  note "  sed -i 's/^VALIDATE_CALLERID=.*/VALIDATE_CALLERID=true/' $CONF"
  note "  sudo $HERE/testenv.sh apply && sudo $HERE/run-acceptance.sh"
  skip "cid-empty" "same reason"
else
  M="$(mark)"
  ROWS="$(($(grep -vc '^SEQUENTIAL' "$SIPP_DIR/destinations-badcid.csv")))"
  if sipp_run badcid uac-expect-403-badcid.xml destinations-badcid.csv "$PK1" 5061 -m "$ROWS" -r 2; then
    R="$(count_rej "$M" BAD_CALLERID)"
    pass "cid" "all $ROWS malformed caller IDs refused with 403 (BAD_CALLERID x$R)"
    note "covers alpha, too-short, self-dial, and invalid-NPA caller IDs"
  else
    fail "cid" "a malformed caller ID was accepted — see $LOGDIR/badcid.msg"
  fi

  M="$(mark)"
  if sipp_run emptycid uac-empty-cid.xml destinations.csv "$PK1" 5061 -m 1; then
    pass "cid-empty" "INVITE with no From user part refused with 403"
  else
    fail "cid-empty" "empty caller ID was accepted"
  fi
fi

# ===========================================================================
# Criterion 12 — the customer's caller ID does not leave this box
# ===========================================================================
# The only place this can be observed is the INVITE the SBC sent toward the
# carrier. Nothing on the customer leg shows it, and the CDR records what we
# INTENDED to send. The stubs run with -trace_msg for exactly this.
CUST_CID=2125551234
DEST12=12125550111
M="$(mark)"
if ! sipp_run cid12 uac-invite.xml destinations-cidrewrite.csv "$PK1" 5061 -m 1 -d 3000; then
  fail "crit 12" "the call did not complete — cannot inspect the outbound INVITE"
  note "see $LOGDIR/cid12.msg"
else
  DID12="$(did_for "$M" "$DEST12")"
  INV12="$(outbound_invite "$DEST12")"
  if [[ -z "$INV12" ]]; then
    fail "crit 12" "no INVITE toward $DEST12 found in any stub trace"
  elif [[ -z "$DID12" ]]; then
    fail "crit 12" "no SBC-DIAL line recorded a selected DID"
  else
    F_FROM="$(grep -i '^From:' <<< "$INV12" | head -1)"
    F_PAI="$(grep  -i '^P-Asserted-Identity:' <<< "$INV12" | head -1)"
    F_RPID="$(grep -i '^Remote-Party-ID:'     <<< "$INV12" | head -1)"
    BAD=""
    grep -q "$DID12" <<< "$F_FROM"  || BAD+="From "
    [[ -n "$F_PAI"  ]] && grep -q "$DID12" <<< "$F_PAI"  || BAD+="P-Asserted-Identity "
    [[ -n "$F_RPID" ]] && grep -q "$DID12" <<< "$F_RPID" || BAD+="Remote-Party-ID "
    # The real assertion: their number is nowhere in the message at all.
    LEAK="$(grep -c "$CUST_CID" <<< "$INV12" || true)"

    if [[ -z "$BAD" && "$LEAK" -eq 0 ]]; then
      pass "crit 12" "From, P-Asserted-Identity and Remote-Party-ID all carry our DID"
      note "customer sent <CUST_CID>; outbound INVITE asserts $DID12 in all three headers"
      note "the customer's value appears 0 times in the outbound INVITE"
      note "$(sed 's/^[[:space:]]*//' <<< "$F_FROM")"
      note "$(sed 's/^[[:space:]]*//' <<< "${F_PAI:-P-Asserted-Identity: (ABSENT)}")"
      note "$(sed 's/^[[:space:]]*//' <<< "${F_RPID:-Remote-Party-ID: (ABSENT)}")"
    elif [[ "$LEAK" -gt 0 ]]; then
      fail "crit 12" "the customer's caller ID LEAKED into the outbound INVITE ($LEAK occurrence(s))"
      note "$(grep -n "$CUST_CID" <<< "$INV12" | head -3)"
    else
      fail "crit 12" "header(s) not carrying our DID: $BAD"
      note "expected $DID12"
      note "${F_FROM:-From: (absent)}"
      note "${F_PAI:-P-Asserted-Identity: (absent — check send_pai on the fractel endpoint)}"
      note "${F_RPID:-Remote-Party-ID: (absent — check send_rpid on the fractel endpoint)}"
    fi
  fi
fi

# ===========================================================================
# Criterion 12b — a malformed caller ID is REPLACED, not refused
# ===========================================================================
# This is the behaviour change. Before, 0000000000 got a 403 and the call was
# lost. Now the call completes on one of our DIDs and the operator gets a
# WARNING telling them the customer's dialer is misbehaving.
DEST12B=13105550112
M="$(mark)"
if ! sipp_run cid12b uac-invite.xml destinations-cidbad.csv "$PK1" 5061 -m 1 -d 3000; then
  fail "crit 12b" "call with caller ID 0000000000 did NOT complete"
  note "if it was refused with 403, VALIDATE_CALLERID is true — see $LOGDIR/cid12b.msg"
else
  DID12B="$(did_for "$M" "$DEST12B")"
  W12B="$(since "$M" | grep -c 'SBC-CID-INVALID' || true)"
  INV12B="$(outbound_invite "$DEST12B")"
  LEAK12B="$(grep -c '0000000000' <<< "$INV12B" || true)"

  if [[ -n "$DID12B" && "$W12B" -ge 1 && "$LEAK12B" -eq 0 ]]; then
    pass "crit 12b" "malformed CID 0000000000 replaced with $DID12B; call completed; WARN logged"
    note "$(since "$M" | grep 'SBC-CID-INVALID' | tail -1 | sed 's/.*SBC-CID/SBC-CID/')"
  elif [[ "$W12B" -lt 1 ]]; then
    fail "crit 12b" "call completed but no SBC-CID-INVALID warning was logged"
    note "the replacement works; the early-warning signal does not"
  elif [[ "$LEAK12B" -gt 0 ]]; then
    fail "crit 12b" "0000000000 leaked into the outbound INVITE"
  else
    fail "crit 12b" "call completed but no DID was recorded as selected"
  fi
fi

# ===========================================================================
# Criterion 14 — per-DID daily cap takes a number out of rotation
# ===========================================================================
# NPA 989 holds exactly one DID in dids.test.csv and DID_DAILY_CAP is 5, so
# the 6th call into 989 cannot use it. Counters were zeroed at startup.
if [[ "$DID_CAP" -gt 20 ]]; then
  skip "crit 14" "DID_DAILY_CAP=$DID_CAP — too high to reach in a test run"
  note "set DID_DAILY_CAP=5 in $CONF (the shipped test config does)"
else
  DEST14=19895550111
  "$ROOT/didctl.sh" reset --all --force >/dev/null 2>&1
  M="$(mark)"
  sipp_run cap14 uac-invite-fast.xml destinations-cap.csv "$PK1" 5061 -m $((DID_CAP + 1)) -r 1
  sleep 2
  SEQ="$(since "$M" | grep 'SBC-DIAL ' | grep -F "dst=$DEST14 " \
         | sed -n 's/.*[ ]did=\([0-9]\{1,\}\).*/\1/p')"
  NSEQ="$(wc -l <<< "$SEQ")"
  FIRST="$(head -1 <<< "$SEQ")"
  LAST="$(tail -1 <<< "$SEQ")"
  ONCAP="$(grep -c "^$FIRST\$" <<< "$SEQ" || true)"
  OVF14="$(since "$M" | grep -c 'SBC-DID-OVERFLOW' || true)"

  if [[ "$NSEQ" -lt $((DID_CAP + 1)) ]]; then
    fail "crit 14" "only $NSEQ of $((DID_CAP + 1)) calls reached DID selection"
    note "$(since "$M" | grep 'SBC-REJECT' | tail -2)"
  elif [[ "$ONCAP" -eq "$DID_CAP" && "$LAST" != "$FIRST" && "$OVF14" -ge 1 ]]; then
    pass "crit 14" "with cap=$DID_CAP, calls 1-$DID_CAP used $FIRST and call $((DID_CAP + 1)) selected $LAST instead"
    note "the capped number went out of rotation and the overflow pool took the call (WARN logged)"
  elif [[ "$LAST" == "$FIRST" ]]; then
    fail "crit 14" "call $((DID_CAP + 1)) reused $FIRST — the cap is NOT enforced in the call path"
  else
    fail "crit 14" "unexpected selection sequence: $(tr '\n' ' ' <<< "$SEQ")"
  fi
fi

# ===========================================================================
# Criterion 15 — an NPA with no pool falls to overflow and logs WARN
# ===========================================================================
DEST15=15055550101
M="$(mark)"
if ! sipp_run ovf15 uac-invite-fast.xml destinations-overflow.csv "$PK1" 5061 -m 1; then
  fail "crit 15" "the call to an unpooled NPA did not complete"
  note "see $LOGDIR/ovf15.msg"
else
  DID15="$(did_for "$M" "$DEST15")"
  W15="$(since "$M" | grep 'SBC-DID-OVERFLOW' | grep -c 'dst_npa=505' || true)"
  R15="$(since "$M" | grep 'SBC-DIAL ' | grep -F "dst=$DEST15 " \
         | sed -n 's/.*didreason=\([a-z_]*\).*/\1/p' | tail -1)"
  if [[ "$W15" -ge 1 && "$R15" == "overflow" && -n "$DID15" ]]; then
    pass "crit 15" "NPA 505 has no pool: selected $DID15 from overflow and logged WARN"
    note "$(since "$M" | grep 'SBC-DID-OVERFLOW' | tail -1 | sed 's/.*SBC-DID/SBC-DID/')"
  elif [[ "$W15" -lt 1 ]]; then
    fail "crit 15" "call used overflow but no WARN was logged (reason=$R15)"
  else
    fail "crit 15" "expected did_selection_reason=overflow, got '$R15'"
  fi
fi

# ===========================================================================
# Criterion 16 — high-cost prefixes are refused with 503
# ===========================================================================
M="$(mark)"
ROWS16="$(($(grep -vc '^SEQUENTIAL' "$SIPP_DIR/destinations-blocked.csv")))"
if sipp_run blocked uac-expect-503.xml destinations-blocked.csv "$PK1" 5061 -m "$ROWS16" -r 2; then
  R16="$(count_rej "$M" HIGH_COST_PREFIX)"
  # 17125550123 matches both 1712555 ($0.270) and 1712555012 ($1.410).
  # Asterisk must pick the more specific pattern or the deck's narrow rows
  # are silently overridden by its broad ones.
  LONGEST="$(since "$M" | grep 'HIGH_COST_PREFIX' | grep -F 'dst=17125550123' \
             | sed -n 's/.*prefix=\([0-9]*\).*/\1/p' | tail -1)"
  if [[ "$R16" -ge "$ROWS16" && "$LONGEST" == "1712555012" ]]; then
    pass "crit 16" "all $ROWS16 blocklisted destinations refused with 503 (HIGH_COST_PREFIX x$R16)"
    note "longest-prefix match confirmed: 17125550123 matched 1712555012 (\$1.410), not 1712555 (\$0.270)"
    note "$(since "$M" | grep 'HIGH_COST_PREFIX' | tail -1 | sed 's/.*SBC-REJECT/SBC-REJECT/')"
  elif [[ "$R16" -lt "$ROWS16" ]]; then
    fail "crit 16" "only $R16 of $ROWS16 blocklisted destinations were refused"
  else
    fail "crit 16" "longest-prefix match is wrong: 17125550123 matched '${LONGEST:-nothing}', expected 1712555012"
    note "the broad rate-deck rows are shadowing the narrow ones — every"
    note "narrower, more expensive prefix in blocklist.csv is being ignored"
  fi
else
  fail "crit 16" "a blocklisted destination was NOT refused — see $LOGDIR/blocked.msg"
fi

# ===========================================================================
# Criteria 13 and 17 — DID and gateway distribution under volume
# ===========================================================================
# Both are measured from the SAME run: they are two questions about one
# mechanism, and placing 1600 calls to answer them separately would only add
# time. Everything asserted below comes out of the CDR, which is the
# requirement — distribution has to be provable from the record.
echo
note "criteria 13/17: placing $VOL_CALLS calls at ${VOL_CPS}/s (about $((VOL_CALLS / VOL_CPS))s)"
if [[ "$VOL_CPS" -ge "$CPS" ]]; then
  note "${YEL}WARNING${NC}: ACCEPT_VOLUME_CPS=$VOL_CPS is not below MAX_CPS=$CPS."
  note "the CPS limiter will refuse part of the run and the sample will be smaller than $VOL_CALLS."
fi

"$ROOT/didctl.sh" reset --all --force >/dev/null 2>&1
stop_stubs
UPF="$(start_stubs uas-fractel-stub-fast.xml)"
if [[ "${UPF:-0}" -lt "$GW_COUNT" ]]; then
  fail "crit 13" "only ${UPF:-0} of $GW_COUNT fast stubs started"
  fail "crit 17" "same"
else
  sleep "${FRACTEL_QUALIFY_FREQ:-15}"
  CDR_BEFORE="$(wc -l < "$CDR_CSV_PATH" 2>/dev/null || echo 0)"
  M="$(mark)"
  sipp -sf "$SIPP_DIR/uac-invite-fast.xml" -inf "$SIPP_DIR/destinations-volume.csv" \
       -i "$PK1" -p 5065 -m "$VOL_CALLS" -r "$VOL_CPS" -rp 1s \
       -nostdin -timeout 600 >"$LOGDIR/volume.out" 2>&1
  sleep 6

  VOL_CSV="$LOGDIR/volume-cdr.csv"
  tail -n +$((CDR_BEFORE + 1)) "$CDR_CSV_PATH" 2>/dev/null > "$VOL_CSV"
  VROWS="$(wc -l < "$VOL_CSV")"

  # --- criterion 13: no DID over its cap, even spread within each pool ----
  read -r WITHDID MAXCNT NPOOLS WORSTSPREAD WORSTNPA <<< "$(awk '
    function csvsplit(line, arr,   i,n,c,f,q,L) {
      n=0; f=""; q=0; L=length(line)
      for (i=1;i<=L;i++) { c=substr(line,i,1)
        if (q) { if (c=="\"") { if (substr(line,i+1,1)=="\"") { f=f "\""; i++ } else q=0 } else f=f c }
        else { if (c=="\"") q=1; else if (c==",") { arr[++n]=f; f="" } else f=f c } }
      arr[++n]=f; return n }
    { n=csvsplit($0,f); if (n<19) next
      did=f[16]; npa=f[18]; cnt=f[19]+0
      if (did=="") next
      withdid++
      if (cnt>maxcnt) maxcnt=cnt
      use[npa "\t" did]++; seen[npa]=1 }
    END {
      worst=0; worstnpa="-"; npools=0
      for (p in seen) {
        lo=-1; hi=0; c=0
        for (k in use) { split(k,a,"\t"); if (a[1]!=p) continue
          v=use[k]; c++; if (lo<0 || v<lo) lo=v; if (v>hi) hi=v }
        if (c<2) continue
        npools++
        d = hi-lo
        if (d>worst) { worst=d; worstnpa=p }
      }
      print withdid+0, maxcnt+0, npools+0, worst+0, worstnpa }' "$VOL_CSV")"

  if [[ "$VROWS" -lt 1 ]]; then
    fail "crit 13" "no CDR rows were produced by the volume run"
  elif [[ "$MAXCNT" -gt "$DID_CAP" ]]; then
    fail "crit 13" "a DID reached $MAXCNT calls against a cap of $DID_CAP"
    note "the cap is not holding under concurrency — check func_lock is loaded"
  elif [[ "$WORSTSPREAD" -gt 3 ]]; then
    fail "crit 13" "uneven distribution: NPA $WORSTNPA has a $WORSTSPREAD-call gap between its busiest and quietest DID"
    note "round-robin over an uncapped pool should differ by at most 1"
  else
    pass "crit 13" "$WITHDID call(s) over $NPOOLS pool(s): no DID exceeded $DID_CAP (worst $MAXCNT), widest in-pool gap $WORSTSPREAD call(s)"
    note "$VROWS CDR row(s) written; $((VOL_CALLS - VROWS)) call(s) not recorded (throttled or not placed)"
  fi

  # --- criterion 17: gateway distribution ---------------------------------
  read -r NGW GLO GHI GAVG <<< "$(awk '
    function csvsplit(line, arr,   i,n,c,f,q,L) {
      n=0; f=""; q=0; L=length(line)
      for (i=1;i<=L;i++) { c=substr(line,i,1)
        if (q) { if (c=="\"") { if (substr(line,i+1,1)=="\"") { f=f "\""; i++ } else q=0 } else f=f c }
        else { if (c=="\"") q=1; else if (c==",") { arr[++n]=f; f="" } else f=f c } }
      arr[++n]=f; return n }
    { n=csvsplit($0,f); if (n<19) next; g=f[12]; if (g!="") gw[g]++ }
    END { lo=-1; hi=0; s=0; c=0
      for (g in gw) { c++; s+=gw[g]; if (lo<0 || gw[g]<lo) lo=gw[g]; if (gw[g]>hi) hi=gw[g] }
      printf "%d %d %d %.1f\n", c, (lo<0?0:lo), hi, (c?s/c:0) }' "$VOL_CSV")"

  GTOL="$(awk -v a="$GAVG" 'BEGIN{t=a*0.05; if (t<2) t=2; printf "%d", t}')"
  GSPREAD=$((GHI - GLO))
  if [[ "$NGW" -lt "$GW_COUNT" ]]; then
    fail "crit 17" "only $NGW of $GW_COUNT gateways took traffic"
    note "$(awk -F'","' '{print $12}' "$VOL_CSV" | sort | uniq -c | sort -rn | head -8 | tr '\n' ' ')"
    note "gateway selection is bucketing instead of rotating per call"
  elif [[ "$GSPREAD" -gt "$GTOL" ]]; then
    fail "crit 17" "uneven across gateways: min $GLO max $GHI (avg $GAVG, tolerance $GTOL)"
  else
    pass "crit 17" "traffic spread across all $NGW gateways: min $GLO, max $GHI, avg $GAVG"
    note "round-robin is per call, not per second — a wall-clock bucket would"
    note "have stacked every call in a given second onto one gateway"
  fi

  # Evidence for the RUNBOOK, computed from the CDR alone.
  echo
  "$ROOT/didctl.sh" distribution "$VOL_CSV" 2>/dev/null | sed 's/^/  /'

  stop_stubs
  start_stubs uas-fractel-stub.xml -rtp_echo >/dev/null
fi

# ===========================================================================
echo "==========================================================================="
printf '  %s%d passed%s, %s%d failed%s, %s%d skipped%s\n' \
  "$GREEN" "$PASS" "$NC" "$RED" "$FAIL" "$NC" "$YEL" "$SKIP" "$NC"
echo
echo "  Logs and SIP traces: $LOGDIR"
echo
echo "  ${YEL}The skips are not passes.${NC} Criterion 3b (host firewall) and criterion 11"
echo "  (reboot) are the two that have bitten real deployments, and neither can be"
echo "  proven from this box. Do them by hand before the customer test."
echo
echo "  Criterion 12 was checked against a SIPp stub, not FracTEL. It proves the"
echo "  INVITE leaving this box carries our DID in all three identity headers and"
echo "  none of the customer's value. It does NOT prove what FracTEL attests off,"
echo "  or that they accept our numbers on this subaccount. Those need the live"
echo "  trunk — RUNBOOK.md has the steps."
echo
echo "  Put production config back:  sudo $HERE/testenv.sh restore"
echo

[[ "$FAIL" -eq 0 ]]
