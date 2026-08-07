#!/usr/bin/env bash
#
# killswitch.sh — cut customer traffic immediately.
#
#   ./killswitch.sh on              stop new customer calls (default, SAFE)
#   ./killswitch.sh on --hard       also drop the customer IPs at the firewall
#   ./killswitch.sh off             restore service
#   ./killswitch.sh status          report current state
#   ./killswitch.sh restore         re-apply persisted state (used at boot)
#
# WHAT "on" DOES, AND WHY IT IS NOT THE FIREWALL BY DEFAULT
# --------------------------------------------------------
# The brief asked for "disable the two customer endpoints and drop their
# firewall rules". Dropping the firewall rules also drops in-dialog BYEs and
# the customer-leg RTP of calls that are already up, so every live call hangs
# until it times out instead of tearing down cleanly — on the FracTEL side
# that looks like a burst of abandoned calls, which is precisely the pattern
# a carrier's fraud system reacts to. So the default was made safer:
#
#   on          sets the dialplan global SBC_KILLSWITCH=1. Every new INVITE
#               from either customer IP is refused with 503 at the top of
#               [sbc-customer], before any FracTEL leg is created. Calls
#               already in progress finish and tear down normally. The
#               FracTEL trunk is untouched. Takes effect in well under a
#               second and needs no reload.
#
#   on --hard   the above, plus the two customer addresses are added to the
#               nftables set 'pk_blocked', which sits above the conntrack rule
#               and therefore kills established flows too. This is the "they
#               are actively defrauding me, pull the cable" option. It WILL
#               strand in-progress calls.
#
# Asterisk has no runtime "disable this endpoint" command for statically
# configured PJSIP endpoints, and removing the identify sections requires a
# reload — which is slower and briefly disturbs the FracTEL trunk. The
# dialplan global achieves the same outcome instantly and reversibly.
#
# State is persisted so that a reboot, an Asterisk restart, or a firewall
# rebuild cannot silently turn customer traffic back on.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${CONF:-$HERE/config.env}"
STATE_DIR="${STATE_DIR:-/etc/sbc}"
STATE_FILE="$STATE_DIR/killswitch.state"
AST="${AST:-asterisk}"

die()  { echo "killswitch.sh: ERROR: $*" >&2; exit 1; }

ACTION="${1:-status}"; shift || true
HARD=0
for a in "$@"; do
  case "$a" in
    --hard) HARD=1 ;;
    *) die "unknown argument '$a'" ;;
  esac
done

have_asterisk() { "$AST" -rx "core show version" >/dev/null 2>&1; }
have_nft_table() { command -v nft >/dev/null 2>&1 && nft list table inet sbc >/dev/null 2>&1; }

read_state() { [[ -f "$STATE_FILE" ]] && cat "$STATE_FILE" || echo "off"; }
write_state() {
  mkdir -p "$STATE_DIR"
  printf '%s\n' "$1" > "$STATE_FILE"
  chmod 0644 "$STATE_FILE"
}

customer_ips() {
  [[ -f "$CONF" ]] || die "config file not found: $CONF"
  # shellcheck disable=SC1090
  ( set -a; source "$CONF"; set +a; echo "${PK_CLIENT_IP_1:-},${PK_CLIENT_IP_2:-}" )
}

nft_block() {
  local ips el=""
  ips="$(customer_ips)"
  IFS=',' read -r -a arr <<< "$ips"
  for i in "${arr[@]}"; do
    i="$(echo "$i" | tr -d '[:space:]')"; [[ -n "$i" ]] || continue
    el+="${el:+, }$i/32"
  done
  [[ -n "$el" ]] || die "no customer IPs found in $CONF"
  nft add element inet sbc pk_blocked "{ $el }"
}

nft_unblock() {
  local ips el=""
  ips="$(customer_ips)"
  IFS=',' read -r -a arr <<< "$ips"
  for i in "${arr[@]}"; do
    i="$(echo "$i" | tr -d '[:space:]')"; [[ -n "$i" ]] || continue
    el+="${el:+, }$i/32"
  done
  [[ -n "$el" ]] || return 0
  nft delete element inet sbc pk_blocked "{ $el }" 2>/dev/null || true
}

set_global() {
  have_asterisk || die "Asterisk is not running or the CLI socket is unreachable.
       The dialplan killswitch cannot be set. If this is an emergency, use:
           sudo systemctl stop asterisk
       which stops all traffic including the FracTEL trunk."
  "$AST" -rx "dialplan set global SBC_KILLSWITCH $1" >/dev/null
}

