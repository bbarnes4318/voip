#!/usr/bin/env bash
#
# firewall.sh — default-DROP nftables ruleset for the SBC. Layer 1 of 3.
#
#   ./firewall.sh apply     build /etc/nftables.conf from config.env and load it
#   ./firewall.sh confirm   cancel the auto-rollback after a successful apply
#   ./firewall.sh status    show the live ruleset and per-rule counters
#   ./firewall.sh clear     tear the table down (emergency access recovery)
#   ./firewall.sh check     render and syntax-check without loading
#
# Idempotent: apply always rebuilds the table from scratch, so running it
# twice leaves exactly the same ruleset.
#
# LOCKOUT PROTECTION
# ------------------
# This ruleset drops SSH from everywhere except ADMIN_SSH_IP. Getting that
# wrong on a remote Hetzner box means a rescue-console trip at the worst
# possible time. So:
#
#   - apply refuses to run if the address you are connected from is not
#     covered by ADMIN_SSH_IP (override with --force if you know better)
#   - after loading, a background timer tears the table down again in
#     ROLLBACK_SECS unless you run `firewall.sh confirm`. If the new rules
#     lock you out, you get your box back automatically.
#
# Run with --no-rollback on a console session where lockout is impossible.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${CONF:-$HERE/config.env}"
NFT_FILE="${NFT_FILE:-/etc/nftables.conf}"
ROLLBACK_SECS="${ROLLBACK_SECS:-90}"
CONFIRM_FLAG=/run/sbc-firewall-confirmed
KILLSWITCH_STATE="${KILLSWITCH_STATE:-/etc/sbc/killswitch.state}"

FORCE=0
ROLLBACK=1
ACTION="apply"

while [[ $# -gt 0 ]]; do
  case "$1" in
    apply|confirm|status|clear|check) ACTION="$1"; shift ;;
    --force)        FORCE=1; shift ;;
    --no-rollback)  ROLLBACK=0; shift ;;
    -c|--conf)      CONF="$2"; shift 2 ;;
    -h|--help)      sed -n '2,32p' "$0"; exit 0 ;;
    *) echo "firewall.sh: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

die()  { echo "firewall.sh: ERROR: $*" >&2; exit 1; }
info() { echo "  $*"; }

need_root() { [[ "$(id -u)" -eq 0 ]] || die "must run as root"; }

# ---------------------------------------------------------------------------
# status / clear / confirm do not need the config file
# ---------------------------------------------------------------------------
case "$ACTION" in
  status)
    need_root
    if nft list table inet sbc >/dev/null 2>&1; then
      echo "sbc firewall: LOADED"
      echo
      nft list table inet sbc
      echo
      if [[ -f "$CONFIRM_FLAG" ]]; then
        echo "rollback: confirmed (no pending revert)"
      else
        echo "rollback: NOT CONFIRMED — an auto-revert may still be pending."
        echo "          run './firewall.sh confirm' once you are satisfied."
      fi
    else
      echo "sbc firewall: NOT LOADED — this box is unprotected"
      exit 1
    fi
    exit 0
    ;;
  confirm)
    need_root
    nft list table inet sbc >/dev/null 2>&1 || die "table inet sbc is not loaded"
    touch "$CONFIRM_FLAG"
    echo "firewall confirmed. Auto-rollback cancelled."
    exit 0
    ;;
  clear)
    need_root
    nft delete table inet sbc 2>/dev/null || true
    rm -f "$CONFIRM_FLAG"
    echo "table inet sbc removed. THIS BOX NOW HAS NO FIREWALL."
    echo "Re-run './firewall.sh apply' as soon as you have fixed config.env."
    exit 0
    ;;
esac

# ---------------------------------------------------------------------------
# apply / check
# ---------------------------------------------------------------------------
[[ -f "$CONF" ]] || die "config file not found: $CONF"
# shellcheck disable=SC1090
set -a; source "$CONF"; set +a

SSH_PORT="${SSH_PORT:-22}"
SIP_PORT="${SIP_PORT:-5060}"
RTP_START="${RTP_START:-10000}"
RTP_END="${RTP_END:-20000}"
PK_CLIENT_MEDIA_EXTRA="${PK_CLIENT_MEDIA_EXTRA:-}"

for v in ADMIN_SSH_IP PK_CLIENT_IP_1 PK_CLIENT_IP_2 FRACTEL_PROXY_IPS; do
  [[ -n "${!v:-}" ]] || die "$v is empty in $CONF — refusing to build a ruleset with a hole in it"
