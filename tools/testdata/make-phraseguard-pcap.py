#!/usr/bin/env python3
"""Build a synthetic SIP+RTP pcap for the PhraseGuard tap tests.

The tap has to be provable without a live trunk. This writes a capture with
the exact shape the SBC produces -- a customer INVITE with SDP, our 200 OK
with our own SDP, RTP in both directions on the negotiated ports, and a BYE --
so tests/run-phraseguard-tests.sh can assert on stream counts, call
attribution and the RMS gate with nothing running.

The audio is synthetic and deliberately so. It is shaped to land in the RMS
bands already measured on this box (silence 0-20, comfort noise 50-150, speech
555-3869) so the gate is exercised at the boundaries it will actually see,
and it is not speech: there is no recording of a real call in this repo and
there is not going to be one.

  ./make-phraseguard-pcap.py out.pcap
"""
import math
import random
import struct
import sys

CUSTOMER_IP = "116.202.146.131"       # a real PK_CLIENT_IPS entry
SBC_IP = "167.235.206.206"
CARRIER_IP = "66.51.196.10"           # stands in for a FracTEL proxy
CUSTOMER_RTP_PORT = 40000
SBC_RTP_CUST_PORT = 10100             # what we answer the customer with
SBC_RTP_CARR_PORT = 10102
CARRIER_RTP_PORT = 30000
CALL_ID = "8f2a1c74-phraseguard-fixture@pkfloor"
ANI = "13257581234"
DNIS = "13365551212"

LINKTYPE_EN10MB = 1


# --- linear PCM -> G.711 mu-law -------------------------------------------
def lin2ulaw(sample):
    BIAS = 0x84
    CLIP = 32635
    sign = 0
    if sample < 0:
        sample = -sample
        sign = 0x80
    if sample > CLIP:
        sample = CLIP
    sample += BIAS
    exp = 7
    mask = 0x4000
    while exp > 0 and not (sample & mask):
        exp -= 1
        mask >>= 1
    man = (sample >> (exp + 3)) & 0x0F
    return ~(sign | (exp << 4) | man) & 0xFF


def frame(kind, seed, n=160):
    """One 20 ms mu-law frame at a chosen energy band."""
    rnd = random.Random(seed)
    out = bytearray()
    for i in range(n):
        if kind == "silence":
            v = 0
        elif kind == "comfort":
            v = int(rnd.gauss(0, 110))
        else:
            # Speech-ish: a couple of formant-ish tones plus noise, amplitude
            # modulated so rms_sd is non-trivial the way real speech is.
            env = 0.35 + 0.65 * abs(math.sin(2 * math.pi * (seed % 40) / 40.0))
            v = int(env * (2200 * math.sin(2 * math.pi * 240 * i / 8000.0)
                           + 1100 * math.sin(2 * math.pi * 870 * i / 8000.0)
                           + rnd.gauss(0, 320)))
        out.append(lin2ulaw(v))
    return bytes(out)


# --- packet assembly -------------------------------------------------------
def udp_packet(src, sport, dst, dport, payload):
    def ip4(a):
        return bytes(int(x) for x in a.split("."))

    udp = struct.pack("!HHHH", sport, dport, 8 + len(payload), 0) + payload
    total = 20 + len(udp)
    ip = struct.pack("!BBHHHBBH", 0x45, 0, total, 0, 0, 64, 17, 0) \
        + ip4(src) + ip4(dst)
    # Ethernet header; the tap accepts EN10MB as well as the LINUX_SLL forms
    # `tcpdump -i any` produces, and EN10MB is the simplest to synthesise.
    eth = b"\x02\x00\x00\x00\x00\x01\x02\x00\x00\x00\x00\x02\x08\x00"
    return eth + ip + udp


def rtp_packet(seq, ts, ssrc, payload, pt=0):
    return struct.pack("!BBHII", 0x80, pt, seq & 0xFFFF, ts & 0xFFFFFFFF, ssrc) \
        + payload


class Pcap(object):
    def __init__(self, path):
        self.fh = open(path, "wb")
        self.fh.write(struct.pack("<IHHiIII", 0xA1B2C3D4, 2, 4, 0, 0,
                                  65535, LINKTYPE_EN10MB))

    def write(self, ts, raw):
        self.fh.write(struct.pack("<IIII", int(ts), int((ts % 1) * 1e6),
                                  len(raw), len(raw)))
        self.fh.write(raw)

    def close(self):
        self.fh.close()


