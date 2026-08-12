#!/bin/bash
# Rkhunter scan with Telegram notifications
#
# "No warnings in the log" is NOT the same as "the scan found nothing". If
# rkhunter aborts on a configuration error it writes that error and stops - no
# warnings, no results. An earlier version of this script tested only for the
# presence of "Warning" lines, so an aborted scan produced a daily
# "✅ All Clear" message. That is precisely how a security tool goes quiet for
# months without anyone noticing.
#
# The scan is therefore only trusted when the log proves it ran to completion.
# --report-warnings-only is deliberately NOT used: it suppresses the summary
# line that is the evidence of completion.

# Credentials live in one place. The values below are only a fallback for
# hosts provisioned before that file existed - a script that holds its own
# copy of a token is one more place to rotate and one more place to leak.
# Single source of truth for credentials. No token is ever written into this
# script: one copy in one root-only file is one place to rotate and one place
# to leak.
# Credentials live with the project checkout, not in /etc. Resolution order:
#   1. $CONFIG_FILE                        explicit override
#   2. $ENV_FILE_DEFAULT                   absolute path recorded at install time
#   3. .env near this script                for running straight from the checkout
#   4. /etc/server-baseline/selfcheck.env  legacy location, still honoured
#
# The recorded path is the fragile part: move or re-clone the project and it
# stops resolving, which would make every alert silently stop. That is why
# security-selfcheck fails outright when no credentials resolve anywhere - the
# breakage shows up within a day instead of as permanent silence.
ENV_FILE_DEFAULT=""   # replaced with an absolute path at install time

resolve_env_file() {
    local self_dir c
    self_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" 2>/dev/null && pwd)" || self_dir=""
    for c in "${CONFIG_FILE:-}" "$ENV_FILE_DEFAULT"              "$self_dir/.env" "$self_dir/../.env" "$self_dir/../../.env"              /etc/server-baseline/selfcheck.env; do
        if [ -n "$c" ] && [ -r "$c" ]; then echo "$c"; return 0; fi
    done
    return 1
}
CONFIG_FILE="$(resolve_env_file || true)"
[ -n "$CONFIG_FILE" ] && . "$CONFIG_FILE"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"

if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
    command -v logger >/dev/null 2>&1 &&         logger -t "$(basename "$0")" "no Telegram credentials in /etc/server-baseline/selfcheck.env; report not sent"
fi
SCAN_LOG="/var/log/rkhunter-scan-$(date +%Y%m%d).log"

# Telegram's Markdown parser answers HTTP 400 on a single unmatched _ * ` or
# [ . rkhunter warnings are full of file paths, so real findings would fail to
# send while clean runs went through. HTML with escaped content instead.
html_escape() {
    sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

send_telegram() {
    local name http_code
    name="$(basename "$0")"

    # A reporter that cannot send must say so. Curling to
    # api.telegram.org/bot/sendMessage with an empty token fails, and
    # >/dev/null 2>&1 turns that into a silent success - the exact failure
    # class every check in this repository exists to eliminate.
    if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
        echo "$name: no Telegram credentials resolved - report NOT sent" >&2
        command -v logger >/dev/null 2>&1 &&             logger -t "$name" "no Telegram credentials resolved; report not sent"
        return 1
    fi

    http_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20         -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage"         -d chat_id="${TELEGRAM_CHAT_ID}"         -d parse_mode="HTML"         -d text="$1")

    [ "$http_code" = "200" ] && return 0

    echo "$name: Telegram rejected the message (HTTP $http_code)" >&2
    command -v logger >/dev/null 2>&1 &&         logger -t "$name" "Telegram send FAILED with HTTP $http_code"
    return 1
}

/usr/bin/rkhunter --check --skip-keypress --nocolors > "$SCAN_LOG" 2>&1
SCAN_RC=$?

# Evidence that the scan actually ran end to end
COMPLETED=$(grep -c "System checks summary" "$SCAN_LOG" 2>/dev/null)

if [ "${COMPLETED:-0}" -eq 0 ]; then
    MESSAGE="<b>🚨 RKHUNTER SCAN FAILED</b>%0A%0A"
    MESSAGE+="Server: <code>$(hostname | html_escape)</code>%0A"
    MESSAGE+="Date: $(date '+%Y-%m-%d %H:%M')%0A%0A"
    MESSAGE+="The scan did not run to completion (exit ${SCAN_RC}).%0A"
    MESSAGE+="<b>This host is currently NOT being scanned for rootkits.</b>%0A%0A"
    MESSAGE+="Last output:%0A<pre>$(tail -8 "$SCAN_LOG" | cut -c1-200 | html_escape)</pre>%0A"
    MESSAGE+="Check the config with: <code>rkhunter --config-check</code>%0A"
    MESSAGE+="Full log: <code>$SCAN_LOG</code>"
    send_telegram "$MESSAGE"

elif grep -q "^Warning:" "$SCAN_LOG"; then
    WARNINGS=$(grep "^Warning:" "$SCAN_LOG" | head -10)
    WARNING_COUNT=$(grep -c "^Warning:" "$SCAN_LOG")

    MESSAGE="<b>🔍 Rkhunter Daily Scan</b>%0A%0A"
    MESSAGE+="Found $WARNING_COUNT warning(s) on <code>$(hostname | html_escape)</code>%0A%0A"
    MESSAGE+="<b>Top warnings:</b>%0A<pre>$(echo "$WARNINGS" | html_escape)</pre>%0A"
    MESSAGE+="Full log: <code>$SCAN_LOG</code>"
    send_telegram "$MESSAGE"

else
    MESSAGE="<b>✅ Rkhunter Daily Scan</b>%0A%0A"
    MESSAGE+="Server: <code>$(hostname | html_escape)</code>%0A"
    MESSAGE+="Status: <b>All Clear</b>%0A"
    MESSAGE+="Date: $(date '+%Y-%m-%d %H:%M')%0A%0A"
    MESSAGE+="Scan completed, no warnings.%0A"
    MESSAGE+="Scan completed, no warnings.%0A"
    MESSAGE+="Full log: <code>$SCAN_LOG</code>"
fi

# Keep scan logs for 30 days
find /var/log -name "rkhunter-scan-*.log" -mtime +30 -delete 2>/dev/null || true
