#!/usr/bin/env bash
#
# didctl.sh — inspect and manage the DID pool, its daily caps and its
#             distribution.
#
#   ./didctl.sh status              today at a glance: usage, caps, overflow
#   ./didctl.sh today [--csv]       every DID's count for today
#   ./didctl.sh show <did>          one number, today and the days before it
#   ./didctl.sh pools               the pools the running dialplan actually has
#   ./didctl.sh distribution [csv]  per-DID / per-NPA / per-gateway, from CDR
#   ./didctl.sh prune [days]        drop counter keys older than <days> (7)
#   ./didctl.sh set <did> <n>       force a count. TEST TOOL — see below.
#   ./didctl.sh reset <did>|--all   zero today's counts. Needs --force.
#
# Counters live in the Asterisk database under
#
#     sbc/didcnt/<YYYYMMDD>/<did>
#
# keyed by LOCAL date, which is what makes midnight rollover free: at 00:00
# the dialplan starts writing a new family and yesterday's counts are simply
# no longer consulted. There is no reset job, so there is no reset job to
# fail, and no race at the boundary.
#
# `prune` exists only to stop those families accumulating forever. It never
# touches today.
#
# `set` and `reset` change what the SBC believes it has already sent. Raising
# a count takes a number out of rotation; lowering one puts it back and lets
# it exceed its real daily volume. Both refuse to run without --force, and
# `set` is here because the acceptance suite needs to drive a DID to its cap
# without waiting for 200 calls.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${CONF:-$HERE/config.env}"
AST="${AST:-asterisk}"

# shellcheck disable=SC1090
[[ -f "$CONF" ]] && { set -a; source "$CONF"; set +a; }

DID_DAILY_CAP="${DID_DAILY_CAP:-200}"
CDR_CSV_PATH="${CDR_CSV_PATH:-/var/log/asterisk/cdr-custom/sbc.csv}"
TODAY="$(date '+%Y%m%d')"

B=$'\033[1m'; D=$'\033[2m'; R=$'\033[31m'; Y=$'\033[33m'; G=$'\033[32m'; N=$'\033[0m'
[[ -t 1 ]] || { B=""; D=""; R=""; Y=""; G=""; N=""; }

die() { echo "didctl.sh: ERROR: $*" >&2; exit 1; }

need_ast() {
  "$AST" -rx "core show version" >/dev/null 2>&1 \
    || die "Asterisk is not running, or this user cannot reach its control socket."
}

# `database show <family>` prints one "/family/key : value" line per entry.
# Anything without a colon is a header or a summary line.
db_show() { "$AST" -rx "database show $1" 2>/dev/null | awk -F':' '/^\// {
    k=$1; v=$2
    gsub(/[[:space:]]+$/,"",k); gsub(/^[[:space:]]+/,"",v); gsub(/[[:space:]]+$/,"",v)
    print k "\t" v
  }'; }

# Counts for one day, emitted as "<did> <count>".
day_counts() { db_show "sbc/didcnt/$1" | awk -F'\t' '{n=split($1,p,"/"); print p[n], $2}'; }

# ---------------------------------------------------------------------------
# The CDR is CSV_QUOTE'd and caller ID is attacker-controlled text that will
# eventually contain a comma, so every reader here walks the quoting properly
# rather than splitting on bare commas.
# ---------------------------------------------------------------------------
CSVSPLIT='
function csvsplit(line, arr,   i,n,c,f,q,L) {
  n=0; f=""; q=0; L=length(line)
  for (i=1;i<=L;i++) { c=substr(line,i,1)
    if (q) { if (c=="\"") { if (substr(line,i+1,1)=="\"") { f=f "\""; i++ } else q=0 } else f=f c }
    else { if (c=="\"") q=1; else if (c==",") { arr[++n]=f; f="" } else f=f c } }
  arr[++n]=f; return n }
'

bar() { # bar <count> <max> <width>
  awk -v c="$1" -v m="$2" -v w="${3:-24}" 'BEGIN{
    if (m<=0) m=1; n=int(c*w/m); if (n>w) n=w
    s=""; for(i=0;i<n;i++) s=s "#"; for(i=n;i<w;i++) s=s " "
    print s }'
}

# ===========================================================================
case "${1:-status}" in

