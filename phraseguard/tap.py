#!/usr/bin/env python3
"""Passive capture, SIP/SDP correlation and RTP demux for PhraseGuard.

OUT OF BAND, AND THAT IS THE WHOLE DESIGN
-----------------------------------------
Nothing here is in the call path. There is no ARI, no Stasis, no MixMonitor,
no dialplan change, and no Asterisk configuration of any kind. This is libpcap
on the wire via tcpdump, exactly like tools/arm-outbound-capture.sh, which is
already validated on this box. If this process dies, calls carry on -- the
kernel does not notice that nobody is reading the capture socket any more.

That is not a stylistic preference. Every dialplan change on this box is on
the caller-ID path for 100% of calls, and the box has a documented history of
config changes taking it down. A monitoring problem must not become a voice
problem.

WHAT IT DOES
------------
  1. tcpdump on the RTP port range plus 5060, both directions, to a PIPE.
  2. SIP is parsed out of the same capture: Call-ID, the customer's source IP
     from the INVITE, ANI and DNIS, and the SDP m=audio ports on both sides.
     That is what maps an RTP 5-tuple back to a call.
  3. RTP is grouped by 5-tuple + SSRC into per-stream ring buffers.
  4. Everything that is not the CUSTOMER leg is dropped before it costs
     anything. The customer leg carries the agent's speech, which is the only
     thing worth classifying.
  5. The customer leg is gated on real speech energy -- the RMS logic from
     tools/rtp-energy.py, unchanged -- so a stream has to carry several
     seconds of actual audio before a recogniser is ever handed a sample.

Steps 4 and 5 are the volume story. Historically only a small minority of
customer legs transmit RTP at all, because most calls never reach a live
agent, and of those that do, a further slice is silence or comfort noise. Both
filters are free relative to ASR, which is not.

NO AUDIO RETENTION
------------------
tcpdump writes to a pipe. There is no code path in this file that writes a
capture, a WAV, or a PCM buffer to disk, and there is deliberately no option
to add one. Decoded audio lives in a bounded in-memory ring and is discarded
as it is consumed. --pcap exists to replay a capture somebody else made
(the test fixtures, or an incident capture); it reads, never writes.

  ./tap.py --report                 live, print stream statistics, no ASR
  ./tap.py --pcap FILE --report     the same against a saved capture
"""
import collections
import math
import select
import os
import struct
import subprocess
import sys
import time

# ---------------------------------------------------------------------------
# G.711 decode tables. Lifted verbatim from tools/rtp-energy.py so that the
# RMS numbers this file produces are directly comparable to the ones already
# measured on this box (speech 555-3869, silence 0-20, comfort noise 50-150).
# If these two ever disagree, the thresholds below become meaningless.
# ---------------------------------------------------------------------------
_ULAW = []
for _u in range(256):
    _v = ~_u & 0xFF
    _sign = _v & 0x80
    _exp = (_v >> 4) & 0x07
    _man = _v & 0x0F
    _s = (((_man << 3) + 0x84) << _exp) - 0x84
    _ULAW.append(-_s if _sign else _s)

_ALAW = []
for _a in range(256):
    _v = _a ^ 0x55
    _sign = _v & 0x80
    _exp = (_v >> 4) & 0x07
    _man = _v & 0x0F
    if _exp:
        _s = ((_man << 4) + 0x108) << (_exp - 1)
    else:
        _s = (_man << 4) + 8
    _ALAW.append(-_s if _sign else _s)

# Pre-rendered little-endian PCM16 for each codepoint. Decoding a 160-byte
# G.711 frame then becomes a table join and a bytes concat rather than 160
# struct.pack calls, which matters when this runs on every packet of every
# concurrent stream.
_ULAW_PCM = [struct.pack("<h", v) for v in _ULAW]
_ALAW_PCM = [struct.pack("<h", v) for v in _ALAW]

SAMPLE_RATE = 8000
BYTES_PER_SAMPLE = 2


def decode_g711(payload, alaw=False):
    """G.711 payload -> little-endian PCM16 bytes."""
    tbl = _ALAW_PCM if alaw else _ULAW_PCM
    return b"".join([tbl[b] for b in payload])


def rms_g711(payload, alaw=False):
    """RMS of a G.711 payload in linear PCM units, without materialising it."""
    if not payload:
        return 0.0
    tbl = _ALAW if alaw else _ULAW
    t = 0
    for b in payload:
        v = tbl[b]
        t += v * v
    return math.sqrt(t / len(payload))


