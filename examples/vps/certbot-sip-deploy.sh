#!/bin/sh
set -eu
case "${RENEWED_LINEAGE:-}" in
    /etc/letsencrypt/live/sip.example.net) ;;
    *) exit 0 ;;
esac
install -d -m 750 -o root -g asterisk /etc/asterisk/tls
install -m 640 -o root -g asterisk "$RENEWED_LINEAGE/fullchain.pem" /etc/asterisk/tls/fullchain.pem
install -m 640 -o root -g asterisk "$RENEWED_LINEAGE/privkey.pem" /etc/asterisk/tls/privkey.pem
if systemctl is-active --quiet asterisk; then
    asterisk -rx 'core restart when convenient'
fi
