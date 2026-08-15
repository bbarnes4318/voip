#!/usr/bin/env bash
#
# capture-answered-calls.sh — answer one question about the 2-second answers:
# is the far end hanging up, or are we?
#
#   ./capture-answered-calls.sh --arm      wait for traffic, then capture
#   ./capture-answered-calls.sh --now      capture immediately
#   ./capture-answered-calls.sh --self-test  preflight only, never enables
#                                            logging, safe on production
#
# WHAT IT IS FOR
# --------------
# 2,182 answered calls on 2026-08-14, of which 1,997 had a billsec of exactly
# 2, and talk time took only three values (0s, 2s, 5s) across 99.7% of them.
# That is machine behaviour. Two explanations fit the CDR equally well and
# they lead opposite directions:
#
#   carrier intercept  — 200 OK with no prior 180, recorded announcement,
#                        BYE from the carrier at ~2s. Our numbers are
#                        labelled and the answer rate is meaningless.
#   something on our path — BYE from OUR side. Then we are tearing down
#                        answered calls and the answer rate is real but the
#                        call path is broken.
#
# The CDR cannot tell them apart: both land as hangup cause 16, normal
# clearing, on the A-leg. Only the SIP trace can, which is what this captures.
#
# WHY IT ARMS INSTEAD OF RUNNING
# ------------------------------
# The box has taken no calls since 2026-08-14 21:31. Running a 15-minute
# capture against silence burns the window and captures nothing. --arm idles
# with SIP logging OFF until it sees an INVITE, and only then starts the
# clock. Nobody has to be watching when the customer's dialler comes back.
#
# SAFETY
# ------
# SIP logging is global and verbose, so it is never left on: the disable runs
# from a trap on EXIT, INT, TERM and HUP, and again unconditionally at the
# end. --self-test proves the preflight without touching the logger.
#
# EXIT CODES
#   0  captured (or --self-test passed)
#   1  preflight refused: not enough disk, Asterisk not reachable, lock held
#   2  bad arguments
#   3  armed but the arm window expired with no traffic
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARSER="$HERE/capture-parse.py"

COUNT=10
WINDOW_MIN=15
MIN_FREE_GB=2
ARM_TIMEOUT_MIN=0            # 0 = wait forever
MAX_BILLSEC=5
MODE=""
OUTDIR="/var/log/asterisk/capture"
FULL_LOG="/var/log/asterisk/full"
LOCK="/var/run/capture-answered-calls.lock"

B=$'\033[1m'; R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; D=$'\033[2m'; N=$'\033[0m'
[[ -t 1 ]] || { B=""; R=""; G=""; Y=""; D=""; N=""; }

say()  { echo "$(date -u '+%H:%M:%S') $*"; }
die()  { echo "capture-answered-calls.sh: ERROR: $*" >&2; exit 2; }
ast()  { asterisk -rx "$*" 2>/dev/null; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --arm)        MODE="arm"; shift ;;
    --now)        MODE="now"; shift ;;
    --self-test)  MODE="selftest"; shift ;;
    -n|--count)   COUNT="$2"; shift 2 ;;
    -t|--minutes) WINDOW_MIN="$2"; shift 2 ;;
    --max-billsec) MAX_BILLSEC="$2"; shift 2 ;;
    --min-free-gb) MIN_FREE_GB="$2"; shift 2 ;;
    --arm-timeout) ARM_TIMEOUT_MIN="$2"; shift 2 ;;
    --out)        OUTDIR="$2"; shift 2 ;;
    -h|--help)    sed -n '2,40p' "$0"; exit 0 ;;
    *) die "unknown argument '$1'" ;;
  esac
done
[[ -n "$MODE" ]] || die "pick one of --arm, --now, --self-test (see --help)"
[[ "$COUNT" =~ ^[0-9]+$ && "$COUNT" -ge 1 ]] || die "--count must be >= 1"
[[ "$WINDOW_MIN" =~ ^[0-9]+$ && "$WINDOW_MIN" -ge 1 ]] || die "--minutes must be >= 1"

