#!/usr/bin/env bash
#
# verify-deployment.sh — prove what is running on the SBC matches a commit.
#
#   ./verify-deployment.sh                     on the box: check /opt/sbc
#   ./verify-deployment.sh --remote root@HOST   from a workstation, over ssh
#   ./verify-deployment.sh --repo               from a checkout: does the
#                                               recorded commit still hash the
#                                               way DEPLOYED_COMMIT claims?
#   ./verify-deployment.sh --write <sha>        regenerate DEPLOYED_COMMIT
#        --write prints the stamp on stdout; redirect it into the file.
#        Add --remote root@HOST to hash the box's rendered config from a
#        workstation, or run it on the box. Without either, the rendered
#        outputs record as UNREADABLE and the stamp proves only templates.
#
# READ-ONLY in every mode except --write. Run it before touching that box.
#
# WHY THIS EXISTS
# ---------------
# The SBC is deployed by scp, deliberately: a git checkout on a production
# border element means credentials and a .git directory on the one host that
# terminates customer traffic, and that is a worse trade than manual file copy.
#
# The cost of that choice is provenance. Three files copied by hand correspond
# to no commit unless something writes down which one, and the failure mode is
# silent and expensive: the next deploy from a clean checkout of a DIFFERENT
# branch reverts Phase 0 — the ring-aware failover split — and nothing anywhere
# reports that it happened. Calls start walking the gateway ring again and the
# only symptom is a slow rise in INVITE volume toward the carrier.
#
# So DEPLOYED_COMMIT is the record and this script is the check. It is not a
# substitute for version control; it is the smallest thing that makes "what is
# on the box" answerable without putting a repo there.
#
# It hashes TWO things, and the second one is the point. The templates in
# /opt/sbc are render.sh's inputs and come out of git. The configs in
# /etc/asterisk are its outputs, exist in no commit, and are the files that
# actually terminate calls. Hashing only the inputs is how a box passes this
# check with a hand-edited pjsip.conf.
#
# EXIT CODES
#   0  everything matches
#   1  drift: a file on the box differs from what DEPLOYED_COMMIT records
#   2  cannot check (missing file, unreadable host, bad arguments)

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SBC_DIR="${SBC_DIR:-/opt/sbc}"
ASTERISK_DIR="${ASTERISK_DIR:-/etc/asterisk}"
STAMP="${STAMP:-$SBC_DIR/DEPLOYED_COMMIT}"
MODE="local"
REMOTE=""
WRITE_SHA=""

# The files that are actually deployed by hand. Adding one here without adding
# it to the deploy is how this check starts lying, so keep the two together.
TRACKED=(render.sh asterisk/extensions.conf.tpl didctl.sh)

# The files Asterisk actually reads. TRACKED covers the INPUTS to render.sh --
# hashing only those leaves the outputs unverified, and the outputs are what
# terminates calls. A hand-edit to /etc/asterisk/pjsip.conf survives every
# check in this script if the templates are the only thing hashed, which is
# how "three tracked files" got mistaken for a verified deployment.
#
# These are outputs, so they are NOT in git and --repo cannot check them.
# They are hashed as-deployed and compared against the box.
RENDERED=(cdr.conf cdr_custom.conf extensions.conf http.conf logger.conf
          manager.conf modules.conf pjsip.conf rtp.conf)

B=$'\033[1m'; R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; D=$'\033[2m'; N=$'\033[0m'
[[ -t 1 ]] || { B=""; R=""; G=""; Y=""; D=""; N=""; }

die()  { echo "verify-deployment.sh: ERROR: $*" >&2; exit 2; }
info() { echo "  $*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    # --remote sets the host; it only claims the mode if nothing else has.
    # "--write <sha> --remote HOST" is the supported way to stamp a box's
    # rendered config from a workstation, and it has to stay in write mode.
    --remote) REMOTE="$2"; [[ "$MODE" == "local" ]] && MODE="remote"; shift 2 ;;
    --repo)   MODE="repo"; shift ;;
    --write)  MODE="write"; WRITE_SHA="$2"; shift 2 ;;
    --stamp)  STAMP="$2"; shift 2 ;;
    --dir)    SBC_DIR="$2"; shift 2 ;;
    --asterisk-dir) ASTERISK_DIR="$2"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) die "unknown argument '$1'" ;;
  esac