# ---------------------------------------------------------------------------
# pcap reading, from a stream rather than from a file
# ---------------------------------------------------------------------------
# tools/rtp-energy.py reads a complete file. This has to work against a pipe
# that never ends, so it reads incrementally and yields as it goes. Same
# link-layer handling: 113 LINUX_SLL, 276 LINUX_SLL2 (what `tcpdump -i any`
# produces on Ubuntu 24.04), 1 EN10MB.
LINKTYPES = {113: 16, 276: 20, 1: 14}


class PcapError(Exception):
    pass


def _read_exact(fh, n, stop=None):
    """Read exactly n bytes. None at clean EOF, or when stop() goes True.

    select() with a short timeout rather than a bare blocking read, so a caller
    with a deadline is not held hostage by a quiet wire. Without this,
    `tap.py --report --seconds 60` on a trunk with no customer-leg RTP blocked
    forever on the very first read and printed nothing at all -- the deadline
    was only ever checked between packets that never came.
    """
    buf = b""
    try:
        fd = fh.fileno()
    except Exception:                                  # noqa: BLE001
        fd = None
    while len(buf) < n:
        if stop is not None and stop():
            return None
        if fd is not None:
            r, _w, _x = select.select([fd], [], [], 0.5)
            if not r:
                continue
        chunk = fh.read(n - len(buf))
        if not chunk:
            return None
        buf += chunk
    return buf


class CaptureFailed(PcapError):
    """The capture never produced a pcap header -- tcpdump did not start."""


def _chain_first(first, rest):
    """Yield a packet already pulled off a generator, then the remainder.

    Tap.run has to consume one packet to tell "tcpdump started and is waiting
    for traffic" from "tcpdump died", and that packet still has to be
    processed. On a quiet trunk this blocks until the first packet arrives,
    which is correct: a tap with nothing to read is not a failure.
    """
    yield first
    for pkt in rest:
        yield pkt


def read_pcap_stream(fh, stop=None):
    """Yield (ts, src, sport, dst, dport, payload) for every UDP packet."""
    gh = _read_exact(fh, 24, stop)
    if gh is None:
        # EOF before even the 24-byte global header. tcpdump exited instead of
        # capturing. Returning quietly here made the daemon look like a clean
        # end-of-capture: it logged start, then stop, exited 0, and systemd
        # reported "Deactivated successfully" with nothing anywhere saying why.
        # A capture that never started is a startup failure and has to say so.
        raise CaptureFailed("capture produced no pcap header")
    magic = struct.unpack("<I", gh[:4])[0]
    if magic == 0xA1B2C3D4:
        e = "<"
    elif magic == 0xD4C3B2A1:
        e = ">"
    else:
        raise PcapError("not a pcap stream: magic %08x" % magic)
    link = struct.unpack(e + "I", gh[20:24])[0]
    if link not in LINKTYPES:
        raise PcapError("unsupported link type %d" % link)
    off0 = LINKTYPES[link]

    while True:
        ph = _read_exact(fh, 16, stop)
        if ph is None:
            return
        _ts, tus, incl, _orig = struct.unpack(e + "IIII", ph)
        data = _read_exact(fh, incl, stop)
        if data is None:
            return
        if len(data) < off0 + 20:
            continue
        if link == 113:
            proto = struct.unpack("!H", data[14:16])[0]
        elif link == 276:
            proto = struct.unpack("!H", data[0:2])[0]
        else:
            proto = struct.unpack("!H", data[12:14])[0]
        if proto != 0x0800:
            continue
        off = off0
        ihl = (data[off] & 0x0F) * 4
        if data[off + 9] != 17:                        # UDP only
            continue
        src = "%d.%d.%d.%d" % tuple(data[off + 12:off + 16])
        dst = "%d.%d.%d.%d" % tuple(data[off + 16:off + 20])
        u = off + ihl
        if len(data) < u + 8:
            continue
        sp, dp = struct.unpack("!HH", data[u:u + 4])
        yield _ts + tus / 1e6, src, sp, dst, dp, data[u + 8:]


# ---------------------------------------------------------------------------
# SIP / SDP
# ---------------------------------------------------------------------------
class CallInfo(object):
    __slots__ = ("call_id", "customer_ip", "ani", "dnis", "started",
                 "answered", "ended", "customer_media", "sbc_media",
                 "invite_seen", "streams")

    def __init__(self, call_id, ts):
        self.call_id = call_id
        self.customer_ip = None
        self.ani = None
        self.dnis = None
        self.started = ts
        self.answered = None
        self.ended = None
        self.customer_media = None     # (ip, port) the customer advertised
        self.sbc_media = None          # (ip, port) we advertised back
        self.invite_seen = False
        self.streams = set()

    def __repr__(self):
        return "<Call %s %s %s->%s>" % (self.call_id[:16], self.customer_ip,
                                        self.ani, self.dnis)


