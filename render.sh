#!/usr/bin/env bash
#
# render.sh — turn asterisk/*.tpl into asterisk/*.conf using config.env.
#
#   ./render.sh                      render into ./asterisk/
#   ./render.sh -o /etc/asterisk     render straight into place
#   CONF=tests/config.test.env ./render.sh -o /etc/asterisk
#
# Idempotent: same config.env in, byte-identical output. Safe to re-run.
#
# Two kinds of placeholder appear in the templates:
#
#   @@NAME@@                inline scalar, substituted from config.env or from
#                           a derived value computed below
#   @@INCLUDE:name@@        on a line by itself, replaced with a generated
#                           multi-line block (the per-gateway PJSIP sections,
#                           the codec list, the module noload list)
#
# Substitution is done with bash parameter expansion rather than sed, so a
# value containing /, &, | or a backslash cannot corrupt the output.
#
# Rendering fails loudly if any @@...@@ survives — that catches a typo in a
# template before it becomes a broken config on test day.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${CONF:-$HERE/config.env}"
OUTDIR="$HERE/asterisk"
STRICT_PLACEHOLDER_CHECK=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--out)  OUTDIR="$2"; shift 2 ;;
    -c|--conf) CONF="$2";   shift 2 ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "render.sh: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

die() { echo "render.sh: ERROR: $*" >&2; exit 1; }
info() { echo "  $*"; }

[[ -f "$CONF" ]] || die "config file not found: $CONF
       Copy config.env.example to config.env and fill it in."

# shellcheck disable=SC1090
set -a; source "$CONF"; set +a

# ---------------------------------------------------------------------------
# Validate. Refuse to render a config that would produce a broken or unsafe
# SBC. Placeholder values from config.env.example are treated as unset.
# ---------------------------------------------------------------------------

PLACEHOLDERS='^(203\.0\.113\.(10|200)|198\.51\.100\.(21|22)|192\.0\.2\.3[1-6](,.*)?|<FILL_ME>)$'

require() {
  local name="$1" val="${!1:-}"
  [[ -n "$val" ]] || die "$name is empty in $CONF"
  if [[ "${ALLOW_PLACEHOLDERS:-0}" != "1" && "$val" =~ $PLACEHOLDERS ]]; then
    die "$name is still the example placeholder value ('$val').
       Put the real value in $CONF.
       (Set ALLOW_PLACEHOLDERS=1 to render anyway for inspection only.)"
  fi
}

for v in SBC_PUBLIC_IP ADMIN_SSH_IP PK_CLIENT_IP_1 PK_CLIENT_IP_2 FRACTEL_PROXY_IPS; do
  require "$v"
done

is_ipv4() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
for v in SBC_PUBLIC_IP PK_CLIENT_IP_1 PK_CLIENT_IP_2; do
  is_ipv4 "${!v}" || die "$v='${!v}' is not a bare IPv4 address"
done

[[ "$PK_CLIENT_IP_1" != "$PK_CLIENT_IP_2" ]] || \
  die "PK_CLIENT_IP_1 and PK_CLIENT_IP_2 are the same address.
       Two separate endpoints require two distinct IPs. If the customer
       really has one IP, delete pkclient2 rather than duplicating it."

