#!/usr/bin/env bash
#
# monitor.sh — live operational view of the SBC.
#
#   ./monitor.sh                 refresh every 2s until Ctrl-C
#   ./monitor.sh --once          print one frame and exit (for logs/RUNBOOK)
#   ./monitor.sh -i 5            refresh interval
#   ./monitor.sh -w 60           stats window in minutes (default 15)
#
# Shows: active channels total and per customer IP, calls/sec, ASR, ACD,
# rejection breakdown, and FracTEL gateway reachability.
#
# ACD is on here because it is the leading indicator nobody watches. A healthy
# US consumer campaign runs an ACD in the tens of seconds. If ACD collapses to
# a handful of seconds while ASR stays high, the far end is answering and
# hanging up straight away — that is what a traceback problem looks like from
# this side, a week before the traceback arrives.
#
# Drives Asterisk through `asterisk -rx` over the local control socket. There
# is deliberately no AMI on this box (see asterisk/manager.conf.tpl).

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${CONF:-$HERE/config.env}"
AST="${AST:-asterisk}"
INTERVAL=2
WINDOW_MIN=15
ONCE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --once)     ONCE=1; shift ;;
    -i|--interval) INTERVAL="$2"; shift 2 ;;
    -w|--window)   WINDOW_MIN="$2"; shift 2 ;;
    -c|--conf)     CONF="$2"; shift 2 ;;
    -h|--help)  sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "monitor.sh: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

if [[ -f "$CONF" ]]; then
  # shellcheck disable=SC1090
  set -a; source "$CONF"; set +a
fi
CDR_CSV_PATH="${CDR_CSV_PATH:-/var/log/asterisk/cdr-custom/sbc.csv}"
AST_LOG="${AST_LOG:-/var/log/asterisk/messages}"
MAX_CONCURRENT_PER_IP="${MAX_CONCURRENT_PER_IP:-50}"
MAX_CPS="${MAX_CPS:-10}"

B=$'\033[1m'; R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; D=$'\033[2m'; N=$'\033[0m'
if [[ ! -t 1 ]]; then B=""; R=""; G=""; Y=""; D=""; N=""; fi

# ---------------------------------------------------------------------------
# CDR statistics over the window.
#
# Fields are CSV_QUOTE'd and caller ID is attacker-controlled, so it will
# eventually contain a comma. Splitting on bare commas would silently
# misattribute columns, so this walks the quoting properly.
#
# Column order (see asterisk/cdr_custom.conf.tpl):
#   1 start  2 answer  3 end  4 source_ip  5 endpoint  6 cid  7 dest
#   8 duration  9 billsec  10 disposition  11 cause  12 gateway
#   13 call-id  14 reject_reason  15 uniqueid
# ---------------------------------------------------------------------------
cdr_stats() {
  local cutoff="$1"
  [[ -r "$CDR_CSV_PATH" ]] || { echo "NOCDR"; return; }
  tail -n 50000 "$CDR_CSV_PATH" 2>/dev/null | awk -v cutoff="$cutoff" '
    function csvsplit(line, arr,   i,n,c,field,inq,L) {
      n=0; field=""; inq=0; L=length(line)
      for (i=1;i<=L;i++) {
        c=substr(line,i,1)
        if (inq) {
          if (c=="\"") { if (substr(line,i+1,1)=="\"") { field=field "\""; i++ } else inq=0 }
          else field=field c
        } else {
          if (c=="\"") inq=1
          else if (c==",") { arr[++n]=field; field="" }
          else field=field c
        }
      }
      arr[++n]=field
      return n
    }
    {
      n = csvsplit($0, f)
      if (n < 14) next
      if (f[1] < cutoff) next
      total++
      ep = (f[5] != "" ? f[5] : "unknown")
      by_ep[ep]++
      if (f[10] == "ANSWERED") { ans++; bill += f[9]+0; by_ep_ans[ep]++ }
      if (f[14] != "") rej[f[14]]++
    }
    END {
      printf "TOTAL %d\n", total
      printf "ANSWERED %d\n", ans
      printf "BILLSEC %d\n", bill
      for (e in by_ep)  printf "EP %s %d %d\n", e, by_ep[e], by_ep_ans[e]+0
      for (r in rej)    printf "REJ %s %d\n", r, rej[r]
    }
  '
}

