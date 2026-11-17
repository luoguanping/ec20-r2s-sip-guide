#!/bin/sh
set -u
umask 077
state=/opt/cellular-sip/sms-state
base=http://10.77.38.1:8765
mkdir -p "$state"
chmod 700 "$state"
candidates=$(mktemp /tmp/sip-sms-clean.XXXXXX)
trap 'rm -f "$candidates"' EXIT
trap 'exit 0' HUP INT TERM

relay_status() {
    curl --noproxy '*' --interface wgsip -sS -m 6 -o /dev/null -w '%{http_code}' "$@" 2>/dev/null
}

read_sms() {
    uqmi -d /dev/cdc-wdm0 -t 3500 --storage "$1" --get-message "$2" 2>/dev/null
}

sms_hash() {
    sum=$(sha256sum)
    printf '%s\n' "${sum%% *}"
}

sim_used() {
    docker exec cellular-sip asterisk -rx 'core show channels count' | grep -q '^0 active calls$' || return 1
    since=$(date +%s)
    docker exec cellular-sip asterisk -rx 'quectel cmd quectel0 AT+CPMS?' >/dev/null || return 1
    sleep 1
    docker logs --since "$since" cellular-sip 2>&1 |
        sed -nE 's/.*\+CPMS: "SM",([0-9]+),40,.*/\1/p' | tail -1
}

check_and_forward() {
    : > "$candidates"
    online=$(relay_status "$base/ready") || return 0
    for storage in sim me; do
        listing=$(uqmi -d /dev/cdc-wdm0 -t 3500 --storage "$storage" --list-messages 2>/dev/null) || continue
        ids=$(printf '%s' "$listing" | jsonfilter -e '@[*]' 2>/dev/null) || continue
        for id in $ids; do
            case "$id" in ''|*[!0-9]*) continue ;; esac
            payload=$(read_sms "$storage" "$id") || continue
            printf '%s' "$payload" | jsonfilter -e '@.sender' >/dev/null 2>&1 || continue
            hash=$(printf '%s' "$payload" | sms_hash)
            if [ -e "$state/$hash" ]; then
                if [ "$storage" = sim ]; then
                    stamp=$(printf '%s' "$payload" | jsonfilter -e '@.timestamp' 2>/dev/null)
                    if printf '%s\n' "$stamp" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$'; then
                        printf '%s|%s|%s\n' "$stamp" "$id" "$hash" >> "$candidates"
                    fi
                fi
            elif [ "$online" = 204 ]; then
                status=$(printf '%s' "$payload" | relay_status -H 'Content-Type: application/json' --data-binary @- "$base/sms") || continue
                if [ "$status" = 204 ]; then
                    touch "$state/$hash"
                    logger -t sip-sms-7001 'Accepted one SIM message for SIP delivery to 7001'
                fi
            fi
        done
    done

    [ -s "$candidates" ] || return 0
    used=$(sim_used) || return 0
    case "$used" in ''|*[!0-9]*) return 0 ;; esac
    [ "$used" -ge 30 ] || return 0
    sort "$candidates" | while IFS='|' read -r stamp id hash; do
        [ "$used" -ge 30 ] || break
        status=$(relay_status "$base/ack/$hash") || break
        [ "$status" = 204 ] || continue
        current=$(read_sms sim "$id") || continue
        [ "$(printf '%s' "$current" | sms_hash)" = "$hash" ] || continue
        uqmi -d /dev/cdc-wdm0 -t 3500 --storage sim --delete-message "$id" >/dev/null 2>&1 || break
        remaining=$(uqmi -d /dev/cdc-wdm0 -t 3500 --storage sim --list-messages 2>/dev/null) || break
        if printf '%s' "$remaining" | jsonfilter -e '@[*]' 2>/dev/null | grep -qx "$id"; then
            break
        fi
        logger -t sip-sms-7001 'Deleted one confirmed SIM message after reaching storage threshold'
        used=$((used - 1))
    done
}

while [ "$#" -eq 0 ]; do
    check_and_forward
    sleep 20
done
check_and_forward