# Defaults for anything the operator left out.
SIP_PORT="${SIP_PORT:-5060}"
RTP_START="${RTP_START:-10000}"
RTP_END="${RTP_END:-20000}"
MAX_CONCURRENT_PER_IP="${MAX_CONCURRENT_PER_IP:-50}"
MAX_CPS="${MAX_CPS:-10}"
NANP_ONLY="${NANP_ONLY:-true}"
BLOCK_HIGH_RISK_NPA="${BLOCK_HIGH_RISK_NPA:-true}"
BLOCK_976="${BLOCK_976:-true}"
# Advisory by default: the customer's caller ID is discarded on every call, so
# refusing the call over it throws away revenue for a field we never use. The
# 403 path still exists and still works when this is true.
VALIDATE_CALLERID="${VALIDATE_CALLERID:-false}"
NORMALIZE_CALLERID="${NORMALIZE_CALLERID:-false}"
DID_DAILY_CAP="${DID_DAILY_CAP:-200}"
OVERFLOW_MIN="${OVERFLOW_MIN:-20}"
TRANSFER_DETECT="${TRANSFER_DETECT:-true}"
TRANSFER_TOLLFREE_NPAS="${TRANSFER_TOLLFREE_NPAS:-800,833,844,855,866,877,888}"
TRANSFER_MIN_CALLS="${TRANSFER_MIN_CALLS:-3}"
TRANSFER_MIN_ACD="${TRANSFER_MIN_ACD:-60}"
TRANSFER_EXPIRE_DAYS="${TRANSFER_EXPIRE_DAYS:-30}"
DIDS_CSV="${DIDS_CSV:-dids.csv}"
BLOCKLIST_CSV="${BLOCKLIST_CSV:-blocklist.csv}"
[[ "$DIDS_CSV"      = /* ]] || DIDS_CSV="$HERE/$DIDS_CSV"
[[ "$BLOCKLIST_CSV" = /* ]] || BLOCKLIST_CSV="$HERE/$BLOCKLIST_CSV"
ENABLE_G729="${ENABLE_G729:-false}"
DIAL_TIMEOUT="${DIAL_TIMEOUT:-60}"
FRACTEL_QUALIFY_FREQ="${FRACTEL_QUALIFY_FREQ:-30}"
CDR_CSV_PATH="${CDR_CSV_PATH:-/var/log/asterisk/cdr-custom/sbc.csv}"
LOG_RETAIN_DAYS="${LOG_RETAIN_DAYS:-30}"
BLOCKED_NPAS="${BLOCKED_NPAS:-}"
FRACTEL_DOMAIN="${FRACTEL_DOMAIN:-$SBC_PUBLIC_IP}"
SBC_NAT_LOCAL_NET="${SBC_NAT_LOCAL_NET:-}"

(( RTP_START >= 1024 && RTP_END > RTP_START && RTP_END <= 65535 )) || \
  die "RTP_START/RTP_END out of range ($RTP_START-$RTP_END)"

[[ "$DID_DAILY_CAP" =~ ^[0-9]+$ ]] && (( DID_DAILY_CAP > 0 )) || \
  die "DID_DAILY_CAP must be a positive integer, got '$DID_DAILY_CAP'"
[[ "$OVERFLOW_MIN" =~ ^[0-9]+$ ]] || \
  die "OVERFLOW_MIN must be an integer, got '$OVERFLOW_MIN'"

[[ "$TRANSFER_MIN_CALLS" =~ ^[0-9]+$ ]] && (( TRANSFER_MIN_CALLS >= 1 )) || \
  die "TRANSFER_MIN_CALLS must be a positive integer, got '$TRANSFER_MIN_CALLS'"
[[ "$TRANSFER_MIN_ACD" =~ ^[0-9]+$ ]] || \
  die "TRANSFER_MIN_ACD must be an integer, got '$TRANSFER_MIN_ACD'"
[[ "$TRANSFER_EXPIRE_DAYS" =~ ^[0-9]+$ ]] || \
  die "TRANSFER_EXPIRE_DAYS must be an integer, got '$TRANSFER_EXPIRE_DAYS'"

# 3 and 60 were validated against production CDRs. 2 flags six destinations
# instead of one. Loosening either turns a prospect dial into a transfer leg,
# which means a customer-supplied caller ID reaches FracTEL unrewritten — the
# exact failure this SBC exists to prevent, arriving through the back door.
if (( TRANSFER_MIN_CALLS < 3 )) && [[ "$TRANSFER_DETECT" == "true" ]]; then
  cat >&2 <<WARN

  ############################################################
  #  WARNING: TRANSFER_MIN_CALLS=$TRANSFER_MIN_CALLS
  #
  #  Below 3 this was measured to flag six destinations
  #  instead of one. Every false positive is a prospect dial
  #  that keeps the customer's caller ID instead of ours.
  ############################################################

WARN
fi

# The membership test in the dialplan is a regex against a comma-wrapped list,
# so ",800," matches only the whole NPA and never a substring of a longer one.
TF_CSV="$(echo "$TRANSFER_TOLLFREE_NPAS" | tr ' ' ',' | tr -s ',' | sed 's/^,//; s/,$//')"
if [[ -n "$TF_CSV" ]]; then
  IFS=',' read -r -a _tfn <<< "$TF_CSV"
  for _n in "${_tfn[@]}"; do
    [[ "$_n" =~ ^[2-9][0-9]{2}$ ]] || \
      die "TRANSFER_TOLLFREE_NPAS entry '$_n' is not a 3-digit NPA starting 2-9"
  done
  SBC_TF_NPAS=",${TF_CSV},"
else
  SBC_TF_NPAS=","
  [[ "$TRANSFER_DETECT" == "true" ]] && \
    echo "  note: TRANSFER_TOLLFREE_NPAS is empty — rule 1 will never fire" >&2
fi

# cdr_custom always writes to <astlogdir>/cdr-custom/<name> and ignores any
# directory component in the mapping key. A CDR_CSV_PATH pointing somewhere
# else would render cleanly, start cleanly, and then silently produce no CDRs
# at the path every other script reads — which fails acceptance criterion 8 in
# the least obvious way possible. Refuse it here instead.
if [[ "$(dirname "$CDR_CSV_PATH")" != "${ASTERISK_LOG_DIR:-/var/log/asterisk}/cdr-custom" ]]; then
  die "CDR_CSV_PATH must be under ${ASTERISK_LOG_DIR:-/var/log/asterisk}/cdr-custom/
       (cdr_custom ignores the directory part of its mapping key and always
       writes there). Got: $CDR_CSV_PATH"
fi

for b in NANP_ONLY BLOCK_HIGH_RISK_NPA BLOCK_976 VALIDATE_CALLERID NORMALIZE_CALLERID ENABLE_G729 TRANSFER_DETECT; do
  case "${!b}" in
    true|false) ;;
    *) die "$b must be exactly 'true' or 'false', got '${!b}'" ;;
  esac
done

if [[ "$NANP_ONLY" != "true" ]]; then
  cat >&2 <<'WARN'

  ############################################################
  #  WARNING: NANP_ONLY=false
  #
  #  The destination allowlist is DISABLED. A compromised
  #  customer dialer can now reach premium-rate international
  #  numbers on your FracTEL account. This is the control that
  #  turns a bad night into a five-figure invoice.
  ############################################################

WARN
fi

# ---------------------------------------------------------------------------
# Derived values
# ---------------------------------------------------------------------------

BLOCK_DIR="$(mktemp -d)"
trap 'rm -rf "$BLOCK_DIR"' EXIT

# --- FracTEL gateways: one endpoint/aor/identify per proxy IP --------------
IFS=',' read -r -a _proxies <<< "$FRACTEL_PROXY_IPS"
FRACTEL_GW_COUNT=0
: > "$BLOCK_DIR/fractel_endpoints"
: > "$BLOCK_DIR/fractel_globals"
FRACTEL_IP_LIST=""

for raw in "${_proxies[@]}"; do
  raw="$(echo "$raw" | tr -d '[:space:]')"
  [[ -n "$raw" ]] || continue
  gw_ip="${raw%%:*}"
  gw_port="${raw##*:}"
  [[ "$gw_port" == "$raw" ]] && gw_port="$SIP_PORT"
  is_ipv4 "$gw_ip" || die "FRACTEL_PROXY_IPS entry '$raw' is not ip or ip:port"

  FRACTEL_GW_COUNT=$((FRACTEL_GW_COUNT + 1))
  n=$FRACTEL_GW_COUNT
  FRACTEL_IP_LIST+="${FRACTEL_IP_LIST:+,}$gw_ip"

  cat >> "$BLOCK_DIR/fractel_endpoints" <<EOF
; --- FracTEL outbound proxy $n -------------------------------------------
[fractel$n]
type=endpoint
context=sbc-fractel-inbound
transport=transport-udp
aors=fractel$n
disallow=all
@@INCLUDE_INLINE_CODECS@@
direct_media=no
rtp_symmetric=yes
force_rport=yes
rewrite_contact=no
from_domain=$FRACTEL_DOMAIN
dtmf_mode=rfc4733
allow_transfer=no
; Nothing FracTEL asserts inbound is trusted: this is an outbound-only trunk.
trust_id_inbound=no
; --- caller identity toward the carrier ---
; The SBC assigns caller ID. The dialplan sets CALLERID(num) and CALLERID(ANI)
; to the selected DID immediately before Dial(), and res_pjsip generates all
; three identity headers from that one value:
;
;   From                     from CALLERID(num)
;   P-Asserted-Identity      send_pai=yes
;   Remote-Party-ID          send_rpid=yes
;
; trust_id_outbound=yes is what makes res_pjsip populate PAI and RPID with the
; real number rather than suppressing it as restricted. Without it the headers
; are emitted as anonymous and FracTEL attests off whatever is left, which is
; the failure this whole change exists to prevent.
;
; FracTEL most likely attests off From alone, but all three are set on purpose:
; if any single header leaked the customer's value, attestation could key to
; the wrong number and the traceback would come back to us.
trust_id_outbound=yes
send_pai=yes
send_rpid=yes
; No Diversion header. There is no forwarding scenario on this trunk, and a
; Diversion carrying a customer-supplied number would be a fourth place their
; caller ID could escape.
send_diversion=no
inband_progress=no
timers=yes
timers_min_se=90
sdp_session=SBC
tos_audio=ef
cos_audio=5
rtp_timeout=120
rtp_timeout_hold=120
media_encryption=no
; No auth section and no outbound_auth: FracTEL authorises this trunk by
; source IP. Registration is deliberately absent — FracTEL firewalls STATIC
; devices that attempt to register.

[fractel$n]
type=aor
contact=sip:$gw_ip:$gw_port
qualify_frequency=$FRACTEL_QUALIFY_FREQ
qualify_timeout=3.0
remove_existing=yes
max_contacts=1

[fractel$n]
type=identify
endpoint=fractel$n
match=$gw_ip

EOF

  echo "FRACTEL_GW_${n}=fractel${n}" >> "$BLOCK_DIR/fractel_globals"
done

(( FRACTEL_GW_COUNT > 0 )) || die "FRACTEL_PROXY_IPS produced no usable gateways"
info "FracTEL gateways: $FRACTEL_GW_COUNT ($FRACTEL_IP_LIST)"

# --- SIP-layer ACL --------------------------------------------------------
# Asterisk ACL semantics are "last matching rule wins", so the blanket deny
# goes first and every explicitly permitted peer follows it.
{
  echo "deny=0.0.0.0/0.0.0.0"
  echo "permit=$PK_CLIENT_IP_1/32"
  echo "permit=$PK_CLIENT_IP_2/32"
  IFS=',' read -r -a _fips <<< "$FRACTEL_IP_LIST"
  for ip in "${_fips[@]}"; do echo "permit=$ip/32"; done
  if [[ -n "${EXTRA_SIP_ACL_PERMIT:-}" ]]; then
    IFS=',' read -r -a _extra <<< "$EXTRA_SIP_ACL_PERMIT"
    for e in "${_extra[@]}"; do
      e="$(echo "$e" | tr -d '[:space:]')"; [[ -n "$e" ]] || continue
      [[ "$e" == */* ]] || e="$e/32"
      echo "permit=$e"
    done
  fi
} > "$BLOCK_DIR/acl"

