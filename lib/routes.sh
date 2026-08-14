#!/usr/bin/env bash
#
# lib/routes.sh — the egress route model. Sourced by render.sh, firewall.sh
# and netroutes.sh.
#
# This exists for the same reason lib/pk-clients.sh does: three scripts have to
# agree on what the egress paths are, and if they ever disagree the box has a
# hole. The firewall would permit a proxy toward an address Asterisk does not
# bind, or bind an address the firewall does not permit, and the failure shows
# up as one-way audio at 3am rather than as an error at render time. One
# parser, one answer.
#
# ---------------------------------------------------------------------------
# WHAT A ROUTE IS
# ---------------------------------------------------------------------------
#
# A route is one egress path: a rate deck reachable through a set of proxies,
# distinguished from its siblings by whatever mechanism the carrier happens to
# use to tell subaccounts apart.
#
# Which mechanism that will be is NOT KNOWN YET, and this file is the answer to
# not knowing. All of them are carried at once:
#
#   bind_ip       separation by source IP
#   bind_port     separation by source port (same IP, different port)
#   tech_prefix   separation by a prefix on the dialled number
#   from_domain   separation by From domain / realm
#   proxies       separation by distinct proxy hostnames
#
# When the carrier answers, the operator sets the relevant field in config.env
# and nothing in any script changes. That is the whole design: the unknown is
# absorbed as configuration rather than deferred as a question.
#
# ---------------------------------------------------------------------------
# FORMAT
# ---------------------------------------------------------------------------
#
#   ROUTE_1=name=sd|carrier=fractel|deck=ShortDuration|bind_ip=203.0.113.10|...
#
# Pipe-delimited key=value. NOT colon-positional: an IPv4 endpoint is already
# written host:port, and a positional format would have to escape that or
# silently mis-split it. Pipes also match the dialplan pool convention, where
# a comma is the argument separator and cannot be used.
#
# Only `name` and `proxies` are required. Everything else defaults.
#
# ---------------------------------------------------------------------------
# WHAT IT POPULATES
# ---------------------------------------------------------------------------
#
#   ROUTE_NAMES[]     ordered route names; the order IS the default failover
#                     order, so it is preserved exactly as written
#   ROUTE_LEGACY      1 when synthesized from FRACTEL_PROXY_IPS (see below)
#   R_CARRIER R_DECK R_BIND_IP R_BIND_PORT R_PREFIX R_FROM_DOMAIN
#   R_PROXIES         comma-separated ip[:port] list
#   R_EPPREFIX        PJSIP endpoint name prefix for this route
#
# ---------------------------------------------------------------------------
# BACKWARD COMPATIBILITY IS THE ROLLBACK PATH
# ---------------------------------------------------------------------------
#
# With no ROUTE_* set and FRACTEL_PROXY_IPS present, routes_load synthesizes a
# single legacy route whose endpoints are named fractel1..N — byte-identical to
# what this box rendered before multi-route existed. That is deliberate and it
# is not a transitional convenience: single-route operation is how the operator
# rolls back, and it has to keep working forever. Reverting is one edit to
# config.env, not a git revert.

# Guard against double-sourcing: render.sh sources this and may also source
# something that sources it.
[[ -n "${_SBC_ROUTES_SH:-}" ]] && return 0
_SBC_ROUTES_SH=1

declare -a ROUTE_NAMES=()
declare -A R_CARRIER=() R_DECK=() R_BIND_IP=() R_BIND_PORT=()
declare -A R_PREFIX=() R_FROM_DOMAIN=() R_PROXIES=() R_EPPREFIX=()
ROUTE_LEGACY=0

# Callers each have their own die(). Use theirs when present so the error
# carries the right script name, and fall back to a local one otherwise.
_routes_die() {
  if declare -F die >/dev/null 2>&1; then die "$@"; else
    echo "routes: ERROR: $*" >&2; exit 1
  fi
}

_routes_is_ipv4() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }

# Addresses actually configured on this host, one per line. Used to refuse a
# bind_ip the box does not hold — the single most likely route misconfiguration
# and one that otherwise surfaces as "the carrier is rejecting our calls".
routes_host_addrs() {
  command -v ip >/dev/null 2>&1 || return 0
  ip -4 -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1
}

# ---------------------------------------------------------------------------
# routes_load — parse ROUTE_* from the already-sourced config into the arrays
# above. Every failure is fatal and names the route, because a route that is
# wrong is a trunk that does not work and there is no safe partial rendering.
# ---------------------------------------------------------------------------
routes_load() {
  local default_bind_ip="${1:-${SBC_PUBLIC_IP:-}}"
  local default_port="${2:-${SIP_PORT:-5060}}"
  local default_domain="${3:-${FRACTEL_DOMAIN:-}}"

  ROUTE_NAMES=(); ROUTE_LEGACY=0
  R_CARRIER=(); R_DECK=(); R_BIND_IP=(); R_BIND_PORT=()
  R_PREFIX=(); R_FROM_DOMAIN=(); R_PROXIES=(); R_EPPREFIX=()

  # Collect ROUTE_<n> in NUMERIC order. Sourcing config.env gives no ordering
  # guarantee, and the order is the default failover order, so it cannot be
  # left to however the shell happens to enumerate variables.
  local -a idxs=()
  local v n
  for v in $(compgen -v | grep -E '^ROUTE_[0-9]+$' || true); do
    idxs+=("${v#ROUTE_}")
  done

  if (( ${#idxs[@]} == 0 )); then
    _routes_load_legacy "$default_bind_ip" "$default_port" "$default_domain"
    return 0
  fi

  while read -r n; do
    _routes_parse_one "ROUTE_$n" "$default_bind_ip" "$default_port" "$default_domain"
  done < <(printf '%s\n' "${idxs[@]}" | sort -n)
}

# Synthesize the single pre-multi-route path. Endpoint names stay fractel1..N
# so the rendered pjsip.conf, the CDR gateway column, monitor.sh and the
# acceptance suite all keep working unchanged.
_routes_load_legacy() {
  local bind_ip="$1" port="$2" domain="$3"
  [[ -n "${FRACTEL_PROXY_IPS:-}" ]] || _routes_die \
    "no ROUTE_* entries and FRACTEL_PROXY_IPS is empty — there is no egress path.
       Set FRACTEL_PROXY_IPS for single-route operation, or define ROUTE_1..N."

  ROUTE_LEGACY=1
  local nm="fractel"
  ROUTE_NAMES=("$nm")
  R_CARRIER[$nm]="fractel"
  R_DECK[$nm]=""
  R_BIND_IP[$nm]="$bind_ip"
  R_BIND_PORT[$nm]="$port"
  R_PREFIX[$nm]=""
  R_FROM_DOMAIN[$nm]="$domain"
  R_PROXIES[$nm]="$(echo "$FRACTEL_PROXY_IPS" | tr -d '[:space:]')"
  # The legacy endpoint prefix. This is why a rollback renders the same file.
  R_EPPREFIX[$nm]="fractel"
  _routes_validate_one "$nm" "FRACTEL_PROXY_IPS"
}

_routes_parse_one() {
  local var="$1" bind_ip="$2" port="$3" domain="$4"
  # Indirect expansion here rather than in the caller's loop, so an entry that
  # is set but empty is reported against its own variable name.
  local raw="${!var:-}"
  [[ -n "$raw" ]] || _routes_die "$var is defined but empty"

  local nm="" carrier="" deck="" bip="" bport="" pfx="" fdom="" proxies=""
  local field key val
  local IFS='|'
  # shellcheck disable=SC2206
  local -a fields=($raw)
  unset IFS

  for field in "${fields[@]}"; do
    [[ -n "$field" ]] || continue
    [[ "$field" == *=* ]] || _routes_die \
      "$var: field '$field' is not key=value (entries are pipe-delimited key=value)"
    key="${field%%=*}"; val="${field#*=}"
    key="${key//[[:space:]]/}"
    val="${val//[[:space:]]/}"
    case "$key" in
      name)        nm="$val" ;;
      carrier)     carrier="$val" ;;
      deck)        deck="$val" ;;
      bind_ip)     bip="$val" ;;
      bind_port)   bport="$val" ;;
      tech_prefix) pfx="$val" ;;
      from_domain) fdom="$val" ;;
      proxies)     proxies="$val" ;;
      *) _routes_die "$var: unknown field '$key'.
       Valid: name carrier deck bind_ip bind_port tech_prefix from_domain proxies" ;;
    esac
  done

  [[ -n "$nm" ]] || _routes_die "$var has no name= field"

  # The name becomes part of a PJSIP section name, a dialplan global name and
  # an nft set name. Keep it to something all three accept without quoting, and
  # short enough that endpoint names stay readable in the CDR.
  [[ "$nm" =~ ^[a-z0-9]{1,12}$ ]] || _routes_die \
    "$var: name '$nm' must be 1-12 chars of [a-z0-9].
       It is used verbatim as a PJSIP section name, a dialplan global and an
       nft set name, so anything needing quoting is refused here."

  local existing
  for existing in "${ROUTE_NAMES[@]}"; do
    [[ "$existing" == "$nm" ]] && _routes_die \
      "$var: duplicate route name '$nm'.
       Names key the CDR route_name column and the per-route firewall sets;
       two routes sharing one would make both unattributable."
  done

  ROUTE_NAMES+=("$nm")
  R_CARRIER[$nm]="${carrier:-fractel}"
  R_DECK[$nm]="$deck"
  R_BIND_IP[$nm]="${bip:-$bind_ip}"
  R_BIND_PORT[$nm]="${bport:-$port}"
  R_PREFIX[$nm]="$pfx"
  R_FROM_DOMAIN[$nm]="${fdom:-$domain}"
  R_PROXIES[$nm]="$proxies"
  R_EPPREFIX[$nm]="rt${nm}"

  _routes_validate_one "$nm" "$var"
}