class SipTracker(object):
    """Call-ID -> CallInfo, and (ip, port) -> Call-ID for RTP attribution.

    Only the CUSTOMER dialog is of interest. The SBC is a B2BUA, so one call is
    two dialogs with different Call-IDs; the carrier-side dialog carries the
    consumer's audio, not the agent's, and is dropped here rather than
    downstream. Legs are told apart by peer address, the same way
    tools/capture-parse.py does it -- anything whose signalling peer is a
    customer IP is the customer leg.
    """

    def __init__(self, customer_ips, expiry_s=7200):
        self.customer_ips = frozenset(customer_ips)
        self.expiry_s = expiry_s
        self.calls = {}
        self.by_media = {}
        self.stats = collections.Counter()
        self._last_gc = 0.0

    @staticmethod
    def _header(text, name):
        """Fetch a header, tolerating the compact form and folded lines."""
        low = name.lower()
        want = low + ":"
        short = None
        if low == "call-id":
            short = "i:"
        elif low == "from":
            short = "f:"
        elif low == "to":
            short = "t:"
        out = None
        for line in text.split("\n"):
            s = line.strip()
            sl = s.lower()
            if sl.startswith(want):
                out = s[len(want):].strip()
                break
            if short and sl.startswith(short):
                out = s[len(short):].strip()
                break
        return out

    @staticmethod
    def _user(uri):
        """sip:15551234567@host;tag=... -> 15551234567"""
        if not uri:
            return None
        s = uri
        if "<" in s:
            s = s[s.index("<") + 1:]
            if ">" in s:
                s = s[:s.index(">")]
        if ":" in s:
            s = s.split(":", 1)[1]
        if "@" in s:
            s = s.split("@", 1)[0]
        s = s.split(";", 1)[0].strip()
        return s or None

    @staticmethod
    def _sdp_audio(text):
        """(connection_ip, audio_port) from an SDP body, or None."""
        ip = None
        port = None
        for line in text.split("\n"):
            s = line.strip()
            if s.startswith("c=IN IP4 "):
                ip = s[9:].split("/")[0].strip() or None
            elif s.startswith("m=audio "):
                parts = s.split()
                if len(parts) >= 2 and parts[1].isdigit():
                    port = int(parts[1])
        if port:
            return (ip, port)
        return None

    def feed(self, ts, src, _sport, dst, _dport, payload):
        """Parse one SIP datagram. Returns the CallInfo it touched, or None."""
        try:
            text = payload.decode("utf-8", "replace")
        except Exception:                              # noqa: BLE001
            return None
        if "Call-ID" not in text and "\ni:" not in text and not text.startswith("i:"):
            return None
        call_id = self._header(text, "Call-ID")
        if not call_id:
            return None

        first = text.split("\n", 1)[0].strip()
        is_request = not first.startswith("SIP/2.0")
        method = first.split(" ", 1)[0].upper() if is_request else None
        code = None
        if not is_request:
            bits = first.split()
            if len(bits) >= 2 and bits[1].isdigit():
                code = int(bits[1])

        from_customer = src in self.customer_ips
        to_customer = dst in self.customer_ips
        if not (from_customer or to_customer):
            self.stats["sip_not_customer"] += 1
            return None

        call = self.calls.get(call_id)
        if call is None:
            if method != "INVITE":
                # Mid-dialog message for a call that started before we did.
                # Nothing to attribute it to, and inventing a CallInfo without
                # an INVITE means a record with no customer IP, no ANI and no
                # DNIS -- which is exactly the record that is useless later.
                self.stats["sip_orphan"] += 1
                return None
            call = CallInfo(call_id, ts)
            self.calls[call_id] = call
            self.stats["calls_seen"] += 1

        if method == "INVITE" and not call.invite_seen:
            call.invite_seen = True
            call.customer_ip = src if from_customer else dst
            call.ani = self._user(self._header(text, "From"))
            call.dnis = self._user(first.split(" ")[1] if " " in first else "")
            if not call.dnis:
                call.dnis = self._user(self._header(text, "To"))

        body = text.split("\n\n", 1)[-1] if "\n\n" in text else \
            (text.split("\r\n\r\n", 1)[-1] if "\r\n\r\n" in text else "")
        if "m=audio" in body:
            media = self._sdp_audio(body)
            if media:
                ip, port = media
                if ip is None:
                    ip = src
                if from_customer:
                    call.customer_media = (ip, port)
                else:
                    # Our own answer toward the customer. This is the port the
                    # customer's RTP is addressed TO, and it is the more
                    # reliable of the two keys: rtp_symmetric plus probation
                    # means the customer's SOURCE port can differ from what
                    # they advertised, but the destination cannot.
                    call.sbc_media = (ip, port)
                self.by_media[(ip, port)] = call_id

        if code == 200 and call.answered is None and call.invite_seen:
            call.answered = ts
        if method == "BYE" or (code and 400 <= code < 700):
            if call.ended is None:
                call.ended = ts
                self.stats["calls_ended"] += 1

        self._gc(ts)
        return call

    def call_for_media(self, ip, port):
        cid = self.by_media.get((ip, port))
        return self.calls.get(cid) if cid else None

    def _gc(self, now):
        """Expire finished calls. Bounded memory is a correctness property on
        a daemon expected to run for weeks between deploys."""
        if now - self._last_gc < 60:
            return
        self._last_gc = now
        dead = [cid for cid, c in self.calls.items()
                if (c.ended and now - c.ended > 120)
                or now - c.started > self.expiry_s]
        for cid in dead:
            c = self.calls.pop(cid, None)
            if c:
                for key in (c.customer_media, c.sbc_media):
                    if key and self.by_media.get(key) == cid:
                        self.by_media.pop(key, None)


