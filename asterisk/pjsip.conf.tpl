; ===========================================================================
; pjsip.conf — rendered by render.sh from @@RENDERED_FROM@@. DO NOT EDIT THE
; RENDERED FILE; edit asterisk/pjsip.conf.tpl and re-run install.sh.
;
; Topology:
;
;   pkclient1 (@@PK_CLIENT_IP_1@@) ─┐
;                                    ├─► [ this SBC, @@SBC_PUBLIC_IP@@ ] ─► fractel1..N
;   pkclient2 (@@PK_CLIENT_IP_2@@) ─┘
;
; The SBC is a back-to-back user agent. The customer leg is terminated here
; and a brand new leg is originated toward FracTEL from this box's own single
; public IP. That is what lets two customer IPs converge into the one source
; address FracTEL authorises on the trunk.
;
; The whole design collapses if media does not transit this box: FracTEL would
; see RTP arriving from a Pakistan address it has never authorised, and the
; call gets one-way audio or dies. Hence direct_media=no on EVERY endpoint
; below, with no exceptions and no re-INVITE path back to direct media.
; ===========================================================================


; ---------------------------------------------------------------------------
; Global
; ---------------------------------------------------------------------------
[global]
type=global

; Do not advertise "Asterisk 20.x.y" to the world. Costs nothing, removes a
; free version-fingerprint for anyone scanning.
user_agent=SBC

; IP is the ONLY way an endpoint may be identified. Without this, res_pjsip
; would also accept username-based identification, which means a caller could
; claim to be pkclient1 just by putting that in the From header. Both customer
; endpoints additionally set identify_by=ip.
endpoint_identifier_order=ip

; Track and log unidentified sources. These land in the security log and are
; the first thing to read if the customer says "our calls stopped working".
unidentified_request_count=5
unidentified_request_period=5
unidentified_request_prune_interval=30

; Single-domain box. Skips per-request domain lookups.
disable_multi_domain=yes

; Note: there is no DNS anywhere in the call path by construction. Every peer
; is a literal IPv4 address from config.env — no hostnames, no SRV records —
; so a resolver hiccup cannot stall call setup.

; How long to wait for the initial qualify of the FracTEL AORs at startup.
max_initial_qualify_time=4

; Terminate a dialog whose transaction has hung rather than leaking channels.
default_realm=@@SBC_PUBLIC_IP@@


[system]
type=system
timer_t1=500
timer_b=32000
compact_headers=no
disable_tcp_switch=yes

; Wholesale traffic is bursty. A too-small pool serialises call setup and
; shows up as rising post-dial delay under load.
threadpool_initial_size=8
threadpool_auto_increment=5
threadpool_idle_timeout=60
threadpool_max_size=100


; ---------------------------------------------------------------------------
; Transports
;
; Bound to 0.0.0.0 rather than the public IP for one reason: the acceptance
; suite runs on-box over loopback, and a transport bound only to the public
; address cannot be reached from 127.0.0.0/8. Exposure is unchanged — the host
; firewall default-DROPs everything to :@@SIP_PORT@@ except the customer and
; FracTEL addresses, and the [sbc-acl] section below is a second independent
; check inside Asterisk itself.
; ---------------------------------------------------------------------------
[transport-udp]
type=transport
protocol=udp
bind=0.0.0.0:@@SIP_PORT@@
allow_reload=no
tos=cs3
cos=3
@@INCLUDE:nat@@

[transport-tcp]
type=transport
protocol=tcp
bind=0.0.0.0:@@SIP_PORT@@
allow_reload=no
tos=cs3
cos=3


; ---------------------------------------------------------------------------
; SIP-layer ACL  (defence layer 2 of 3)
;
; Layer 1 is the host firewall (firewall.sh). Layer 3 is the dialplan.
; This is layer 2 and it is deliberately independent of the identify sections
; below: res_pjsip_acl drops the packet before endpoint identification even
; runs. If a firewall rule is ever fat-fingered, this still holds the line.
;
; contact_deny/contact_permit are intentionally NOT set. They filter on the
; Contact header address, which for a customer behind NAT is frequently an
; RFC1918 address, and enabling them would reject legitimate traffic.
; ---------------------------------------------------------------------------
[sbc-acl]
type=acl
@@INCLUDE:acl@@


; ---------------------------------------------------------------------------
; Customer endpoints
;
; Two endpoints, not one endpoint with two match lines. That buys:
;   - per-IP CDR attribution (customer_endpoint column)
;   - per-IP concurrency caps (GROUP() keyed on endpoint name)
;   - the ability to disable one IP without touching the other
;
; No [auth] section and no auth= line anywhere: authentication is by source IP
; only. There is nothing here to brute-force and no registration to expire.
; Neither endpoint has an aors= line, so this box has no way to originate a
; call toward the customer even if the dialplan were wrong.
; ---------------------------------------------------------------------------
[pkclient1]
type=endpoint
context=sbc-customer
transport=transport-udp
identify_by=ip
disallow=all
@@INCLUDE:codecs@@

; --- media: full relay, non-negotiable ---
direct_media=no
direct_media_method=invite
disable_direct_media_on_nat=yes
rtp_symmetric=yes
force_rport=yes
rewrite_contact=yes
media_encryption=no
rtp_timeout=120
rtp_timeout_hold=120
tos_audio=ef
cos_audio=5

; --- behaviour ---
dtmf_mode=rfc4733
allow_transfer=no
allow_subscribe=no
trust_id_inbound=no
trust_id_outbound=no
send_pai=no
send_rpid=no
send_diversion=no
inband_progress=no
timers=yes
timers_min_se=90
sdp_session=SBC
language=en

[pkclient1]
type=identify
endpoint=pkclient1
match=@@PK_CLIENT_IP_1@@


[pkclient2]
type=endpoint
context=sbc-customer
transport=transport-udp
identify_by=ip
disallow=all
@@INCLUDE:codecs@@

direct_media=no
direct_media_method=invite
disable_direct_media_on_nat=yes
rtp_symmetric=yes
force_rport=yes
rewrite_contact=yes
media_encryption=no
rtp_timeout=120
rtp_timeout_hold=120
tos_audio=ef
cos_audio=5

dtmf_mode=rfc4733
allow_transfer=no
allow_subscribe=no
trust_id_inbound=no
trust_id_outbound=no
send_pai=no
send_rpid=no
send_diversion=no
inband_progress=no
timers=yes
timers_min_se=90
sdp_session=SBC
language=en

[pkclient2]
type=identify
endpoint=pkclient2
match=@@PK_CLIENT_IP_2@@


; ---------------------------------------------------------------------------
; FracTEL gateways — generated, one set per entry in FRACTEL_PROXY_IPS
;
; Each gets an endpoint, an aor with qualify (that is what healthcheck.sh
; reads), and an identify so inbound traffic from the carrier is attributed
; rather than landing as an unidentified request.
;
; Their context is sbc-fractel-inbound, which rejects everything. This is an
; outbound-only trunk; an INVITE arriving from FracTEL is either a mistake or
; an attack. In-dialog traffic (re-INVITE, BYE, responses) is matched to the
; existing dialog by the transaction layer and never touches the dialplan, so
; answered calls tear down normally.
; ---------------------------------------------------------------------------
@@INCLUDE:fractel_endpoints@@
