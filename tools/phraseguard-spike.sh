#!/usr/bin/env bash
#
# phraseguard-spike.sh — settle the one question PhraseGuard depends on:
# does a Call-ID seen on the wire resolve to an Asterisk channel that
# `channel request hangup` accepts, and how fast?
#
#   ./phraseguard-spike.sh --self-test   preflight only; touches nothing
#   ./phraseguard-spike.sh --dump        raw CLI output, to verify the field
#                                        layout rather than assume it
#   ./phraseguard-spike.sh --arm         wait for traffic, then measure
#   ./phraseguard-spike.sh --now         measure immediately
#
# WHY THIS RUNS FIRST
# -------------------
# The brief is explicit: prototype the channel mapping in isolation before
# writing anything else, and stop and report if it does not resolve reliably.
# Everything downstream — the tap, the recogniser, the corpus, the matcher —
# is only worth having if this works, and none of it can be validated by
# reasoning. So this is the gate.
#
# WHAT IT MEASURES
#   coverage    fraction of INVITE Call-IDs that resolve to a channel
#   method      exact (the SBC_CALLID channel variable the dialplan already
#               sets) versus the documented heuristic fallback
#   ambiguity   how often more than one channel matches — the case where
#               enforcement would disconnect somebody else's call
#   latency     INVITE on the wire -> channel name in hand
#
# READ-ONLY, with exactly one exception. Every mode above only ever runs
# `core show channels concise` and `core show channel`, which are reads, plus
# a tcpdump on port 5060. The exception is --prove-hangup, which disconnects
# ONE live call on purpose and asks before it does.
#
# It does NOT change any configuration, does not reload Asterisk, does not
# touch the dialplan, and does not enable the pjsip logger. Unlike
# capture-answered-calls.sh it has nothing to disable afterwards, which is
# why there is no cleanup trap here — there is no global state to restore.
#
# EXIT CODES
#   0  PASS      — exact resolution, no ambiguity. Enforcement can be built.
#   1  FAIL      — resolution unreliable, or only the heuristic worked. STOP.
#   2  bad arguments or preflight refused
#   3  armed but no traffic arrived
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SPIKE="$ROOT/phraseguard/spike.py"
CONF="${CONF:-$ROOT/config.env}"

MODE=""
SECONDS_RUN=120
ARM_TIMEOUT_MIN=0
POLL=0.5
IFACE="any"
PROVE=0
NO_HEURISTIC=0

B=$'\033[1m'; R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; D=$'\033[2m'; N=$'\033[0m'
[[ -t 1 ]] || { B=""; R=""; G=""; Y=""; D=""; N=""; }

say() { echo "$(date -u '+%H:%M:%S') $*"; }
die() { echo "phraseguard-spike.sh: ERROR: $*" >&2; exit 2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --self-test)    MODE="selftest"; shift ;;
    --dump)         MODE="dump"; shift ;;
    --arm)          MODE="arm"; shift ;;
    --now)          MODE="now"; shift ;;
    -t|--seconds)   SECONDS_RUN="$2"; shift 2 ;;
    --arm-timeout)  ARM_TIMEOUT_MIN="$2"; shift 2 ;;
    --poll)         POLL="$2"; shift 2 ;;
    --iface)        IFACE="$2"; shift 2 ;;
    --no-heuristic) NO_HEURISTIC=1; shift ;;
    --prove-hangup) PROVE=1; shift ;;
    -c|--conf)      CONF="$2"; shift 2 ;;
    -h|--help)      sed -n '2,46p' "$0"; exit 0 ;;
    *) die "unknown argument '$1'" ;;
  esac
done
[[ -n "$MODE" ]] || die "pick one of --self-test, --dump, --arm, --now (see --help)"
[[ "$SECONDS_RUN" =~ ^[0-9]+$ && "$SECONDS_RUN" -ge 5 ]] || die "--seconds must be >= 5"

if [[ -f "$CONF" ]]; then
  # shellcheck disable=SC1090
  set -a; source "$CONF"; set +a
fi

# Customer IPs come from config.env through the same list every other script
# on this box reads. A spike that measured against a hardcoded pair would pass
# on a box whose third customer IP was the broken one.
# shellcheck source=../lib/pk-clients.sh
if [[ -r "$ROOT/lib/pk-clients.sh" ]]; then
  . "$ROOT/lib/pk-clients.sh"
  CUST="$(pk_client_ips 2>/dev/null | tr '\n' ',' | sed 's/,$//')"
else
  CUST="${PK_CLIENT_IPS:-}"
fi

echo
echo "${B}phraseguard-spike${N}  mode=$MODE  window=${SECONDS_RUN}s  iface=$IFACE"
echo

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
command -v python3  >/dev/null || die "python3 is required"
[[ -r "$SPIKE" ]] || die "spike module not found: $SPIKE"

FAIL=0
chk() { # chk <ok|warn|bad> <label> <detail>
  case "$1" in
    ok)   printf '  %s OK %s  %-22s %s\n' "$G" "$N" "$2" "$3" ;;
    warn) printf '  %sWARN%s  %-22s %s\n' "$Y" "$N" "$2" "$3" ;;
    bad)  printf '  %sFAIL%s  %-22s %s\n' "$R" "$N" "$2" "$3"; FAIL=1 ;;
  esac
}

if [[ -z "$CUST" ]]; then
  chk bad "customer IPs" "none — set PK_CLIENT_IPS in $CONF"
else
  chk ok "customer IPs" "$CUST"
fi

if command -v tcpdump >/dev/null; then
  chk ok "tcpdump" "$(command -v tcpdump)"
else
  chk bad "tcpdump" "not installed — the capture cannot start"
fi

