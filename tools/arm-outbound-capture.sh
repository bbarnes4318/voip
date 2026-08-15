#!/usr/bin/env bash
#
# arm-outbound-capture.sh — settle one question the moment traffic returns:
# does the audio we relay toward the customer actually contain the carrier's
# speech, or are we forwarding silence?
#
#   ./arm-outbound-capture.sh            arm, wait for traffic, capture
#   ./arm-outbound-capture.sh --now      capture immediately
#
# WHY
# ---
# Everything measured so far looks clean and the customer still hears nothing:
#
#   inbound from FracTEL   REAL AUDIO, mean_rms 555-3869, decoded from payload
#   outbound to customer   tx>0 on 45 of 45 legs
#   customer RTCP          44 report blocks, fraction_lost=0/256 on every one
#
# Packet counters and RTCP cannot distinguish speech from silence: a relayed
# stream of G.711 silence produces identical counts, identical loss stats and
# an identical "we are transmitting" reading, and the far end hears dead air.
# If we forward silent packets the dialler hangs up at ~2.85s -- which is
# exactly what it does, and it would explain why disabling AMD changed nothing.
#
# So this captures BOTH directions in one window and decodes the payloads. The
# comparison is the answer: inbound loud and outbound at the silence floor
# means the bridge is the fault.
#
# It also snapshots the bridge while calls are up -- whether the legs are
# actually bridged, what technology, what codec each side negotiated, and
# whether anything is transcoding or holding.
#
# READ-ONLY. tcpdump and CLI reads only; it changes no configuration and
# touches neither Asterisk nor nftables state.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DECODER="$HERE/rtp-energy.py"
LOCAL_IP="${LOCAL_IP:-167.235.206.206}"
SECS="${SECS:-45}"
OUTDIR="${OUTDIR:-/var/log/asterisk/capture}"
MODE="arm"
RTP_LO=10000
RTP_HI=20000

B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; D=$'\033[2m'; N=$'\033[0m'
[[ -t 1 ]] || { B=""; G=""; Y=""; R=""; D=""; N=""; }
say() { echo "$(date -u '+%H:%M:%S') $*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --now)   MODE="now"; shift ;;
    --arm)   MODE="arm"; shift ;;
    --secs)  SECS="$2"; shift 2 ;;
    --ip)    LOCAL_IP="$2"; shift 2 ;;
    --out)   OUTDIR="$2"; shift 2 ;;
    -h|--help) sed -n '2,36p' "$0"; exit 0 ;;
    *) echo "unknown arg $1" >&2; exit 2 ;;
  esac
done

command -v tcpdump >/dev/null || { echo "tcpdump missing" >&2; exit 1; }
[[ -r "$DECODER" ]] || { echo "decoder not found: $DECODER" >&2; exit 1; }
mkdir -p "$OUTDIR"

RTP_LO="$(sed -n 's/^rtpstart=\([0-9]*\).*/\1/p' /etc/asterisk/rtp.conf 2>/dev/null | head -1)"
RTP_HI="$(sed -n 's/^rtpend=\([0-9]*\).*/\1/p'   /etc/asterisk/rtp.conf 2>/dev/null | head -1)"
RTP_LO="${RTP_LO:-10000}"; RTP_HI="${RTP_HI:-20000}"

echo
echo "${B}arm-outbound-capture${N}  mode=$MODE  window=${SECS}s  local=$LOCAL_IP  ports=${RTP_LO}-${RTP_HI}"
echo

# ---------------------------------------------------------------------------
# Arm: idle until a call actually goes up. Waiting on channels rather than on
# the log, because a captured window with no media in it proves nothing.
# ---------------------------------------------------------------------------
if [[ "$MODE" == "arm" ]]; then
  say "armed -- waiting for a live channel (nothing is being captured yet)"
  while :; do
    # "channel" not "channels": Asterisk prints "1 active channel" in the
    # singular, so a pattern anchored on the plural never matches a single
    # call and the capture sits armed straight through it. That is exactly
    # what happened on the first originate test.
    n="$(asterisk -rx 'core show channels' 2>/dev/null \
         | sed -n 's/^\([0-9]\{1,\}\) active channels\{0,1\}.*/\1/p' | head -1)"
    [[ "${n:-0}" -gt 0 ]] && { say "${G}traffic detected (${n} channels)${N}"; break; }
    sleep 2
  done
fi

STAMP="$(date -u '+%Y%m%dT%H%M%SZ')"
PCAP="$OUTDIR/both-$STAMP.pcap"
BRIDGE="$OUTDIR/bridge-$STAMP.txt"
REPORT="$OUTDIR/energy-$STAMP.txt"

say "capturing BOTH directions for ${SECS}s -> $PCAP"
timeout "$SECS" tcpdump -i any -nn -s 250 -w "$PCAP" \
  "udp and portrange ${RTP_LO}-${RTP_HI}" >/dev/null 2>&1 &
TD=$!

# ---------------------------------------------------------------------------
# Bridge state, sampled while the capture runs. The question is not only
# whether audio flows but whether the two legs are joined at all.
# ---------------------------------------------------------------------------
{
  echo "=== bridge snapshot $STAMP ==="
  for i in 1 2 3; do
    echo "--- sample $i ---"
    echo "[channels]";      asterisk -rx "core show channels"      2>/dev/null | tail -20
    echo "[bridges]";       asterisk -rx "bridge show all"         2>/dev/null | head -20
    echo "[channelstats]";  asterisk -rx "pjsip show channelstats" 2>/dev/null | head -20
    ch="$(asterisk -rx 'core show channels concise' 2>/dev/null | head -1 | cut -d! -f1)"
    if [[ -n "$ch" ]]; then
      echo "[detail $ch]"
      asterisk -rx "core show channel $ch" 2>/dev/null \
        | grep -iE 'NativeFormats|WriteFormat|ReadFormat|Writetrans|Readtrans|BridgeID|State|Application'
    fi
    sleep $(( SECS / 4 ))
  done
} > "$BRIDGE" 2>&1

wait $TD 2>/dev/null
say "capture complete: $(du -h "$PCAP" 2>/dev/null | cut -f1)"
echo

python3 "$DECODER" "$PCAP" --local "$LOCAL_IP" --top 12 | tee "$REPORT"

echo
echo "${B}bridge / transcode summary${N}"
grep -iE 'Writetrans|Readtrans' "$BRIDGE" | sort | uniq -c | sed 's/^/  /' \
  || echo "  (no translation lines captured)"
grep -icE 'native_rtp|simple_bridge' "$BRIDGE" >/dev/null && {
  echo "  bridge technologies seen:"
  grep -oiE 'native_rtp|simple_bridge|holding_bridge|softmix' "$BRIDGE" \
    | sort | uniq -c | sed 's/^/    /'
}
echo
echo "  pcap   : $PCAP"
echo "  bridge : $BRIDGE"
echo "  report : $REPORT"
