#!/usr/bin/env bash
#
# install.sh — build the SBC on a fresh Debian 12 / Ubuntu 22.04+ host.
#
#   sudo ./install.sh                 full install
#   sudo ./install.sh --config-only   re-render and reload config, no packages
#   sudo ./install.sh --no-firewall   skip firewall.sh (you will run it yourself)
#   sudo ./install.sh --no-tests      do not install sipp/tcpdump
#   sudo ./install.sh --dry-run       show what would happen
#
# Idempotent. Every run:
#   - backs up /etc/asterisk to /etc/asterisk.bak-<timestamp>
#   - re-renders all configs from config.env
#   - re-writes the systemd units and logrotate rules
#   - restarts Asterisk and verifies it came up clean
#
# Installs on the HOST, not in Docker. Docker's userland proxy allocates a
# forwarding process per published port; a 10,000-port RTP range either fails
# to start or eats the box, and the usual --network=host workaround gives up
# every benefit of the container anyway. There is no upside here.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${CONF:-$HERE/config.env}"
STAMP="$(date +%Y%m%d-%H%M%S)"
AST_ETC=/etc/asterisk
STATE_DIR=/etc/sbc

DO_PACKAGES=1
DO_FIREWALL=1
DO_TESTS=1
DRY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config-only) DO_PACKAGES=0; shift ;;
    --no-firewall) DO_FIREWALL=0; shift ;;
    --no-tests)    DO_TESTS=0; shift ;;
    --dry-run)     DRY=1; shift ;;
    -c|--conf)     CONF="$2"; shift 2 ;;
    -h|--help)     sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "install.sh: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

