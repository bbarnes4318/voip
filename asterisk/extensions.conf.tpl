; ===========================================================================
; extensions.conf — rendered by render.sh from @@RENDERED_FROM@@.
;
; This file is the fraud stop. Read it before you change it.
;
; The customer context has exactly ONE egress: Dial(PJSIP/<n>@fractelN).
; There are no context includes, no Local/ channels, no AGI, no System(), no
; Originate(). res_agi, app_system, func_shell and app_originate are not even
; loaded (see modules.conf). If traffic from @@PK_CLIENT_IP_1@@ or
; @@PK_CLIENT_IP_2@@ can reach anything other than the FracTEL trunk, that is
; a bug and it is the expensive kind.
;
; Order of checks, cheapest and most consequential first:
;
;   1. killswitch      operator has pulled the plug
;   2. destination     NANP allowlist + high-risk NPA denylist
;   3. caller ID       plausible NANP number, not self-dialling
;   4. CPS             protects the FracTEL trunk from a dialer blast
;   5. concurrency     per customer IP
;   6. dial            FracTEL, with failover across all gateways
;
; Destination is checked before the concurrency slot is taken, so a burst of
; junk destinations cannot starve legitimate traffic out of the cap.
;
; Every rejection emits a NOTICE of the form
;     SBC-REJECT reason=<REASON> ...
; which is what monitor.sh counts and what the acceptance suite greps for.
; ===========================================================================

[general]
static=yes
; No 'dialplan save' from the CLI. The file on disk is the only source of
; truth, and it is generated from config.env.
writeprotect=yes
autofallthrough=yes
; Runtime globals (the killswitch) must survive a 'dialplan reload'.
clearglobalvars=no


[globals]
SBC_MAX_CONCURRENT=@@MAX_CONCURRENT_PER_IP@@
SBC_MAX_CPS=@@MAX_CPS@@
SBC_NANP_ONLY=@@NANP_ONLY@@
SBC_BLOCK_NPA=@@BLOCK_HIGH_RISK_NPA@@
SBC_BLOCK_976=@@BLOCK_976@@
SBC_BLOCKED_NPAS=@@SBC_BLOCKED_NPAS@@
SBC_VALIDATE_CID=@@VALIDATE_CALLERID@@
SBC_NORMALIZE_CID=@@NORMALIZE_CALLERID@@
SBC_DIAL_TIMEOUT=@@DIAL_TIMEOUT@@
SBC_GW_COUNT=@@FRACTEL_GW_COUNT@@
@@INCLUDE:fractel_globals@@

; SBC_KILLSWITCH is deliberately NOT declared here. killswitch.sh sets it at
; runtime with `dialplan set global`. If it were declared, a `dialplan reload`
; would silently reset it to 0 and quietly restore customer traffic while the
; operator believed the plug was still pulled. Unset is treated as off.


