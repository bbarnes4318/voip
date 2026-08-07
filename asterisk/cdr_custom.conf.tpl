; ===========================================================================
; cdr_custom.conf — rendered by render.sh from @@RENDERED_FROM@@.
;
; This defines the system-of-record CDR. Asterisk writes it to
;     <astlogdir>/cdr-custom/@@CDR_CSV_NAME@@
; which on a stock install is @@CDR_CSV_PATH@@.
;
; COLUMN ORDER (no header row is written — the file stays machine-parseable;
; this comment block and README.md are the schema):
;
;    1  timestamp_start         call arrived at the SBC
;    2  timestamp_answer        far end answered, empty if never answered
;    3  timestamp_end           call torn down
;    4  source_ip               customer's signaling IP  [MANDATORY]
;    5  customer_endpoint       pkclient1 | pkclient2
;    6  caller_id               as sent by the customer, unmodified
;    7  destination             normalised 11-digit NANP number dialled
;    8  duration                seconds from start to end
;    9  billsec                 RAW whole seconds of answered time  [MANDATORY]
;   10  disposition             ANSWERED | NO ANSWER | BUSY | FAILED | CONGESTION
;   11  hangup_cause            Q.850 cause code
;   12  fractel_gateway_used    fractel1..fractelN, empty if never dialled
;   13  sip_call_id             customer-leg SIP Call-ID  [MANDATORY]
;   14  reject_reason           empty, or NOT_NANP / BLOCKED_NPA / CPS_LIMIT /
;                               CONCURRENCY_CAP / BAD_CALLERID / KILLSWITCH /
;                               ALL_GATEWAYS_FAILED
;   15  uniqueid                Asterisk channel unique id, joins to the log
;
; billsec is deliberately RAW. Do NOT round to 6- or 12-second increments
; here. Billing increments are a downstream calculation, and rounding at the
; source destroys the ability to reconcile against FracTEL's own CDR.
;
; source_ip and sip_call_id are what gets handed over on a traceback request,
; and there is a 24-hour clock on answering one. They are set at the very top
; of the dialplan, before any check can reject the call, so even a refused
; call produces a complete row.
;
; Every field is CSV_QUOTE'd. Caller ID is attacker-controlled text and will
; eventually contain a comma or a quote; unquoted, that shifts every later
; column and quietly corrupts the record you need most.
; ===========================================================================

[mappings]
@@CDR_CSV_NAME@@ => ${CSV_QUOTE(${CDR(start)})},${CSV_QUOTE(${CDR(answer)})},${CSV_QUOTE(${CDR(end)})},${CSV_QUOTE(${CDR(source_ip)})},${CSV_QUOTE(${CDR(customer_endpoint)})},${CSV_QUOTE(${CDR(caller_id)})},${CSV_QUOTE(${CDR(destination)})},${CSV_QUOTE(${CDR(duration)})},${CSV_QUOTE(${CDR(billsec)})},${CSV_QUOTE(${CDR(disposition)})},${CSV_QUOTE(${CDR(hangup_cause)})},${CSV_QUOTE(${CDR(fractel_gateway_used)})},${CSV_QUOTE(${CDR(sip_call_id)})},${CSV_QUOTE(${CDR(reject_reason)})},${CSV_QUOTE(${CDR(uniqueid)})}
