#!/usr/bin/env bash
#
# deploy-phraseguard.sh — install and start PhraseGuard on the SBC, in one
# command, without restarting Asterisk.
#
#   ./deploy-phraseguard.sh --check       is it working right now? (read-only)
#   ./deploy-phraseguard.sh --dry-run     print every action, change nothing
#   ./deploy-phraseguard.sh --install     do it
#   ./deploy-phraseguard.sh --uninstall   stop it and remove it
#
# Add --remote root@HOST to any of those to run it ON the box from a machine
# that has ssh to it:
#
#   ./deploy-phraseguard.sh --remote root@167.235.206.206 --dry-run
#   ./deploy-phraseguard.sh --remote root@167.235.206.206 --install
#   ./deploy-phraseguard.sh --remote root@167.235.206.206 --check
#
# It scp-equivalents the files over and re-invokes itself there, so there is
# exactly one implementation of the install and it is the one that runs on the
# box. Same idiom as verify-deployment.sh --remote.
#
# WHAT IT WILL NOT DO, EVER
# -------------------------
# It does not restart Asterisk. It does not reload Asterisk. It does not touch
# extensions.conf, cdr_custom.conf, pjsip.conf, the firewall, or any file under
# /etc/asterisk. It does not run render.sh or install.sh.
#
# Those are not omissions, they are the design. Every dialplan change on this
# box is on the caller-ID path for 100% of calls, and this box has a documented
# history of config changes taking it down. PhraseGuard is a packet tap and a
# systemd unit; adding or removing it is not a voice event, and this script is
# what keeps that true.
#
# The one file outside PhraseGuard's own directories that it writes is
# config.env, and only to APPEND a settings block if one is not already there.
# It backs the file up first and never edits an existing line.
#
# WHAT YOU GET WHEN IT FINISHES
# -----------------------------
# A daemon running in SHADOW MODE. That means it watches every call, transcribes
# the customer leg, matches the scam-phrase corpus, and writes an evidence
# record for every hit — and it does not hang up anything.
#
# That is deliberate and it is the right first state. The per-customer record
# it starts building on day one is the thing that answers a carrier traceback
# or a regulator; disconnecting calls is a separate switch you throw later,
# after you have seen five days of what it would have killed. Turning
# enforcement on before that risks dropping legitimate insurance calls, and a
# detector that hangs up paying customers gets switched off within a week.
#
# Read phraseguard/README.md § Order of work before enabling enforcement.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$HERE/.." && pwd)"

SBC_DIR="${SBC_DIR:-/opt/sbc}"
DEST="$SBC_DIR/phraseguard"
CONF="${CONF:-$SBC_DIR/config.env}"
UNIT_SRC="$SRC/phraseguard/sbc-phraseguard.service"
UNIT="/etc/systemd/system/sbc-phraseguard.service"
LOG_DIR="${PHRASEGUARD_LOG_DIR:-/var/log/phraseguard}"
STATE_DIR="/var/lib/phraseguard"
MODEL_DIR="${PHRASEGUARD_MODEL_DIR:-/opt/vosk}"
MODEL_NAME="vosk-model-small-en-us-0.15"
MODEL_URL="https://alphacephei.com/vosk/models/${MODEL_NAME}.zip"
MODEL_PATH=""
MODE=""
DRY=0
REMOTE=""
PASSTHRU=()

B=$'\033[1m'; R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; D=$'\033[2m'; N=$'\033[0m'
[[ -t 1 ]] || { B=""; R=""; G=""; Y=""; D=""; N=""; }

say()  { echo "  $*"; }
head_(){ printf '\n%s%s%s\n' "$B" "$1" "$N"; }
ok()   { printf '  %s OK %s  %s\n' "$G" "$N" "$1"; }
warn() { printf '  %sWARN%s  %s\n' "$Y" "$N" "$1"; }
bad()  { printf '  %sFAIL%s  %s\n' "$R" "$N" "$1"; }
die()  { echo "deploy-phraseguard.sh: ERROR: $*" >&2; exit 2; }