# --- codecs ---------------------------------------------------------------
# Identical list on both legs, so Asterisk bridges natively and never
# transcodes. Order matters: first entry is preferred.
{
  echo "allow=ulaw"
  echo "allow=alaw"
  [[ "$ENABLE_G729" == "true" ]] && echo "allow=g729"
} > "$BLOCK_DIR/codecs"
CODEC_INLINE="$(cat "$BLOCK_DIR/codecs")"

# The generated FracTEL block above carries a nested placeholder; expand it
# now that the codec list exists.
python_free_expand() {
  local f="$1" out=""
  while IFS= read -r l || [[ -n "$l" ]]; do
    if [[ "$l" == "@@INCLUDE_INLINE_CODECS@@" ]]; then
      out+="$CODEC_INLINE"$'\n'
    else
      out+="$l"$'\n'
    fi
  done < "$f"
  printf '%s' "$out" > "$f"
}
python_free_expand "$BLOCK_DIR/fractel_endpoints"

# --- blocked NPA list, comma-wrapped for the dialplan regex membership test -
NPA_CSV="$(echo "$BLOCKED_NPAS" | tr ' ' ',' | tr -s ',' | sed 's/^,//; s/,$//')"
if [[ -n "$NPA_CSV" ]]; then
  SBC_BLOCKED_NPAS=",${NPA_CSV},"