# ---------------------------------------------------------------------------
# The disable path. This is the only thing in here that MUST never fail to
# run, so it is a trap, it is idempotent, and it does not depend on any state
# built up above it.
# ---------------------------------------------------------------------------
LOGGER_ON=0
cleanup() {
  local rc=$?
  if (( LOGGER_ON )); then
    ast "pjsip set logger off" >/dev/null
    ast "rtcp set stats off"   >/dev/null
    LOGGER_ON=0
    say "${G}SIP logging disabled.${N}"
    # Prove it rather than assert it: this is the failure everyone regrets.
    if ast "pjsip show settings" | grep -qi 'debug.*[Yy]es'; then
      echo "${R}WARNING: pjsip logger may still be enabled. Run:" >&2
      echo "  asterisk -rx 'pjsip set logger off'${N}" >&2
    fi
  fi
  exit "$rc"
}
trap cleanup EXIT INT TERM HUP

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
echo
echo "${B}capture-answered-calls${N}  mode=$MODE  target=${COUNT} calls  window=${WINDOW_MIN}m"
echo

command -v asterisk >/dev/null || die "asterisk CLI not on PATH"
command -v python3  >/dev/null || die "python3 is needed for the trace parser"
[[ -r "$PARSER" ]] || die "parser not found next to this script: $PARSER"
ast "core show version" >/dev/null || { echo "${R}Asterisk is not reachable.${N}"; exit 1; }

[[ -r "$FULL_LOG" ]] || { echo "${R}cannot read $FULL_LOG${N}"; exit 1; }
if ! grep -q 'verbose' /etc/asterisk/logger.conf 2>/dev/null; then
  echo "${Y}WARNING: logger.conf has no verbose channel on any file.${N}"
  echo "${D}  pjsip logger output is emitted at verbose level; without it the${N}"
  echo "${D}  trace goes to the console only and this capture sees nothing.${N}"
fi

# Disk. Refuse rather than risk filling the partition that also holds the CDR.
FREE_KB="$(df -Pk /var/log | awk 'NR==2{print $4}')"
FREE_GB=$(( FREE_KB / 1024 / 1024 ))
printf '  %-22s %s GB free (floor %s GB)\n' "disk /var/log" "$FREE_GB" "$MIN_FREE_GB"
if (( FREE_GB < MIN_FREE_GB )); then
  echo
  echo "  ${R}${B}REFUSING:${N} under ${MIN_FREE_GB} GB free on /var/log."
  echo "  Largest consumers:"
  du -sh /var/log/* 2>/dev/null | sort -rh | head -5 | sed 's/^/    /'
  echo "  Rotate with: logrotate -f /etc/logrotate.d/asterisk"
  exit 1
fi

# Rough sizing so nobody is surprised by the growth.
EST_MB=$(( COUNT * 12 / 1000 + 1 ))
printf '  %-22s ~%s MB for %s calls (~8-12 KB/call, both legs)\n' \
       "estimated trace" "$EST_MB" "$COUNT"
printf '  %-22s %s\n' "current full log" "$(du -h "$FULL_LOG" 2>/dev/null | cut -f1)"

# Carrier addresses, read live so this cannot drift from the config. Anything
# that is not one of these is the customer side.
CARRIER_IPS="$(ast "pjsip show contacts" \
               | sed -n 's/.*fractel[0-9]*\/sip:\([0-9.]*\):.*/\1/p' | sort -u)"
if [[ -z "$CARRIER_IPS" ]]; then
  echo "  ${Y}WARNING: no fractel contacts found; BYE attribution will be${N}"
  echo "  ${D}  reported as unknown rather than guessed.${N}"
fi
printf '  %-22s %s\n' "carrier IPs" "$(tr '\n' ' ' <<< "$CARRIER_IPS")"
echo

if [[ "$MODE" == "selftest" ]]; then
  echo "  ${G}${B}Preflight passed.${N} Nothing was enabled; the logger is untouched."
  echo "  ${D}Arm it with:  $0 --arm${N}"
  exit 0
fi

# One at a time. Two of these racing would each disable the other's logger.
exec 9>"$LOCK" || die "cannot open lock $LOCK"
flock -n 9 || { echo "${R}another capture is already running (lock $LOCK)${N}"; exit 1; }

mkdir -p "$OUTDIR" || die "cannot create $OUTDIR"
STAMP="$(date -u '+%Y%m%dT%H%M%SZ')"
TRACE="$OUTDIR/trace-$STAMP.log"
STATS="$OUTDIR/rtpstats-$STAMP.txt"
REPORT="$OUTDIR/report-$STAMP.txt"

