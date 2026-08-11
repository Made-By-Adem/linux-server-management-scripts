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
[ -r /etc/server-baseline/selfcheck.env ] && . /etc/server-baseline/selfcheck.env
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"

if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
    command -v logger >/dev/null 2>&1 &&         logger -t "$(basename "$0")" "no Telegram credentials in /etc/server-baseline/selfcheck.env; report not sent"
fi
SCAN_LOG="/var/log/rkhunter-scan-$(date +%Y%m%d).log"

send_telegram() {
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d chat_id="${TELEGRAM_CHAT_ID}" \
        -d text="$1" \
        -d parse_mode="Markdown" >/dev/null 2>&1
}

/usr/bin/rkhunter --check --skip-keypress --nocolors > "$SCAN_LOG" 2>&1
SCAN_RC=$?

# Evidence that the scan actually ran end to end
COMPLETED=$(grep -c "System checks summary" "$SCAN_LOG" 2>/dev/null)

if [ "${COMPLETED:-0}" -eq 0 ]; then
    MESSAGE="🚨 *RKHUNTER SCAN FAILED*%0A%0A"
    MESSAGE+="Server: $(hostname)%0A"
    MESSAGE+="Date: $(date '+%Y-%m-%d %H:%M')%0A%0A"
    MESSAGE+="The scan did not run to completion (exit ${SCAN_RC}).%0A"
    MESSAGE+="*This host is currently NOT being scanned for rootkits.*%0A%0A"
    MESSAGE+="Last output:%0A\`\`\`%0A$(tail -8 "$SCAN_LOG" | cut -c1-200)%0A\`\`\`%0A%0A"
    MESSAGE+="Check the config with: \`rkhunter --config-check\`%0A"
    MESSAGE+="Full log: $SCAN_LOG"
    send_telegram "$MESSAGE"

elif grep -q "^Warning:" "$SCAN_LOG"; then
    WARNINGS=$(grep "^Warning:" "$SCAN_LOG" | head -10)
    WARNING_COUNT=$(grep -c "^Warning:" "$SCAN_LOG")

    MESSAGE="🔍 *Rkhunter Daily Scan*%0A%0A"
    MESSAGE+="⚠️ Found $WARNING_COUNT warning(s) on $(hostname)%0A%0A"
    MESSAGE+="*Top warnings:*%0A\`\`\`%0A${WARNINGS}%0A\`\`\`%0A%0A"
    MESSAGE+="Full log: $SCAN_LOG"
    send_telegram "$MESSAGE"

else
    MESSAGE="✅ *Rkhunter Daily Scan*%0A%0A"
    MESSAGE+="Server: $(hostname)%0A"
    MESSAGE+="Status: *All Clear*%0A"
    MESSAGE+="Date: $(date '+%Y-%m-%d %H:%M')%0A%0A"
    MESSAGE+="Scan completed, no warnings.%0A"
    MESSAGE+="Full log: $SCAN_LOG"
    send_telegram "$MESSAGE"
fi

# Keep scan logs for 30 days
find /var/log -name "rkhunter-scan-*.log" -mtime +30 -delete 2>/dev/null || true