else
  SBC_BLOCKED_NPAS=","
  [[ "$BLOCK_HIGH_RISK_NPA" == "true" ]] && \
    echo "  note: BLOCK_HIGH_RISK_NPA=true but BLOCKED_NPAS is empty — nothing extra blocked" >&2
fi

# --- DID pool -------------------------------------------------------------
# dids.csv (npa,did) becomes one dialplan global per pool:
#
#   SBC_DID_POOL_212=12125550101|12125550102|...
#   SBC_DID_CNT_212=4
#   SBC_DID_POOL_OVERFLOW=...
#   SBC_DID_CNT_OVERFLOW=24
#
# The dialplan reads ${GLOBAL(SBC_DID_POOL_${SBC_NPA})}, so an NPA with no
# pool yields an empty string and falls straight to OVERFLOW. Pools are
# pipe-delimited rather than comma-delimited: a comma is the argument
# separator in every dialplan application, and CUT() would need it escaped.
#
# Every rule below is a hard error with a line number rather than a skipped
# row. A silently dropped DID shrinks a pool without telling anyone, and a
# pool that shrinks far enough is the single-default-number failure this
# build exists to prevent.
[[ -f "$DIDS_CSV" ]] || die "DID pool not found: $DIDS_CSV
       cp dids.csv.example dids.csv && chmod 600 dids.csv && \$EDITOR dids.csv
       The SBC assigns caller ID from this file. It cannot place a call
       without it."

declare -A DID_POOL=() DID_MEMBER=() DID_HOME=()
DID_TOTAL=0
DID_CROSS=""
_lineno=0

