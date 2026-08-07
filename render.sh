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
VALIDATE_CALLERID="${VALIDATE_CALLERID:-true}"
NORMALIZE_CALLERID="${NORMALIZE_CALLERID:-false}"
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

for b in NANP_ONLY BLOCK_HIGH_RISK_NPA BLOCK_976 VALIDATE_CALLERID NORMALIZE_CALLERID ENABLE_G729; do
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
trust_id_inbound=no
trust_id_outbound=no
send_pai=no
send_rpid=no
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