# CPS is measured from SBC-DIAL notices in the Asterisk log rather than from
# CDRs, because a CDR row is written when a call ENDS — deriving CPS from it
# would lag by the call duration and read as zero during a burst.
current_cps() {
  local secs="${1:-10}" cutoff
  cutoff="$(date -d "$secs seconds ago" '+%F %T' 2>/dev/null)" || { echo "n/a"; return; }
  [[ -r "$AST_LOG" ]] || { echo "n/a"; return; }
  tail -n 20000 "$AST_LOG" 2>/dev/null | awk -v cutoff="$cutoff" -v secs="$secs" '
    /SBC-DIAL/ {
      ts = substr($0, 1, 19)
      if (ts >= cutoff) c++
    }
    END { printf "%.1f", c/secs }
  '
}

# Per-endpoint live concurrency, straight from the same GROUP() counters the
# dialplan enforces the cap with — so what is displayed is exactly what is
# being enforced, not a second estimate that can drift from it.
group_counts() {
  "$AST" -rx "group show channels" 2>/dev/null | awk '
    NF >= 3 && $3 == "cust" { c[$2]++ }
    END { for (g in c) printf "%s %d\n", g, c[g] }
  '
}

# `pjsip show contacts` rows look like:
#   Contact:  fractel1/sip:192.0.2.31:5060   <hash>  Avail   12.345
# Status match is case-sensitive: "Unavail" is lowercase after the U and so
# cannot be confused with "Avail".
gateway_health() {
  "$AST" -rx "pjsip show contacts" 2>/dev/null | awk '
    /fractel/ {
      name = ""; status = "Unknown"
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^fractel[0-9]+\//) { split($i, b, "/"); name = b[1] }
        if ($i == "Avail" || $i == "Unavail" || $i == "NonQual" ||
            $i == "Unknown" || $i == "Created" || $i == "Removed") status = $i
      }
      if (name != "") printf "%s %s\n", name, status
    }
  ' | sort -u
}