done

sha_of() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }

# Hash an ABSOLUTE path, on the box or over ssh. -n is load-bearing for the
# same reason it is in read_stamp: this gets called inside read loops, and an
# ssh without it eats the remaining lines from stdin.
abs_sha() {
  if [[ -n "$REMOTE" ]]; then
    ssh -n -o BatchMode=yes -o ConnectTimeout=10 "$REMOTE" \
      "sha256sum '$1' 2>/dev/null | cut -d' ' -f1" 2>/dev/null
  else
    sha_of "$1"
  fi
}

# ---------------------------------------------------------------------------
# --write : regenerate the stamp from a commit in this checkout
# ---------------------------------------------------------------------------
if [[ "$MODE" == "write" ]]; then
  command -v git >/dev/null || die "--write needs git"
  git -C "$HERE" rev-parse --verify "$WRITE_SHA^{commit}" >/dev/null 2>&1 \
    || die "'$WRITE_SHA' is not a commit in this repo"
  FULL="$(git -C "$HERE" rev-parse "$WRITE_SHA^{commit}")"
  DIRTY=""
  [[ -n "$(git -C "$HERE" status --porcelain)" ]] && DIRTY=" (WORKING TREE DIRTY AT WRITE TIME)"
  RENDER_GAPS=0

  {
    echo "# /opt/sbc provenance. Generated by verify-deployment.sh --write."
    echo "# Check with: ./verify-deployment.sh   (read-only)"
    echo "#"
    echo "# The box is deployed by scp, not by checkout: no .git and no"
    echo "# credentials on a production border element. This file is what makes"
    echo "# 'which commit is running' answerable anyway."
    echo "commit=$FULL$DIRTY"
    echo "deployed_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "deployed_by=verify-deployment.sh --write"
    echo "host=${DEPLOY_HOST:-167.235.206.206}"
    echo "#"
    echo "# file sha256 (as deployed) -- render.sh INPUTS, hashed out of git"
    for f in "${TRACKED[@]}"; do
      printf 'file=%s %s\n' "$f" "$(git -C "$HERE" show "$FULL:$f" | sha256sum | cut -d' ' -f1)"
    done
    echo "#"
    echo "# rendered sha256 -- what Asterisk actually reads, hashed off the"
    echo "# filesystem because these are OUTPUTS and are not in any commit."
    echo "# A mismatch here means the live config no longer matches what was"
    echo "# deployed: either someone hand-edited /etc/asterisk, or render.sh"
    echo "# was re-run (didctl sync, a config.env change) without re-stamping."
    echo "# Both are worth stopping for; the second is fixed by --write again."
    for f in "${RENDERED[@]}"; do
      rs="$(abs_sha "$ASTERISK_DIR/$f")"
      printf 'rendered=%s %s\n' "$f" "${rs:-UNREADABLE}"
      [[ -n "$rs" ]] || RENDER_GAPS=$((RENDER_GAPS + 1))
    done
    echo "#"
    echo "# --- STATE OF THIS DEPLOY -------------------------------------------"
    echo "# LIVE: Phase 0 (ring-aware CHANUNAVAIL split, MAX_ROUTE_ATTEMPTS=2),"
    echo "#       DID pool reallocation (70 moves), 3 suppressed incumbents."
    echo "# NOT LIVE: Phase 1 in any form."
    echo "#"
    echo "# UNEXECUTED ACCEPTANCE CRITERIA: 24, 25, 26"
    echo "#   These cover the Phase 0 failover split and have NEVER been run --"
    echo "#   there has been no Asterisk+SIPp box to run them on. Phase 0 is live"
    echo "#   and carries real calls the moment the trunk returns, so running"
    echo "#   them is the FIRST thing the lab box does: before VERIFY item V3"
    echo "#   and before any Phase 1 work. V3 only gates code that has not"
    echo "#   shipped; criteria 24-26 gate code that has."
    echo "unexecuted_criteria=24,25,26"
  }
  # stderr, not stdout: the stamp itself goes to stdout and the caller
  # redirects it into DEPLOYED_COMMIT. Echoing this on stdout appends it to
  # the file -- the stamp currently on the box ends with exactly this line.
  echo "  wrote stamp for $FULL$DIRTY" >&2
  if (( RENDER_GAPS )); then
    echo "  WARNING: $RENDER_GAPS of ${#RENDERED[@]} rendered file(s) under $ASTERISK_DIR" >&2
    echo "  were unreadable and are recorded as UNREADABLE. The stamp cannot" >&2
    echo "  prove what Asterisk is reading. Run --write on the box, or add" >&2
    echo "  --remote root@HOST so the rendered outputs are hashed there." >&2
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# Read the stamp (locally, or off the box)
# ---------------------------------------------------------------------------
read_stamp() {
  case "$MODE" in
    # -n is load-bearing: without it ssh reads from stdin, and when this is
    # called inside the read loop below it swallows the remaining lines. The
    # check then passes having verified only the first file, which is exactly
    # the silent pass this whole script exists to prevent.
    remote) ssh -n -o BatchMode=yes -o ConnectTimeout=10 "$REMOTE" "cat '$STAMP'" 2>/dev/null ;;
    *)      cat "$STAMP" 2>/dev/null ;;
  esac
}