# ---------------------------------------------------------------------------
# RTP demux
# ---------------------------------------------------------------------------
class Stream(object):
    """One RTP stream: 5-tuple + SSRC, with a bounded PCM ring behind it."""
    __slots__ = ("key", "ssrc", "call_id", "codec_alaw", "packets", "first_ts",
                 "last_ts", "voiced_packets", "voiced_seconds", "gate_open",
                 "pcm", "pcm_dropped", "rms_sum", "rms_n", "closed")

    def __init__(self, key, ssrc, ts):
        self.key = key
        self.ssrc = ssrc
        self.call_id = None
        self.codec_alaw = False
        self.packets = 0
        self.first_ts = ts
        self.last_ts = ts
        self.voiced_packets = 0
        self.voiced_seconds = 0.0
        self.gate_open = False
        self.pcm = bytearray()
        self.pcm_dropped = 0
        self.rms_sum = 0.0
        self.rms_n = 0
        self.closed = False

    @property
    def mean_rms(self):
        return self.rms_sum / self.rms_n if self.rms_n else 0.0

    def take_pcm(self):
        """Hand off everything buffered and forget it. Audio is never kept."""
        out = bytes(self.pcm)
        del self.pcm[:]
        return out


class RtpDemux(object):
    """Group RTP into per-stream ring buffers, filtered and energy-gated.

    THE TWO FILTERS, in the order they are cheapest:

    customer-leg  Only RTP whose SOURCE is one of the customer's addresses is
                  considered at all. That leg carries the agent's speech. The
                  carrier leg carries the consumer's, which is not what needs
                  classifying, and dropping it here halves the packet volume
                  before anything decodes a byte.

    energy gate   A stream must accumulate GATE_SECONDS of genuinely non-silent
                  audio before any of it reaches a recogniser. The thresholds
                  are the ones already measured on this box: silence reads
                  0-20, comfort noise 50-150 and is FLAT, speech 555-3869. The
                  gate sits at 200, comfortably above comfort noise and well
                  below the bottom of the speech range.

    Media addresses are matched against the customer's SIGNALLING addresses
    plus PK_CLIENT_MEDIA_EXTRA, because config.env is explicit that the two
    can differ and the firewall already treats them as separate lists.
    """

    def __init__(self, media_ips, gate_rms=200.0, gate_seconds=5.0,
                 ring_seconds=10.0, idle_timeout=30.0):
        self.media_ips = frozenset(media_ips)
        self.gate_rms = gate_rms
        self.gate_seconds = gate_seconds
        self.ring_bytes = int(ring_seconds * SAMPLE_RATE * BYTES_PER_SAMPLE)
        self.idle_timeout = idle_timeout
        self.streams = {}
        self.stats = collections.Counter()
        self._last_gc = 0.0

    def feed(self, ts, src, sport, dst, dport, payload, tracker=None):
        """Parse one RTP datagram. Returns the Stream if its gate is open."""
        # GC FIRST, not last. Every filter below returns early, and the
        # below-gate return is the MAJORITY path by design -- the class
        # docstring says so. With the sweep at the end of the method it ran
        # only for packets on streams that had already opened their gate, so
        # the silent streams, which are most of them, were never expired and
        # self.streams grew for the life of the daemon. It also pinned
        # phraseguardd's per-stream Vosk recognisers, which are pruned against
        # this dict.
        self._gc(ts)
        if len(payload) < 13:
            return None
        if (payload[0] >> 6) != 2:                     # not RTP v2
            return None
        # RTCP shares the port range (odd ports) and has the same version
        # bits, so it reaches here. Counting it as "non-G.711" would put tens
        # of thousands of packets into a bucket whose whole purpose is to say
        # whether the customer is sending a codec we cannot decode.
        if 200 <= payload[1] <= 204:
            self.stats["rtcp"] += 1
            return None
        pt = payload[1] & 0x7F
        if pt not in (0, 8):                           # PCMU / PCMA only
            self.stats["rtp_other_codec"] += 1
            return None

        if src not in self.media_ips:
            # The carrier leg and our own outbound. Counted, not decoded.
            self.stats["rtp_not_customer"] += 1
            return None

        cc = payload[0] & 0x0F
        ext = (payload[0] >> 4) & 0x01
        hdr = 12 + cc * 4
        if ext:
            if len(payload) < hdr + 4:
                return None
            hdr += 4 + 4 * struct.unpack("!H", payload[hdr + 2:hdr + 4])[0]
        if len(payload) <= hdr:
            return None
        audio = payload[hdr:]

        ssrc = struct.unpack("!I", payload[8:12])[0]
        key = (src, sport, dst, dport, ssrc)
        st = self.streams.get(key)
        if st is None:
            st = Stream(key, ssrc, ts)
            st.codec_alaw = (pt == 8)
            self.streams[key] = st
            self.stats["streams_customer"] += 1

        # Attribution is RETRIED until it succeeds, not attempted once at
        # stream creation. RTP routinely beats the SDP answer through the
        # pipe -- early media, reordering, a dropped SIP datagram -- and a
        # stream that missed its one chance stayed unattributable for the
        # whole call: no Call-ID means no channel, so no hangup is possible
        # even when enforcing, and a null customer IP means every kill and
        # near-miss on that call is silently dropped from the per-customer
        # counters, which are the point of the component.
        if st.call_id is None and tracker is not None:
            # The destination is OUR port, from the SDP we answered with.
            # Try it first: symmetric RTP and probation mean the source
            # port can drift from what the customer advertised.
            call = (tracker.call_for_media(dst, dport)
                    or tracker.call_for_media(src, sport))
            if call is not None:
                st.call_id = call.call_id
                call.streams.add(key)
                self.stats["streams_attributed"] += 1
            elif st.packets == 0:
                self.stats["streams_unattributed"] += 1

        st.packets += 1
        st.last_ts = ts

        r = rms_g711(audio, st.codec_alaw)
        st.rms_sum += r
        st.rms_n += 1
        frame_s = (len(audio) / float(SAMPLE_RATE))
        if r >= self.gate_rms:
            st.voiced_packets += 1
            st.voiced_seconds += frame_s

        if not st.gate_open:
            if st.voiced_seconds < self.gate_seconds:
                self.stats["rtp_below_gate"] += 1
                return None
            st.gate_open = True
            self.stats["streams_gate_opened"] += 1

        st.pcm += decode_g711(audio, st.codec_alaw)
        if len(st.pcm) > self.ring_bytes:
            # The consumer is not keeping up. Drop the OLDEST audio: a
            # recogniser fed stale speech reports a phrase against the wrong
            # part of the call, and the +/-10 word context in the record then
            # describes audio nobody said. Losing the tail is the honest
            # failure; misattributing it is not.
            over = len(st.pcm) - self.ring_bytes
            del st.pcm[:over]
            st.pcm_dropped += over
            self.stats["pcm_dropped_bytes"] += over
        self._gc(ts)
        return st

    def _gc(self, now):
        if now - self._last_gc < 30:
            return
        self._last_gc = now
        dead = [k for k, s in self.streams.items()
                if now - s.last_ts > self.idle_timeout]
        for k in dead:
            s = self.streams.pop(k)
            s.closed = True
            self.stats["streams_closed"] += 1