# ---------------------------------------------------------------------------
# Arm: idle with the logger OFF until an INVITE shows up.
# ---------------------------------------------------------------------------
if [[ "$MODE" == "arm" ]]; then
  say "armed — waiting for traffic, SIP logging is OFF"
  (( ARM_TIMEOUT_MIN > 0 )) && say "will give up after ${ARM_TIMEOUT_MIN}m"
  ARM_DEADLINE=$(( $(date +%s) + ARM_TIMEOUT_MIN * 60 ))
  BASE=$(wc -c < "$FULL_LOG")
  while :; do
    sleep 2
    NOW_SZ=$(wc -c < "$FULL_LOG")
    # A shrinking file means logrotate moved it; re-baseline.
    (( NOW_SZ < BASE )) && BASE=0
    if (( NOW_SZ > BASE )); then
      if tail -c "+$((BASE + 1))" "$FULL_LOG" | grep -q 'SBC-DIAL'; then
        say "${G}traffic detected${N} — starting capture"
        break
      fi
      BASE=$NOW_SZ
    fi
    if (( ARM_TIMEOUT_MIN > 0 && $(date +%s) > ARM_DEADLINE )); then
      say "${Y}arm window expired with no traffic; logger was never enabled${N}"
      exit 3
    fi
  done
fi

# ---------------------------------------------------------------------------
# Capture
# ---------------------------------------------------------------------------
START_OFF=$(wc -c < "$FULL_LOG")
ast "pjsip set logger on" >/dev/null
ast "rtcp set stats on"   >/dev/null
LOGGER_ON=1
say "${G}SIP logging enabled${N} (offset $START_OFF)"

DEADLINE=$(( $(date +%s) + WINDOW_MIN * 60 ))
: > "$STATS"
QUALIFIED=0

while :; do
  sleep 1

  # RTP counters, sampled while calls are up. pjsip show channelstats is the
  # only place both directions are visible per channel; after the hangup the
  # channel is gone and the counts with it.
  # awk, not sed: the channel and the optional BridgeId are both bare tokens,
  # and a backtracking BRE happily matches the tail of the channel name
  # ("1-000027a1" out of "fractel1-000027a1"). Anchor on the HH:MM:SS uptime
  # column instead and take the fields relative to it.
  ast "pjsip show channelstats" \
    | awk 'NF==12 && $2 ~ /^[0-9][0-9]:[0-9][0-9]:[0-9][0-9]$/ && ($4>0 || $8>0) \
           {print $1, "rx="$4, "tx="$8}' \
    >> "$STATS" 2>/dev/null

  NOW_SZ=$(wc -c < "$FULL_LOG")
  (( NOW_SZ < START_OFF )) && { say "${Y}log rotated mid-capture; stopping${N}"; break; }
  tail -c "+$((START_OFF + 1))" "$FULL_LOG" > "$TRACE"

  QUALIFIED="$(python3 "$PARSER" --trace "$TRACE" --max-billsec "$MAX_BILLSEC" \
                 --carrier-ips "$CARRIER_IPS" --count-only 2>/dev/null)"
  [[ "$QUALIFIED" =~ ^[0-9]+$ ]] || QUALIFIED=0

  (( QUALIFIED >= COUNT )) && { say "${G}captured $QUALIFIED call(s)${N}"; break; }
  if (( $(date +%s) > DEADLINE )); then
    say "${Y}${WINDOW_MIN}m window expired with $QUALIFIED call(s)${N}"
    break
  fi
  say "capturing… $QUALIFIED/$COUNT  ($(( (DEADLINE - $(date +%s)) / 60 ))m left)"
done

ast "pjsip set logger off" >/dev/null
ast "rtcp set stats off"   >/dev/null
LOGGER_ON=0
say "${G}SIP logging disabled.${N}"

tail -c "+$((START_OFF + 1))" "$FULL_LOG" > "$TRACE"
python3 "$PARSER" --trace "$TRACE" --max-billsec "$MAX_BILLSEC" \
        --carrier-ips "$CARRIER_IPS" --stats "$STATS" | tee "$REPORT"

echo
echo "  trace  : $TRACE"
echo "  report : $REPORT"
exit 0
