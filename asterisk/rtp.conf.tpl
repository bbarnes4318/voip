; ===========================================================================
; rtp.conf — rendered by render.sh from @@RENDERED_FROM@@.
;
; Media transits this box on every call. That is the entire reason the SBC
; exists: FracTEL authorises exactly one source IP, so RTP toward them has to
; leave from @@SBC_PUBLIC_IP@@ and nowhere else. See direct_media=no on every
; endpoint in pjsip.conf.
; ===========================================================================

[general]

; Port range for media. Each call consumes 4 ports (RTP+RTCP on both legs),
; so @@RTP_START@@-@@RTP_END@@ supports roughly 2500 concurrent calls. The
; firewall opens this range to the customer and FracTEL addresses only.
rtpstart=@@RTP_START@@
rtpend=@@RTP_END@@

; Drop RTP arriving from a source other than the one negotiated for this
; stream. On a box whose whole job is relaying other people's media, this is
; what stops a third party injecting audio into a live call by guessing a
; port. probation=4 means learn the peer from the first few packets, which is
; what makes rtp_symmetric work for a customer behind NAT.
strictrtp=yes
probation=4

; No ICE, no STUN, no TURN. Both peers are static public addresses read from
; config.env. ICE here would add candidate gathering latency to call setup
; and could advertise an address other than @@SBC_PUBLIC_IP@@ — which is the
; one thing that must never happen on the FracTEL side.
icesupport=no

rtpchecksums=yes

; Time to wait for the rest of a DTMF digit before giving up (ms).
dtmftimeout=3000