# ---------------------------------------------------------------------------
# The tap itself
# ---------------------------------------------------------------------------
class Tap(object):
    """tcpdump -> pcap stream -> SIP tracker + RTP demux.

    tcpdump rather than a raw AF_PACKET socket in Python: it is what the rest
    of tools/ already uses on this box, it drops privileges and applies the BPF
    filter in the kernel (so uninteresting packets never cross into userspace),
    and its buffering behaviour under load is a known quantity. The filter is
    compiled once by the kernel; the Python below only ever sees UDP that
    already matched.
    """

    def __init__(self, customer_ips, media_ips=None, rtp_lo=10000, rtp_hi=20000,
                 iface="any", snaplen=0, pcap_path=None, demux=None,
                 tracker=None):
        self.customer_ips = list(customer_ips)
        self.media_ips = list(media_ips or customer_ips)
        self.rtp_lo = rtp_lo
        self.rtp_hi = rtp_hi
        self.iface = iface
        self.snaplen = snaplen
        self.pcap_path = pcap_path
        self.proc = None
        self.tracker = tracker or SipTracker(self.customer_ips)
        self.demux = demux or RtpDemux(self.media_ips)
        self.stats = collections.Counter()

    def bpf(self):
        return "udp and (portrange %d-%d or port 5060)" % (self.rtp_lo, self.rtp_hi)

    def _open(self):
        if self.pcap_path:
            return open(self.pcap_path, "rb"), None
        # -Z root: Ubuntu's tcpdump drops privileges to the "tcpdump" user and
        # chroots to /var/lib/tcpdump as soon as the capture socket is open.
        # Under this unit's ProtectSystem=strict sandbox that directory is not
        # writable, so tcpdump exits immediately and the daemon sees an empty
        # stream. We are already root and staying root is what the capture
        # needs; -Z root tells it not to try.
        cmd = ["tcpdump", "-i", self.iface, "-nn", "-s", str(self.snaplen),
               "-U", "-Z", "root", "-w", "-", self.bpf()]
        # -w - is stdout, a PIPE. There is no filesystem path in this command
        # and there must never be one: the no-audio-retention rule is enforced
        # by there being nowhere for audio to land, not by remembering to
        # delete it afterwards.
        # Keep stderr. Discarding it is why a failed capture was undiagnosable:
        # tcpdump explains itself perfectly well on stderr and we were throwing
        # that away, leaving "started, then stopped" and nothing else.
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, bufsize=0)
        return proc.stdout, proc

    def capture_error(self):
        """Whatever tcpdump said before it died, trimmed to one line."""
        if self.proc is None or self.proc.stderr is None:
            return ""
        try:
            err = self.proc.stderr.read(4096).decode("utf-8", "replace")
        except Exception:                              # noqa: BLE001
            return ""
        lines = [l.strip() for l in err.split("\n") if l.strip()]
        return "; ".join(lines[:3])

    def _iter(self, fh, stop):
        """read_pcap_stream, with tcpdump's own stderr attached to a failure."""
        try:
            for pkt in read_pcap_stream(fh, stop):
                yield pkt
        except CaptureFailed as e:
            detail = self.capture_error()
            raise CaptureFailed(
                "%s. tcpdump: %s" % (e, detail or "(no output on stderr)"))

    def run(self, on_audio=None, on_packet=None, stop=None):
        """Read until EOF or `stop()` returns True.

        on_audio(stream, pcm_bytes, call) is called for gated customer audio.
        Exceptions raised by it are swallowed and counted: a recogniser fault
        must not stop the tap, and the tap stopping must not stop calls.
        """
        fh, proc = self._open()
        self.proc = proc
        try:
            # The try must wrap the ITERATION, not the call. read_pcap_stream
            # is a generator: calling it only builds the object, and the
            # CaptureFailed fires on the first next(). Wrapping the call alone
            # produced the right exit code with tcpdump's own message missing,
            # which is most of what makes the error worth having.
            for pkt in self._iter(fh, stop):
                if stop is not None and stop():
                    break
                ts, src, sport, dst, dport, payload = pkt
                self.stats["packets"] += 1
                if on_packet is not None:
                    on_packet(*pkt)
                if sport == 5060 or dport == 5060:
                    self.stats["sip"] += 1
                    try:
                        self.tracker.feed(ts, src, sport, dst, dport, payload)
                    except Exception:                  # noqa: BLE001
                        self.stats["sip_errors"] += 1
                    continue
                if not (self.rtp_lo <= dport <= self.rtp_hi):
                    continue
                self.stats["rtp"] += 1
                try:
                    st = self.demux.feed(ts, src, sport, dst, dport, payload,
                                         self.tracker)
                except Exception:                      # noqa: BLE001
                    self.stats["rtp_errors"] += 1
                    continue
                if st is None or on_audio is None:
                    continue
                pcm = st.take_pcm()
                if not pcm:
                    continue
                call = self.tracker.calls.get(st.call_id) if st.call_id else None
                try:
                    on_audio(st, pcm, call)
                except Exception:                      # noqa: BLE001
                    self.stats["asr_errors"] += 1
                if stop is not None and stop():
                    break
            # Ran out of packets. Distinguish a quiet wire from a dead capture:
            # a tcpdump still running has simply seen nothing, which on a trunk
            # whose calls mostly never carry audio is the expected answer, not
            # an error. A tcpdump that has EXITED is a failure and says why.
            if self.stats["packets"] == 0 and self.proc is not None:
                if self.proc.poll() is not None:
                    raise CaptureFailed(
                        "tcpdump exited without capturing anything. tcpdump: %s"
                        % (self.capture_error() or "(no output on stderr)"))
        finally:
            self.close()

    def close(self):
        if self.proc is not None:
            try:
                self.proc.terminate()
                self.proc.wait(timeout=5)
            except Exception:                          # noqa: BLE001
                try:
                    self.proc.kill()
                except Exception:                      # noqa: BLE001
                    pass
            self.proc = None


