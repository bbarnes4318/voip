; ===========================================================================
; cdr.conf — rendered by render.sh from @@RENDERED_FROM@@.
;
; Two independent CDR writers are enabled on purpose:
;
;   cdr_custom -> @@CDR_CSV_PATH@@     the system of record, columns defined
;                                      in cdr_custom.conf
;   cdr_csv    -> Master.csv           stock Asterisk format, kept as a
;                                      cross-check when reconciling against
;                                      FracTEL's own CDR
; ===========================================================================

[general]
enable=yes

; Rejected calls MUST produce a CDR row. A 503 for a blocked +252 destination
; or an over-cap call is exactly the event worth having a record of, and
; without these two lines those calls vanish silently.
unanswered=yes
congestion=yes

; Run the h extension BEFORE finalising the CDR, so the CDR() assignments in
; the h extension of [sbc-customer] (hangup_cause) actually land in the row.
; Flipping this to yes silently blanks that column.
endbeforehexten=no

; Do not count the ringing period as billable time.
initiatedseconds=no

; Write each record synchronously. Batching trades durability for throughput,
; and a CDR lost to a crash is a call that cannot be reconciled or traced.
batch=no
safeshutdown=yes


[csv]
; Stock Master.csv. Local time so it lines up with the Asterisk log and with
; the cdr_custom file; convert when reconciling against FracTEL if they
; report UTC.
usegmtime=no
loguniqueid=yes
loguserfield=yes
accountlogs=no
