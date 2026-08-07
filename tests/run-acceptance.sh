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

cleanup() {
  [[ -n "${STUB_PID:-}" ]] && kill "$STUB_PID" 2>/dev/null
  [[ -n "${HOLD_PID:-}" ]] && kill "$HOLD_PID" 2>/dev/null
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

# --- start the FracTEL stub ----------------------------------------------
sipp -sf "$SIPP_DIR/uas-fractel-stub.xml" -i "$STUB_IP" -p "$STUB_PORT" \
     -rtp_echo -nostdin -bg >"$LOGDIR/stub.out" 2>&1
sleep 2
if ! pgrep -f 'uas-fractel-stub' >/dev/null; then
  echo "${RED}the FracTEL stub failed to start${NC} — see $LOGDIR/stub.out"
  exit 1
fi
note "fractel stub up on $STUB_IP:$STUB_PORT"
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
else
  pass "crit 1" "pkclient1, pkclient2 and fractel gateways present; $AVAIL gateway(s) Avail"
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
# Caller ID validation (not a numbered criterion, but it is what stops
# unanswerable tracebacks)
# ===========================================================================
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
  fail "cid-empty" "empty caller ID was accepted — this is what makes a traceback unanswerable"
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
echo "  Put production config back:  sudo $HERE/testenv.sh restore"
echo

[[ "$FAIL" -eq 0 ]]