STAMP_TXT="$(read_stamp)"
[[ -n "$STAMP_TXT" ]] || die "cannot read $STAMP${REMOTE:+ on $REMOTE}
       The box has no provenance record. Do NOT deploy over it blind:
       regenerate one with --write against the commit you believe is running,
       and confirm the hashes match before trusting it."

COMMIT="$(sed -n 's/^commit=//p' <<< "$STAMP_TXT" | head -1)"
WHEN="$(sed -n 's/^deployed_at=//p' <<< "$STAMP_TXT" | head -1)"
UNEXEC="$(sed -n 's/^unexecuted_criteria=//p' <<< "$STAMP_TXT" | head -1)"

echo
echo "${B}deployment check${N}   ${REMOTE:-$SBC_DIR}"
echo "  commit      ${COMMIT:-<none recorded>}"
echo "  deployed    ${WHEN:-<unknown>}"
echo

# ---------------------------------------------------------------------------
# --repo : does this checkout still produce the hashes the stamp claims?
# Catches a rewritten branch or a tag moved out from under the record.
# ---------------------------------------------------------------------------
if [[ "$MODE" == "repo" ]]; then
  command -v git >/dev/null || die "--repo needs git"
  git -C "$HERE" rev-parse --verify "${COMMIT%% *}^{commit}" >/dev/null 2>&1 \
    || die "commit ${COMMIT%% *} is not in this repo. The box is running something
       this checkout cannot account for."
  bad=0
  while read -r f want; do
    got="$(git -C "$HERE" show "${COMMIT%% *}:$f" 2>/dev/null | sha256sum | cut -d' ' -f1)"
    if [[ "$got" == "$want" ]]; then
      printf '  %sOK%s    %-32s %s\n' "$G" "$N" "$f" "${want:0:12}"
    else
      printf '  %sDRIFT%s %-32s repo=%s stamp=%s\n' "$R" "$N" "$f" "${got:0:12}" "${want:0:12}"
      bad=1
    fi
  done < <(sed -n 's/^file=//p' <<< "$STAMP_TXT")
  echo
  if grep -q '^rendered=' <<< "$STAMP_TXT"; then
    echo "  ${D}rendered outputs are not checked here: they are render.sh's${N}"
    echo "  ${D}products, not commit content. Use the local or --remote mode${N}"
    echo "  ${D}against the box to verify those.${N}"
    echo
  fi
  (( bad )) && { echo "  ${R}The recorded commit no longer hashes as recorded.${N}"; exit 1; }
  echo "  ${G}Repo agrees with the stamp.${N}"
  exit 0
