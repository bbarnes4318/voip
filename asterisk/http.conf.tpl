; ===========================================================================
; http.conf — rendered by render.sh from @@RENDERED_FROM@@.
;
; The built-in HTTP server is OFF. It is the transport for ARI and for the
; AMI-over-HTTP interface, neither of which this box uses, and the distro
; package ships a http.conf that is easy to leave half-configured.
;
; res_ari*, res_stasis*, res_http_websocket and res_http_post are additionally
; not loaded at all (see modules.conf), and the firewall has no rule for 8088.
; Three independent reasons nothing is listening. This file is the one an
; operator will look at first, so it is explicit rather than absent.
; ===========================================================================

[general]
enabled=no
bindaddr=127.0.0.1
bindport=8088
tlsenable=no
