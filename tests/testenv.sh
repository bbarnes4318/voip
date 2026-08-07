#!/usr/bin/env bash
#
# testenv.sh — swap the SBC between production and test configuration.
#
#   sudo ./tests/testenv.sh apply     point the trunk at the local SIPp stub
#   sudo ./tests/testenv.sh restore   re-render production config from config.env
#   ./tests/testenv.sh status         which configuration is live
#
# THIS REPLACES THE RUNNING ASTERISK CONFIGURATION AND RESTARTS ASTERISK.
# Never run `apply` on a box carrying customer traffic. The acceptance suite
# needs the trunk pointed at a stub — running it against the live FracTEL
# trunk would put test INVITEs on a brand new subaccount, which is a good way
# to have the carrier's fraud system look at you on day one.
#
# restore re-renders from config.env rather than copying the backup, so the
# production configuration is always exactly what config.env describes. The
# timestamped backup is kept as a fallback either way.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PROD_CONF="${PROD_CONF:-$ROOT/config.env}"
TEST_CONF="${TEST_CONF:-$HERE/config.test.env}"
AST_ETC=/etc/asterisk
MARKER=/etc/sbc/testenv.active

die()  { echo "testenv.sh: ERROR: $*" >&2; exit 1; }
info() { echo "  $*"; }

wait_for_asterisk() {
  for _ in $(seq 1 30); do
    asterisk -rx "core show version" >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

case "${1:-status}" in

  apply)
    [[ "$(id -u)" -eq 0 ]] || die "must run as root"
    [[ -f "$TEST_CONF" ]] || die "not found: $TEST_CONF
       cp tests/config.test.env.example tests/config.test.env"

    STAMP="$(date +%Y%m%d-%H%M%S)"
    cp -a "$AST_ETC" "${AST_ETC}.prod-${STAMP}"
    info "backed up $AST_ETC -> ${AST_ETC}.prod-${STAMP}"

    CONF="$TEST_CONF" ALLOW_PLACEHOLDERS=1 "$ROOT/render.sh" -o "$AST_ETC" \
      || die "rendering the test configuration failed; production config untouched"

    AST_GROUP="$(id -gn asterisk 2>/dev/null || echo root)"
    chown root:"$AST_GROUP" "$AST_ETC"/*.conf
    chmod 640 "$AST_ETC"/*.conf

    mkdir -p /etc/sbc
    printf '%s\n' "${AST_ETC}.prod-${STAMP}" > "$MARKER"

    systemctl restart asterisk
    wait_for_asterisk || die "asterisk did not come back after the restart"
    sleep 3

    echo
    echo "  TEST CONFIGURATION IS LIVE."
    echo "  Trunk points at the SIPp stub, not FracTEL. Caps are tiny."
    echo "  Restore with: sudo $HERE/testenv.sh restore"
    ;;

  restore)
    [[ "$(id -u)" -eq 0 ]] || die "must run as root"
    [[ -f "$PROD_CONF" ]] || die "not found: $PROD_CONF — cannot re-render production config"

    CONF="$PROD_CONF" "$ROOT/render.sh" -o "$AST_ETC" \
      || die "rendering production config failed. The box is still on TEST config.
       Fix config.env and re-run, or restore the backup listed in $MARKER"

    AST_GROUP="$(id -gn asterisk 2>/dev/null || echo root)"
    chown root:"$AST_GROUP" "$AST_ETC"/*.conf
    chmod 640 "$AST_ETC"/*.conf

    rm -f "$MARKER"
    systemctl restart asterisk
    wait_for_asterisk || die "asterisk did not come back after the restart"
    sleep 3

    echo
    echo "  PRODUCTION CONFIGURATION RESTORED from $(basename "$PROD_CONF")."
    "$ROOT/healthcheck.sh" || true
    ;;

  status)
    if [[ -f "$MARKER" ]]; then
      echo "live configuration: TEST  (backup of production: $(cat "$MARKER"))"
      exit 1
    else
      echo "live configuration: PRODUCTION"
    fi
    ;;

  *)
    sed -n '2,8p' "$0"
    exit 2
    ;;
esac