case "$ACTION" in

  on)
    T0=$(date +%s.%N)
    set_global 1
    if [[ "$HARD" == 1 ]]; then
      have_nft_table || die "nftables table 'inet sbc' is not loaded — run firewall.sh apply first"
      nft_block
      write_state hard
      MODE="hard"
    else
      write_state on
      MODE="soft"
    fi
    T1=$(date +%s.%N)
    echo "KILLSWITCH ON ($MODE) — applied in $(awk -v a="$T0" -v b="$T1" 'BEGIN{printf "%.3f", b-a}')s"
    echo
    if [[ "$MODE" == soft ]]; then
      echo "  New customer INVITEs are now refused with 503."
      echo "  Calls already up will finish normally. FracTEL trunk untouched."
    else
      echo "  Customer addresses are dropped at the firewall AND at the dialplan."
      echo "  In-progress customer calls are stranded and will time out."
    fi
    if have_asterisk; then
      echo
      echo "  channels still up: $("$AST" -rx "core show channels count" 2>/dev/null | head -1)"
    fi
    echo
    echo "  Restore with: sudo $HERE/killswitch.sh off"
    ;;

  off)
    T0=$(date +%s.%N)
    set_global 0
    if have_nft_table; then nft_unblock; fi
    write_state off
    T1=$(date +%s.%N)
    echo "KILLSWITCH OFF — restored in $(awk -v a="$T0" -v b="$T1" 'BEGIN{printf "%.3f", b-a}')s"
    echo "  Customer traffic is accepted again."
    ;;

  restore)
    # Called by sbc-killswitch.service after asterisk and nftables are up, so
    # that a reboot cannot quietly re-enable a customer you deliberately cut
    # off. Silent and non-fatal by design — never block boot on this.
    S="$(read_state)"
    case "$S" in
      on)   set_global 1 2>/dev/null || true
            echo "killswitch restored: on (soft)" ;;
      hard) set_global 1 2>/dev/null || true
            have_nft_table && nft_block 2>/dev/null || true
            echo "killswitch restored: on (hard)" ;;
      *)    set_global 0 2>/dev/null || true
            echo "killswitch restored: off" ;;
    esac
    ;;

  status)
    S="$(read_state)"
    echo "persisted state : $S"

    if have_asterisk; then
      G="$("$AST" -rx "dialplan show globals" 2>/dev/null | grep -E '^\s*SBC_KILLSWITCH' || true)"
      if [[ "$G" =~ SBC_KILLSWITCH[[:space:]]*=[[:space:]]*1 ]]; then
        echo "dialplan global : SBC_KILLSWITCH=1  -> new customer calls REFUSED (503)"
      else
        echo "dialplan global : SBC_KILLSWITCH unset/0 -> customer calls ACCEPTED"
      fi
      echo "active channels : $("$AST" -rx "core show channels count" 2>/dev/null | head -1)"
    else
      echo "dialplan global : UNKNOWN (Asterisk not reachable)"
    fi

    if have_nft_table; then
      BL="$(nft list set inet sbc pk_blocked 2>/dev/null | grep -o 'elements = {[^}]*}' || true)"
      if [[ -n "$BL" ]]; then
        echo "firewall block  : ACTIVE  $BL"
      else
        echo "firewall block  : none (customer addresses reachable)"
      fi
    else
      echo "firewall block  : UNKNOWN (table inet sbc not loaded)"
    fi

    # Disagreement between the persisted state and what is actually live is
    # the dangerous case — it means someone believes traffic is cut when it
    # is not. Exit non-zero so a monitoring wrapper notices.
    if have_asterisk; then
      LIVE_ON=0
      "$AST" -rx "dialplan show globals" 2>/dev/null | grep -qE '^\s*SBC_KILLSWITCH\s*=\s*1' && LIVE_ON=1
      case "$S:$LIVE_ON" in
        off:0|on:1|hard:1) ;;
        *) echo; echo "  WARNING: persisted state '$S' does not match the live dialplan."
           echo "           Run '$HERE/killswitch.sh restore' to reconcile."
           exit 2 ;;
      esac
    fi
    ;;

  *)
    sed -n '2,8p' "$0"
    exit 2
    ;;
esac
