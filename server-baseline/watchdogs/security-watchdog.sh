#!/bin/bash
###############################################################################
# Security watchdog - alerts on STATE TRANSITIONS of security controls
#
# The daily self-check is level-triggered: it reports what is true at 06:00.
# This is edge-triggered: it reports the moment a control changes state, and
# says nothing the rest of the time.
#
# That distinction is the whole point. In the incident this was written for,
# auditd was stopped at 07:24:49 as the first step of the compromise and the
# payload was deployed 25 seconds later. A daily check would have reported it
# hours afterwards. Nothing alerted at all.
#
# Reports both directions. "It came back" is not noise - an unexplained restart
# is as interesting as an unexplained stop.
#
# WHAT IS WATCHED
#
#   auditd            systemd unit state
#   fail2ban          systemd unit state
#   fail2ban-jail     synthetic: is the sshd jail actually reachable?
#
# The last one exists because "fail2ban is active" was true throughout the
# incident while the jail banned nothing. A unit being up is not the same as the
# control working, so the jail is tracked as a state of its own.
#
# Usage:
#   security-watchdog.sh           # check and alert on change (for cron/timer)
#   security-watchdog.sh --test    # send a test alert, verifying the alert path
#   security-watchdog.sh --status  # print current state, change nothing
#
# Config, from /etc/server-baseline/selfcheck.env:
#   TELEGRAM_BOT_TOKEN=...
#   TELEGRAM_CHAT_ID=...
#   WATCH_UNITS="auditd fail2ban"   # optional, space separated
#   WATCH_JAIL="sshd"               # optional, "" disables the jail check
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
WATCH_UNITS="${WATCH_UNITS:-auditd fail2ban}"
WATCH_JAIL="${WATCH_JAIL-sshd}"

MODE="check"
case "${1:-}" in
    --test)   MODE="test" ;;
    --status) MODE="status" ;;
    --help|-h) sed -n '2,38p' "$0"; exit 0 ;;
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
# would vanish silently - the exact failure class this watchdog exists to catch,
# so it must not be reintroduced here.
html_escape() {
    sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

send_telegram() {
    local msg="$1"

    if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
        logger -t security-watchdog "no Telegram credentials configured; alert not sent"
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
    # A silently failing alerter is worse than none, so make it loud in syslog.
    logger -t security-watchdog "Telegram send FAILED with HTTP ${http_code}"
    return 1
}

# What this control is for, and why its absence matters. Shown in the alert so
# whoever reads it at 03:00 does not have to remember.
impact_of() {
    case "$1" in
        auditd)
            echo "Syscall auditing is off. Changes to shell profiles, cron, systemd units and SSH keys are no longer recorded. Stopping auditd is a normal part of a reboot - and also the first step of a compromise." ;;
        fail2ban)
            echo "Brute-force protection is off. SSH is now accepting unlimited authentication attempts without banning anything." ;;
        fail2ban-jail)
            echo "The fail2ban service is running but the sshd jail is not reachable. This is the dangerous case: the service reports healthy while banning nothing at all." ;;
        *)
            echo "This security control is no longer running." ;;
    esac
}

recovery_of() {
    case "$1" in
        auditd)        echo "Audit logging is running again." ;;
        fail2ban)      echo "Brute-force protection is running again." ;;
        fail2ban-jail) echo "The sshd jail is reachable again." ;;
        *)             echo "The control is running again." ;;
    esac
}

# Current state of a watched thing. Real units resolve through systemctl; the
# synthetic fail2ban-jail entry resolves through fail2ban-client.
state_of() {
    case "$1" in
        fail2ban-jail)
            if ! systemctl is-active fail2ban >/dev/null 2>&1; then
                echo "service-down"
            elif fail2ban-client status "$WATCH_JAIL" >/dev/null 2>&1; then
                echo "active"
            else
                echo "jail-unreachable"
            fi
            ;;
        *)
            systemctl is-active "$1" 2>/dev/null || echo "inactive"
            ;;
    esac
}