# ---------------------------------------------------------------------------
status)
  need_ast
  echo
  echo "${B}DID pool${N}   $(date '+%F %T')   cap ${DID_DAILY_CAP}/DID/day   counters for ${TODAY}"
  echo

  COUNTS="$(day_counts "$TODAY")"
  if [[ -z "$COUNTS" ]]; then
    echo "  ${D}no calls counted today${N}"
    echo
    exit 0
  fi

  read -r USED TOTALCALLS MAXC <<< "$(awk '{n++; s+=$2; if($2>m) m=$2} END{print n+0, s+0, m+0}' <<< "$COUNTS")"
  ATCAP="$(awk -v c="$DID_DAILY_CAP" '$2>=c' <<< "$COUNTS" | wc -l)"
  NEAR="$(awk -v c="$DID_DAILY_CAP" '$2>=c*0.8 && $2<c' <<< "$COUNTS" | wc -l)"

  echo "  numbers used today   $USED"
  echo "  calls counted        $TOTALCALLS"
  echo "  busiest number       $MAXC calls"
  capcol="$G"; [[ "$ATCAP" -gt 0 ]] && capcol="$R"
  echo "  ${capcol}at cap${N}               $ATCAP"
  nearcol="$G"; [[ "$NEAR" -gt 0 ]] && nearcol="$Y"
  echo "  ${nearcol}within 20% of cap${N}    $NEAR"
  echo

  echo "  ${B}busiest 15${N}"
  sort -k2 -rn <<< "$COUNTS" | head -15 | while read -r did cnt; do
    col="$N"
    awk -v c="$cnt" -v m="$DID_DAILY_CAP" 'BEGIN{exit !(c>=m*0.8)}' && col="$Y"
    awk -v c="$cnt" -v m="$DID_DAILY_CAP" 'BEGIN{exit !(c>=m)}'     && col="$R"
    printf '    %s%-13s %5s/%-5s%s |%s|\n' "$col" "$did" "$cnt" "$DID_DAILY_CAP" "$N" "$(bar "$cnt" "$DID_DAILY_CAP")"
  done
  echo

  # An overflow rate that is climbing means an NPA pool is undersized. It is
  # not an error and nothing is broken — it is the number to watch.
  if [[ -r "$CDR_CSV_PATH" ]]; then
    echo "  ${B}selection reason, last 20000 CDR rows${N}"
    tail -n 20000 "$CDR_CSV_PATH" 2>/dev/null | awk "$CSVSPLIT"'
      { n=csvsplit($0,f); if (n<19) next; r=(f[17]==""?"(not selected)":f[17]); c[r]++ ; t++ }
      END { for (k in c) printf "    %-16s %6d  %5.1f%%\n", k, c[k], 100*c[k]/t }' | sort -k2 -rn
    echo
  fi
  ;;

# ---------------------------------------------------------------------------
today)
  need_ast
  C="$(day_counts "$TODAY")"
  if [[ "${2:-}" == "--csv" ]]; then
    echo "did,count,cap,remaining"
    sort <<< "$C" | awk -v c="$DID_DAILY_CAP" 'NF{r=c-$2; if(r<0)r=0; print $1 "," $2 "," c "," r}'
  else
    printf '%-14s %8s %8s %10s\n' did count cap remaining
    sort <<< "$C" | awk -v c="$DID_DAILY_CAP" 'NF{r=c-$2; if(r<0)r=0; printf "%-14s %8d %8d %10d\n", $1, $2, c, r}'
  fi
  ;;

