; ===========================================================================
; manager.conf — rendered by render.sh from @@RENDERED_FROM@@.
;
; AMI is OFF. Not bound to loopback — off entirely.
;
; The brief allowed binding it to 127.0.0.1 if monitor.sh needed it. It does
; not: monitor.sh, killswitch.sh and healthcheck.sh all drive Asterisk through
; `asterisk -rx`, which goes over the local control socket in /var/run and is
; already restricted to root and the asterisk group by file permissions.
;
; That removes a TCP listener, a credentials file, and an entire class of
; "AMI exposed to the internet" incident from the box. There is no upside to
; running it here.
;
; If you later need AMI for a monitoring integration: set enabled=yes,
; bindaddr=127.0.0.1, add a user with the narrowest read/write classes that
; work, and add nothing to the firewall.
; ===========================================================================

[general]
enabled=no
webenabled=no