INVITE = """INVITE sip:{dnis}@{sbc}:5060 SIP/2.0\r
Via: SIP/2.0/UDP {cust}:5060;branch=z9hG4bK-fixture\r
From: <sip:{ani}@{cust}>;tag=pgfixture\r
To: <sip:{dnis}@{sbc}>\r
Call-ID: {cid}\r
CSeq: 1 INVITE\r
Contact: <sip:{ani}@{cust}:5060>\r
Content-Type: application/sdp\r
Content-Length: 0\r
\r
v=0\r
o=- 1 1 IN IP4 {cust}\r
s=-\r
c=IN IP4 {cust}\r
t=0 0\r
m=audio {cport} RTP/AVP 0 101\r
a=rtpmap:0 PCMU/8000\r
"""

OK200 = """SIP/2.0 200 OK\r
Via: SIP/2.0/UDP {cust}:5060;branch=z9hG4bK-fixture\r
From: <sip:{ani}@{cust}>;tag=pgfixture\r
To: <sip:{dnis}@{sbc}>;tag=sbcside\r
Call-ID: {cid}\r
CSeq: 1 INVITE\r
Contact: <sip:{dnis}@{sbc}:5060>\r
Content-Type: application/sdp\r
Content-Length: 0\r
\r
v=0\r
o=- 2 2 IN IP4 {sbc}\r
s=-\r
c=IN IP4 {sbc}\r
t=0 0\r
m=audio {sport} RTP/AVP 0\r
a=rtpmap:0 PCMU/8000\r
"""

BYE = """BYE sip:{ani}@{cust} SIP/2.0\r
Via: SIP/2.0/UDP {sbc}:5060;branch=z9hG4bK-fixbye\r
From: <sip:{dnis}@{sbc}>;tag=sbcside\r
To: <sip:{ani}@{cust}>;tag=pgfixture\r
Call-ID: {cid}\r
CSeq: 2 BYE\r
Content-Length: 0\r
\r
"""


def main(argv):
    if len(argv) < 2:
        sys.stderr.write("usage: make-phraseguard-pcap.py OUT.pcap "
                         "[--voiced-seconds N] [--kind speech|comfort|silence]\n")
        return 2
    out = argv[1]
    voiced_s = 12.0
    kind = "speech"
    i = 2
    while i < len(argv):
        if argv[i] == "--voiced-seconds":
            voiced_s = float(argv[i + 1]); i += 2
        elif argv[i] == "--kind":
            kind = argv[i + 1]; i += 2
        else:
            sys.stderr.write("unknown argument %r\n" % argv[i]); return 2

    fmt = dict(cid=CALL_ID, cust=CUSTOMER_IP, sbc=SBC_IP, ani=ANI, dnis=DNIS,
               cport=CUSTOMER_RTP_PORT, sport=SBC_RTP_CUST_PORT)
    p = Pcap(out)
    t = 1_760_000_000.0

    p.write(t, udp_packet(CUSTOMER_IP, 5060, SBC_IP, 5060,
                          INVITE.format(**fmt).encode()))
    t += 0.9
    p.write(t, udp_packet(SBC_IP, 5060, CUSTOMER_IP, 5060,
                          OK200.format(**fmt).encode()))
    t += 0.1

    # Media. The customer leg is what PhraseGuard cares about; the carrier leg
    # is written too, at full speech energy, precisely so the test can assert
    # that it is DROPPED rather than merely absent.
    nframes = int(voiced_s / 0.02)
    cust_ssrc, carr_ssrc = 0x11223344, 0x55667788
    for n in range(nframes):
        ts = t + n * 0.02
        pay = frame(kind, n)
        p.write(ts, udp_packet(CUSTOMER_IP, CUSTOMER_RTP_PORT,
                               SBC_IP, SBC_RTP_CUST_PORT,
                               rtp_packet(n, n * 160, cust_ssrc, pay)))
        p.write(ts, udp_packet(CARRIER_IP, CARRIER_RTP_PORT,
                               SBC_IP, SBC_RTP_CARR_PORT,
                               rtp_packet(n, n * 160, carr_ssrc,
                                          frame("speech", n + 5000))))
    t += nframes * 0.02
    p.write(t, udp_packet(SBC_IP, 5060, CUSTOMER_IP, 5060,
                          BYE.format(**fmt).encode()))
    p.close()
    print("wrote %s: 1 call, %d customer frames (%s), %d carrier frames"
          % (out, nframes, kind, nframes))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