# ---------------------------------------------------------------------------
show)
  need_ast
  DID="$(printf '%s' "${2:-}" | tr -cd '0-9')"
  [[ -n "$DID" ]] || die "usage: didctl.sh show <did>"
  (( ${#DID} == 10 )) && DID="1$DID"
  echo
  echo "  ${B}$DID${N}   cap ${DID_DAILY_CAP}/day"
  echo
  for i in $(seq 0 13); do
    d="$(date -d "-$i day" '+%Y%m%d' 2>/dev/null || date -v-"${i}"d '+%Y%m%d' 2>/dev/null)"
    [[ -n "$d" ]] || continue
    v="$("$AST" -rx "database get sbc/didcnt/$d $DID" 2>/dev/null | awk -F': ' '/Value/{print $2}')"
    [[ -z "$v" ]] && v=0
    mark=""; [[ "$d" == "$TODAY" ]] && mark=" ${D}(today)${N}"
    printf '    %s  %5s  |%s|%s\n' "$d" "$v" "$(bar "$v" "$DID_DAILY_CAP")" "$mark"
  done
  echo
  ;;

# ---------------------------------------------------------------------------
pools)
  need_ast
  echo
  echo "  ${B}pools in the RUNNING dialplan${N}  ${D}(not what dids.csv says — what Asterisk loaded)${N}"
  echo
  "$AST" -rx "dialplan show globals" 2>/dev/null \
    | grep -E '^SBC_DID_(POOL|CNT)_' \
    | sort \
    | awk -F'=' '
        /_CNT_/ { split($1,a,"_CNT_"); cnt[a[2]]=$2 }
        /_POOL_/ { split($1,a,"_POOL_"); pool[a[2]]=$2 }
        END {
          for (k in pool) {
            n=split(pool[k], d, "|")
            printf "    %-10s %3d number(s)\n", k, n
            for (i=1;i<=n && i<=4;i++) printf "               %s\n", d[i]
            if (n>4) printf "               ... and %d more\n", n-4
          }
        }' | sed 's/^/  /'
  echo
  CAP="$("$AST" -rx "dialplan show globals" 2>/dev/null | awk -F'=' '/^SBC_DID_CAP/{print $2}')"
  echo "    daily cap per DID: ${CAP:-unknown}"
  echo
  ;;

# ---------------------------------------------------------------------------
# The criterion-13 and criterion-17 evidence: everything below comes out of
# the CDR alone, which is the requirement — per-DID distribution has to be
# provable from the record, not from the dialplan's own bookkeeping.
distribution)
  CSV="${2:-$CDR_CSV_PATH}"
  [[ -r "$CSV" ]] || die "cannot read $CSV"
  echo
  echo "  ${B}distribution from $CSV${N}"
  echo

  awk "$CSVSPLIT"'
    { n=csvsplit($0,f); if (n<19) { short++; next }
      did=f[16]; reason=f[17]; npa=f[18]; cnt=f[19]+0; gw=f[12]
      rows++
      if (did=="") { nodid++ } else {
        byDid[did]++; if (cnt>maxSeen[did]) maxSeen[did]=cnt
        byNpaDid[npa "\t" did]++; npaTotal[npa]++
      }
      if (reason!="") byReason[reason]++
      if (gw!="") byGw[gw]++
    }
    END {
      printf "  rows read %d   with a DID %d   without %d\n\n", rows, rows-nodid, nodid+0

      printf "  %s\n", "--- per-DID call count, from the CDR ---"
      max=0; for (d in byDid) if (byDid[d]>max) max=byDid[d]
      nd=0; for (d in byDid) nd++
      printf "  %d distinct DID(s) used\n", nd
      # Evenness within a pool is the thing being proven, so report the
      # spread rather than a list nobody will read.
      for (k in byNpaDid) { split(k,p,"\t"); npas[p[1]]=1 }
      for (npa in npas) {
        lo=999999; hi=0; sum=0; c=0
        for (k in byNpaDid) { split(k,p,"\t"); if (p[1]!=npa) continue
          v=byNpaDid[k]; c++; sum+=v; if (v<lo) lo=v; if (v>hi) hi=v }
        if (c==0) continue
        avg=sum/c
        spread = (avg>0) ? (hi-lo)/avg*100 : 0
        printf "    NPA %-5s %4d call(s) over %2d DID(s)  min %d  max %d  avg %.1f  spread %.0f%%\n",
               npa, sum, c, lo, hi, avg, spread
      }
      printf "\n  %s\n", "--- highest daily count any single DID reached ---"
      worst=0; worstd=""
      for (d in maxSeen) if (maxSeen[d]>worst) { worst=maxSeen[d]; worstd=d }
      printf "    %s at %d\n", (worstd==""?"(none)":worstd), worst

      printf "\n  %s\n", "--- selection reason ---"
      for (r in byReason) printf "    %-12s %6d\n", r, byReason[r]

      printf "\n  %s\n", "--- gateway ---"
      gmax=0; for (g in byGw) if (byGw[g]>gmax) gmax=byGw[g]
      ng=0; gsum=0; glo=999999
      for (g in byGw) { ng++; gsum+=byGw[g]; if (byGw[g]<glo) glo=byGw[g] }
      for (g in byGw) printf "    %-10s %6d\n", g, byGw[g]
      if (ng>0) {
        gavg=gsum/ng
        printf "    %d gateway(s), min %d, max %d, avg %.1f, spread %.0f%%\n",
               ng, glo, gmax, gavg, (gavg>0 ? (gmax-glo)/gavg*100 : 0)
      }
      if (short>0) printf "\n  %d row(s) had fewer than 19 columns and were skipped\n", short
    }' "$CSV"
  echo
  echo "  ${D}spread is (max-min)/avg. Round-robin over a pool that is not"
  echo "  capping out should sit in the low single digits.${N}"
  echo
  ;;

# ---------------------------------------------------------------------------
prune)
  need_ast
  DAYS="${2:-7}"
  [[ "$DAYS" =~ ^[0-9]+$ ]] || die "usage: didctl.sh prune [days]"
  CUTOFF="$(date -d "-$DAYS day" '+%Y%m%d' 2>/dev/null || date -v-"${DAYS}"d '+%Y%m%d' 2>/dev/null)"
  [[ -n "$CUTOFF" ]] || die "could not compute a cutoff date"

  # Enumerate the day families actually present rather than guessing dates —
  # a box that was off for a month still gets cleaned up correctly.
  DAYS_PRESENT="$(db_show "sbc/didcnt" | awk -F'\t' '{n=split($1,p,"/"); print p[n-1]}' | sort -u)"
  [[ -n "$DAYS_PRESENT" ]] || { echo "  nothing stored"; exit 0; }

  n=0
  for d in $DAYS_PRESENT; do
    [[ "$d" =~ ^[0-9]{8}$ ]] || continue
    # Never today, whatever the arithmetic says.
    [[ "$d" == "$TODAY" ]] && continue
    if [[ "$d" < "$CUTOFF" ]]; then
      "$AST" -rx "database deltree sbc/didcnt/$d" >/dev/null 2>&1
      echo "  dropped sbc/didcnt/$d"
      n=$((n + 1))
    fi
  done
  echo "  pruned $n day(s) older than $CUTOFF; kept $DAYS day(s) of history"
  ;;