fi

# ---------------------------------------------------------------------------
# local / remote : hash what is actually on the box
# ---------------------------------------------------------------------------
box_sha() { abs_sha "$SBC_DIR/$1"; }

bad=0; missing=0
while read -r f want; do
  got="$(box_sha "$f")"
  if [[ -z "$got" ]]; then
    printf '  %sMISSING%s %-30s not present on the box\n' "$R" "$N" "$f"
    missing=1; bad=1
  elif [[ "$got" == "$want" ]]; then
    printf '  %sOK%s      %-30s %s\n' "$G" "$N" "$f" "${want:0:12}"
  else
    printf '  %sDRIFT%s   %-30s box=%s stamp=%s\n' "$R" "$N" "$f" "${got:0:12}" "${want:0:12}"
    bad=1
  fi
done < <(sed -n 's/^file=//p' <<< "$STAMP_TXT")

# --- the rendered outputs -------------------------------------------------
# Hashing the templates proves what render.sh was given. It says nothing about
# what Asterisk is reading, and that is the file that terminates calls.
rendered_lines="$(sed -n 's/^rendered=//p' <<< "$STAMP_TXT")"
if [[ -z "$rendered_lines" ]]; then
  echo
  echo "  ${Y}This stamp predates rendered-output hashing.${N}"
  echo "  ${D}It covers the templates only, so a hand-edit to anything under${N}"
  echo "  ${D}$ASTERISK_DIR is invisible to this check. Re-stamp with --write.${N}"
  unstamped=1
else
  echo
  echo "  ${B}rendered${N}   $ASTERISK_DIR"
  while read -r f want; do
    [[ -n "$f" ]] || continue
    if [[ "$want" == "UNREADABLE" ]]; then
      printf '  %sUNKNOWN%s %-30s not hashed at deploy time\n' "$Y" "$N" "$f"
      continue
    fi
    got="$(abs_sha "$ASTERISK_DIR/$f")"
    if [[ -z "$got" ]]; then
      printf '  %sMISSING%s %-30s Asterisk config absent\n' "$R" "$N" "$f"
      missing=1; bad=1
    elif [[ "$got" == "$want" ]]; then
      printf '  %sOK%s      %-30s %s\n' "$G" "$N" "$f" "${want:0:12}"
    else
      printf '  %sDRIFT%s   %-30s live=%s stamp=%s\n' "$R" "$N" "$f" "${got:0:12}" "${want:0:12}"
      bad=1
    fi
  done <<< "$rendered_lines"
fi

echo
if [[ -n "$UNEXEC" ]]; then
  echo "  ${Y}Acceptance criteria never executed against this build: $UNEXEC${N}"
  echo "  ${D}Run these before anything else on the lab box. They gate code that${N}"
  echo "  ${D}is already carrying calls, which outranks gating code that is not.${N}"
  echo
fi

if (( bad )); then
  echo "  ${R}${B}DRIFT.${N} The box is not running the recorded commit."
  echo "  Reconcile before deploying: a deploy from a clean checkout will"
  echo "  silently revert whatever the box has that the commit does not."
  echo
  echo "  ${D}A file= drift is a template that does not match the commit.${N}"
  echo "  ${D}A rendered= drift is narrower: the templates may be right and${N}"
  echo "  ${D}the live config still wrong. Either someone edited $ASTERISK_DIR${N}"
  echo "  ${D}by hand, or render.sh was re-run without re-stamping. Diff the${N}"
  echo "  ${D}file before assuming the second -- that is the assumption that${N}"
  echo "  ${D}lets a hand-edit survive.${N}"
  exit 1
fi

if [[ -n "${unstamped:-}" ]]; then
  echo "  ${Y}${B}Partial match.${N} Templates match ${COMMIT%% *}; the live"
  echo "  Asterisk config was never hashed and is unverified."
  exit 0
fi

echo "  ${G}${B}Match.${N} The box is running ${COMMIT%% *},"
echo "  and every rendered file under $ASTERISK_DIR is what was deployed."
exit 0