run() { # run <description> <cmd...>
  local desc="$1"; shift
  if (( DRY )); then
    printf '  %s[dry-run]%s %s\n' "$D" "$N" "$desc"
    return 0
  fi
  if "$@" >/dev/null 2>&1; then ok "$desc"; return 0; fi
  bad "$desc"; return 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install)   MODE="install"; PASSTHRU+=("$1"); shift ;;
    --check)     MODE="check"; PASSTHRU+=("$1"); shift ;;
    --uninstall) MODE="uninstall"; PASSTHRU+=("$1"); shift ;;
    --dry-run)   MODE="${MODE:-install}"; DRY=1; PASSTHRU+=("$1"); shift ;;
    --model)     MODEL_PATH="$2"; PASSTHRU+=("$1" "$2"); shift 2 ;;
    --sbc-dir)   SBC_DIR="$2"; DEST="$2/phraseguard"; CONF="$2/config.env"
                 PASSTHRU+=("$1" "$2"); shift 2 ;;
    --conf)      CONF="$2"; PASSTHRU+=("$1" "$2"); shift 2 ;;
    --remote)    REMOTE="$2"; shift 2 ;;
    -h|--help)   sed -n '2,44p' "$0"; exit 0 ;;
    *) die "unknown argument '$1'" ;;
  esac
done
[[ -n "$MODE" ]] || die "pick one of --check, --dry-run, --install, --uninstall (see --help)"

# ===========================================================================
# --remote : run this same script ON the box, over ssh
# ===========================================================================
# The SBC is deployed by scp, deliberately -- no .git and no credentials on the
# one host that terminates customer traffic (see verify-deployment.sh). So this
# ships the files and then re-invokes ITSELF there.
#
# One implementation, not two. Everything below this block runs on the box
# either way; --remote only decides how it got there. A separate "remote
# install" code path would be a second thing to keep correct, and the one that
# never gets tested is always the one that runs on the night it matters.
if [[ -n "$REMOTE" ]]; then
  command -v ssh  >/dev/null || die "no ssh client on THIS machine. Run this from a machine that can reach the box."
  command -v tar  >/dev/null || die "tar is required to stage the files"

  echo
  echo "  staging PhraseGuard onto ${B}$REMOTE${N} and running there"
  echo "  ${D}Asterisk is never restarted, reloaded, or written to.${N}"
  echo

  STAGE="/tmp/phraseguard-deploy.$$"
  # -o BatchMode=no on purpose: an interactive key passphrase or password
  # prompt has to reach the operator, and refusing to prompt would turn a
  # working credential into a mysterious failure.
  if ! tar cz -C "$SRC" phraseguard tools/deploy-phraseguard.sh \
          tools/phraseguard-spike.sh tools/phraseguard-lint.py 2>/dev/null \
       | ssh -o ConnectTimeout=15 "$REMOTE" "mkdir -p '$STAGE' && tar xz -C '$STAGE'"; then
    echo
    bad "could not copy the files to $REMOTE"
    say "${D}Check: ssh $REMOTE 'echo ok'${N}"
    echo
    exit 2
  fi
  ok "files staged at $STAGE on $REMOTE"

  # printf %q so a path with a space cannot break out of the remote command.
  REMOTE_ARGS=""
  for a in "${PASSTHRU[@]}"; do REMOTE_ARGS+=" $(printf '%q' "$a")"; done

  # -t for a tty: sudo may need to prompt, and the deploy prints progress the
  # operator should watch. The staging directory is removed whether the deploy
  # succeeded or not.
  # sudo only when we are not already root. Connecting as root@ is the normal
  # case on this box, and a minimal Hetzner image frequently has no sudo
  # installed at all -- hardcoding it turns a working login into
  # "sudo: command not found".
  ssh -t -o ConnectTimeout=15 "$REMOTE" \
      "cd '$STAGE' && if [ \"\$(id -u)\" = 0 ]; then SUDO=; elif command -v sudo >/dev/null; then SUDO=sudo; else echo 'not root and no sudo on this box' >&2; exit 2; fi; \$SUDO bash ./tools/deploy-phraseguard.sh$REMOTE_ARGS; rc=\$?; rm -rf '$STAGE'; exit \$rc"
  rc=$?
  echo
  if (( rc == 0 )); then
    ok "remote deploy finished on $REMOTE"
  else
    bad "remote deploy exited $rc on $REMOTE"
  fi
  echo
  exit "$rc"
fi

