#!/usr/bin/env bash
#
# healthcheck.sh — is this SBC able to carry a call right now?
#
#   ./healthcheck.sh          human-readable, exit code reflects health
#   ./healthcheck.sh --quiet  log only, for the systemd timer
#
# Exit codes (chosen so a monitoring system can page on 2 and warn on 1):
#   0  healthy    — Asterisk up, firewall loaded, at least one FracTEL
#                   gateway qualifying Avail
#   1  degraded   — carrying calls, but something needs looking at
#                   (some gateways down, firewall unconfirmed, CDR stalled)
#   2  down       — cannot carry calls (Asterisk down, or every FracTEL
#                   gateway unreachable)
#
# Findings also go to syslog with tag sbc-health, so `journalctl -t sbc-health`
# is a timeline of trunk state without needing an external monitoring system.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${CONF:-$HERE/config.env}"
AST="${AST:-asterisk}"
QUIET=0
[[ "${1:-}" == "--quiet" ]] && QUIET=1

if [[ -f "$CONF" ]]; then
  # shellcheck disable=SC1090
  set -a; source "$CONF"; set +a
fi
CDR_CSV_PATH="${CDR_CSV_PATH:-/var/log/asterisk/cdr-custom/sbc.csv}"

# Which endpoints SHOULD exist, from config.env rather than from a hardcoded
# pair. A health check that only knows about the first two endpoints reports a
# healthy box while the third customer IP is being refused.
# shellcheck source=lib/pk-clients.sh
PK_EP_NAMES=""
if [[ -r "$HERE/lib/pk-clients.sh" ]]; then
  . "$HERE/lib/pk-clients.sh"
  PK_EP_NAMES="$(pk_client_endpoint_names || true)"
fi

STATUS=0
MSGS=()

note() { # note <ok|warn|crit> <message>
  MSGS+=("$1|$2")
  case "$1" in
    warn) (( STATUS < 1 )) && STATUS=1 ;;
    crit) STATUS=2 ;;
  esac
}

# --- Asterisk alive? -------------------------------------------------------
if ! "$AST" -rx "core show version" >/dev/null 2>&1; then
  note crit "Asterisk is not responding on the control socket"
else
  VER="$("$AST" -rx "core show version" 2>/dev/null | head -1)"
  note ok "Asterisk up: $VER"

  # --- FracTEL trunk reachability, straight from qualify ------------------
  # qualify_frequency in pjsip.conf drives an OPTIONS ping per AOR; this is
  # simply reading the result rather than generating new traffic.
  # Status column is one of Avail / Unavail / Unknown / NonQual / Created, and
  # it is matched as a whole FIELD, not as a substring.
  #
  # A case-sensitive `grep -c Avail` does happen to work here, because
  # "Unavail" is lowercase after the U. That is a coincidence of formatting and
  # a bad thing to rely on: `grep -ci avail` matches "Unavail" AND the
  # "Unavailable" that `pjsip show endpoints` prints for the customer legs,
  # which is how an operator one-liner reported 7 gateways available on a box
  # that had 5. Comparing the field exactly cannot drift that way.
  #
  # Line shape:  Contact:  fractel1/sip:HOST:5060  <hash>  Avail  90.617
  CONTACT_LIST="$("$AST" -rx "pjsip show contacts" 2>/dev/null | grep 'fractel' || true)"
  CONTACTS="$(grep -c . <<< "${CONTACT_LIST:-}" || true)"
  [[ -z "$CONTACT_LIST" ]] && CONTACTS=0
  AVAIL="$(awk '$1=="Contact:" && $4=="Avail" {n++} END{print n+0}' <<< "${CONTACT_LIST:-}")"

  if (( CONTACTS == 0 )); then
    note crit "no FracTEL contacts configured — check FRACTEL_PROXY_IPS and re-run install.sh"
  elif (( AVAIL == 0 )); then
    note crit "ALL $CONTACTS FracTEL gateways unreachable — no calls can complete"
  elif (( AVAIL < CONTACTS )); then
    note warn "FracTEL gateways: $AVAIL of $CONTACTS reachable"
  else
    note ok "FracTEL gateways: $AVAIL of $CONTACTS reachable"
  fi

  # --- customer endpoints present? ---------------------------------------
  if [[ -z "$PK_EP_NAMES" ]]; then
    note warn "cannot tell which customer endpoints to expect (no readable config.env or lib/pk-clients.sh)"
  else
    while read -r ep; do
      [[ -n "$ep" ]] || continue
      # Captured, not piped. `grep -q` exits on the first match, which
      # SIGPIPEs `asterisk -rx` (status 141), and this script runs with
      # pipefail — so a SUCCESSFUL match intermittently reported the endpoint
      # as MISSING and the whole box as DOWN. Measured at 2 in 30 on a live
      # box, and it pages.
      _ep_out="$("$AST" -rx "pjsip show endpoint $ep" 2>/dev/null)"
      if grep -q "$ep" <<< "$_ep_out"; then
        note ok "endpoint $ep configured"
      else
        note crit "endpoint $ep is MISSING — customer traffic from that IP will be refused"
      fi
    done <<< "$PK_EP_NAMES"
  fi

  # --- killswitch ---------------------------------------------------------
  # Captured for the same reason as above: piped, a false negative here means
  # failing to say the killswitch is on.
  _globals="$("$AST" -rx "dialplan show globals" 2>/dev/null)"
  if grep -qE '^\s*SBC_KILLSWITCH\s*=\s*1' <<< "$_globals"; then
    note warn "KILLSWITCH IS ON — customer traffic is being refused by design"
  fi
