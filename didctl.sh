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
#   ./didctl.sh sync-globals        push rendered [globals] into the RUNNING
#                                   dialplan. REQUIRED after every render on a
#                                   live box - see the note in that section.
#   ./didctl.sh prune [days]        drop counter keys older than <days> (7)
#   ./didctl.sh set <did> <n>       force a count. TEST TOOL — see below.
#   ./didctl.sh reset <did>|--all   zero today's counts. Needs --force.
#
#   ./didctl.sh transfers list      learned transfer destinations, counts, ACD
#   ./didctl.sh transfers add <n>   pin a destination as a transfer leg
#   ./didctl.sh transfers remove <n>   unpin AND suppress re-learning
#   ./didctl.sh transfers stats     transfer legs vs prospect dials, last 24h
#   ./didctl.sh transfers reset     forget everything learned. Needs --force.
#
# TRANSFER STATE lives under
#
#     sbc/xfer/<customer endpoint>/<destination>
#
# as <flag>:<answered>:<billsec>:<lastseen>, one key per destination so
# detection in the call path costs a single read.
#
#   L  learning or learned — flagged once answered >= TRANSFER_MIN_CALLS and
#      billsec/answered > TRANSFER_MIN_ACD
#   P  pinned by `transfers add` — always a transfer leg
#   S  suppressed by `transfers remove` — never one, and never re-learned
#
# Per endpoint, not global: two customers dialling the same number are not
# evidence about each other.
#
# Unlike the DID counters these are NOT date-keyed and do NOT reset at
# midnight — the whole point is that a buyer line stays recognised. They are
# expired by inactivity instead (`prune`), and only flag L is ever expired.
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

# shellcheck source=lib/pk-clients.sh
[[ -r "$HERE/lib/pk-clients.sh" ]] && . "$HERE/lib/pk-clients.sh"

DID_DAILY_CAP="${DID_DAILY_CAP:-200}"
CDR_CSV_PATH="${CDR_CSV_PATH:-/var/log/asterisk/cdr-custom/sbc.csv}"
TRANSFER_MIN_CALLS="${TRANSFER_MIN_CALLS:-3}"
TRANSFER_MIN_ACD="${TRANSFER_MIN_ACD:-60}"
TRANSFER_EXPIRE_DAYS="${TRANSFER_EXPIRE_DAYS:-30}"
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

# Transfer state, emitted as "<endpoint> <dest> <flag> <answered> <billsec> <lastseen>".
xfer_rows() {
  db_show "sbc/xfer" | awk -F'\t' '{
    n=split($1,p,"/"); dest=p[n]; ep=p[n-1]
    split($2,v,":")
    if (dest=="" || v[1]=="") next
    print ep, dest, v[1], v[2]+0, v[3]+0, v[4]
  }'
}

# Customer endpoints, from the running config. A buyer number is a buyer
# number whichever customer IP reached it, so pin and suppress apply to all of
# them unless --ep narrows it.
xfer_endpoints() {
  local eps
  eps="$("$AST" -rx "pjsip show endpoints" 2>/dev/null | grep -oE 'pkclient[0-9]+' | sort -u)"
  [[ -n "$eps" ]] && { echo "$eps"; return; }
  # Asterisk is not answering. Fall back to what config.env says should exist
  # rather than to a hardcoded pair, or a pin/suppress applied while the box is
  # down silently misses the endpoints past the second one.
  if declare -F pk_client_endpoint_names >/dev/null; then
    pk_client_endpoint_names
  else
    echo "didctl.sh: cannot list customer endpoints — Asterisk is not answering" >&2
    echo "           and $HERE/lib/pk-clients.sh is missing." >&2
    return 1
  fi
}

