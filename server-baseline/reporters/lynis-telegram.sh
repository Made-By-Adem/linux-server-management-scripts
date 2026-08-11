#!/bin/bash
# Lynis audit with Telegram notifications

# Credentials live in one place. The values below are only a fallback for
# hosts provisioned before that file existed - a script that holds its own
# copy of a token is one more place to rotate and one more place to leak.
# Single source of truth for credentials; no token is written into this script.
[ -r /etc/server-baseline/selfcheck.env ] && . /etc/server-baseline/selfcheck.env
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"

if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
    command -v logger >/dev/null 2>&1 &&         logger -t lynis-telegram "no Telegram credentials in /etc/server-baseline/selfcheck.env; report not sent"
fi
LYNIS_LOG="/var/log/lynis-report.dat"
RECOMMENDATIONS_DIR="/var/log/lynis-recommendations"
DATE_STAMP=$(date +%Y%m%d-%H%M%S)
RECOMMENDATIONS_FILE="${RECOMMENDATIONS_DIR}/lynis-recommendations-${DATE_STAMP}.log"

# Create recommendations directory if it doesn't exist
mkdir -p "$RECOMMENDATIONS_DIR"

# Remove stale PID file if exists (prevents "another process running" warning)
rm -f /run/lynis/lynis.pid 2>/dev/null || true

# Run lynis audit (supports both GitHub and legacy apt installations)
if [ -x /usr/local/lynis/lynis ]; then
    /usr/local/lynis/lynis audit system --quiet --quick
elif [ -x /usr/sbin/lynis ]; then
    /usr/sbin/lynis audit system --quiet --quick
elif [ -x /usr/local/bin/lynis ]; then
    /usr/local/bin/lynis audit system --quiet --quick
else
    echo "Error: Lynis not found"
    exit 1
fi

# Extract score and suggestions
HARDENING_INDEX=$(grep "hardening_index=" "$LYNIS_LOG" | cut -d'=' -f2)
SUGGESTION_COUNT=$(grep -c "suggestion\[\]=" "$LYNIS_LOG")

# Extract top 5 suggestions - get only the description (second field after TEST-ID)
# Format in lynis: suggestion[]=TEST-ID|Description|Details|Solution|
SUGGESTIONS_CLEAN=$(grep "suggestion\[\]=" "$LYNIS_LOG" | head -5 | cut -d'|' -f2)

# Export ALL recommendations to a dated log file
echo "Lynis Security Recommendations Report" > "$RECOMMENDATIONS_FILE"
echo "Generated: $(date '+%Y-%m-%d %H:%M:%S')" >> "$RECOMMENDATIONS_FILE"
echo "Server: $(hostname)" >> "$RECOMMENDATIONS_FILE"
echo "Hardening Index: ${HARDENING_INDEX}/100" >> "$RECOMMENDATIONS_FILE"
echo "Total Suggestions: ${SUGGESTION_COUNT}" >> "$RECOMMENDATIONS_FILE"
echo "" >> "$RECOMMENDATIONS_FILE"
echo "═══════════════════════════════════════════════════════════════" >> "$RECOMMENDATIONS_FILE"
echo "ALL RECOMMENDATIONS:" >> "$RECOMMENDATIONS_FILE"
echo "═══════════════════════════════════════════════════════════════" >> "$RECOMMENDATIONS_FILE"
echo "" >> "$RECOMMENDATIONS_FILE"

# Extract and format all suggestions with TEST-ID and description
grep "suggestion\[\]=" "$LYNIS_LOG" | while IFS= read -r line; do
    TEST_ID=$(echo "$line" | cut -d'=' -f2 | cut -d'|' -f1)
    DESCRIPTION=$(echo "$line" | cut -d'|' -f2)
    echo "[$TEST_ID] $DESCRIPTION"
done | nl -w3 -s'. ' >> "$RECOMMENDATIONS_FILE"

echo "" >> "$RECOMMENDATIONS_FILE"
echo "═══════════════════════════════════════════════════════════════" >> "$RECOMMENDATIONS_FILE"
echo "Full report: /var/log/lynis-report.dat" >> "$RECOMMENDATIONS_FILE"
echo "Detailed log: /var/log/lynis.log" >> "$RECOMMENDATIONS_FILE"
echo "═══════════════════════════════════════════════════════════════" >> "$RECOMMENDATIONS_FILE"

# Set appropriate permissions
chmod 644 "$RECOMMENDATIONS_FILE"

# Report locations
REPORT_FILE="/var/log/lynis-report.dat"
REPORT_LOG="/var/log/lynis.log"

# Function to escape HTML special characters
escape_html() {
    echo "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'
}

# Build Telegram message with HTML formatting
MESSAGE="🛡️ <b>Lynis Monthly Audit</b>%0A%0A"
MESSAGE+="<b>Server:</b> $(hostname)%0A"
MESSAGE+="<b>Hardening Score:</b> <code>${HARDENING_INDEX}/100</code>%0A"
MESSAGE+="<b>Total suggestions:</b> ${SUGGESTION_COUNT}%0A%0A"
MESSAGE+="<b>Top 5 suggestions:</b>%0A"

# Format top 5 suggestions (escaped for HTML)
while IFS= read -r suggestion; do
    if [ -n "$suggestion" ]; then
        ESCAPED=$(escape_html "$suggestion")
        MESSAGE+="• ${ESCAPED}%0A"
    fi
done <<< "$SUGGESTIONS_CLEAN"

MESSAGE+="%0A📄 <b>Full recommendations:</b>%0A"
MESSAGE+="<code>${RECOMMENDATIONS_FILE}</code>%0A%0A"
MESSAGE+="<b>View commands:</b>%0A"
MESSAGE+="<code>cat ${RECOMMENDATIONS_FILE}</code>%0A"
MESSAGE+="<code>lynis show details TEST-ID</code>"

curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d chat_id="${TELEGRAM_CHAT_ID}" \
    -d text="${MESSAGE}" \
    -d parse_mode="HTML" >/dev/null 2>&1

# Clean up old recommendation files (keep last 12 months)
find "$RECOMMENDATIONS_DIR" -name "lynis-recommendations-*.log" -type f -mtime +365 -delete 2>/dev/null || true