# ---------------------------------------------------------------------------
set)
  need_ast
  DID="$(printf '%s' "${2:-}" | tr -cd '0-9')"
  VAL="${3:-}"
  [[ -n "$DID" && "$VAL" =~ ^[0-9]+$ ]] || die "usage: didctl.sh set <did> <count> --force"
  (( ${#DID} == 10 )) && DID="1$DID"
  [[ "${4:-}" == "--force" || "${SBC_FORCE:-}" == "1" ]] || die \
"refusing without --force.

       This overwrites what the SBC believes it has already sent on $DID
       today. Raising it takes the number out of rotation; lowering it puts
       it back and lets it exceed its real daily volume.

       didctl.sh set $DID $VAL --force"
  "$AST" -rx "database put sbc/didcnt/$TODAY $DID $VAL" >/dev/null 2>&1 \
    || die "database put failed"
  echo "  sbc/didcnt/$TODAY/$DID = $VAL  (cap $DID_DAILY_CAP)"
  ;;

# ---------------------------------------------------------------------------
reset)
  need_ast
  TARGET="${2:-}"
  [[ -n "$TARGET" ]] || die "usage: didctl.sh reset <did>|--all --force"
  [[ "${3:-}" == "--force" || "${SBC_FORCE:-}" == "1" ]] || die \
"refusing without --force.

       Zeroing today's counters lets every affected number carry another full
       ${DID_DAILY_CAP} calls today, on top of what it has already sent. That is
       exactly the concentration the cap exists to prevent, so it is a
       deliberate act and not a convenience.

       didctl.sh reset $TARGET --force"

  if [[ "$TARGET" == "--all" ]]; then
    "$AST" -rx "database deltree sbc/didcnt/$TODAY" >/dev/null 2>&1
    echo "  cleared every counter for $TODAY"
  else
    DID="$(printf '%s' "$TARGET" | tr -cd '0-9')"
    (( ${#DID} == 10 )) && DID="1$DID"
    "$AST" -rx "database del sbc/didcnt/$TODAY $DID" >/dev/null 2>&1
    echo "  cleared sbc/didcnt/$TODAY/$DID"
  fi
  ;;

# ---------------------------------------------------------------------------
*)
  sed -n '2,30p' "$0"
  exit 2
  ;;
esac