_routes_validate_one() {
  local nm="$1" var="$2"

  [[ -n "${R_PROXIES[$nm]}" ]] || _routes_die \
    "$var: route '$nm' has an empty proxy list. A route with nowhere to send
       calls renders cleanly and then fails every call on it."

  _routes_is_ipv4 "${R_BIND_IP[$nm]}" || _routes_die \
    "$var: route '$nm' bind_ip '${R_BIND_IP[$nm]}' is not a bare IPv4 address"

  [[ "${R_BIND_PORT[$nm]}" =~ ^[0-9]+$ ]] \
    && (( R_BIND_PORT[$nm] >= 1 && R_BIND_PORT[$nm] <= 65535 )) || _routes_die \
    "$var: route '$nm' bind_port '${R_BIND_PORT[$nm]}' is not a valid port"

  # The tech prefix is prepended to the dialled number AFTER every destination
  # check has run. Restricting it to digits is what keeps it from being able to
  # carry dialplan syntax into the Dial() string. It is a fraud control, not a
  # formatting nicety — see the route loop in extensions.conf.tpl.
  [[ "${R_PREFIX[$nm]}" =~ ^[0-9*#]*$ ]] || _routes_die \
    "$var: route '$nm' tech_prefix '${R_PREFIX[$nm]}' may contain only digits,
       * and #. It is prepended to the dialled number, so anything else would
       be able to inject dialplan syntax into the carrier leg."

  if [[ -n "${R_FROM_DOMAIN[$nm]}" ]]; then
    [[ "${R_FROM_DOMAIN[$nm]}" =~ ^[A-Za-z0-9._-]+$ ]] || _routes_die \
      "$var: route '$nm' from_domain '${R_FROM_DOMAIN[$nm]}' is not a bare host or domain"
  fi

  local p ip port
  local IFS=','
  # shellcheck disable=SC2206
  local -a plist=(${R_PROXIES[$nm]})
  unset IFS
  for p in "${plist[@]}"; do
    [[ -n "$p" ]] || continue
    ip="${p%%:*}"; port="${p##*:}"
    [[ "$port" == "$p" ]] && port=""
    _routes_is_ipv4 "$ip" || _routes_die \
      "$var: route '$nm' proxy '$p' is not ip or ip:port"
    if [[ -n "$port" ]]; then
      [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )) || _routes_die \
        "$var: route '$nm' proxy '$p' has an invalid port"
    fi
  done
}

# ---------------------------------------------------------------------------
# routes_check_binds — every distinct bind_ip must actually be on this host.
#
# Separate from routes_load because it can only be answered on the SBC itself.
# render.sh runs off-box during development, and dying there would make the
# templates un-renderable on a laptop; so this NOTES off-box and DIES on-box.
# ---------------------------------------------------------------------------
routes_check_binds() {
  local addrs nm missing=""
  addrs="$(routes_host_addrs)"
  if [[ -z "$addrs" ]]; then
    echo "  note: cannot read local addresses (no 'ip' command) — bind_ip not checked" >&2
    return 0
  fi
  for nm in "${ROUTE_NAMES[@]}"; do
    grep -qxF "${R_BIND_IP[$nm]}" <<< "$addrs" || \
      missing+="${missing:+, }$nm (${R_BIND_IP[$nm]})"
  done
  [[ -z "$missing" ]] || _routes_die \
    "these routes bind an address this host does not have: $missing

       Configured here: $(tr '\n' ' ' <<< "$addrs")

       Asterisk would fail to bind the transport, or bind it to the wrong
       address and send from the primary IP — which the carrier sees as an
       unauthorised source. Add the address first (netroutes.sh reports what
       it finds), or correct bind_ip in config.env."
}

# ---------------------------------------------------------------------------
# routes_transports — the deduplicated (bind_ip, bind_port) pairs.
#
# Two routes on the same address and port SHARE one transport, and that is
# correct: a transport is a socket, and Asterisk will refuse to bind two to the
# same address:port. Separation by port is expressed by giving the routes
# different bind_port values, which yields two transports here.
#
# Emits: "<name>\t<bind_ip>\t<bind_port>" per unique pair.
# ---------------------------------------------------------------------------
routes_transports() {
  local nm key ip port
  local -A seen=()
  for nm in "${ROUTE_NAMES[@]}"; do
    ip="${R_BIND_IP[$nm]}"; port="${R_BIND_PORT[$nm]}"
    key="$ip:$port"
    [[ -n "${seen[$key]:-}" ]] && continue
    seen[$key]=1
    printf '%s\t%s\t%s\n' "$(routes_transport_name "$ip" "$port")" "$ip" "$port"
  done
}

# Transport section name for a bind pair. Dots become dashes because a PJSIP
# section name containing dots reads as a hostname to anyone debugging it.
# Legacy mode keeps the original name so a rollback render is byte-identical.
routes_transport_name() {
  if (( ROUTE_LEGACY )); then printf 'transport-udp'; return; fi
  printf 'transport-%s-%s' "${1//./-}" "$2"
}

# Distinct bind addresses, one per line. netroutes.sh keys its policy routing
# tables on exactly this list, and firewall.sh keys its per-route permits on it.
routes_bind_ips() {
  local nm
  for nm in "${ROUTE_NAMES[@]}"; do printf '%s\n' "${R_BIND_IP[$nm]}"; done | sort -u
}

# Proxy IPs (no port) for one route, one per line.
routes_proxy_ips() {
  local nm="$1" p
  local IFS=','
  # shellcheck disable=SC2206
  local -a plist=(${R_PROXIES[$nm]})
  unset IFS
  for p in "${plist[@]}"; do
    [[ -n "$p" ]] || continue
    printf '%s\n' "${p%%:*}"
  done
}

# Every proxy IP across every route, deduplicated.
routes_all_proxy_ips() {
  local nm
  for nm in "${ROUTE_NAMES[@]}"; do routes_proxy_ips "$nm"; done | sort -u
}