frame() {
  local cutoff stats total ans bill asr acd cps
  cutoff="$(date -d "$WINDOW_MIN minutes ago" '+%F %T' 2>/dev/null || echo '0000-00-00 00:00:00')"
  stats="$(cdr_stats "$cutoff")"

  if [[ "$stats" == "NOCDR" ]]; then
    total=0; ans=0; bill=0
  else
    total="$(awk '/^TOTAL/{print $2}'    <<< "$stats")"; total="${total:-0}"
    ans="$(awk   '/^ANSWERED/{print $2}' <<< "$stats")"; ans="${ans:-0}"
    bill="$(awk  '/^BILLSEC/{print $2}'  <<< "$stats")"; bill="${bill:-0}"
  fi

  if (( total > 0 )); then asr="$(awk -v a="$ans" -v t="$total" 'BEGIN{printf "%.1f%%", 100*a/t}')"
  else asr="--"; fi
  if (( ans > 0 )); then acd="$(awk -v b="$bill" -v a="$ans" 'BEGIN{printf "%.0fs", b/a}')"
  else acd="--"; fi
  cps="$(current_cps 10)"

  echo "${B}SBC monitor${N}   $(date '+%F %T')   window ${WINDOW_MIN}m   ${D}cdr: ${CDR_CSV_PATH}${N}"
  echo "-------------------------------------------------------------------------"

  # --- live channels ---
  local chans
  chans="$("$AST" -rx "core show channels count" 2>/dev/null | head -1)"
  if [[ -z "$chans" ]]; then
    echo "  ${R}Asterisk unreachable${N} — is it running? (systemctl status asterisk)"
    echo
    return
  fi
  echo "  ${B}channels${N}      $chans"

  echo -n "  ${B}per customer${N}  "
  local gc any=0
  gc="$(group_counts)"
  if [[ -n "$gc" ]]; then
    while read -r ep n; do
      local col="$G"
      (( n >= MAX_CONCURRENT_PER_IP ))          && col="$R"
      (( n >= (MAX_CONCURRENT_PER_IP * 8 / 10) && n < MAX_CONCURRENT_PER_IP )) && col="$Y"
      printf "%s%s=%d/%d%s  " "$col" "$ep" "$n" "$MAX_CONCURRENT_PER_IP" "$N"
      any=1
    done <<< "$gc"
  fi
  (( any )) || printf "${D}idle${N}"
  echo

  # --- rate and quality ---
  local cpscol="$G"
  awk -v c="$cps" -v m="$MAX_CPS" 'BEGIN{exit !(c+0 >= m*0.8)}' && cpscol="$Y"
  awk -v c="$cps" -v m="$MAX_CPS" 'BEGIN{exit !(c+0 >= m)}'     && cpscol="$R"
  echo "  ${B}cps (10s)${N}     ${cpscol}${cps}${N} / ${MAX_CPS}"
  echo "  ${B}calls${N}         ${total} in window, ${ans} answered"
  echo "  ${B}ASR${N}           ${asr}"

  # ACD colouring: very short average duration on answered calls is the
  # traceback tell. Flag it here rather than discovering it in a complaint.
  local acdcol="$G" acdnote=""
  if [[ "$acd" != "--" ]]; then
    local acdn="${acd%s}"
    if (( acdn < 10 )); then acdcol="$R"; acdnote=" ${R}<- abnormally short, check for traceback/complaint pattern${N}"
    elif (( acdn < 20 )); then acdcol="$Y"; acdnote=" ${Y}<- low${N}"; fi
  fi
  echo "  ${B}ACD${N}           ${acdcol}${acd}${N}${acdnote}"

  # --- rejections ---
  local rejlines
  rejlines="$(awk '/^REJ/{printf "%s=%s  ", $2, $3}' <<< "$stats")"
  if [[ -n "$rejlines" ]]; then
    echo "  ${B}rejected${N}      ${Y}${rejlines}${N}"
  else
    echo "  ${B}rejected${N}      ${D}none in window${N}"
  fi

  # --- trunk ---
  echo -n "  ${B}fractel${N}       "
  local gh up=0 down=0
  gh="$(gateway_health)"
  if [[ -z "$gh" ]]; then
    echo "${R}no gateway contacts found${N}"
  else
    while read -r name st; do
      if [[ "$st" == "Avail" ]]; then printf "${G}%s${N} " "$name"; up=$((up+1))
      else printf "${R}%s(%s)${N} " "$name" "$st"; down=$((down+1)); fi
    done <<< "$gh"
    (( up == 0 )) && printf "  ${R}<- TRUNK DOWN${N}"
    echo
  fi

  # --- killswitch ---
  local ks
  ks="$("$AST" -rx "dialplan show globals" 2>/dev/null | grep -cE '^\s*SBC_KILLSWITCH\s*=\s*1' || true)"
  if [[ "${ks:-0}" != "0" ]]; then
    echo
    echo "  ${R}${B}*** KILLSWITCH IS ON — new customer calls are being refused ***${N}"
  fi
  echo
}

if [[ "$ONCE" == 1 ]]; then
  frame
  exit 0
fi

trap 'echo; exit 0' INT
while true; do
  out="$(frame)"
  clear
  printf '%s\n' "$out"
  echo "  ${D}refresh ${INTERVAL}s — Ctrl-C to exit${N}"
  sleep "$INTERVAL"
done