while IFS= read -r _line || [[ -n "$_line" ]]; do
  _lineno=$((_lineno + 1))
  _line="${_line%$'\r'}"
  _line="${_line#"${_line%%[![:space:]]*}"}"
  _line="${_line%"${_line##*[![:space:]]}"}"
  [[ -z "$_line" || "$_line" == \#* ]] && continue
  [[ "$_line" == *,* ]] || die "$DIDS_CSV:$_lineno: expected 'npa,did', got '$_line'"

  _npa="${_line%%,*}"
  _rest="${_line#*,}"
  _did="${_rest%%,*}"
  # Pure parameter expansion, no subshells. dids.csv can run to hundreds of
  # rows and blocklist.csv to well over a thousand; at four forks a row this
  # loop was the slowest thing in the whole render.
  _npa="${_npa//[[:space:]]/}"
  _npa="${_npa^^}"
  _did="${_did//[!0-9]/}"

  # Optional header row.
  [[ "$_npa" == "NPA" ]] && continue

  if [[ "$_npa" != "OVERFLOW" ]]; then
    [[ "$_npa" =~ ^[2-9][0-9]{2}$ ]] || \
      die "$DIDS_CSV:$_lineno: '$_npa' is not a 3-digit NPA or the literal OVERFLOW"
  fi

  [[ -n "$_did" ]] || die "$DIDS_CSV:$_lineno: no digits in the did column"
  (( ${#_did} == 10 )) && _did="1$_did"
  (( ${#_did} == 11 )) || \
    die "$DIDS_CSV:$_lineno: did '$_did' is ${#_did} digits, expected 10 or 11"
  [[ "${_did:0:1}" == "1" ]] || \
    die "$DIDS_CSV:$_lineno: 11-digit did '$_did' must start with country code 1"
  [[ "${_did:1:1}" =~ [2-9] ]] || \
    die "$DIDS_CSV:$_lineno: did '$_did' has an NPA starting with ${_did:1:1} (must be 2-9)"
  [[ "${_did:4:1}" =~ [2-9] ]] || \
    die "$DIDS_CSV:$_lineno: did '$_did' has an NXX starting with ${_did:4:1} (must be 2-9)"

  if [[ -n "${DID_MEMBER[$_npa/$_did]:-}" ]]; then
    echo "  note: $DIDS_CSV:$_lineno: $_did is already in pool $_npa — collapsed" >&2
    continue
  fi
  DID_MEMBER[$_npa/$_did]=1

  # A DID may legitimately serve several NPAs, but its daily cap is keyed on
  # the number, so the pools share one budget. Say so — an operator who
  # expected two independent 200-call allowances needs to know they have one.
  if [[ -n "${DID_HOME[$_did]:-}" && "${DID_HOME[$_did]}" != "$_npa" ]]; then
    DID_CROSS+="${DID_CROSS:+, }$_did (${DID_HOME[$_did]}+$_npa)"
  else
    DID_HOME[$_did]="$_npa"
  fi

  DID_POOL[$_npa]="${DID_POOL[$_npa]:+${DID_POOL[$_npa]}|}$_did"
  DID_TOTAL=$((DID_TOTAL + 1))
done < "$DIDS_CSV"

(( DID_TOTAL > 0 )) || die "$DIDS_CSV contains no usable DIDs"

: > "$BLOCK_DIR/did_globals"
DID_NPA_POOLS=0
for _k in "${!DID_POOL[@]}"; do
  _list="${DID_POOL[$_k]}"
  _cnt="$(awk -F'|' '{print NF}' <<< "$_list")"
  printf 'SBC_DID_POOL_%s=%s\n' "$_k" "$_list" >> "$BLOCK_DIR/did_globals"
  printf 'SBC_DID_CNT_%s=%s\n'  "$_k" "$_cnt"  >> "$BLOCK_DIR/did_globals"
  [[ "$_k" != "OVERFLOW" ]] && DID_NPA_POOLS=$((DID_NPA_POOLS + 1))
done

OVERFLOW_COUNT=0
[[ -n "${DID_POOL[OVERFLOW]:-}" ]] && \
  OVERFLOW_COUNT="$(awk -F'|' '{print NF}' <<< "${DID_POOL[OVERFLOW]}")"

# Not negotiable. A thin overflow pool degrades into "one default number",
# which is precisely the behaviour that put 50,864 calls on a single DID.
(( OVERFLOW_COUNT >= OVERFLOW_MIN )) || die \
  "the OVERFLOW pool holds $OVERFLOW_COUNT number(s); OVERFLOW_MIN is $OVERFLOW_MIN.

       Overflow absorbs every destination NPA you have not bought numbers in,
       plus every call whose NPA pool is capped out for the day. Too few
       numbers here and it collapses into the single-default-number behaviour
       this build exists to prevent — the same failure that put 50,864 calls
       on one DID in an afternoon.

       Add OVERFLOW rows to $DIDS_CSV. Lowering OVERFLOW_MIN is not the fix."

info "DID pool: $DID_TOTAL number(s) across $DID_NPA_POOLS NPA pool(s) + $OVERFLOW_COUNT overflow"
info "per-DID daily cap: $DID_DAILY_CAP  (pool capacity ~$((DID_TOTAL * DID_DAILY_CAP)) calls/day)"
[[ -n "$DID_CROSS" ]] && \
  echo "  note: DID(s) in more than one pool, sharing one daily cap: $DID_CROSS" >&2

# --- high-cost LRN prefix blocklist ---------------------------------------
# blocklist.csv becomes a generated dialplan context. The match is then a
# single lookup in Asterisk's extension matcher, which already prefers the
# most specific pattern — so longest-prefix-wins comes for free and 1,248
# rows cost the same per INVITE as 12. A linear scan over a comma-joined
# string would be O(rows) on every call.
[[ -f "$BLOCKLIST_CSV" ]] || die "blocklist not found: $BLOCKLIST_CSV

       This is the primary cost control. Generate it from the rate deck:
         python3 tools/build-blocklist.py --deck <ShortDuration.csv> --out $(basename "$BLOCKLIST_CSV")

       Or start from the example:
         cp blocklist.csv.example $(basename "$BLOCKLIST_CSV")"

declare -A LRN_RATE=() LRN_DEST=()
LRN_COUNT=0
LRN_WORST=0
_lineno=0

while IFS= read -r _line || [[ -n "$_line" ]]; do
  _lineno=$((_lineno + 1))
  _line="${_line%$'\r'}"
  _line="${_line#"${_line%%[![:space:]]*}"}"
  _line="${_line%"${_line##*[![:space:]]}"}"
  [[ -z "$_line" || "$_line" == \#* ]] && continue

  _pfx="${_line%%,*}"
  _rest="${_line#*,}"
  _rate="${_rest%%,*}"
  _dest="${_rest#*,}"
  [[ "$_rest" == *,* ]] || _dest=""

  _pfx="${_pfx//[!0-9]/}"
  _rate="${_rate//[[:space:]\$]/}"

  # Header row.
  [[ "$_line" == prefix,* ]] && continue
  [[ -z "$_pfx" ]] && die "$BLOCKLIST_CSV:$_lineno: no digits in the prefix column"

  [[ "$_rate" =~ ^[0-9]+(\.[0-9]+)?$ ]] || \
    die "$BLOCKLIST_CSV:$_lineno: rate_per_min '$_rate' is not a decimal number"

  # Reject what can never match rather than padding the dialplan with rows
  # that read like coverage and are not. Destinations reaching this check are
  # always 11 digits, 1 + NPA + NXX + line, NPA and NXX both starting 2-9.
  (( ${#_pfx} >= 4 && ${#_pfx} <= 11 )) || \
    die "$BLOCKLIST_CSV:$_lineno: prefix '$_pfx' is ${#_pfx} digits (expected 4-11, country code 1 included)"
  [[ "${_pfx:0:1}" == "1" ]] || \
    die "$BLOCKLIST_CSV:$_lineno: prefix '$_pfx' must start with country code 1"
  [[ "${_pfx:1:1}" =~ [2-9] ]] || \
    die "$BLOCKLIST_CSV:$_lineno: prefix '$_pfx' has an NPA starting with ${_pfx:1:1} (must be 2-9); it can never match"
  if (( ${#_pfx} >= 5 )); then
    [[ "${_pfx:4:1}" =~ [2-9] ]] || \
      die "$BLOCKLIST_CSV:$_lineno: prefix '$_pfx' has an NXX starting with ${_pfx:4:1} (must be 2-9); it can never match"
  fi

  # A comma here would become a second Set() argument, and a quote would end
  # the value early. Carrier free-text does not survive contact with the
  # dialplan intact, so it gets flattened.
  _dest="${_dest//[\",;|]/ }"
  # Word-splitting collapses runs of whitespace and trims both ends without
  # forking tr twice per row.
  read -r -a _dw <<< "$_dest"
  _dest="${_dw[*]}"
  _dest="${_dest:0:40}"

  if [[ -n "${LRN_RATE[$_pfx]:-}" ]]; then
    # Keep the worst rate. Blocking on the cheaper of two entries for the same
    # prefix would let the expensive one through.
    if awk -v a="$_rate" -v b="${LRN_RATE[$_pfx]}" 'BEGIN{exit !(a>b)}'; then
      LRN_RATE[$_pfx]="$_rate"; LRN_DEST[$_pfx]="$_dest"
    fi
    echo "  note: $BLOCKLIST_CSV:$_lineno: duplicate prefix $_pfx — keeping the higher rate" >&2
    continue
  fi

  LRN_RATE[$_pfx]="$_rate"
  LRN_DEST[$_pfx]="$_dest"
  LRN_COUNT=$((LRN_COUNT + 1))
done < "$BLOCKLIST_CSV"

# Worst rate and the count above $0.50 in ONE awk over the whole set, rather
# than a fork per row. A real blocklist is ~1,250 rows.
if (( LRN_COUNT > 0 )); then
  read -r LRN_WORST LRN_N50 <<< "$(
    printf '%s\n' "${LRN_RATE[@]}" | awk '$1>w{w=$1} $1>=0.50{n++} END{printf "%.6f %d", w+0, n+0}')"
fi

: > "$BLOCK_DIR/lrn_blocklist"
if (( LRN_COUNT > 0 )); then
  for _pfx in $(printf '%s\n' "${!LRN_RATE[@]}" | sort); do
    # A prefix shorter than a full 11-digit number needs the trailing '.' to
    # match the rest of it. One that IS 11 digits is already exact, and '.'
    # would demand a 12th digit that never comes.
    if (( ${#_pfx} >= 11 )); then _pat="_${_pfx}"; else _pat="_${_pfx}."; fi
    cat >> "$BLOCK_DIR/lrn_blocklist" <<EOF
exten => ${_pat},1,Set(SBC_LRN_PREFIX=${_pfx})
 same => n,Set(SBC_LRN_RATE=${LRN_RATE[$_pfx]})
 same => n,Set(SBC_LRN_DEST=${LRN_DEST[$_pfx]})
 same => n,Return()
EOF
  done
  info "LRN blocklist: $LRN_COUNT prefix(es), $LRN_N50 at or above \$0.50/min, worst \$$LRN_WORST/min"
else
  {
    echo "; blocklist.csv held no usable rows. Nothing is blocked by rate."
  } >> "$BLOCK_DIR/lrn_blocklist"
  cat >&2 <<WARN

  ############################################################
  #  WARNING: $(basename "$BLOCKLIST_CSV") is empty
  #
  #  The high-cost prefix blocklist is the primary cost
  #  control on this box and it is currently blocking
  #  nothing. Regenerate it from the rate deck:
  #
  #    python3 tools/build-blocklist.py --deck <deck.csv>
  ############################################################

WARN
fi

# --- module noload list ---------------------------------------------------
# Only emit a noload for a module that actually exists on this box. A noload
# for a module that was never built is harmless at runtime but muddies the
# "zero warnings" check in acceptance criterion 2.
DENY_MODULES=(
  # Remote control / management surfaces. Nothing on this box should be
  # reachable over HTTP or a websocket.
  res_ari.so res_ari_applications.so res_ari_asterisk.so res_ari_bridges.so
  res_ari_channels.so res_ari_device_states.so res_ari_endpoints.so
  res_ari_events.so res_ari_mailboxes.so res_ari_model.so
  res_ari_playbacks.so res_ari_recordings.so res_ari_sounds.so
  res_stasis.so res_stasis_answer.so res_stasis_device_state.so
  res_stasis_playback.so res_stasis_recording.so res_stasis_snoop.so
  res_stasis_mailbox.so app_stasis.so
  res_http_post.so res_http_websocket.so res_http_media_cache.so
  res_phoneprov.so res_pjsip_transport_websocket.so

  # Anything that can execute a command or reach an external interpreter.
  # These are the classic pivot from "dialplan bug" to "shell on the SBC".
  app_system.so func_shell.so app_exec.so res_agi.so app_originate.so
  app_externalivr.so app_dictate.so app_nbscat.so app_mp3.so
  func_curl.so res_curl.so func_odbc.so

  # Other channel drivers. This box speaks PJSIP to two parties and nothing
  # else; every other driver is attack surface with no upside.
  chan_iax2.so chan_mgcp.so chan_skinny.so chan_unistim.so chan_ooh323.so
  chan_alsa.so chan_console.so chan_dahdi.so chan_motif.so chan_audiosocket.so

  # Voicemail, conferencing, queues, features we do not offer.
  app_voicemail.so app_minivm.so app_meetme.so app_confbridge.so
  app_queue.so app_followme.so app_chanspy.so app_amd.so
  res_calendar.so res_calendar_caldav.so res_calendar_ews.so
  res_calendar_exchange.so res_calendar_icalendar.so
  res_xmpp.so res_snmp.so cdr_radius.so cel_radius.so
)

# install.sh appends cdr_pgsql.so here when PG_DSN is empty: a loaded
# cdr_pgsql with no usable config warns on every start, which would fail the
# zero-warnings check in acceptance criterion 2.
if [[ -n "${EXTRA_DENY_MODULES:-}" ]]; then
  read -r -a _extra_deny <<< "$(echo "$EXTRA_DENY_MODULES" | tr ',' ' ')"
  DENY_MODULES+=("${_extra_deny[@]}")
fi

MODDIR="${ASTERISK_MODULE_DIR:-/usr/lib/asterisk/modules}"
: > "$BLOCK_DIR/noload"
if [[ -d "$MODDIR" ]]; then
  for m in "${DENY_MODULES[@]}"; do
    [[ -e "$MODDIR/$m" ]] && echo "noload => $m"
  done >> "$BLOCK_DIR/noload"
  info "modules denied: $(wc -l < "$BLOCK_DIR/noload") of ${#DENY_MODULES[@]} (rest not built on this box)"
else
  {
    echo "; NOTE: rendered off-box — $MODDIR was not present, so this list was"
    echo "; not filtered against the modules actually installed. Re-render on the"
    echo "; SBC (install.sh does this) to drop entries for modules that do not"
    echo "; exist here, which is what keeps startup warning-free."
    printf 'noload => %s\n' "${DENY_MODULES[@]}"
  } >> "$BLOCK_DIR/noload"
  info "modules denied: full list (not filtered — no $MODDIR on this host)"
fi

# --- NAT / external address lines ----------------------------------------
if [[ -n "$SBC_NAT_LOCAL_NET" ]]; then
  {
    echo "external_media_address=$SBC_PUBLIC_IP"
    echo "external_signaling_address=$SBC_PUBLIC_IP"
    IFS=',' read -r -a _nets <<< "$SBC_NAT_LOCAL_NET"
    for n in "${_nets[@]}"; do echo "local_net=$(echo "$n" | tr -d '[:space:]')"; done
  } > "$BLOCK_DIR/nat"
else
  {
    echo "; No NAT. The public IP is bound directly to this host's interface,"
    echo "; so external_media_address / external_signaling_address are"
    echo "; deliberately absent — setting them without NAT causes one-way audio."
  } > "$BLOCK_DIR/nat"
fi

# ---------------------------------------------------------------------------
# Scalar substitution map
# ---------------------------------------------------------------------------

declare -A R=(
  [SBC_PUBLIC_IP]="$SBC_PUBLIC_IP"
  [PK_CLIENT_IP_1]="$PK_CLIENT_IP_1"
  [PK_CLIENT_IP_2]="$PK_CLIENT_IP_2"
  [SIP_PORT]="$SIP_PORT"
  [RTP_START]="$RTP_START"
  [RTP_END]="$RTP_END"
  [MAX_CONCURRENT_PER_IP]="$MAX_CONCURRENT_PER_IP"
  [MAX_CPS]="$MAX_CPS"
  [NANP_ONLY]="$NANP_ONLY"
  [BLOCK_HIGH_RISK_NPA]="$BLOCK_HIGH_RISK_NPA"
  [BLOCK_976]="$BLOCK_976"
  [SBC_BLOCKED_NPAS]="$SBC_BLOCKED_NPAS"
  [VALIDATE_CALLERID]="$VALIDATE_CALLERID"
  [NORMALIZE_CALLERID]="$NORMALIZE_CALLERID"
  [DIAL_TIMEOUT]="$DIAL_TIMEOUT"
  [FRACTEL_GW_COUNT]="$FRACTEL_GW_COUNT"
  [DID_DAILY_CAP]="$DID_DAILY_CAP"
  [TRANSFER_DETECT]="$TRANSFER_DETECT"
  [SBC_TF_NPAS]="$SBC_TF_NPAS"
  [TRANSFER_MIN_CALLS]="$TRANSFER_MIN_CALLS"
  [TRANSFER_MIN_ACD]="$TRANSFER_MIN_ACD"
  [TRANSFER_EXPIRE_DAYS]="$TRANSFER_EXPIRE_DAYS"
  [DID_TOTAL]="$DID_TOTAL"
  [DID_NPA_POOLS]="$DID_NPA_POOLS"
  [OVERFLOW_COUNT]="$OVERFLOW_COUNT"
  [LRN_COUNT]="$LRN_COUNT"
  [FRACTEL_DOMAIN]="$FRACTEL_DOMAIN"
  [CDR_CSV_PATH]="$CDR_CSV_PATH"
  [CDR_CSV_DIR]="$(dirname "$CDR_CSV_PATH")"
  [CDR_CSV_NAME]="$(basename "$CDR_CSV_PATH")"
  [LOG_RETAIN_DAYS]="$LOG_RETAIN_DAYS"
  [RENDERED_FROM]="$(basename "$CONF")"
)

render_one() {
  local tpl="$1" out="$2" line key
  : > "$out.tmp"
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      @@INCLUDE:*@@)
        key="${line#@@INCLUDE:}"; key="${key%@@}"
        [[ -f "$BLOCK_DIR/$key" ]] || die "template $tpl includes unknown block '$key'"
        cat "$BLOCK_DIR/$key" >> "$out.tmp"
        continue
        ;;
    esac
    for key in "${!R[@]}"; do
      line="${line//@@${key}@@/${R[$key]}}"
    done
    printf '%s\n' "$line" >> "$out.tmp"
  done < "$tpl"

  if [[ "$STRICT_PLACEHOLDER_CHECK" == 1 ]] && grep -n '@@[A-Za-z_:]*@@' "$out.tmp" >/dev/null; then
    grep -n '@@[A-Za-z_:]*@@' "$out.tmp" >&2
    rm -f "$out.tmp"
    die "unresolved placeholder(s) in $tpl (listed above)"
  fi

  mv "$out.tmp" "$out"
}

mkdir -p "$OUTDIR"
shopt -s nullglob
count=0
for tpl in "$HERE"/asterisk/*.tpl; do
  base="$(basename "$tpl" .tpl)"
  render_one "$tpl" "$OUTDIR/$base"
  chmod 640 "$OUTDIR/$base"
  info "rendered $base"
  count=$((count + 1))
done
shopt -u nullglob

(( count > 0 )) || die "no templates found in $HERE/asterisk/*.tpl"

echo "render.sh: $count file(s) written to $OUTDIR from $(basename "$CONF")"