# Is this row currently treated as a transfer destination?
xfer_active() { # xfer_active <flag> <answered> <billsec>
  case "$1" in
    P) echo yes; return ;;
    S) echo no;  return ;;
  esac
  awk -v n="$2" -v b="$3" -v mc="$TRANSFER_MIN_CALLS" -v ma="$TRANSFER_MIN_ACD" \
    'BEGIN{ print (n>=mc && n>0 && b/n>ma) ? "yes" : "no" }'
}

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
  # `dialplan show globals` INDENTS every line. An anchored ^SBC_ pattern
  # matches nothing and this silently reports zero pools on a box that has
  # them, which reads as "the pool failed to load" during a deploy. Strip the
  # leading whitespace first.
  "$AST" -rx "dialplan show globals" 2>/dev/null \
    | sed 's/^[[:space:]]*//' \
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
  CAP="$("$AST" -rx "dialplan show globals" 2>/dev/null \
         | sed 's/^[[:space:]]*//' | awk -F'=' '/^SBC_DID_CAP=/{print $2}')"
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

  # --- learned transfer destinations ---------------------------------------
  # Expired by INACTIVITY, not by date-keying: a buyer line has to stay
  # recognised across days or the first calls of every morning would go out
  # with a pool DID.
  #
  # Only flag L is expired. P (pinned) and S (suppressed) are deliberate
  # operator decisions and outliving a quiet month is exactly what they are
  # for — expiring an S would let the destination be re-learned, silently
  # undoing a `transfers remove`.
  XCUT="$(date -d "-$TRANSFER_EXPIRE_DAYS day" '+%Y%m%d' 2>/dev/null \
          || date -v-"${TRANSFER_EXPIRE_DAYS}"d '+%Y%m%d' 2>/dev/null)"
  if [[ -n "$XCUT" ]]; then
    x=0; kept=0
    while read -r ep dest flag n b seen; do
      [[ -n "$dest" ]] || continue
      if [[ "$flag" != "L" ]]; then kept=$((kept + 1)); continue; fi
      if [[ ! "$seen" =~ ^[0-9]{8}$ ]] || [[ "$seen" < "$XCUT" ]]; then
        "$AST" -rx "database del sbc/xfer/$ep $dest" >/dev/null 2>&1
        echo "  forgot   $ep/$dest (last seen ${seen:-never})"
        x=$((x + 1))
      fi
    done <<< "$(xfer_rows)"
    echo "  expired $x learned transfer destination(s) idle since before $XCUT; kept $kept pinned/suppressed"
  fi
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
sync-globals)
  need_ast
  AST_ETC="${AST_ETC:-/etc/asterisk}"
  CONF_FILE="$AST_ETC/extensions.conf"
  [[ -r "$CONF_FILE" ]] || die "cannot read $CONF_FILE"

  # WHY THIS EXISTS
  #
  # extensions.conf sets clearglobalvars=no, deliberately: it is what stops a
  # `dialplan reload` silently wiping the killswitch and quietly restoring
  # customer traffic while the operator believes the plug is pulled.
  #
  # The cost is that `dialplan reload` then does NOT apply the [globals]
  # section at all. It neither updates an existing global nor creates a new
  # one. Render a new dids.csv, reload, and Asterisk keeps serving the OLD
  # pool - with no error and no warning. The rendered file and the running
  # dialplan disagree, and the only visible symptom is that calls keep going
  # out on numbers you thought you had replaced.
  #
  # So: read [globals] out of the rendered file and set each changed value at
  # runtime, which is the same mechanism killswitch.sh uses. No restart, no
  # dropped calls. Run this after every render on a box carrying traffic.
  WANT="$(awk '/^\[globals\]/{f=1;next} /^\[/{f=0} f && /^[A-Za-z_][A-Za-z0-9_]*=/{print}' "$CONF_FILE")"
  [[ -n "$WANT" ]] || die "no [globals] block found in $CONF_FILE"

  # `asterisk -rx` will not carry an arbitrarily long command. Measured on
  # Asterisk 20: the whole command line survives to about 491 bytes and fails
  # somewhere before 506, and the failure mode is the worst available — the
  # CLI returns success and the global keeps its OLD value.
  #
  # SBC_DID_POOL_OVERFLOW is the one that hits this. At ~12 bytes per DID the
  # ceiling is roughly 38 overflow numbers; a 36-number pool produced a
  # 473-byte command and fit with two numbers to spare. Past that, the pool
  # can only be loaded by restarting Asterisk, which reads [globals] from the
  # file directly.
  #
  # This is called out separately because the counter global is short and
  # updates fine while the pool global silently does not: the dialplan then
  # believes it has 236 numbers to choose from and can only address 36, and
  # every selection past the 36th yields an EMPTY DID.
  CLI_LIMIT=490

  HAVE="$("$AST" -rx "dialplan show globals" 2>/dev/null | sed 's/^[[:space:]]*//')"
  changed=0; same=0; toolong=""
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    name="${line%%=*}"; val="${line#*=}"
    cur="$(grep -m1 "^${name}=" <<< "$HAVE" | cut -d= -f2-)"
    if [[ "$cur" != "$val" ]]; then
      cmd="dialplan set global ${name} ${val}"
      if (( ${#cmd} > CLI_LIMIT )); then
        toolong+="${toolong:+ }$name"
        [[ "${2:-}" == "--verbose" ]] && echo "  SKIP  $name (${#cmd} bytes, over the CLI limit)"
        continue
      fi
      "$AST" -rx "$cmd" >/dev/null 2>&1
      [[ "${2:-}" == "--verbose" ]] && echo "  set   $name"
      changed=$((changed + 1))
    else
      same=$((same + 1))
    fi
  done <<< "$WANT"

  # Read back. A silent failure here means the running dialplan is asserting
  # numbers that are not in dids.csv, which is worth failing loudly over.
  NOW="$("$AST" -rx "dialplan show globals" 2>/dev/null | sed 's/^[[:space:]]*//')"
  bad=0
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    name="${line%%=*}"; val="${line#*=}"
    [[ "$(grep -m1 "^${name}=" <<< "$NOW" | cut -d= -f2-)" == "$val" ]] || {
      echo "  ${R}MISMATCH${N} $name"; bad=$((bad + 1)); }
  done <<< "$WANT"

  echo "  updated $changed, already correct $same, mismatched $bad"
  if [[ -n "$toolong" ]]; then
    echo
    echo "  ${R}TOO LONG FOR THE CLI:${N} $toolong"
    echo
    echo "  These cannot be applied at runtime. 'dialplan set global' silently"
    echo "  keeps the old value once the command passes ~${CLI_LIMIT} bytes, so this is"
    echo "  reported rather than attempted — attempting it is what produces a"
    echo "  pool the dialplan half-believes in."
    echo
    echo "  Loading them needs a drain and a restart, which reads [globals]"
    echo "  straight out of $CONF_FILE:"
    echo
    echo "      sudo $HERE/killswitch.sh on      # refuse new calls"
    echo "      asterisk -rx 'core show channels'  # wait for zero"
    echo "      sudo systemctl restart asterisk"
    echo "      sudo $HERE/killswitch.sh off     # a restart clears the global"
    echo
    echo "  Until then the running dialplan is serving the OLD value."
  fi
  if (( bad )); then
    echo "  ${R}the running dialplan does not match $CONF_FILE${N}"
    exit 1
  fi
  echo "  ${G}running dialplan matches $CONF_FILE${N}"

  # clearglobalvars=no also means a global for a pool you DELETED from
  # dids.csv survives until a full restart. Nothing above can remove it.
  STALE="$(grep -oE '^SBC_DID_POOL_[0-9]{3}' <<< "$NOW" | sort -u)"
  FILE_POOLS="$(grep -oE '^SBC_DID_POOL_[0-9]{3}' <<< "$WANT" | sort -u)"
  ORPHAN="$(comm -13 <(echo "$FILE_POOLS") <(echo "$STALE"))"
  if [[ -n "$ORPHAN" ]]; then
    echo
    echo "  ${Y}STALE POOLS still in memory${N} - not in the rendered file:"
    sed 's/^SBC_DID_POOL_/    NPA /' <<< "$ORPHAN"
    echo "  These will keep being asserted until Asterisk fully restarts."
    echo "  Drain with killswitch.sh on, then restart, to clear them."
    exit 2
  fi
  ;;

# ---------------------------------------------------------------------------
transfers)
  need_ast
  case "${2:-list}" in

  list)
    ROWS="$(xfer_rows)"
    echo
    echo "  ${B}transfer destinations${N}   flagged at >=${TRANSFER_MIN_CALLS} answered AND ACD >${TRANSFER_MIN_ACD}s"
    echo
    if [[ -z "$ROWS" ]]; then
      echo "  ${D}nothing tracked yet${N}"
      echo
      echo "  ${D}A destination is only tracked once it has produced one answered${N}"
      echo "  ${D}call longer than ${TRANSFER_MIN_ACD}s. Toll-free destinations are detected${N}"
      echo "  ${D}statelessly by rule 1 and never appear here.${N}"
      echo
      exit 0
    fi
    printf '    %-11s %-13s %-4s %8s %9s %7s %-9s %s\n' \
           endpoint destination flag answered billsec acd lastseen active
    while read -r ep dest flag n b seen; do
      [[ -n "$dest" ]] || continue
      acd=$(awk -v n="$n" -v b="$b" 'BEGIN{printf "%d", (n>0? b/n : 0)}')
      act="$(xfer_active "$flag" "$n" "$b")"
      col="$N"; [[ "$act" == "yes" ]] && col="$G"
      [[ "$flag" == "S" ]] && col="$D"
      printf '    %s%-11s %-13s %-4s %8s %9s %7s %-9s %s%s\n' \
             "$col" "$ep" "$dest" "$flag" "$n" "$b" "$acd" "$seen" "$act" "$N"
    done <<< "$ROWS"
    echo
    echo "    ${D}L learning/learned   P pinned by hand   S suppressed by hand${N}"
    echo
    ;;

  add)
    DEST="$(printf '%s' "${3:-}" | tr -cd '0-9')"
    [[ -n "$DEST" ]] || die "usage: didctl.sh transfers add <number> [--ep <endpoint>]"
    (( ${#DEST} == 10 )) && DEST="1$DEST"
    EPS="$(xfer_endpoints)"
    if [[ "${4:-}" == "--ep" && -n "${5:-}" ]]; then EPS="$5"; fi
    for ep in $EPS; do
      "$AST" -rx "database put sbc/xfer/$ep $DEST P:0:0:$TODAY" >/dev/null 2>&1 \
        || die "database put failed for $ep"
      echo "  pinned   $ep/$DEST"
    done
    echo
    echo "  ${D}Calls to $DEST now pass the customer's caller ID through${N}"
    echo "  ${D}unchanged and consume no DID. Pinned entries never expire.${N}"
    ;;

  remove)
    DEST="$(printf '%s' "${3:-}" | tr -cd '0-9')"
    [[ -n "$DEST" ]] || die "usage: didctl.sh transfers remove <number> [--ep <endpoint>]"
    (( ${#DEST} == 10 )) && DEST="1$DEST"
    EPS="$(xfer_endpoints)"
    if [[ "${4:-}" == "--ep" && -n "${5:-}" ]]; then EPS="$5"; fi
    for ep in $EPS; do
      # Suppress rather than delete. A plain delete would let the next three
      # answered calls re-learn the destination and silently undo this.
      "$AST" -rx "database put sbc/xfer/$ep $DEST S:0:0:$TODAY" >/dev/null 2>&1 \
        || die "database put failed for $ep"
      echo "  suppressed   $ep/$DEST"
    done
    echo
    echo "  ${D}Calls to $DEST get the full caller ID rewrite again, and the${N}"
    echo "  ${D}destination will NOT be re-learned. Suppression never expires;${N}"
    echo "  ${D}clear it with: asterisk -rx \"database del sbc/xfer/<ep> $DEST\"${N}"
    ;;

  stats)
    HRS="${3:-24}"
    [[ -r "$CDR_CSV_PATH" ]] || die "cannot read $CDR_CSV_PATH"
    CUT_TS="$(date -d "-$HRS hour" '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
              || date -v-"${HRS}"H '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
    echo
    echo "  ${B}transfer legs vs prospect dials${N}   last ${HRS}h   ${D}from $CDR_CSV_PATH${N}"
    echo
    tail -n 200000 "$CDR_CSV_PATH" 2>/dev/null | awk -v cutoff="$CUT_TS" "$CSVSPLIT"'
      { n=csvsplit($0,f); if (n<19) next
        if (cutoff!="" && f[1] < cutoff) next
        r=f[17]
        if (r=="")                        cls="(refused before selection)"
        else if (r ~ /^transfer_leg_/)  { cls=r; xfer++ }
        else                            { cls=r; pros++ }
        c[cls]++; t++
        if (f[10]=="ANSWERED") { ans[cls]++; bs[cls]+=f[9]+0 }
      }
      END {
        if (t==0) { print "    no rows in window"; exit }
        for (k in c)
          printf "    %-28s %7d  %5.1f%%   answered %6d   acd %5.0fs\n",
                 k, c[k], 100*c[k]/t, ans[k]+0, (ans[k]>0 ? bs[k]/ans[k] : 0)
        printf "\n    %-28s %7d  %5.1f%%\n", "TRANSFER LEGS", xfer+0, 100*(xfer+0)/t
        printf "    %-28s %7d  %5.1f%%\n",   "prospect dials", pros+0, 100*(pros+0)/t
        printf "    %-28s %7d\n",            "total rows", t
      }' | sort
    echo
    echo "  ${D}A transfer-leg share far above a few tenths of a percent means${N}"
    echo "  ${D}rule 2 is over-firing: prospect dials are keeping the customer's${N}"
    echo "  ${D}caller ID instead of ours. Check 'transfers list'.${N}"
    echo
    ;;

  reset)
    [[ "${3:-}" == "--force" || "${SBC_FORCE:-}" == "1" ]] || die \
"refusing without --force.

       This forgets every learned transfer destination AND every manual pin
       and suppression. Buyer lines then take ${TRANSFER_MIN_CALLS} answered calls each to
       re-learn, and during that window their transfers go out with a pool
       DID — the buyer sees a stranger.

       didctl.sh transfers reset --force"
    "$AST" -rx "database deltree sbc/xfer" >/dev/null 2>&1
    echo "  cleared all transfer state"
    ;;

  *)
    echo "usage: didctl.sh transfers list|add <n>|remove <n>|stats [hours]|reset" >&2
    exit 2
    ;;
  esac
  ;;

# ---------------------------------------------------------------------------
*)
  sed -n '2,30p' "$0"
  exit 2
  ;;
esac