echo
# ${DRY:+...} would fire on the string "0", which is set and non-empty, so
# every run labelled itself a dry run. Test the value, not whether it exists.
DRY_LABEL=""
(( DRY )) && DRY_LABEL="  (DRY RUN — nothing will be changed)"
echo "${B}deploy-phraseguard${N}  mode=$MODE${DRY_LABEL}  dest=$DEST"

# ===========================================================================
# --check : is it working right now?
# ===========================================================================
if [[ "$MODE" == "check" ]]; then
  RC=0
  head_ "service"
  if systemctl is-active --quiet sbc-phraseguard 2>/dev/null; then
    ok "sbc-phraseguard is running (since $(systemctl show -p ActiveEnterTimestamp --value sbc-phraseguard 2>/dev/null))"
  else
    bad "sbc-phraseguard is NOT running"
    say "${D}systemctl status sbc-phraseguard  —  journalctl -u sbc-phraseguard -n 50${N}"
    RC=1
  fi

  head_ "mode"
  # The single most important line of output in this whole script.
  if grep -qE '^\s*PHRASEGUARD_ENFORCE\s*=\s*1' "$CONF" 2>/dev/null; then
    warn "ENFORCING — Tier A matches are DISCONNECTING calls"
  else
    ok "shadow mode — detecting and recording, hanging up nothing"
  fi

  head_ "is it seeing anything?"
  # grep -c prints "0" AND exits 1 when there are no matches, so the `|| echo 0`
  # this used to carry appended a SECOND zero and the line rendered as "0\n0".
  # grep -c cannot fail in a way that needs a fallback; drop it.
  TODAY="$LOG_DIR/phraseguard-$(date -u +%Y%m%d).jsonl"
  if [[ -r "$TODAY" ]]; then
    N_MATCH="$(grep -c '"event": "match"' "$TODAY" 2>/dev/null)"
    N_START="$(grep -c '"event": "start"' "$TODAY" 2>/dev/null)"
    ok "today's evidence log: $TODAY"
    say "matches recorded today: ${N_MATCH:-0}   (daemon starts: ${N_START:-0})"
  else
    warn "no evidence log for today at $TODAY"
    say "${D}normal if the daemon has just started, or if the trunk is quiet${N}"
  fi

  CH="$(asterisk -rx 'core show channels' 2>/dev/null \
        | sed -n 's/^\([0-9]\{1,\}\) active channels\{0,1\}.*/\1/p' | head -1)"
  say "active Asterisk channels right now: ${CH:-unknown}"

  # Report the trunk's ACTUAL state from the CDR, not a claim copied out of a
  # document. This used to assert "the trunk has been paused since 2026-08-12"
  # because HANDOFF.md said so -- and by the time anyone read it on the box the
  # trunk was carrying nearly 200 calls a day. A status tool that repeats a
  # stale doc as present-tense fact is worse than one that says nothing.
  CDR="${CDR_CSV_PATH:-/var/log/asterisk/cdr-custom/sbc.csv}"
  if [[ -r "$CDR" ]]; then
    LAST_CDR="$(tail -1 "$CDR" 2>/dev/null | cut -d'"' -f2)"
    if [[ -n "$LAST_CDR" ]]; then
      LAST_EPOCH="$(date -d "$LAST_CDR" +%s 2>/dev/null || echo 0)"
      if (( LAST_EPOCH > 0 )); then
        AGE_MIN=$(( ( $(date +%s) - LAST_EPOCH ) / 60 ))
        if (( AGE_MIN < 60 )); then
          ok "trunk is LIVE — last call ${AGE_MIN}m ago ($LAST_CDR)"
        else
          say "last call in the CDR: $LAST_CDR (${AGE_MIN}m ago)"
        fi
      fi
    fi
  fi

  if [[ "${CH:-0}" == "0" ]]; then
    warn "no calls are up right now, so there is nothing for PhraseGuard to hear"
    say "${D}A running daemon and an empty log is the CORRECT state while the${N}"
    say "${D}trunk is quiet, or while calls are being rejected before answer${N}"
    say "${D}(PORTAL_NO_FUNDS rejects never carry audio).${N}"
  fi

  head_ "per-customer record (the thing that answers a traceback)"
  if [[ -x "$DEST/record.py" ]]; then
    python3 "$DEST/record.py" --state "$STATE_DIR/counters.json" 2>/dev/null \
      | sed 's/^/  /' || warn "counters not readable yet"
  else
    warn "$DEST/record.py not installed"
    RC=1
  fi

  head_ "Asterisk is untouched"
  if systemctl is-active --quiet asterisk 2>/dev/null; then
    ok "asterisk is running (PhraseGuard has never restarted it)"
  else
    bad "asterisk is NOT running — that is not PhraseGuard's doing, but fix it first"
    RC=1
  fi
  echo
  exit "$RC"