# ---------------------------------------------------------------------------
# --report: the phase 2 deliverable, standalone
# ---------------------------------------------------------------------------
def _report(tap, elapsed=0.0):
    """Print stream counts and how many calls carried customer-leg speech.

    Reporting is deliberately separate from running: the caller has to be able
    to print a report after a Ctrl-C, and a _report() that also ran the tap
    would restart the capture on a torn-down tcpdump to do it.
    """
    tr, dm = tap.tracker, tap.demux
    calls = list(tr.calls.values())
    answered = [c for c in calls if c.answered]
    with_stream = [c for c in calls if c.streams]
    # Live streams only tell you what is up RIGHT NOW: _gc expires a stream
    # 30s after it goes idle, and SipTracker drops a call 120s after the BYE.
    # Counting gated calls out of the live dict therefore undercounts any run
    # longer than the idle timeout -- and this is the number that sizes the
    # ASR fleet, so undercounting it under-provisions the recogniser pool.
    # The cumulative counters are the honest source.
    gated_now = {st.call_id for st in dm.streams.values()
                 if st.gate_open and st.call_id}
    gated_total = dm.stats["streams_gate_opened"]

    def pct(a, b):
        return "%5.1f%%" % (100.0 * a / b) if b else "    n/a"

    print()
    print("=" * 74)
    print("PHRASEGUARD TAP REPORT   %s"
          % (tap.pcap_path or "live %.0fs on %s" % (elapsed, tap.iface)))
    print("=" * 74)
    print("  bpf filter            %s" % tap.bpf())
    print()
    print("  packets seen          %d" % tap.stats["packets"])
    print("    SIP                 %d" % tap.stats["sip"])
    print("    RTP in range        %d" % tap.stats["rtp"])
    print("      customer leg      %d" % (tap.stats["rtp"]
                                          - dm.stats["rtp_not_customer"]
                                          - dm.stats["rtp_other_codec"]
                                          - dm.stats["rtcp"]))
    print("      other leg (drop)  %d" % dm.stats["rtp_not_customer"])
    print("      non-G.711 (drop)  %d" % dm.stats["rtp_other_codec"])
    print("      RTCP (drop)       %d" % dm.stats["rtcp"])
    print()
    print("  calls seen            %d   (live in the tracker; finished calls" % len(calls))
    print("                             are expired 120s after the BYE)")
    print("  calls answered (200)  %d   %s" % (len(answered), pct(len(answered), len(calls))))
    print("  calls w/ customer RTP %d   %s" % (len(with_stream), pct(len(with_stream), len(calls))))
    print("  streams past RMS gate %d   cumulative, %d still live"
          % (gated_total, len(gated_now)))
    print()
    print("  customer streams      %d" % dm.stats["streams_customer"])
    print("    attributed to call  %d" % dm.stats["streams_attributed"])
    print("    UNATTRIBUTED        %d" % dm.stats["streams_unattributed"])
    print("    gate opened         %d" % dm.stats["streams_gate_opened"])
    print()
    print("  THE NUMBER THAT SIZES THE ASR FLEET is 'streams past RMS gate'.")
    print("  Everything else is filtered before a recogniser is involved.")
    if dm.stats["streams_unattributed"]:
        print()
        print("  WARNING: %d customer stream(s) could not be mapped to a Call-ID."
              % dm.stats["streams_unattributed"])
        print("  Those can be transcribed but NOT acted on -- with no Call-ID")
        print("  there is no channel to hang up and no call to attribute. If")
        print("  this is more than a rounding error, the SDP correlation needs")
        print("  looking at before enforcement is considered.")
    if dm.streams:
        print()
        print("  %-46s %7s %8s %6s" % ("stream", "pkts", "mean_rms", "gate"))
        rows = sorted(dm.streams.values(), key=lambda s: -s.packets)[:15]
        for s in rows:
            src, sp, dst, dp, ssrc = s.key
            print("  %-46s %7d %8.0f %6s"
                  % ("%s:%d -> %s:%d ssrc=%08x" % (src, sp, dst, dp, ssrc),
                     s.packets, s.mean_rms, "open" if s.gate_open else "shut"))
    print()


