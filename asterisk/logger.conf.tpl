; ===========================================================================
; logger.conf — rendered by render.sh from @@RENDERED_FROM@@.
;
; Retention is @@LOG_RETAIN_DAYS@@ days, enforced by the logrotate snippet
; install.sh drops in /etc/logrotate.d/sbc-asterisk. Full SIP ladders are NOT
; written here — they go to the rotating pcap capture (sbc-siptrace.service),
; which is both smaller and directly usable as traceback evidence.
; ===========================================================================

[general]

; Millisecond precision. Correlating an SBC row against FracTEL's CDR when
; both sides only log whole seconds is unpleasant.
dateformat=%F %T.%3q

; Tag every line with the channel's call id, so a single call can be pulled
; out of a log carrying hundreds of concurrent calls:
;     grep '\[C-0000abcd\]' /var/log/asterisk/full
use_callids=yes

appendhostname=no

; No queues on this box.
queue_log=no

; Rotate in place and let logrotate do the aging. 'rotate' keeps the numbered
; sequence logrotate expects; the default 'sequential' does not.
rotatestrategy=rotate


[logfiles]

; Console: what you see on `asterisk -rvvv`.
console => notice,warning,error

; The operational log. SBC-REJECT / SBC-DIAL / SBC-FAILOVER notices land here
; and this is what monitor.sh and the acceptance suite read.
messages => notice,warning,error

; Verbose detail for debugging a specific call. verbose(3) is deliberate:
; verbose(5)+ on a wholesale box at real CPS will fill the disk in hours and
; the write pressure shows up as post-dial delay.
full => notice,warning,error,verbose(3)

; Security events — unidentified request sources, failed identification,
; invalid transports. This is the first file to read when the customer says
; "our calls stopped working" (usually: they changed IP and did not say so)
; and the first file to read when something unexpected is probing port 5060.
security => security