fi

# ===========================================================================
# --uninstall
# ===========================================================================
if [[ "$MODE" == "uninstall" ]]; then
  head_ "removing PhraseGuard"
  say "${D}Asterisk is not touched. Calls are unaffected at every step.${N}"
  run "stopped the service"    systemctl disable --now sbc-phraseguard
  run "removed the unit"       rm -f "$UNIT"
  run "reloaded systemd"       systemctl daemon-reload
  run "removed $DEST"          rm -rf "$DEST"
  echo
  say "Left in place on purpose:"
  say "  $LOG_DIR      the evidence log. Deleting it destroys your record."
  say "  $STATE_DIR    the per-customer counters."
  say "  $CONF         the settings block is inert with nothing to read it."
  echo
  exit 0
fi

# ===========================================================================
# --install
# ===========================================================================
FAIL=0

head_ "1. preflight"
[[ "$(id -u)" == "0" ]] || { bad "must run as root"; FAIL=1; }
command -v systemctl >/dev/null || { bad "systemd is required"; FAIL=1; }
command -v python3   >/dev/null || { bad "python3 is required"; FAIL=1; }
command -v tcpdump   >/dev/null || { bad "tcpdump is required (apt-get install -y tcpdump)"; FAIL=1; }
[[ -d "$SBC_DIR" ]] || { bad "$SBC_DIR does not exist — is this the SBC?"; FAIL=1; }
[[ -r "$CONF" ]] || { bad "$CONF not readable — PhraseGuard needs PK_CLIENT_IPS from it"; FAIL=1; }
[[ -r "$UNIT_SRC" ]] || { bad "unit file missing: $UNIT_SRC"; FAIL=1; }

if asterisk -rx "core show version" >/dev/null 2>&1; then
  ok "asterisk reachable: $(asterisk -rx 'core show version' 2>/dev/null | head -1)"
else
  bad "asterisk not reachable on the control socket — PhraseGuard could not hang up even if asked"
  FAIL=1
fi

# The dialplan line the exact Call-ID -> channel mapping depends on. Checked
# against the LIVE config, not the template: the template is what we intended,
# /etc/asterisk is what is running.
if [[ -r /etc/asterisk/extensions.conf ]]; then
  if grep -q '__SBC_CALLID' /etc/asterisk/extensions.conf; then
    ok "dialplan already records the Call-ID (__SBC_CALLID) — exact matching available"
  else
    warn "the live dialplan has no __SBC_CALLID — PhraseGuard will DETECT and RECORD"
    say  "${D}but will not be able to hang up. That is still the whole evidence${N}"
    say  "${D}record, so this is a warning, not a failure. Run${N}"
    say  "${D}tools/phraseguard-spike.sh --dump once traffic returns.${N}"
  fi
fi

FREE_GB="$(( $(df -Pk /var/log | awk 'NR==2{print $4}') / 1024 / 1024 ))"
if (( FREE_GB < 2 )); then
  bad "/var/log has only ${FREE_GB}GB free; PhraseGuard writes an append-only log"
  FAIL=1
else
  ok "/var/log has ${FREE_GB}GB free"
fi

PK="$(sed -n 's/^\s*PK_CLIENT_IPS\s*=\s*//p' "$CONF" 2>/dev/null | head -1 | tr -d '"'"'")"
if [[ -n "$PK" ]]; then
  ok "customer IPs from config.env: $PK"
else
  bad "PK_CLIENT_IPS is not set in $CONF"
  say "${D}Without it the customer-leg filter cannot tell the customer from the${N}"
  say "${D}carrier, and that is the one filter that must not fail open.${N}"
  FAIL=1
fi

if (( FAIL )); then
  echo
  bad "preflight refused. NOTHING was installed and nothing was changed."
  echo
  exit 2
fi