if [[ "$(id -u)" != "0" ]]; then
  chk warn "privileges" "not root; tcpdump and 'asterisk -rx' will likely fail"
else
  chk ok "privileges" "root"
fi

if asterisk -rx "core show version" >/dev/null 2>&1; then
  chk ok "asterisk CLI" "$(asterisk -rx 'core show version' 2>/dev/null | head -1)"
else
  chk bad "asterisk CLI" "not reachable on the control socket"
fi

# AMI, reported rather than assumed — the brief asks specifically.
if [[ -r /etc/asterisk/manager.conf ]]; then
  if grep -qiE '^\s*enabled\s*=\s*(yes|true|on|1)' /etc/asterisk/manager.conf; then
    chk warn "AMI" "ENABLED — prefer a persistent AMI connection over forking"
  else
    chk ok "AMI" "disabled (expected; see asterisk/manager.conf.tpl)"
  fi
else
  chk warn "AMI" "/etc/asterisk/manager.conf not readable"
fi

# The dialplan line the exact mapping depends on. Checked against the RENDERED
# config, not the template: the template is what we intended, /etc/asterisk is
# what is running.
if [[ -r /etc/asterisk/extensions.conf ]]; then
  if grep -q '__SBC_CALLID' /etc/asterisk/extensions.conf; then
    chk ok "SBC_CALLID in dialplan" "present in the live extensions.conf"
  else
    chk bad "SBC_CALLID in dialplan" \
        "ABSENT — exact resolution is impossible on this box"
  fi
else
  chk warn "SBC_CALLID in dialplan" "/etc/asterisk/extensions.conf not readable"
fi

CHANNELS="$(asterisk -rx 'core show channels' 2>/dev/null \
            | sed -n 's/^\([0-9]\{1,\}\) active channels\{0,1\}.*/\1/p' | head -1)"
chk ok "active channels" "${CHANNELS:-0}"

echo
if (( FAIL )); then
  echo "  ${R}${B}Preflight refused.${N} Nothing was started."
  echo
  exit 2
fi

if [[ "$MODE" == "selftest" ]]; then
  echo "  ${G}${B}Preflight passed.${N} Nothing was started and nothing changed."
  echo "  ${D}Verify the CLI field layout next:  $0 --dump${N}"
  echo "  ${D}Then measure:                      $0 --arm${N}"
  echo
  exit 0
fi

ARGS=(--customer-ips "$CUST" --iface "$IFACE" --seconds "$SECONDS_RUN"
      --poll "$POLL")
(( NO_HEURISTIC )) && ARGS+=(--no-heuristic)

if [[ "$MODE" == "dump" ]]; then
  exec python3 "$SPIKE" "${ARGS[@]}" --dump
fi

# ---------------------------------------------------------------------------
# --prove-hangup: the one destructive path
# ---------------------------------------------------------------------------
if (( PROVE )); then
  echo "  ${R}${B}--prove-hangup will DISCONNECT ONE LIVE CALL.${N}"
  echo
  echo "  That call belongs to a paying customer and its consumer hears the"
  echo "  line go dead. It is the only way to prove that the resolved channel"
  echo "  name is one Asterisk will actually act on, so it is offered — but it"
  echo "  is a deliberate act, not a side effect of measuring."
  echo
  echo "  Resolution coverage and latency are measured WITHOUT this. Run the"
  echo "  spike normally first; only reach for this once the mapping already"
  echo "  looks right and the remaining doubt is whether the hangup lands."
  echo
  read -r -p "  Type DISCONNECT to proceed: " ans
  if [[ "$ans" != "DISCONNECT" ]]; then
    echo "  Not confirmed. Exiting without measuring."
    echo
    exit 2
  fi
  ARGS+=(--prove-hangup)
  echo
fi

# ---------------------------------------------------------------------------
# Arm: idle until a call is actually up.
# ---------------------------------------------------------------------------
if [[ "$MODE" == "arm" ]]; then
  say "armed — waiting for a live channel (nothing is being captured yet)"
  (( ARM_TIMEOUT_MIN > 0 )) && say "will give up after ${ARM_TIMEOUT_MIN}m"
  DEADLINE=$(( $(date +%s) + ARM_TIMEOUT_MIN * 60 ))
  while :; do
    # "channel" not "channels" — Asterisk prints the singular for one call,
    # and a pattern anchored on the plural sits armed straight through it.
    # tools/arm-outbound-capture.sh learned this the hard way.
    n="$(asterisk -rx 'core show channels' 2>/dev/null \
         | sed -n 's/^\([0-9]\{1,\}\) active channels\{0,1\}.*/\1/p' | head -1)"
    [[ "${n:-0}" -gt 0 ]] && { say "${G}traffic detected (${n} channels)${N}"; break; }
    if (( ARM_TIMEOUT_MIN > 0 && $(date +%s) > DEADLINE )); then
      say "${Y}arm window expired with no traffic${N}"
      echo
      echo "  ${D}The trunk has been paused since 2026-08-12 (HANDOFF.md §Trunk${N}"
      echo "  ${D}is paused). This measurement needs live calls; there is${N}"
      echo "  ${D}nothing to fix here until the trunk returns.${N}"
      echo
      exit 3
    fi
    sleep 2
  done
fi

say "measuring for ${SECONDS_RUN}s"
python3 "$SPIKE" "${ARGS[@]}"
rc=$?
echo
case "$rc" in
  0) echo "  ${G}${B}PASS${N} — the mapping holds. Phase 2 (capture and demux) can start." ;;
  1) echo "  ${R}${B}STOP${N} — report this before building anything downstream." ;;
  3) echo "  ${Y}No traffic was seen.${N} Re-run with --arm." ;;
esac
echo
exit "$rc"