# Only watch what is actually installed on this host.
WATCH_LIST=""
for unit in $WATCH_UNITS; do
    if systemctl list-unit-files "${unit}.service" >/dev/null 2>&1 && \
       systemctl cat "$unit" >/dev/null 2>&1; then
        WATCH_LIST="$WATCH_LIST $unit"
    fi
done
if [ -n "$WATCH_JAIL" ] && command -v fail2ban-client >/dev/null 2>&1; then
    WATCH_LIST="$WATCH_LIST fail2ban-jail"
fi
WATCH_LIST="${WATCH_LIST# }"

HOST=$(hostname)
TS=$(date '+%d-%m-%Y %H:%M:%S')

if [ "$MODE" = "test" ]; then
    STATE_LINES=""
    for unit in $WATCH_LIST; do
        STATE_LINES="${STATE_LINES}• <code>${unit}</code>: $(state_of "$unit")
"
    done
    MSG="<b>🧪 WATCHDOG TEST</b>
<b>Host:</b> <code>${HOST}</code>
<b>Time:</b> ${TS}

<b>Currently watching:</b>
${STATE_LINES}
<i>This is a deliberate test. If you are reading it, the alert path works.</i>"
    if send_telegram "$MSG"; then
        echo "Test alert sent. Watching: $WATCH_LIST"
        exit 0
    fi
    echo "Test alert FAILED - see: journalctl -t security-watchdog" >&2
    exit 1
fi

if [ "$MODE" = "status" ]; then
    for unit in $WATCH_LIST; do
        printf '%-18s now=%-18s last_seen=%s\n' \
            "$unit" \
            "$(state_of "$unit")" \
            "$(cat "${STATE_DIR}/${unit}.state" 2>/dev/null || echo '(none)')"
    done
    exit 0
fi

###############################################################################
# Transition check
###############################################################################

EXIT_CODE=0

for unit in $WATCH_LIST; do
    STATE_FILE="${STATE_DIR}/${unit}.state"

    NOW=$(state_of "$unit")
    NOW=${NOW:-unknown}

    # First run has no baseline. Assume "active" so a control that is already
    # broken at install time is reported rather than silently accepted.
    PREV=$(cat "$STATE_FILE" 2>/dev/null || echo "active")

    # Persist before alerting. If the send fails we would otherwise re-fire
    # every minute; the send failure itself is logged separately.
    echo "$NOW" > "$STATE_FILE"
    chmod 600 "$STATE_FILE"

    [ "$NOW" = "$PREV" ] && continue   # no transition, nothing to report

    LABEL=$(echo "$unit" | tr '[:lower:]-' '[:upper:] ')

    if [ "$NOW" = "active" ]; then
        MSG="<b>✅ ${LABEL} RESTORED</b>
<b>Host:</b> <code>${HOST}</code>
<b>Time:</b> ${TS}
<b>Status:</b> active (was <code>${PREV}</code>)

$(recovery_of "$unit")"
        logger -t security-watchdog "${unit} restored on ${HOST} (was ${PREV})"
    else
        case "$unit" in
            fail2ban-jail) JOURNAL_UNIT="fail2ban" ;;
            *)             JOURNAL_UNIT="$unit" ;;
        esac
        LAST=$(journalctl -u "$JOURNAL_UNIT" -n1 --no-pager -o cat 2>/dev/null | head -c 300 | html_escape)
        WHO=$(who 2>/dev/null | wc -l)

        MSG="<b>🚨 ${LABEL} STOPPED</b>
<b>Host:</b> <code>${HOST}</code>
<b>Time:</b> ${TS}
<b>Status:</b> <code>${NOW}</code> (was <code>${PREV}</code>)
<b>Sessions:</b> ${WHO} logged in

<b>Impact:</b>
$(impact_of "$unit")

<b>Last log entry:</b>
<pre>${LAST}</pre>

<i>Verify whether this was expected.</i>"
        logger -t security-watchdog "${unit} STOPPED on ${HOST} (state=${NOW}, was ${PREV})"
        EXIT_CODE=1
    fi

    send_telegram "$MSG" || true
done

exit "$EXIT_CODE"
