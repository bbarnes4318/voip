#!/usr/bin/env bash
#
# lib/pk-clients.sh — the customer's signaling IPs, parsed once and the same
# way everywhere.
#
# Sourced by render.sh, firewall.sh, killswitch.sh, healthcheck.sh,
# install.sh, didctl.sh and the acceptance suite. Every one of them used to
# spell the list out as PK_CLIENT_IP_1 and PK_CLIENT_IP_2 by hand, which meant
# a third customer address was seven separate edits and any one of them left
# behind was a silent hole: an IP Asterisk accepts but the firewall drops, or
# the reverse.
#
# The source of truth is PK_CLIENT_IPS in config.env:
#
#     PK_CLIENT_IPS=198.51.100.21,198.51.100.22,198.51.100.23
#
# ---------------------------------------------------------------------------
# ORDER IS AN IDENTITY, NOT A PREFERENCE.
#
# Endpoint names are positional: entry 1 is pkclient1, entry 2 is pkclient2,
# and so on. That name is what the rest of the system bills and rate-limits on
#
#   - CDR column 5 (customer_endpoint), and the portal's attribution of a call
#     to a customer
#   - the per-IP concurrency group, GROUP(cust)=${SBC_EP}
#   - the transfer-state keys in astdb, sbc/xfer/<endpoint>/<destination>
#
# So APPEND to this list. Never reorder it and never delete from the middle:
# either one silently renames the endpoints after the gap, and every one of
# those records then belongs to the wrong customer IP. render.sh warns when a
# render would move an existing pkclientN to a different address.
# ---------------------------------------------------------------------------

# Emits one IPv4 address per line, in list order.
#
# Returns non-zero with a message on stderr if the list is empty, holds
# something that is not a bare IPv4 address, or names the same address twice.
# Callers are expected to treat that as fatal — every consumer of this list is
# either a security control or a billing key, and a half-parsed list is worse
# than no list at all.
pk_client_ips() {
  local raw="${PK_CLIENT_IPS:-}" e out=() seen=" "

  # Pre-list config.env files spelled the two addresses out individually.
  # Still honoured so that a config.env which has not been migrated keeps
  # producing the ruleset and the endpoints it always did.
  if [[ -z "${raw//[[:space:],]/}" ]]; then
    raw="${PK_CLIENT_IP_1:-}"
    [[ -n "${PK_CLIENT_IP_2:-}" ]] && raw+="${raw:+,}${PK_CLIENT_IP_2}"
  fi

  while read -r e; do
    [[ -n "$e" ]] || continue
    if [[ ! "$e" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      echo "pk-clients: '$e' is not a bare IPv4 address" >&2
      echo "            PK_CLIENT_IPS is signaling addresses only — no CIDR, no port, no hostname." >&2
      return 1
    fi
    if [[ "$seen" == *" $e "* ]]; then
      # Two endpoints matching one address is not a duplicate that can be
      # collapsed: res_pjsip would identify the traffic as whichever section
      # it read last, and the concurrency cap and the CDR would disagree about
      # who the call belongs to. If the customer really has fewer IPs than
      # this list has entries, delete the entry rather than repeating one.
      echo "pk-clients: $e appears twice in the customer IP list" >&2
      return 1
    fi
    seen+="$e "
    out+=("$e")
  done <<< "$(tr ', ' '\n\n' <<< "$raw" | tr -d '[:blank:]')"

  if (( ${#out[@]} == 0 )); then
    echo "pk-clients: no customer signaling IPs. Set PK_CLIENT_IPS in config.env." >&2
    return 1
  fi

  printf '%s\n' "${out[@]}"
}

# Emits "<endpoint name> <ip>" per line, e.g. "pkclient3 198.51.100.23".
pk_client_endpoints() {
  local ips n=0 ip
  ips="$(pk_client_ips)" || return 1
  while read -r ip; do
    [[ -n "$ip" ]] || continue
    n=$((n + 1))
    printf 'pkclient%d %s\n' "$n" "$ip"
  done <<< "$ips"
}

# Emits just the endpoint names, one per line.
pk_client_endpoint_names() {
  local eps
  eps="$(pk_client_endpoints)" || return 1
  awk '{print $1}' <<< "$eps"
}
