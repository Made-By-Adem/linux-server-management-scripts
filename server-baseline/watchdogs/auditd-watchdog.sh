#!/bin/bash
###############################################################################
# auditd watchdog - alerts on STATE TRANSITIONS of critical security units
#
# The daily self-check is level-triggered: it reports what is true at 06:00.
# This is edge-triggered: it reports the moment a unit changes state, and says
# nothing the rest of the time.
#
# That distinction is the whole point. In the incident this was written for,
# auditd was stopped at 07:24:49 as the first step of the compromise. A daily
# check would have reported it hours later, if at all. Nothing alerted.
#
# Reports both directions. "auditd came back" is not noise - an unexplained
# restart is as interesting as an unexplained stop.
#
# Usage:
#   auditd-watchdog.sh           # check and alert on change (for cron/timer)
#   auditd-watchdog.sh --test    # send a test alert, verifying the alert path
#   auditd-watchdog.sh --status  # print current state, change nothing
#
# Config, from /etc/server-baseline/selfcheck.env:
#   TELEGRAM_BOT_TOKEN=...
#   TELEGRAM_CHAT_ID=...
#   WATCH_UNITS="auditd"        # optional, space separated
###############################################################################

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
set -u

CONFIG_FILE="${CONFIG_FILE:-/etc/server-baseline/selfcheck.env}"
STATE_DIR="/var/lib/server-baseline"

if [ -r "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
fi

# Accept the alternative variable names some setups already use
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-${SECRET_TOKEN:-}}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-${CHAT_ID_PERSON1:-}}"
WATCH_UNITS="${WATCH_UNITS:-auditd}"

MODE="check"
case "${1:-}" in
    --test)   MODE="test" ;;
    --status) MODE="status" ;;
    --help|-h) sed -n '2,26p' "$0"; exit 0 ;;
    "") : ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
esac

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must run as root" >&2
    exit 1
fi

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"

# Telegram's HTML parse mode rejects a message containing a raw <, > or &.
# A journal line with any of those would make the API return 400 and the alert
# would vanish silently - the exact failure class this whole watchdog exists to
# catch, so it must not be reintroduced here.
html_escape() {
    sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

send_telegram() {
    local msg="$1"

    if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
        # No credentials: still leave a trace somewhere that survives.
        logger -t auditd-watchdog "no Telegram credentials configured; alert not sent"
        echo "$msg" >&2
        return 1
    fi

    local http_code
    http_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
        -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d chat_id="${TELEGRAM_CHAT_ID}" \
        -d parse_mode="HTML" \
        -d disable_web_page_preview="true" \
        --data-urlencode text="$msg")

    if [ "$http_code" = "200" ]; then
        return 0
    fi
    # A silently failing alerter is worse than none, so make the failure loud
    # in the journal.
    logger -t auditd-watchdog "Telegram send FAILED with HTTP ${http_code}"
    return 1
}

HOST=$(hostname)
TS=$(date '+%d-%m-%Y %H:%M:%S')

if [ "$MODE" = "test" ]; then
    MSG="<b>🧪 WATCHDOG TEST</b>
<b>Host:</b> <code>${HOST}</code>
<b>Time:</b> ${TS}
<b>Watching:</b> <code>${WATCH_UNITS}</code>

<i>This is a deliberate test. If you are reading it, the alert path works.</i>"
    if send_telegram "$MSG"; then
        echo "Test alert sent."
        exit 0
    fi
    echo "Test alert FAILED - see: journalctl -t auditd-watchdog" >&2
    exit 1
fi

if [ "$MODE" = "status" ]; then
    for unit in $WATCH_UNITS; do
        printf '%-20s now=%-10s last_seen=%s\n' \
            "$unit" \
            "$(systemctl is-active "$unit" 2>/dev/null || echo unknown)" \
            "$(cat "${STATE_DIR}/${unit}.state" 2>/dev/null || echo '(none)')"
    done
    exit 0
fi

###############################################################################
# Transition check
###############################################################################

EXIT_CODE=0

for unit in $WATCH_UNITS; do
    STATE_FILE="${STATE_DIR}/${unit}.state"

    NOW=$(systemctl is-active "$unit" 2>/dev/null || true)
    NOW=${NOW:-unknown}

    # First run has no baseline. Assume "active" so that a unit already down at
    # install time is reported rather than silently accepted as normal.
    PREV=$(cat "$STATE_FILE" 2>/dev/null || echo "active")

    # Persist the new state before alerting. If the alert fails we would
    # otherwise re-fire on every run; the send failure is logged separately.
    echo "$NOW" > "$STATE_FILE"
    chmod 600 "$STATE_FILE"

    [ "$NOW" = "$PREV" ] && continue   # no transition, nothing to report

    if [ "$NOW" = "active" ]; then
        MSG="<b>✅ ${unit^^} RESTORED</b>
<b>Host:</b> <code>${HOST}</code>
<b>Time:</b> ${TS}
<b>Status:</b> active (was ${PREV})

Audit logging is running again."
        logger -t auditd-watchdog "${unit} restored on ${HOST} (was ${PREV})"
    else
        LAST=$(journalctl -u "$unit" -n1 --no-pager -o cat 2>/dev/null | head -c 300 | html_escape)
        WHO=$(who 2>/dev/null | wc -l)
        MSG="<b>🚨 ${unit^^} STOPPED</b>
<b>Host:</b> <code>${HOST}</code>
<b>Time:</b> ${TS}
<b>Status:</b> <code>${NOW}</code> (was ${PREV})
<b>Sessions:</b> ${WHO} logged in

<b>Last log entry:</b>
<pre>${LAST}</pre>

<i>Audit logging is disabled. This happens on reboot, but it is also the first step of a compromise. Verify whether this was expected.</i>"
        logger -t auditd-watchdog "${unit} STOPPED on ${HOST} (state=${NOW}, was ${PREV})"
        EXIT_CODE=1
    fi

    send_telegram "$MSG" || true
done

exit "$EXIT_CODE"