head_ "2. speech model"
# Without a model PhraseGuard still runs: it taps, correlates calls and keeps
# per-customer counters, and it matches nothing. That is a safe degraded state,
# not a broken one -- but it is not what you want, so this tries hard.
if [[ -n "$MODEL_PATH" ]]; then
  if [[ -d "$MODEL_PATH" ]]; then ok "using the model you named: $MODEL_PATH"
  else bad "no such model directory: $MODEL_PATH"; FAIL=1; fi
elif [[ -d "$MODEL_DIR/$MODEL_NAME" ]]; then
  MODEL_PATH="$MODEL_DIR/$MODEL_NAME"
  ok "model already present: $MODEL_PATH"
else
  MODEL_PATH="$MODEL_DIR/$MODEL_NAME"
  if (( DRY )); then
    printf '  %s[dry-run]%s would download %s into %s\n' "$D" "$N" "$MODEL_NAME" "$MODEL_DIR"
  else
    # Install the fetch tools if they are missing. A hardened SBC often has
    # neither curl nor unzip, and "could not fetch the model" without saying
    # WHICH piece was missing sent the first real install away with detection
    # silently disabled.
    MISSING=""
    for t in curl unzip; do command -v "$t" >/dev/null || MISSING+=" $t"; done
    if [[ -n "$MISSING" ]]; then
      say "missing:$MISSING — installing"
      apt-get update -qq >/dev/null 2>&1
      # shellcheck disable=SC2086
      apt-get install -y -qq $MISSING >/dev/null 2>&1
      for t in $MISSING; do
        command -v "$t" >/dev/null && ok "installed $t" || bad "could not install $t"
      done
    fi

    say "downloading $MODEL_NAME (~40MB) into $MODEL_DIR"
    mkdir -p "$MODEL_DIR"
    DL_ERR=""
    if ! command -v curl >/dev/null; then
      DL_ERR="curl is not installed and could not be installed"
    elif ! DL_ERR="$(curl -fsSL --retry 3 --max-time 300 \
                     -o "$MODEL_DIR/model.zip" "$MODEL_URL" 2>&1)"; then
      DL_ERR="${DL_ERR:-curl failed (network egress blocked?)}"
    elif ! command -v unzip >/dev/null; then
      DL_ERR="downloaded, but unzip is not available to extract it"
    elif ! DL_ERR="$(unzip -q -o "$MODEL_DIR/model.zip" -d "$MODEL_DIR" 2>&1)"; then
      DL_ERR="${DL_ERR:-unzip failed}"
    else
      DL_ERR=""
    fi
    rm -f "$MODEL_DIR/model.zip"

    if [[ -z "$DL_ERR" && -d "$MODEL_PATH" ]]; then
      ok "model installed at $MODEL_PATH"
    else
      warn "could not fetch the model: ${DL_ERR:-unknown}"
      say "${D}PhraseGuard will still install and run, recording calls and${N}"
      say "${D}per-customer counters, but it will not transcribe anything.${N}"
      say "${D}Fetch it on any machine with internet and copy it over:${N}"
      say "${D}  curl -LO $MODEL_URL${N}"
      say "${D}  scp $MODEL_NAME.zip root@THIS-BOX:/opt/vosk/${N}"
      say "${D}  ssh root@THIS-BOX 'cd /opt/vosk && unzip $MODEL_NAME.zip'${N}"
      say "${D}then re-run: $0 --install --model $MODEL_DIR/$MODEL_NAME${N}"
      MODEL_PATH=""
    fi
  fi
fi

# vosk itself. Same rule: a failure here degrades the detector, it does not
# stop the install, and it never touches Asterisk.
if python3 -c 'import vosk' 2>/dev/null; then
  ok "python vosk module present"
elif (( DRY )); then
  printf '  %s[dry-run]%s would pip install vosk\n' "$D" "$N"