die()  { echo; echo "install.sh: ERROR: $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }
info() { echo "    $*"; }
run()  { if [[ "$DRY" == 1 ]]; then echo "    [dry-run] $*"; else "$@"; fi; }

[[ "$(id -u)" -eq 0 ]] || die "must run as root (sudo ./install.sh)"
[[ -f "$CONF" ]] || die "config file not found: $CONF
       cp config.env.example config.env && chmod 600 config.env && \$EDITOR config.env"

# Refuse to run with a world-readable config: it holds the customer's IPs and,
# if Postgres is in use, a database password.
PERM="$(stat -c '%a' "$CONF")"
if [[ "$PERM" != "600" && "$PERM" != "400" ]]; then
  info "tightening permissions on $CONF (was $PERM)"
  run chmod 600 "$CONF"
fi

# shellcheck disable=SC1090
set -a; source "$CONF"; set +a

# shellcheck source=lib/pk-clients.sh
[[ -r "$HERE/lib/pk-clients.sh" ]] || die "missing $HERE/lib/pk-clients.sh"
. "$HERE/lib/pk-clients.sh"
PK_EP_NAMES="$(pk_client_endpoint_names)" || die "PK_CLIENT_IPS is unusable (see above). Fix it in $CONF."

# dids.csv holds numbers we own and blocklist.csv holds carrier pricing.
# Neither is a credential, but neither belongs to every user on the box.
for _f in "${DIDS_CSV:-dids.csv}" "${BLOCKLIST_CSV:-blocklist.csv}"; do
  [[ "$_f" = /* ]] || _f="$HERE/$_f"
  [[ -f "$_f" ]] || continue
  _p="$(stat -c '%a' "$_f")"
  if [[ "$_p" != "600" && "$_p" != "400" ]]; then
    info "tightening permissions on $(basename "$_f") (was $_p)"
    run chmod 600 "$_f"
  fi
done

ASTERISK_INSTALL_METHOD="${ASTERISK_INSTALL_METHOD:-package}"
ASTERISK_SOURCE_VERSION="${ASTERISK_SOURCE_VERSION:-20-current}"
CDR_CSV_PATH="${CDR_CSV_PATH:-/var/log/asterisk/cdr-custom/sbc.csv}"
SIP_TRACE_ENABLED="${SIP_TRACE_ENABLED:-true}"
SIP_TRACE_DIR="${SIP_TRACE_DIR:-/var/log/asterisk/siptrace}"
SIP_TRACE_FILE_MB="${SIP_TRACE_FILE_MB:-100}"
SIP_TRACE_KEEP="${SIP_TRACE_KEEP:-20}"
LOG_RETAIN_DAYS="${LOG_RETAIN_DAYS:-30}"
CDR_RETAIN_DAYS="${CDR_RETAIN_DAYS:-90}"
SIP_PORT="${SIP_PORT:-5060}"
PG_DSN="${PG_DSN:-}"

# ---------------------------------------------------------------------------
step "Host check"
# ---------------------------------------------------------------------------
. /etc/os-release 2>/dev/null || die "cannot read /etc/os-release"
info "os: $PRETTY_NAME"
case "$ID:$VERSION_ID" in
  debian:12*|debian:13*|ubuntu:22.04|ubuntu:24.04|ubuntu:24.10|ubuntu:25.*) ;;
  *) echo "    WARNING: untested on $ID $VERSION_ID. Debian 12 and Ubuntu 24.04" >&2
     echo "             both ship Asterisk 20 in-repo; other releases may not." >&2 ;;
esac

command -v systemctl >/dev/null || die "systemd is required (for boot persistence)"

# Interface holding the public IP — used by the SIP trace capture.
if [[ "${SBC_IFACE:-auto}" == "auto" ]]; then
  SBC_IFACE="$(ip -4 -o addr show 2>/dev/null | awk -v ip="$SBC_PUBLIC_IP" '$4 ~ "^"ip"/" {print $2; exit}')"
  if [[ -z "$SBC_IFACE" ]]; then
    SBC_IFACE="$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')"
    echo "    WARNING: SBC_PUBLIC_IP=$SBC_PUBLIC_IP is not bound to any interface on this" >&2
    echo "             host. Falling back to the default route interface ($SBC_IFACE)." >&2
    echo "             If this box really is behind NAT, set SBC_NAT_LOCAL_NET in" >&2
    echo "             config.env or you will get one-way audio." >&2
  fi
fi
info "interface: ${SBC_IFACE:-unknown}"

# ---------------------------------------------------------------------------
step "Packages"
# ---------------------------------------------------------------------------
if [[ "$DO_PACKAGES" == 1 ]]; then
  export DEBIAN_FRONTEND=noninteractive
  run apt-get update -qq

  PKGS=(nftables logrotate ca-certificates gawk coreutils iproute2 rsyslog)
  [[ "$DO_TESTS" == 1 ]] && PKGS+=(sip-tester tcpdump)
  [[ -n "$PG_DSN" ]] && PKGS+=(postgresql-client)

  if [[ "$ASTERISK_INSTALL_METHOD" == "package" ]]; then
    PKGS+=(asterisk asterisk-modules asterisk-config)
  fi

  info "installing: ${PKGS[*]}"
  run apt-get install -y -qq "${PKGS[@]}" || die "package installation failed"

  if [[ "$ASTERISK_INSTALL_METHOD" == "source" ]]; then
    step "Building Asterisk $ASTERISK_SOURCE_VERSION from source (this takes a while)"
    run apt-get install -y -qq build-essential libedit-dev libjansson-dev libsqlite3-dev \
        uuid-dev libxml2-dev libssl-dev libsrtp2-dev wget subversion
    SRC=/usr/local/src/asterisk
    run mkdir -p "$SRC"
    if [[ "$DRY" == 0 ]]; then
      cd "$SRC"
      wget -q "https://downloads.asterisk.org/pub/telephony/asterisk/asterisk-${ASTERISK_SOURCE_VERSION}.tar.gz" \
        -O asterisk.tar.gz || die "could not download Asterisk source"
      tar xzf asterisk.tar.gz --strip-components=1
      ./configure --with-jansson-bundled --with-pjproject-bundled >/dev/null
      make menuselect.makeopts >/dev/null
      # Enable only what this box needs; skip sounds we will never play.
      ./menuselect/menuselect --enable chan_pjsip --enable res_pjsip \
          --enable cdr_custom --enable cdr_csv --enable codec_alaw --enable codec_ulaw \
          menuselect.makeopts
      make -j"$(nproc)" >/dev/null || die "Asterisk build failed"
      make install >/dev/null
      make config >/dev/null
      ldconfig
      cd "$HERE"
    fi
  fi
else
  info "skipped (--config-only)"
fi

# --- version gate ---------------------------------------------------------
if [[ "$DRY" == 0 ]]; then
  command -v asterisk >/dev/null || die "asterisk binary not found after install"
  AST_VER="$(asterisk -V 2>/dev/null | awk '{print $2}')"
  AST_MAJ="${AST_VER%%.*}"
  info "asterisk version: $AST_VER"
  if [[ "$AST_MAJ" != "20" ]]; then
    die "this build targets Asterisk 20 LTS, found $AST_VER.
       chan_sip does not exist in 20 and several pjsip.conf options here are
       20-specific. Either use a release that ships 20, or set
       ASTERISK_INSTALL_METHOD=source in config.env and re-run."
  fi
fi

# ---------------------------------------------------------------------------
step "Directories and ownership"
# ---------------------------------------------------------------------------
AST_USER="$(id -un asterisk 2>/dev/null || echo root)"
AST_GROUP="$(id -gn asterisk 2>/dev/null || echo root)"
info "asterisk runs as ${AST_USER}:${AST_GROUP}"

run mkdir -p "$STATE_DIR" "$(dirname "$CDR_CSV_PATH")" "$SIP_TRACE_DIR" /var/log/asterisk
run chown -R "$AST_USER:$AST_GROUP" "$(dirname "$CDR_CSV_PATH")" /var/log/asterisk
run chmod 750 "$(dirname "$CDR_CSV_PATH")"
run chmod 750 "$SIP_TRACE_DIR"
run chmod 755 "$STATE_DIR"

# Where the ops scripts live, so the systemd units can find them after a
# reboot even if someone moves their shell elsewhere.
run bash -c "printf '%s\n' '$HERE' > $STATE_DIR/repo-path"

# ---------------------------------------------------------------------------
step "Rendering configuration"
# ---------------------------------------------------------------------------
if [[ -d "$AST_ETC" && "$DRY" == 0 ]]; then
  cp -a "$AST_ETC" "${AST_ETC}.bak-${STAMP}"
  info "backed up $AST_ETC -> ${AST_ETC}.bak-${STAMP}"
fi

# When Postgres is not configured, cdr_pgsql must not be loaded at all — a
# loaded cdr_pgsql with no usable config logs a connection warning on every
# start and would fail the zero-warnings acceptance check.
EXTRA_DENY=""
[[ -z "$PG_DSN" ]] && EXTRA_DENY="cdr_pgsql.so"

if [[ "$DRY" == 0 ]]; then
  CONF="$CONF" EXTRA_DENY_MODULES="$EXTRA_DENY" "$HERE/render.sh" -o "$AST_ETC" \
    || die "rendering failed — nothing was changed in Asterisk's running config"
  chown root:"$AST_GROUP" "$AST_ETC"/*.conf
  chmod 640 "$AST_ETC"/*.conf
else
  info "[dry-run] would render templates into $AST_ETC"
fi

# --- optional Postgres CDR mirror ----------------------------------------
if [[ -n "$PG_DSN" ]]; then
  step "Postgres CDR mirror"
  # cdr_pgsql populates one table column per matching CDR field name, so the
  # column names below must match the CDR variables set in the dialplan.
  if [[ "$DRY" == 0 ]]; then
    psql "$PG_DSN" -v ON_ERROR_STOP=1 -q <<'SQL' || die "could not create the CDR table — check PG_DSN"
CREATE TABLE IF NOT EXISTS sbc_cdr (
    id                    bigserial PRIMARY KEY,
    calldate              timestamp with time zone,
    start                 varchar(64),
    answer                varchar(64),
    "end"                 varchar(64),
    source_ip             varchar(45)  NOT NULL,
    customer_endpoint     varchar(64),
    caller_id             varchar(64),
    destination           varchar(64),
    duration              integer,
    billsec               integer,
    disposition           varchar(32),
    hangup_cause          varchar(16),
    fractel_gateway_used  varchar(32),
    sip_call_id           varchar(255) NOT NULL,
    reject_reason         varchar(64),
    uniqueid              varchar(64),
    -- Carrier-assigned caller ID. selected_did is what actually went out in
    -- From, P-Asserted-Identity and Remote-Party-ID; caller_id above is what
    -- the customer asked for and did not get.
    selected_did          varchar(16),
    did_selection_reason  varchar(16),
    destination_npa       varchar(8),
    did_daily_count_at_selection integer,
    -- Always NULL from the SBC: no LNP dip happens here. Populated by
    -- reconciliation against FracTEL's LRN-rated CDR.
    lrn                   varchar(16)
);
-- Added after the initial deployment, so an existing table needs them too.
ALTER TABLE sbc_cdr ADD COLUMN IF NOT EXISTS selected_did         varchar(16);
ALTER TABLE sbc_cdr ADD COLUMN IF NOT EXISTS did_selection_reason varchar(16);
ALTER TABLE sbc_cdr ADD COLUMN IF NOT EXISTS destination_npa      varchar(8);
ALTER TABLE sbc_cdr ADD COLUMN IF NOT EXISTS did_daily_count_at_selection integer;
ALTER TABLE sbc_cdr ADD COLUMN IF NOT EXISTS lrn                  varchar(16);
CREATE INDEX IF NOT EXISTS sbc_cdr_did_idx ON sbc_cdr (selected_did);
CREATE INDEX IF NOT EXISTS sbc_cdr_calldate_idx  ON sbc_cdr (calldate);
CREATE INDEX IF NOT EXISTS sbc_cdr_srcip_idx     ON sbc_cdr (source_ip);
CREATE INDEX IF NOT EXISTS sbc_cdr_callid_idx    ON sbc_cdr (sip_call_id);
CREATE INDEX IF NOT EXISTS sbc_cdr_dest_idx      ON sbc_cdr (destination);
SQL
    info "table sbc_cdr ready"

    # Parse the DSN into cdr_pgsql.conf fields.
    _dsn="${PG_DSN#postgresql://}"; _dsn="${_dsn#postgres://}"
    _cred="${_dsn%%@*}"; _rest="${_dsn#*@}"
    _pguser="${_cred%%:*}"; _pgpass="${_cred#*:}"
    [[ "$_pgpass" == "$_cred" ]] && _pgpass=""
    _hostport="${_rest%%/*}"; _pgdb="${_rest#*/}"; _pgdb="${_pgdb%%\?*}"
    _pghost="${_hostport%%:*}"; _pgport="${_hostport#*:}"
    [[ "$_pgport" == "$_hostport" ]] && _pgport=5432

    cat > "$AST_ETC/cdr_pgsql.conf" <<EOF
; Generated by install.sh. Contains a database password — mode 0640, root:$AST_GROUP.
[global]
hostname=$_pghost
port=$_pgport
dbname=$_pgdb
user=$_pguser
password=$_pgpass
table=sbc_cdr
encoding=UTF8
EOF
    chown root:"$AST_GROUP" "$AST_ETC/cdr_pgsql.conf"
    chmod 640 "$AST_ETC/cdr_pgsql.conf"
    info "cdr_pgsql.conf written (CSV remains the system of record)"
  fi
else
  info "PG_DSN empty — CSV-only CDR (this is sufficient for the test)"
  run rm -f "$AST_ETC/cdr_pgsql.conf"
fi

# ---------------------------------------------------------------------------
step "Log rotation"
# ---------------------------------------------------------------------------
if [[ "$DRY" == 0 ]]; then
  cat > /etc/logrotate.d/sbc-asterisk <<EOF
# Generated by install.sh. Keeps SIP traces and CDRs long enough to answer a
# traceback (24h clock) without letting them fill the disk.

/var/log/asterisk/messages /var/log/asterisk/full /var/log/asterisk/security {
    daily
    rotate $LOG_RETAIN_DAYS
    missingok
    notifempty
    compress
    delaycompress
    create 0640 $AST_USER $AST_GROUP
    sharedscripts
    postrotate
        /usr/sbin/asterisk -rx 'logger reload' > /dev/null 2>&1 || true
    endscript
}

$(dirname "$CDR_CSV_PATH")/*.csv /var/log/asterisk/cdr-csv/*.csv {
    daily
    rotate $CDR_RETAIN_DAYS
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
    create 0640 $AST_USER $AST_GROUP
}
EOF
  info "/etc/logrotate.d/sbc-asterisk"
  logrotate -d /etc/logrotate.d/sbc-asterisk >/dev/null 2>&1 \
    || echo "    WARNING: logrotate config did not validate" >&2
fi

# ---------------------------------------------------------------------------
step "systemd units"
# ---------------------------------------------------------------------------
write_unit() { # write_unit <name> <content-on-stdin>
  if [[ "$DRY" == 1 ]]; then info "[dry-run] would write /etc/systemd/system/$1"; cat >/dev/null; return; fi
  cat > "/etc/systemd/system/$1"
  info "/etc/systemd/system/$1"
}

# --- rotating SIP capture ---
if [[ "$SIP_TRACE_ENABLED" == "true" && "$DO_TESTS" == 1 ]]; then
  write_unit sbc-siptrace.service <<EOF
[Unit]
Description=SBC rotating SIP signaling capture
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
# -C caps each file at ${SIP_TRACE_FILE_MB}MB and -W keeps ${SIP_TRACE_KEEP} of
# them, so disk usage is bounded at about $((SIP_TRACE_FILE_MB * SIP_TRACE_KEEP))MB
# no matter how long this runs. -s0 keeps full packets: a truncated INVITE is
# useless as traceback evidence.
ExecStart=/usr/bin/tcpdump -i $SBC_IFACE -s0 -n -W $SIP_TRACE_KEEP -C $SIP_TRACE_FILE_MB \\
  -w $SIP_TRACE_DIR/sip-%Y%m%d-%H%M%S.pcap -Z $AST_USER \\
  "port $SIP_PORT"
Restart=on-failure
RestartSec=5
Nice=10

[Install]
WantedBy=multi-user.target
EOF
fi

# --- health check timer ---
write_unit sbc-healthcheck.service <<EOF
[Unit]
Description=SBC health check
After=asterisk.service

[Service]
Type=oneshot
ExecStart=$HERE/healthcheck.sh --quiet
# Exit 1 is "degraded" and must not mark the unit failed; exit 2 is "down"
# and must. journalctl -t sbc-health has the detail either way.
SuccessExitStatus=0 1
EOF

write_unit sbc-healthcheck.timer <<EOF
[Unit]
Description=Run the SBC health check every minute

[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
AccuracySec=10s

[Install]
WantedBy=timers.target
EOF

# --- DID counter housekeeping ---
# Per-DID daily counters are keyed by date, so they roll over at local
# midnight on their own — this timer does NOT reset anything and must never
# be made to. It only stops old day-families accumulating in the Asterisk
# database forever. A week of history is enough to answer "how much did that
# number carry on Tuesday" without turning astdb into an archive.
write_unit sbc-did-prune.service <<EOF
[Unit]
Description=Drop DID counter keys older than a week
After=asterisk.service

[Service]
Type=oneshot
ExecStart=$HERE/didctl.sh prune 7
EOF

write_unit sbc-did-prune.timer <<EOF
[Unit]
Description=Weekly DID counter housekeeping

[Timer]
OnCalendar=Sun 04:17
Persistent=true
AccuracySec=1h

[Install]
WantedBy=timers.target
EOF

# --- killswitch state restore ---
# Without this, a reboot while the killswitch is on would silently start
# accepting customer traffic again.
write_unit sbc-killswitch.service <<EOF
[Unit]
Description=Re-apply the SBC killswitch state after boot
After=asterisk.service nftables.service
Requires=asterisk.service

[Service]
Type=oneshot
RemainAfterExit=yes
# Asterisk needs a moment after the unit reports started before its CLI
# socket answers.
ExecStartPre=/bin/sleep 10
ExecStart=$HERE/killswitch.sh restore

[Install]
WantedBy=multi-user.target
EOF

if [[ "$DRY" == 0 ]]; then
  systemctl daemon-reload
  systemctl enable asterisk.service    >/dev/null 2>&1 || true
  systemctl enable nftables.service    >/dev/null 2>&1 || true
  systemctl enable sbc-healthcheck.timer >/dev/null 2>&1 || true
  systemctl enable sbc-did-prune.timer >/dev/null 2>&1 || true
  systemctl enable sbc-killswitch.service >/dev/null 2>&1 || true
  [[ -f /etc/systemd/system/sbc-siptrace.service ]] && \
    systemctl enable sbc-siptrace.service >/dev/null 2>&1 || true
  info "units enabled for boot"
fi

# ---------------------------------------------------------------------------
step "Firewall"
# ---------------------------------------------------------------------------
if [[ "$DO_FIREWALL" == 1 ]]; then
  if [[ "$DRY" == 0 ]]; then
    CONF="$CONF" "$HERE/firewall.sh" apply || die "firewall.sh failed — Asterisk config is in place but the box is NOT protected"
  else
    info "[dry-run] would run firewall.sh apply"
  fi
else
  echo "    WARNING: --no-firewall. This box is unprotected until you run" >&2
  echo "             sudo ./firewall.sh apply" >&2
fi

# ---------------------------------------------------------------------------
step "Starting Asterisk"
# ---------------------------------------------------------------------------
if [[ "$DRY" == 1 ]]; then
  info "[dry-run] would restart and validate asterisk"
  echo; echo "Dry run complete."; exit 0
fi

RESTART_MARK="$(date '+%F %T')"
sleep 1
systemctl restart asterisk || die "asterisk failed to start — journalctl -u asterisk -n 50"

for i in $(seq 1 30); do
  asterisk -rx "core show version" >/dev/null 2>&1 && break
  sleep 1
done
asterisk -rx "core show version" >/dev/null 2>&1 \
  || die "asterisk started but the CLI socket never came up"

sleep 4   # let the initial qualify round complete

# ---------------------------------------------------------------------------
step "Validation"
# ---------------------------------------------------------------------------
FAILED=0

# Acceptance criterion 2: zero errors and zero warnings on load.
LOGF=/var/log/asterisk/messages
PROBLEMS=""
if [[ -r "$LOGF" ]]; then
  PROBLEMS="$(awk -v mark="$RESTART_MARK" '
      substr($0,1,19) >= mark && (/WARNING/ || /ERROR/) { print }
    ' "$LOGF" | grep -v 'SBC-REJECT' || true)"
fi
if [[ -n "$PROBLEMS" ]]; then
  echo "    WARNINGS/ERRORS since restart:"
  sed 's/^/      /' <<< "$PROBLEMS"
  FAILED=1
else
  info "config loaded with zero warnings and zero errors"
fi

# Acceptance criterion 1: endpoints exist.
EP_OUT="$(asterisk -rx "pjsip show endpoints" 2>/dev/null)"
while read -r ep; do
  [[ -n "$ep" ]] || continue
  if grep -q "$ep" <<< "$EP_OUT"; then info "endpoint $ep present"
  else echo "    MISSING endpoint $ep" >&2; FAILED=1; fi
done <<< "$PK_EP_NAMES"
GWN="$(grep -c 'fractel' <<< "$EP_OUT" || true)"
info "fractel endpoint lines: $GWN"

# --- dialplan functions the DID logic depends on --------------------------
# The module denylist in render.sh removes every path to an external lookup —
# no func_curl, no func_odbc, no AGI — so DID rotation and the daily cap are
# built out of these five. A missing one does not stop Asterisk loading; it
# makes ${LOCK(...)} expand to nothing and the cap silently stop counting.
# Check for them explicitly rather than discovering it in a fraud alert.
for fn in LOCK TRYLOCK UNLOCK DB DIALPLAN_EXISTS CUT IF STRFTIME; do
  if asterisk -rx "core show function $fn" 2>/dev/null | grep -qi "$fn"; then
    :
  else
    echo "    MISSING dialplan function $fn" >&2
    case "$fn" in
      LOCK|TRYLOCK|UNLOCK)
        echo "      func_lock.so is not loaded. Without it the per-DID daily cap" >&2
        echo "      has no mutual exclusion and will undercount under load." >&2 ;;
      DB)
        echo "      func_db.so is not loaded. Daily counters cannot be stored at" >&2
        echo "      all and the cap will not enforce." >&2 ;;
      DIALPLAN_EXISTS)
        echo "      func_dialplan.so is not loaded. The high-cost prefix" >&2
        echo "      blocklist will never match anything." >&2 ;;
    esac
    FAILED=1
  fi
done

# --- DID pool actually reached the running dialplan -----------------------
# `dialplan show globals` indents its output, so these must strip leading
# whitespace before anchoring — otherwise validation reports zero pools on a
# box whose pools loaded perfectly.
GLOBALS="$(asterisk -rx "dialplan show globals" 2>/dev/null | sed 's/^[[:space:]]*//')"
POOLN="$(grep -c '^SBC_DID_POOL_' <<< "$GLOBALS" || true)"
OVF="$(awk -F'=' '/^SBC_DID_CNT_OVERFLOW=/{print $2}' <<< "$GLOBALS")"
if [[ "${POOLN:-0}" -lt 1 || -z "$OVF" ]]; then
  echo "    DID pool did not load into the dialplan — the SBC cannot assign caller ID" >&2
  FAILED=1
else
  info "DID pools loaded: $POOLN (overflow holds $OVF)"
fi

LRNN="$(asterisk -rx "dialplan show sbc-lrn-blocklist" 2>/dev/null | grep -c "'" || true)"
info "high-cost prefixes loaded: $(( LRNN > 0 ? LRNN - 1 : 0 ))"

echo
"$HERE/healthcheck.sh" || true

# ---------------------------------------------------------------------------
echo
echo "==========================================================================="
if [[ "$FAILED" == 0 ]]; then
  echo " SBC installed."
else
  echo " SBC installed, BUT validation reported problems above. Do not put"
  echo " customer traffic on this box until they are resolved."
fi
cat <<EOF
===========================================================================

  config      $CONF
  dids        ${DIDS_CSV:-dids.csv}         (the numbers this box asserts)
  blocklist   ${BLOCKLIST_CSV:-blocklist.csv}    (high-cost prefixes, from the rate deck)
  asterisk    $AST_ETC/*.conf   (rendered — edit the .tpl files, not these)
  cdr         $CDR_CSV_PATH
  sip traces  $SIP_TRACE_DIR
  backup      ${AST_ETC}.bak-${STAMP}

  Next:
    1. sudo $HERE/firewall.sh confirm      <- do this from a SECOND ssh session
    2. $HERE/didctl.sh pools               <- confirm the DID pools Asterisk loaded
    3. $HERE/monitor.sh
    4. $HERE/tests/run-acceptance.sh       <- see tests/README.md first
    5. Probe the firewall FROM ANOTHER MACHINE. The on-box test suite
       cannot see it. RUNBOOK.md has the nmap commands.

  Caller ID is assigned by this box. The customer's value is discarded on
  every call and recorded in the CDR. Confirm on the first live call that
  From, P-Asserted-Identity and Remote-Party-ID all carry one of your DIDs:

    $HERE/didctl.sh status
    grep SBC-DIAL /var/log/asterisk/messages | tail

  Regenerate the blocklist after every rate deck update:

    python3 $HERE/tools/build-blocklist.py --deck <ShortDuration.csv>
    sudo $HERE/install.sh --config-only

EOF