done

# Normalise a comma/space list into nft set elements, defaulting bare
# addresses to /32.
to_elements() {
  local raw="$1" out="" e
  raw="$(echo "$raw" | tr ', ' '\n\n')"
  while read -r e; do
    e="${e%%:*}"                       # strip any :port suffix
    [[ -n "$e" ]] || continue
    [[ "$e" == */* ]] || e="$e/32"
    out+="${out:+, }$e"
  done <<< "$raw"
  printf '%s' "$out"
}

ADMIN_EL="$(to_elements "$ADMIN_SSH_IP")"
PK_EL="$(to_elements "$PK_CLIENT_IP_1,$PK_CLIENT_IP_2")"
FT_EL="$(to_elements "$FRACTEL_PROXY_IPS")"
MEDIA_EXTRA_EL="$(to_elements "$PK_CLIENT_MEDIA_EXTRA")"

[[ -n "$ADMIN_EL" ]] || die "ADMIN_SSH_IP produced no usable addresses"
[[ -n "$PK_EL"    ]] || die "customer IPs produced no usable addresses"
[[ -n "$FT_EL"    ]] || die "FRACTEL_PROXY_IPS produced no usable addresses"

info "admin   : $ADMIN_EL"
info "customer: $PK_EL"
info "fractel : $FT_EL"
[[ -n "$MEDIA_EXTRA_EL" ]] && info "extra RTP: $MEDIA_EXTRA_EL"

# --- lockout check --------------------------------------------------------
# $SSH_CONNECTION is "<client ip> <client port> <server ip> <server port>".
if [[ "$ACTION" == "apply" && -n "${SSH_CONNECTION:-}" ]]; then
  MY_IP="$(awk '{print $1}' <<< "$SSH_CONNECTION")"
  if ! grep -qx "$MY_IP" <<< "$(tr ', ' '\n\n' <<< "$ADMIN_SSH_IP" | sed 's#/.*##')"; then
    if [[ "$FORCE" == 1 ]]; then
      echo "  WARNING: connected from $MY_IP which is not in ADMIN_SSH_IP — proceeding (--force)" >&2
    else
      die "you are connected from $MY_IP but ADMIN_SSH_IP is '$ADMIN_SSH_IP'.
       Loading this ruleset would drop your own SSH session.
       Fix ADMIN_SSH_IP in $CONF, or re-run with --force if the address is
       covered by a CIDR this check cannot see."
    fi
  else
    info "lockout check: connected from $MY_IP, covered by ADMIN_SSH_IP"
  fi
fi

# --- killswitch state -----------------------------------------------------
# If the killswitch was left in hard mode, rebuilding the firewall must not
# quietly restore customer traffic.
BLOCKED_EL=""
if [[ -f "$KILLSWITCH_STATE" ]] && grep -q '^hard$' "$KILLSWITCH_STATE" 2>/dev/null; then
  BLOCKED_EL="$PK_EL"
  echo "  NOTE: killswitch state is 'hard' — customer addresses stay blocked in the new ruleset" >&2
fi

# ---------------------------------------------------------------------------
# Generate the ruleset
# ---------------------------------------------------------------------------
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

cat > "$TMP" <<EOF
#!/usr/sbin/nft -f
#
# Generated by firewall.sh from $(basename "$CONF") — do not hand-edit.
# Regenerate with: $HERE/firewall.sh apply
#
# Default DROP inbound. Four addresses may speak SIP to this box and nothing
# else may speak to it at all.

# Create-then-delete so this file is safe to load repeatedly and never errors
# on a first run. Only the 'sbc' table is touched; anything else on the box
# is left alone.
table inet sbc
delete table inet sbc

table inet sbc {

    set admin {
        type ipv4_addr
        flags interval
        comment "ADMIN_SSH_IP — the only source allowed to reach SSH"
        elements = { $ADMIN_EL }
    }

    set pk_clients {
        type ipv4_addr
        flags interval
        comment "customer signaling IPs (pkclient1, pkclient2)"
        elements = { $PK_EL }
    }

    set pk_media {
        type ipv4_addr
        flags interval
        comment "extra customer RTP-only sources, if any"
$( [[ -n "$MEDIA_EXTRA_EL" ]] && echo "        elements = { $MEDIA_EXTRA_EL }" )
    }

    set fractel {
        type ipv4_addr
        flags interval
        comment "FracTEL outbound proxies"
        elements = { $FT_EL }
    }

    set pk_blocked {
        type ipv4_addr
        flags interval
        comment "filled by killswitch.sh --hard; empty in normal operation"
$( [[ -n "$BLOCKED_EL" ]] && echo "        elements = { $BLOCKED_EL }" )
    }

    chain input {
        type filter hook input priority filter; policy drop;

        # Loopback first. The acceptance suite drives Asterisk over 127.0.0.0/8
        # and the CLI control socket lives here.
        iif lo accept

        # Killswitch. Deliberately placed ABOVE the conntrack rule: a hard cut
        # has to take effect on already-established flows immediately, not
        # whenever their conntrack entries happen to expire.
        ip saddr @pk_blocked counter drop

        ct state invalid counter drop
        ct state established,related accept

        # Rate-limited ping. Useful for proving reachability to the customer
        # and to FracTEL without becoming an amplification target.
        ip protocol icmp icmp type echo-request limit rate 5/second accept
        ip protocol icmp icmp type { destination-unreachable, time-exceeded } accept

        # --- SSH: admin only ---
        ip saddr @admin tcp dport $SSH_PORT ct state new counter accept

        # --- SIP signaling: customer and carrier only ---
        ip saddr @pk_clients udp dport $SIP_PORT counter accept
        ip saddr @pk_clients tcp dport $SIP_PORT counter accept
        ip saddr @fractel    udp dport $SIP_PORT counter accept
        ip saddr @fractel    tcp dport $SIP_PORT counter accept

        # --- RTP: same four addresses, media range only ---
        ip saddr @pk_clients udp dport $RTP_START-$RTP_END counter accept
        ip saddr @pk_media   udp dport $RTP_START-$RTP_END counter accept
        ip saddr @fractel    udp dport $RTP_START-$RTP_END counter accept

        # Nothing else. Note what is NOT here: AMI (5038), ARI/HTTP (8088),
        # and every other port on the box. There is no rule that could expose
        # them because there is no rule for them at all.
        limit rate 10/minute burst 5 packets log prefix "SBC-DROP-IN " level info
        counter drop
    }

    chain forward {
        type filter hook forward priority filter; policy drop;
        # This box routes nothing.
    }

    chain output {
        type filter hook output priority filter; policy accept;
        # Outbound is open: Asterisk must be able to reach FracTEL, and the
        # host needs DNS, NTP and package updates.
    }
}
EOF

if ! nft -c -f "$TMP"; then
  die "generated ruleset failed nft syntax check (kept at $TMP for inspection)"
fi
trap - EXIT
info "syntax check passed"

if [[ "$ACTION" == "check" ]]; then
  echo
  cat "$TMP"
  rm -f "$TMP"
  exit 0
fi

need_root

install -o root -g root -m 0640 "$TMP" "$NFT_FILE"
rm -f "$TMP"
info "wrote $NFT_FILE"

# --- arm the rollback before loading -------------------------------------
if [[ "$ROLLBACK" == 1 ]]; then
  rm -f "$CONFIRM_FLAG"
  setsid bash -c "
    sleep $ROLLBACK_SECS
    if [[ ! -f '$CONFIRM_FLAG' ]]; then
      nft delete table inet sbc 2>/dev/null
      logger -t sbc-firewall 'auto-rollback: firewall was never confirmed, table removed'
    fi
  " >/dev/null 2>&1 < /dev/null &
  info "auto-rollback armed: ${ROLLBACK_SECS}s"
fi

nft -f "$NFT_FILE"
info "ruleset loaded"

# --- persistence across reboot -------------------------------------------
if command -v systemctl >/dev/null 2>&1; then
  systemctl enable nftables.service >/dev/null 2>&1 \
    && info "nftables.service enabled (ruleset reloads from $NFT_FILE on boot)" \
    || echo "  WARNING: could not enable nftables.service — the firewall will NOT come back after a reboot" >&2
fi

echo
if [[ "$ROLLBACK" == 1 ]]; then
  cat <<EOF
Firewall loaded, with an auto-rollback in ${ROLLBACK_SECS} seconds.

  Open a SECOND ssh session now and confirm it works. Then run:

      sudo $HERE/firewall.sh confirm

  If you cannot get back in, do nothing — the table removes itself and your
  access returns.
EOF
else
  echo "Firewall loaded (rollback disabled)."
fi