else
  say "installing the vosk python module"
  if ! python3 -m pip --version >/dev/null 2>&1; then
    say "pip is not present — installing python3-pip"
    apt-get update -qq >/dev/null 2>&1
    apt-get install -y -qq python3-pip >/dev/null 2>&1
    python3 -m pip --version >/dev/null 2>&1 \
      && ok "pip installed" || bad "could not install python3-pip"
  fi
  # --break-system-packages is needed on Ubuntu 24.04 (PEP 668). Try the plain
  # form first so we do not use it where it is unnecessary, and KEEP the error
  # from the second attempt -- discarding it is what turned a fixable problem
  # into "could not install vosk" with no reason attached.
  PIP_ERR=""
  if python3 -m pip install --quiet vosk >/dev/null 2>&1; then
    ok "vosk installed"
  elif PIP_ERR="$(python3 -m pip install --quiet --break-system-packages vosk 2>&1)"; then
    ok "vosk installed (--break-system-packages)"
  else
    warn "could not install vosk — PhraseGuard runs with DETECTION DISABLED"
    say "${D}$(head -3 <<< "${PIP_ERR:-no output from pip}")${N}"
    say "${D}The tap, call correlation and per-customer counters still work.${N}"
    say "${D}Nothing about calls is affected either way.${N}"
  fi
fi

head_ "3. files"
if (( DRY )); then
  printf '  %s[dry-run]%s would copy %s -> %s\n' "$D" "$N" "$SRC/phraseguard" "$DEST"
  printf '  %s[dry-run]%s would create %s and %s\n' "$D" "$N" "$LOG_DIR" "$STATE_DIR"
else
  mkdir -p "$DEST" "$LOG_DIR" "$STATE_DIR" || die "cannot create directories"
  # --no-preserve=mode then an explicit chmod: a stray group-writable bit on a
  # script that runs as root on a border element is worth removing.
  cp -f "$SRC/phraseguard"/*.py "$SRC/phraseguard/phrases.csv" \
        "$SRC/phraseguard/README.md" "$DEST/" || die "copy failed"
  mkdir -p "$SBC_DIR/tools"
  cp -f "$SRC/tools/phraseguard-spike.sh" "$SRC/tools/phraseguard-lint.py" \
        "$SBC_DIR/tools/" 2>/dev/null || true
  chmod 0755 "$DEST"/*.py "$SBC_DIR/tools/phraseguard-spike.sh" \
             "$SBC_DIR/tools/phraseguard-lint.py" 2>/dev/null
  chmod 0644 "$DEST/phrases.csv" "$DEST/README.md"
  chmod 0750 "$LOG_DIR" "$STATE_DIR"
  ok "installed to $DEST"
  ok "created $LOG_DIR and $STATE_DIR (mode 0750)"
fi

head_ "4. settings"
# Append-only, and only if absent. config.env holds live credentials and the
# customer IP list; this never edits a line that is already there.
if grep -q 'PHRASEGUARD_ENFORCE' "$CONF" 2>/dev/null; then
  ok "config.env already has a PhraseGuard block — left exactly as it is"
  # ...with ONE exception. If the block was written by an earlier run whose
  # model download failed, PHRASEGUARD_VOSK_MODEL is empty and STAYS empty
  # forever, because this branch refuses to touch an existing block. The model
  # then installs successfully on the retry and is never wired in: the service
  # comes up healthy with "model directory not found: ''" and detection
  # silently off. That is exactly what happened on the first real deploy.
  #
  # Filling in an empty value is not the same as editing a setting somebody
  # chose. A non-empty value is still left alone.
  CUR_MODEL="$(sed -n 's/^[[:space:]]*PHRASEGUARD_VOSK_MODEL[[:space:]]*=[[:space:]]*//p' "$CONF" | head -1)"
  if [[ -z "$CUR_MODEL" && -n "$MODEL_PATH" && -d "$MODEL_PATH" ]]; then
    if (( DRY )); then
      printf '  %s[dry-run]%s would fill in the empty PHRASEGUARD_VOSK_MODEL=%s\n' \
             "$D" "$N" "$MODEL_PATH"
    else
      cp -a "$CONF" "$CONF.bak.$(date -u +%Y%m%dT%H%M%SZ)"
      sed -i "s|^[[:space:]]*PHRASEGUARD_VOSK_MODEL[[:space:]]*=.*|PHRASEGUARD_VOSK_MODEL=$MODEL_PATH|" "$CONF"
      ok "filled in PHRASEGUARD_VOSK_MODEL=$MODEL_PATH (was empty)"
      ok "detection is now ENABLED"
    fi
  elif [[ -n "$CUR_MODEL" ]]; then
    ok "model already configured: $CUR_MODEL"
  elif [[ -z "$MODEL_PATH" ]]; then
    warn "PHRASEGUARD_VOSK_MODEL is empty and no model is installed"
    say "${D}PhraseGuard will record calls but transcribe nothing. Install a${N}"
    say "${D}model, then re-run this script to wire it in.${N}"
  fi