; ===========================================================================
; [default] — nothing should ever land here. Defined explicitly and left
; hostile so that an endpoint accidentally rendered without a context= line
; cannot fall through into something permissive.
; ===========================================================================
; Patterns are enumerated rather than using a bare '_.', which would also
; match the special extensions h/i/t and shadow them. Anything not matched
; here gets a 404 straight from extension matching, which is still a refusal
; — just one that logs less.
[default]
exten => h,1,NoOp(default teardown)
exten => _X.,1,Goto(refuse,1)
exten => _[+*#].,1,Goto(refuse,1)
exten => _[a-zA-Z].,1,Goto(refuse,1)
exten => refuse,1,Log(WARNING,SBC-REJECT reason=LANDED_IN_DEFAULT_CONTEXT exten=${EXTEN} src=${CHANNEL(pjsip,remote_addr)})
 same => n,Hangup(21)


; ===========================================================================
; [sbc-fractel-inbound] — the carrier's context.
;
; This is an outbound-only trunk. An INVITE arriving from FracTEL is either a
; misconfiguration on their side or someone spoofing their address, and either
; way it does not get dialplan. In-dialog requests on an established call
; (re-INVITE, BYE, in-dialog OPTIONS) are matched to the existing dialog by
; the transaction layer and never reach here, so answered calls tear down
; normally.
; ===========================================================================
[sbc-fractel-inbound]
exten => h,1,NoOp(fractel leg teardown cause=${HANGUPCAUSE})
exten => _X.,1,Goto(refuse,1)
exten => _[+*#].,1,Goto(refuse,1)
exten => _[a-zA-Z].,1,Goto(refuse,1)
exten => refuse,1,Log(NOTICE,SBC-REJECT reason=INBOUND_FROM_CARRIER exten=${EXTEN} src=${CHANNEL(pjsip,remote_addr)} callid=${CHANNEL(pjsip,call-id)})
 same => n,Hangup(21)


; ===========================================================================
; [sbc-customer] — the only context reachable from customer traffic.
; ===========================================================================
[sbc-customer]

; --- E.164 alias. A dialer sending +1NXXNXXXXXX enters here, gets stripped to
; --- digits, and re-enters the main pattern below.
exten => _+X.,1,Set(SBC_D=${FILTER(0-9,${EXTEN})})
 same => n,Goto(sbc-customer,${SBC_D},1)

; --- Main entry point ------------------------------------------------------
exten => _X.,1,NoOp(SBC inbound raw=${EXTEN} cid=${CALLERID(num)} ep=${CHANNEL(endpoint)})

 ; Capture identity up front. These are the fields handed over on a traceback
 ; request, so they are recorded before any check can reject the call — a
 ; rejected call still produces a CDR row (cdr.conf sets unanswered=yes).
 same => n,Set(SBC_RADDR=${CHANNEL(pjsip,remote_addr)})
 same => n,Set(__SBC_SRC_IP=${CUT(SBC_RADDR,:,1)})
 same => n,Set(__SBC_EP=${CHANNEL(endpoint)})
 same => n,Set(__SBC_CALLID=${CHANNEL(pjsip,call-id)})
 same => n,Set(__SBC_CID_RAW=${CALLERID(num)})
 same => n,Set(CDR(source_ip)=${SBC_SRC_IP})
 same => n,Set(CDR(customer_endpoint)=${SBC_EP})
 same => n,Set(CDR(sip_call_id)=${SBC_CALLID})
 same => n,Set(CDR(caller_id)=${SBC_CID_RAW})
 same => n,Set(CDR(destination)=${EXTEN})
 same => n,Set(CDR(reject_reason)=)
 same => n,Set(CDR(fractel_gateway_used)=)

 ; ---- 1. killswitch ------------------------------------------------------
 same => n,GotoIf($["${SBC_KILLSWITCH}" = "1"]?rej_killswitch)

 ; ---- 2. destination -----------------------------------------------------
 same => n,Set(SBC_DEST=${FILTER(0-9,${EXTEN})})
 same => n,GotoIf($[${LEN(${SBC_DEST})} = 0]?rej_dest)
 same => n,GotoIf($["${SBC_NANP_ONLY}" != "true"]?dest_ok)

 ; Normalise to 11 digits. _NXXNXXXXXX gets a 1 prepended; _1NXXNXXXXXX is
 ; already there; anything else is not NANP and is refused.
 same => n,GotoIf($[${LEN(${SBC_DEST})} = 10]?dest_add1)
 same => n,GotoIf($[${LEN(${SBC_DEST})} = 11]?dest_chk)
 same => n,Goto(rej_dest)
 same => n(dest_add1),Set(SBC_DEST=1${SBC_DEST})

 same => n(dest_chk),GotoIf($["${SBC_DEST:0:1}" != "1"]?rej_dest)
 same => n,Set(SBC_NPA=${SBC_DEST:1:3})
 same => n,Set(SBC_NXX=${SBC_DEST:4:3})
 ; NPA and NXX must both begin 2-9 (the N in _1NXXNXXXXXX).
 same => n,GotoIf($[${SBC_NPA:0:1} < 2]?rej_dest)
 same => n,GotoIf($[${SBC_NXX:0:1} < 2]?rej_dest)
 ; N11 service codes (211/311/411/511/611/711/811/911) are never valid NPAs.
 same => n,GotoIf($["${SBC_NPA:1:2}" = "11"]?rej_dest)

 ; 976 is US domestic premium-rate.
 same => n,GotoIf($["${SBC_BLOCK_976}" != "true"]?dest_npa)
 same => n,GotoIf($["${SBC_NXX}" = "976"]?rej_npa)

 ; High-risk NANP area codes. NANP-only is NOT enough on its own: the whole
 ; Caribbean is inside the NANP and matches _1NXXNXXXXXX perfectly while
 ; costing dollars a minute. +1-876, +1-809/829/849, +1-284 and friends are
 ; the classic IRSF destinations. Membership test against a comma-wrapped
 ; list, so ",876," matches only the whole area code.
 same => n(dest_npa),GotoIf($["${SBC_BLOCK_NPA}" != "true"]?dest_ok)
 same => n,GotoIf($["${SBC_BLOCKED_NPAS}" : ".*,${SBC_NPA},"]?rej_npa)

 same => n(dest_ok),Set(CDR(destination)=${SBC_DEST})

 ; ---- 3. caller ID -------------------------------------------------------
 ; Validate only. The customer's CID is passed through byte-for-byte unless
 ; NORMALIZE_CALLERID=true, because rewriting or inventing CID is exactly
 ; what makes a traceback unanswerable.
 same => n,GotoIf($["${SBC_VALIDATE_CID}" != "true"]?cid_done)
 same => n,Set(SBC_CIDN=${FILTER(0-9,${SBC_CID_RAW})})
 same => n,GotoIf($[${LEN(${SBC_CIDN})} = 10]?cid_add1)
 same => n,GotoIf($[${LEN(${SBC_CIDN})} = 11]?cid_chk)
 same => n,Goto(rej_cid)
 same => n(cid_add1),Set(SBC_CIDN=1${SBC_CIDN})
 same => n(cid_chk),GotoIf($["${SBC_CIDN:0:1}" != "1"]?rej_cid)
 same => n,GotoIf($[${SBC_CIDN:1:1} < 2]?rej_cid)
 same => n,GotoIf($[${SBC_CIDN:4:1} < 2]?rej_cid)
 ; Caller ID identical to the number being dialled is a dialer bug or a
 ; spoofing attempt. Either way it is not a real originating number.
 same => n,GotoIf($["${SBC_CIDN}" = "${SBC_DEST}"]?rej_cid)
 same => n,GotoIf($["${SBC_NORMALIZE_CID}" != "true"]?cid_done)
 same => n,Set(CALLERID(num)=${SBC_CIDN})
 same => n(cid_done),Set(CDR(caller_id)=${CALLERID(num)})

 ; ---- 4. CPS -------------------------------------------------------------
 ; The group name is the current epoch second, so GROUP_COUNT returns the
 ; number of calls that started during this second and are still up — which
 ; at the moment of the check is every call that started this second.
 ; Counted across both customer IPs combined: FracTEL's fraud system reacts
 ; to the aggregate arriving from our one source address, not per-endpoint.
 ; EPOCH is read ONCE into a variable. Reading it twice risks the second read
 ; landing in the next second, which would count a group this channel is not
 ; in and let an extra call through at every second boundary.
 same => n,Set(SBC_SEC=${EPOCH})
 same => n,Set(GROUP(cps)=${SBC_SEC})
 same => n,Set(SBC_CPSNOW=${GROUP_COUNT(${SBC_SEC}@cps)})
 same => n,GotoIf($[${SBC_CPSNOW} > ${SBC_MAX_CPS}]?rej_cps)

 ; ---- 5. concurrency, per customer endpoint (so per customer IP) ---------
 ; GROUP_COUNT includes this channel, so with a cap of 3 the fourth
 ; simultaneous call sees 4 and is refused.
 same => n,Set(GROUP(cust)=${SBC_EP})
 same => n,Set(SBC_CCNOW=${GROUP_COUNT(${SBC_EP}@cust)})
 same => n,GotoIf($[${SBC_CCNOW} > ${SBC_MAX_CONCURRENT}]?rej_cap)

 ; ---- 6. dial FracTEL ----------------------------------------------------
 ; Start gateway is rotated by wall clock so load spreads across the proxy
 ; set instead of hammering gateway 1, then walks the ring on failure.
 same => n,Set(SBC_TRY=0)
 same => n,Set(SBC_GWIDX=$[( ${EPOCH} % ${SBC_GW_COUNT} ) + 1])

 same => n(gwloop),Set(SBC_GW=${GLOBAL(FRACTEL_GW_${SBC_GWIDX})})
 same => n,Set(CDR(fractel_gateway_used)=${SBC_GW})
 same => n,Log(NOTICE,SBC-DIAL callid=${SBC_CALLID} src=${SBC_SRC_IP} ep=${SBC_EP} cid=${CALLERID(num)} dst=${SBC_DEST} gw=${SBC_GW} attempt=${SBC_TRY})
 ; No Dial() options at all. No t/T (no transfer), no g/G, no M/L. The only
 ; thing this leg can do is connect two RTP streams through this box.
 same => n,Dial(PJSIP/${SBC_DEST}@${SBC_GW},${SBC_DIAL_TIMEOUT})
 same => n,Set(SBC_DS=${DIALSTATUS})
 same => n,NoOp(SBC dialstatus=${SBC_DS} cause=${HANGUPCAUSE} gw=${SBC_GW})

 ; Fail over only on trunk-level failures. BUSY and NOANSWER are real answers
 ; from the far end; retrying those on another gateway would dial the same
 ; consumer twice and is how you generate complaints.
 same => n,GotoIf($["${SBC_DS}" = "CONGESTION"]?gwnext)
 same => n,GotoIf($["${SBC_DS}" = "CHANUNAVAIL"]?gwnext)
 same => n,Goto(finish)

 same => n(gwnext),Set(SBC_TRY=$[${SBC_TRY} + 1])
 same => n,Log(NOTICE,SBC-FAILOVER callid=${SBC_CALLID} gw=${SBC_GW} status=${SBC_DS} attempt=${SBC_TRY})
 same => n,GotoIf($[${SBC_TRY} >= ${SBC_GW_COUNT}]?rej_exhausted)
 same => n,Set(SBC_GWIDX=$[( ${SBC_GWIDX} % ${SBC_GW_COUNT} ) + 1])
 same => n,Goto(gwloop)

 same => n(finish),Hangup()

 ; ---- rejection paths ----------------------------------------------------
 same => n(rej_killswitch),Set(SBC_REJ=KILLSWITCH)
 same => n,Goto(reject503)
 same => n(rej_dest),Set(SBC_REJ=NOT_NANP)
 same => n,Goto(reject503)
 same => n(rej_npa),Set(SBC_REJ=BLOCKED_NPA)
 same => n,Goto(reject503)
 same => n(rej_cps),Set(SBC_REJ=CPS_LIMIT)
 same => n,Goto(reject503)
 same => n(rej_cap),Set(SBC_REJ=CONCURRENCY_CAP)
 same => n,Goto(reject503)
 same => n(rej_exhausted),Set(SBC_REJ=ALL_GATEWAYS_FAILED)
 same => n,Goto(reject503)

 ; Bad caller ID gets 403, not 503. 503 says "try again later" and a dialer
 ; will do exactly that; 403 says "this call is wrong" and should make them
 ; fix their CID.
 same => n(rej_cid),Set(CDR(reject_reason)=BAD_CALLERID)
 same => n,Log(NOTICE,SBC-REJECT reason=BAD_CALLERID callid=${SBC_CALLID} src=${SBC_SRC_IP} ep=${SBC_EP} cid=${SBC_CID_RAW} dst=${SBC_DEST})
 same => n,Hangup(21)

 ; 34 = circuit congestion, which chan_pjsip maps to 503 Service Unavailable.
 same => n(reject503),Set(CDR(reject_reason)=${SBC_REJ})
 same => n,Log(NOTICE,SBC-REJECT reason=${SBC_REJ} callid=${SBC_CALLID} src=${SBC_SRC_IP} ep=${SBC_EP} cid=${SBC_CID_RAW} dst=${SBC_DEST} concurrent=${SBC_CCNOW} cps=${SBC_CPSNOW})
 same => n,Hangup(34)


; --- teardown --------------------------------------------------------------
; cdr.conf sets endbeforehexten=no, so CDR() assignments made here still land
; in the written row. This is where hangup_cause gets recorded.
exten => h,1,Set(CDR(hangup_cause)=${HANGUPCAUSE})
 same => n,NoOp(SBC-END callid=${SBC_CALLID} src=${SBC_SRC_IP} ep=${SBC_EP} dst=${SBC_DEST} disp=${CDR(disposition)} billsec=${CDR(billsec)} gw=${CDR(fractel_gateway_used)} reject=${CDR(reject_reason)})