fi

# --- firewall --------------------------------------------------------------
if command -v nft >/dev/null 2>&1; then
  if nft list table inet sbc >/dev/null 2>&1; then
    POLICY="$(nft list chain inet sbc input 2>/dev/null | grep -o 'policy [a-z]*' | head -1)"
    if [[ "$POLICY" == "policy drop" ]]; then
      note ok "firewall loaded, input $POLICY"
    else
      note crit "firewall input chain is '$POLICY' — expected 'policy drop'"
    fi
    [[ -f /run/sbc-firewall-confirmed ]] || note warn "firewall never confirmed (an auto-rollback may be pending)"
  else
    note crit "nftables table 'inet sbc' is NOT loaded — this box is unprotected"
  fi
else
  note warn "nft not installed — cannot verify the firewall"
fi

# --- CDR writable ----------------------------------------------------------
if [[ -f "$CDR_CSV_PATH" ]]; then
  if [[ -w "$(dirname "$CDR_CSV_PATH")" ]]; then
    note ok "CDR file present: $CDR_CSV_PATH ($(wc -l < "$CDR_CSV_PATH") rows)"
  else
    note warn "CDR directory not writable: $(dirname "$CDR_CSV_PATH")"
  fi
else
  note warn "CDR file does not exist yet: $CDR_CSV_PATH (normal before the first call)"
fi

# --- disk ------------------------------------------------------------------
USE="$(df --output=pcent /var/log 2>/dev/null | tail -1 | tr -dc '0-9')"
if [[ -n "$USE" ]]; then
  if   (( USE >= 90 )); then note crit "/var/log is ${USE}% full — logging and CDR writes are about to fail"
  elif (( USE >= 75 )); then note warn "/var/log is ${USE}% full"
  else note ok "/var/log ${USE}% used"; fi
fi

# --- report ----------------------------------------------------------------
for m in "${MSGS[@]}"; do
  lvl="${m%%|*}"; txt="${m#*|}"
  case "$lvl" in
    crit) logger -t sbc-health -p daemon.err  "CRIT: $txt" ;;
    warn) logger -t sbc-health -p daemon.warning "WARN: $txt" ;;
    *)    logger -t sbc-health -p daemon.info "OK: $txt" ;;
  esac
done

if [[ "$QUIET" == 0 ]]; then
  for m in "${MSGS[@]}"; do
    lvl="${m%%|*}"; txt="${m#*|}"
    case "$lvl" in
      crit) printf '  \033[31mCRIT\033[0m  %s\n' "$txt" ;;
      warn) printf '  \033[33mWARN\033[0m  %s\n' "$txt" ;;
      *)    printf '  \033[32m OK \033[0m  %s\n' "$txt" ;;
    esac
  done
  echo
  case "$STATUS" in
    0) printf '  \033[32mHEALTHY\033[0m\n' ;;
    1) printf '  \033[33mDEGRADED\033[0m — carrying calls, but see WARN above\n' ;;
    2) printf '  \033[31mDOWN\033[0m — this box cannot complete calls\n' ;;
  esac
fi

exit "$STATUS"