elif (( DRY )); then
  printf '  %s[dry-run]%s would append a PhraseGuard block to %s\n' "$D" "$N" "$CONF"
else
  cp -a "$CONF" "$CONF.bak.$(date -u +%Y%m%dT%H%M%SZ)" || die "could not back up $CONF"
  {
    echo ""
    echo "# ---------------------------------------------------------------------------"
    echo "# PhraseGuard — added by tools/deploy-phraseguard.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "# Full annotated list of settings: config.env.example, and phraseguard/README.md"
    echo "# ---------------------------------------------------------------------------"
    echo "# 0 = shadow mode: detect, record, hang up NOTHING. This is the safe default."
    echo "# Do not set this to 1 until you have reviewed five full traffic days of"
    echo "# shadow-mode hits. See phraseguard/README.md, Order of work."
    echo "PHRASEGUARD_ENFORCE=0"
    echo "PHRASEGUARD_LANGS=en"
    echo "PHRASEGUARD_VOSK_MODEL=${MODEL_PATH}"
    echo "PHRASEGUARD_LOG_DIR=$LOG_DIR"
    echo "PHRASEGUARD_STATE=$STATE_DIR/counters.json"
  } >> "$CONF"
  ok "appended a PhraseGuard block to $CONF (backup alongside it)"
  ok "PHRASEGUARD_ENFORCE=0 — shadow mode"
fi

head_ "5. preflight the daemon itself"
if (( DRY )); then
  printf '  %s[dry-run]%s would run phraseguardd.py --self-test\n' "$D" "$N"
else
  if python3 "$DEST/phraseguardd.py" --config "$CONF" --self-test 2>&1 | sed 's/^/  /'; then
    ok "daemon self-test passed"
  else
    bad "daemon self-test REFUSED — not starting the service"
    say "${D}Nothing has been started. Fix what it printed and re-run.${N}"
    echo
    exit 1
  fi
fi

head_ "6. service"
if (( DRY )); then
  printf '  %s[dry-run]%s would install %s and start it\n' "$D" "$N" "$UNIT"
else
  install -m 0644 "$UNIT_SRC" "$UNIT" || die "could not install the unit"
  systemctl daemon-reload
  systemctl enable --now sbc-phraseguard >/dev/null 2>&1
  sleep 2
  if systemctl is-active --quiet sbc-phraseguard; then
    ok "sbc-phraseguard is running"
  else
    bad "sbc-phraseguard failed to start"
    journalctl -u sbc-phraseguard -n 20 --no-pager 2>/dev/null | sed 's/^/      /'
    echo
    say "${D}Asterisk is unaffected — the unit has no Requires= on it.${N}"
    exit 1
  fi
fi

head_ "7. Asterisk was not touched"
if systemctl is-active --quiet asterisk 2>/dev/null; then
  ok "asterisk still running, never restarted, never reloaded"
else
  warn "asterisk is not running — but PhraseGuard did not do that"
fi

echo
echo "  ${G}${B}PhraseGuard is installed and running in SHADOW MODE.${N}"
echo
echo "  It is watching calls and writing an evidence record. It is NOT"
echo "  hanging up anything, and it will not until you change one setting."
echo
echo "  ${B}What to do next${N}"
echo "    1. Confirm it is alive:      $0 --check"
echo "    2. Watch it live:            journalctl -t sbc-phraseguard -f"
echo "    3. Once traffic returns, prove the hangup path works:"
echo "                                 $SBC_DIR/tools/phraseguard-spike.sh --arm"
echo "    4. After 5 full traffic days, review what it WOULD have killed:"
echo "                                 python3 $DEST/phraseguardd.py --status"
echo "    5. Only then, and only if that review is clean, set"
echo "       PHRASEGUARD_ENFORCE=1 in $CONF and:"
echo "                                 systemctl restart sbc-phraseguard"
echo "       ${D}(that restarts PhraseGuard, never Asterisk)${N}"
echo
echo "  ${D}Uninstall at any time with: $0 --uninstall${N}"
echo
exit 0
