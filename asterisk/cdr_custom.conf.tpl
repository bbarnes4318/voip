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
;   12  fractel_gateway_used    fractel1..fractelN, empty if never dialled.
;                               THIS IS the gateway_used column. It is not
;                               renamed, because monitor.sh, the acceptance
;                               parser and anything downstream index columns
;                               positionally, and a rename breaks all of them
;                               silently.
;   13  sip_call_id             customer-leg SIP Call-ID  [MANDATORY]
;   14  reject_reason           empty, or NOT_NANP / BLOCKED_NPA / CPS_LIMIT /
;                               CONCURRENCY_CAP / BAD_CALLERID / KILLSWITCH /
;                               ALL_GATEWAYS_FAILED / HIGH_COST_PREFIX /
;                               NO_DID_AVAILABLE / BAD_SELECTED_DID
;   15  uniqueid                Asterisk channel unique id, joins to the log
;
; --- appended for carrier-assigned caller ID ------------------------------
; These are APPENDED, never inserted. Columns 1-15 keep their positions so
; every existing reader keeps working.
;
;   16  selected_did            the DID this SBC asserted, 11 digits. This is
;                               what went out in From, P-Asserted-Identity and
;                               Remote-Party-ID. Empty only on a call refused
;                               before selection.
;   17  did_selection_reason    npa_match | overflow | none
;   18  destination_npa         3-digit NPA of the number dialled
;   19  did_daily_count_at_selection
;                               that DID's call count for the day INCLUDING
;                               this call. A value equal to DID_DAILY_CAP
;                               means this was the last call that number will
;                               take until local midnight.
;   20  lrn                     ALWAYS EMPTY from the SBC. This box performs
;                               no LNP dip and has no LRN at call time. The
;                               column exists so FracTEL's LRN-rated CDR can
;                               be joined in downstream, which is how a ported
;                               number in an expensive prefix gets discovered
;                               and added to blocklist.csv. Do not read a
;                               populated value here as evidence of a dip.
;
; Columns 16-19 are what proves per-DID distribution and cap compliance from
; the CDR alone:
;
;   no DID over its cap
;     awk -F'","' '{print $16}' sbc.csv | sort | uniq -c | sort -rn | head
;   distribution within one NPA pool
;     awk -F'","' '$18=="212"{print $16}' sbc.csv | sort | uniq -c
;   overflow rate, which is how you spot an undersized pool
;     awk -F'","' '{print $17}' sbc.csv | sort | uniq -c
;
; (Those one-liners assume no embedded quotes; ./didctl.sh distribution does
; it properly with a real CSV parse.)
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
@@CDR_CSV_NAME@@ => ${CSV_QUOTE(${CDR(start)})},${CSV_QUOTE(${CDR(answer)})},${CSV_QUOTE(${CDR(end)})},${CSV_QUOTE(${CDR(source_ip)})},${CSV_QUOTE(${CDR(customer_endpoint)})},${CSV_QUOTE(${CDR(caller_id)})},${CSV_QUOTE(${CDR(destination)})},${CSV_QUOTE(${CDR(duration)})},${CSV_QUOTE(${CDR(billsec)})},${CSV_QUOTE(${CDR(disposition)})},${CSV_QUOTE(${CDR(hangup_cause)})},${CSV_QUOTE(${CDR(fractel_gateway_used)})},${CSV_QUOTE(${CDR(sip_call_id)})},${CSV_QUOTE(${CDR(reject_reason)})},${CSV_QUOTE(${CDR(uniqueid)})},${CSV_QUOTE(${CDR(selected_did)})},${CSV_QUOTE(${CDR(did_selection_reason)})},${CSV_QUOTE(${CDR(destination_npa)})},${CSV_QUOTE(${CDR(did_daily_count_at_selection)})},${CSV_QUOTE(${CDR(lrn)})}