def _read_config(path):
    """KEY=VALUE out of a config.env. Never executes it, never raises.

    Deliberately not a shell source: config.env holds live credentials on a
    border element and a diagnostic has no business executing it.
    """
    out = {}
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            for raw in fh:
                line = raw.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                out[k.strip()] = v.strip().strip('"').strip("'")
    except OSError:
        pass
    return out


def main(argv=None):
    import argparse
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--pcap", help="replay a saved capture instead of tapping live")
    ap.add_argument("--iface", default="any")
    ap.add_argument("--customer-ips", default="",
                    help="comma-separated; defaults to PK_CLIENT_IPS from the "
                         "environment or from --config")
    ap.add_argument("--config", default="/opt/sbc/config.env",
                    help="config.env to read PK_CLIENT_IPS and the RTP range "
                         "from when they are not in the environment")
    ap.add_argument("--media-extra", default=os.environ.get("PK_CLIENT_MEDIA_EXTRA", ""))
    ap.add_argument("--rtp-lo", type=int, default=int(os.environ.get("RTP_START", 10000)))
    ap.add_argument("--rtp-hi", type=int, default=int(os.environ.get("RTP_END", 20000)))
    ap.add_argument("--gate-rms", type=float, default=200.0)
    ap.add_argument("--gate-seconds", type=float, default=5.0)
    ap.add_argument("--seconds", type=int, default=60, help="0 = until EOF/Ctrl-C")
    ap.add_argument("--report", action="store_true")
    a = ap.parse_args(argv)

    # config.env is where every other script on this box gets these. Requiring
    # the operator to retype three IP addresses to run a diagnostic is how a
    # diagnostic stops being run -- the first live attempt at --report died on
    # exactly that.
    cfg = _read_config(a.config)
    if not a.customer_ips:
        a.customer_ips = os.environ.get("PK_CLIENT_IPS") or cfg.get("PK_CLIENT_IPS", "")
    if not a.media_extra:
        a.media_extra = (os.environ.get("PK_CLIENT_MEDIA_EXTRA")
                         or cfg.get("PK_CLIENT_MEDIA_EXTRA", ""))
    for name, attr, default in (("RTP_START", "rtp_lo", 10000),
                                ("RTP_END", "rtp_hi", 20000)):
        if getattr(a, attr) == default and cfg.get(name):
            try:
                setattr(a, attr, int(cfg[name]))
            except ValueError:
                pass

    cust = [x.strip() for x in a.customer_ips.replace(",", " ").split() if x.strip()]
    if not cust:
        sys.stderr.write(
            "tap.py: no customer IPs. Pass --customer-ips or set PK_CLIENT_IPS.\n"
            "        Without them every RTP stream on the box looks like the\n"
            "        customer leg, which is the one filter that must not fail\n"
            "        open in the permissive direction.\n")
        return 2
    media = cust + [x.strip() for x in a.media_extra.replace(",", " ").split()
                    if x.strip()]

    demux = RtpDemux(media, gate_rms=a.gate_rms, gate_seconds=a.gate_seconds)
    tap = Tap(cust, media, a.rtp_lo, a.rtp_hi, iface=a.iface,
              pcap_path=a.pcap, demux=demux)

    t0 = time.time()
    # A replayed pcap runs to EOF; a live tap runs for --seconds, or until
    # Ctrl-C when --seconds is 0.
    deadline = None if a.pcap or not a.seconds else t0 + a.seconds
    if not a.pcap:
        sys.stderr.write(
            "capturing for %ss on %s ... (a quiet trunk prints nothing until "
            "the end)\n" % (a.seconds or "unlimited", a.iface))
        sys.stderr.flush()

    # A heartbeat, so a run that finds nothing is visibly ALIVE rather than
    # looking hung. The first live attempt at this printed absolutely nothing
    # for 70 seconds and was reasonably assumed to be broken.
    state = {"last": t0}

    def _stop():
        now = time.time()
        if not a.pcap and now - state["last"] >= 10:
            state["last"] = now
            sys.stderr.write("  %3ds  packets=%d  sip=%d  rtp=%d  streams=%d\n"
                             % (now - t0, tap.stats["packets"], tap.stats["sip"],
                                tap.stats["rtp"], len(tap.demux.streams)))
            sys.stderr.flush()
        return deadline is not None and now > deadline

    try:
        tap.run(on_audio=None, stop=_stop)
    except PcapError as e:
        sys.stderr.write("tap.py: %s\n" % e)
        _report(tap, time.time() - t0)
        return 1
    except KeyboardInterrupt:
        pass
    _report(tap, time.time() - t0)
    return 0


if __name__ == "__main__":
    sys.exit(main())
