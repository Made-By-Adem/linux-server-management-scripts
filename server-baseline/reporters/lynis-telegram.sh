#!/bin/bash
# Lynis audit with Telegram notifications

# Credentials live in one place. The values below are only a fallback for
# hosts provisioned before that file existed - a script that holds its own
# copy of a token is one more place to rotate and one more place to leak.
# Single source of truth for credentials; no token is written into this script.
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

###############################################################################
# Sending
#
# This reporter used to end in a bare `curl ... >/dev/null 2>&1`: no status
# check, no guard on empty credentials. A rejected message, an expired token
# and a delivered report were all indistinguishable from each other, which is
# the same silent-failure class the other reporters were fixed for.
###############################################################################

html_escape() {
    sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

send_telegram() {
    local name http_code
    name="$(basename "$0")"

    if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
        echo "$name: no Telegram credentials resolved - report NOT sent" >&2
        command -v logger >/dev/null 2>&1 && \
            logger -t "$name" "no Telegram credentials resolved; report not sent"
        return 1
    fi

    # Retried: no queue behind this, so a dropped alert is a lost alert.
    # Attempts 2 and 3 force IPv4 - api.telegram.org resolves to IPv6 first
    # here, and a flapping v6 route returns HTTP 000, no response at all.
    #
    # -d, not --data-urlencode: line breaks are written as %0A below, which
    # Telegram decodes from a plain field. Urlencoding would escape the percent
    # sign and print "%0A" throughout the message.
    local attempt v4
    for attempt in 1 2 3; do
        v4=(); [ "$attempt" -gt 1 ] && v4=(-4)
        http_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
            "${v4[@]}" \
            -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            -d chat_id="${TELEGRAM_CHAT_ID}" \
            -d parse_mode="HTML" \
            -d text="$1")
        [ "$http_code" = "200" ] && return 0
        case "$http_code" in 4*) break ;; esac   # refused; retrying changes nothing
        [ "$attempt" -lt 3 ] && sleep $((attempt * 3))
    done

    echo "$name: Telegram send failed (HTTP $http_code)" >&2
    command -v logger >/dev/null 2>&1 && \
        logger -t "$name" "Telegram send FAILED with HTTP $http_code"
    return 1
}

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

# Build Telegram message with HTML formatting
MESSAGE="🛡️ <b>Lynis Monthly Audit</b>%0A%0A"
MESSAGE+="<b>Server:</b> $(hostname | html_escape)%0A"
MESSAGE+="<b>Hardening Score:</b> <code>${HARDENING_INDEX}/100</code>%0A"
MESSAGE+="<b>Total suggestions:</b> ${SUGGESTION_COUNT}%0A%0A"
MESSAGE+="<b>Top 5 suggestions:</b>%0A"

# Format top 5 suggestions (escaped for HTML)
while IFS= read -r suggestion; do
    if [ -n "$suggestion" ]; then
        ESCAPED=$(printf %s "$suggestion" | html_escape)
        MESSAGE+="• ${ESCAPED}%0A"
    fi
done <<< "$SUGGESTIONS_CLEAN"

MESSAGE+="%0A📄 <b>Full recommendations:</b>%0A"
MESSAGE+="<code>${RECOMMENDATIONS_FILE}</code>%0A%0A"
MESSAGE+="<b>View commands:</b>%0A"
MESSAGE+="<code>cat ${RECOMMENDATIONS_FILE}</code>%0A"
MESSAGE+="<code>lynis show details TEST-ID</code>"

# Say it here, in the message that arrives first.
#
# Lynis tests whether the root filesystem honours noexec by writing a probe
# file into /, using it, and removing it. Nothing is left behind except the
# directory's mtime - which AIDE reports the next morning as a single changed
# entry. Every operator meets that alert once, spends a while working out where
# it came from, and by the following month has forgotten again.
#
# Only mentioned where AIDE actually runs. On a host without it the note would
# be advice about an alert that can never arrive.
if command -v aide >/dev/null 2>&1 && [ -f /var/lib/aide/aide.db ]; then
    MESSAGE+="%0A%0Aℹ️ <b>This audit will trigger one AIDE alert.</b>%0A"
    MESSAGE+="The noexec probe touches <code>/</code>, so the next check reports%0A"
    MESSAGE+="<code>Changed: 1 - Directory: /</code>. That entry is this run.%0A"
    MESSAGE+="Absorb it with:%0A"
    MESSAGE+="<code>aide-refresh --reason 'lynis monthly audit'</code>%0A"
    MESSAGE+="Anything else in that report is not from Lynis."
fi

send_telegram "$MESSAGE"
SEND_RC=$?

# Clean up old recommendation files (keep last 12 months)
find "$RECOMMENDATIONS_DIR" -name "lynis-recommendations-*.log" -type f -mtime +365 -delete 2>/dev/null || true

# Exit non-zero when the report did not reach Telegram, so a cron mail or a
# manual run shows the failure instead of the cleanup's exit code.
exit "$SEND_RC"
