#!/bin/bash
###############################################################################
# Alert path test
#
# Runs every scheduled job once, now, and says which of them actually reached
# Telegram.
#
# It exists because the failure mode of an alerting system is silence - and
# silence is also what a healthy quiet night looks like. Everything else in
# this repository is built to make controls prove they work; this is the same
# idea applied to the last link in the chain, the one that carries the news.
#
# Every failure this repository has fixed would have shown up here in under
# half an hour: the AIDE reporter that never sent, the rkhunter reporter that
# reported All Clear on an aborted scan, the .env holding a placeholder that
# expanded to an empty token, the cron entry that was never written.
#
# Usage:
#   sudo bash test-alerts.sh           # every job (25-35 minutes; AIDE is 10-20)
#   sudo bash test-alerts.sh --quick   # only the jobs that finish in seconds
#
# This sends REAL messages - five of them on a fully equipped host. Run it by
# hand after changing anything about alerting, and once a month or so to prove
# the chain is still intact. Never schedule it.
#
# Three things happen as a side effect, all deliberate:
#   - a clean AIDE run refreshes the baseline, exactly as the 05:00 cron does
#   - rkhunter and Lynis write fresh logs, which the daily self-check reads
#   - rkhunter rewrites its properties database and Lynis touches /, both AFTER
#     the AIDE run above. Absorb them with one aide-refresh when you are done
#     testing, or let tomorrow's 05:00 report them once.
#
# Exit codes: 0 = every job delivered, otherwise the number that did not.
###############################################################################

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
set -u

QUICK=false
case "${1:-}" in
    --quick)   QUICK=true ;;
    # To the end of the header block, not to a line number: that range goes
    # stale the first time the header grows, and then quietly hides the newest
    # paragraph from the help output.
    --help|-h) sed -n '3,/^#####/p' "$0" | sed '$d'; exit 0 ;;
    "")        : ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
esac

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must run as root: sudo bash $0" >&2
    exit 1
fi

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

START_STAMP="$(date '+%Y-%m-%d %H:%M:%S')"
FAILED=0; SENT=0; MISSING=0

# The scripts in /usr/local/bin are what cron runs. Testing the copies in the
# checkout would answer a question nobody asked - the installed copy is the one
# that has to work, and it is the one that drifts.

# run_job <label> <script> <ok_codes> <exit_proves_delivery> [args...]
#
# The fourth argument matters. The three reporters end on `exit "$SEND_RC"`, so
# a zero exit really does mean Telegram accepted the message. The self-check
# does not: its code describes the HOST - 1 for a failing control, 2 for
# warnings - and it returns those whether or not anything was delivered.
# Printing "sent" for it would be the same lie this script exists to expose, so
# it says "ran" and the syslog scan at the end judges its delivery.
run_job() {
    local label="$1" script="$2" ok_codes="$3" proves="$4"; shift 4

    if [ ! -x "$script" ]; then
        printf "${YELLOW}  --  %-34s not installed (%s)${NC}\n" "$label" "$script"
        MISSING=$((MISSING + 1))
        return 0
    fi

    printf "  ..  %-34s started %s\n" "$label" "$(date '+%H:%M:%S')"
    "$script" "$@" >/dev/null 2>&1
    local rc=$?

    case " $ok_codes " in
        *" $rc "*)
            if [ "$proves" = yes ]; then
                printf "${GREEN}  OK  %-34s exit %s - sent${NC}\n" "$label" "$rc"
                SENT=$((SENT + 1))
            else
                printf "${GREEN}  OK  %-34s exit %s - ran (delivery judged from syslog)${NC}\n" \
                    "$label" "$rc"
            fi ;;
        *)
            printf "${RED}  !!  %-34s exit %s - FAILED${NC}\n" "$label" "$rc"
            FAILED=$((FAILED + 1)) ;;
    esac
}

echo ""
echo "=========================================================================="
echo "  Alert path test - $(hostname) - $START_STAMP"
echo "=========================================================================="
[ "$QUICK" = false ] && echo "  Running every job. Expect 25-35 minutes; AIDE alone is 10 to 20."
[ "$QUICK" = true ]  && echo "  Quick mode: skipping rkhunter, Lynis and AIDE."
echo ""

run_job "watchdog test alert"    /usr/local/bin/security-watchdog.sh  "0"     yes --test

if [ "$QUICK" = false ]; then
    # AIDE first, and not for cosmetic reasons. rkhunter rewrites its own
    # properties database on a scan, and Lynis drops a probe file in / to test
    # whether the root filesystem honours noexec - it removes the file but the
    # directory mtime stays changed. Running either of them before AIDE
    # guarantees the integrity check reports differences, refuses to refresh
    # the baseline, and hands you an alert that this very script caused.
    #
    # In this order AIDE sees the host as the 05:00 cron would, and whatever
    # the two scanners touch afterwards is absorbed by the next refresh.
    run_job "AIDE (05:00)"                /usr/local/bin/aide-telegram.sh     "0" yes
    run_job "rkhunter (03:00)"            /usr/local/bin/rkhunter-telegram.sh "0" yes
    run_job "Lynis (1st of month, 04:00)" /usr/local/bin/lynis-telegram.sh    "0" yes
fi

# The self-check runs last, which is also where it sits in the real schedule:
# rkhunter at 03:00, AIDE at 05:00, this at 06:00. That order is not incidental
# - the self-check reads the logs the other jobs write, so running it first
# judges yesterday's state.
#
# It was first here, and on fireman it reported "the rkhunter log contains no
# completed scan" as a FAILURE while the rkhunter job two lines below was about
# to write a clean one. A run that alerts on a condition it is in the middle of
# fixing is worse than no test at all.
#
# Its exit code describes the HOST (0 clean, 1 a failing control, 2 warnings
# only), not whether its message went out. A host with a genuine finding must
# not read as a broken alert path, so every code counts as "ran" and delivery
# is judged from syslog at the end.
run_job "self-check (06:00)"     /usr/local/bin/security-selfcheck.sh "0 1 2" no  --quiet --test-alert

###############################################################################
# Syslog is the second opinion. Every reporter logs its own send failure there,
# which is how the self-check's delivery gets judged at all - and it catches a
# reporter that returns 0 for a reason unrelated to sending.
###############################################################################

echo ""
echo -e "${CYAN}Send failures logged since ${START_STAMP} (nothing here is the good outcome):${NC}"
if command -v journalctl >/dev/null 2>&1; then
    # No -p filter. Every reporter logs through plain `logger`, which defaults
    # to user.notice, so asking for warning-or-worse hid precisely the lines
    # this scan exists to find. It reported "(none)" on a host whose watchdog
    # had just logged an HTTP 401 four seconds earlier.
    LOGGED=$(journalctl --since "$START_STAMP" --no-pager 2>/dev/null \
                -t security-watchdog -t security-selfcheck \
                -t aide-telegram.sh -t rkhunter-telegram.sh -t lynis-telegram.sh \
             | grep -iE 'fail|no telegram credentials|not sent' | tail -20)
    if [ -n "$LOGGED" ]; then
        echo "$LOGGED" | sed 's/^/    /'
        FAILED=$((FAILED + 1))
    else
        echo "    (none)"
    fi
else
    echo "    journalctl unavailable - cannot cross-check, trust the exit codes above"
fi

echo ""
echo "=========================================================================="
if [ "$MISSING" -gt 0 ]; then
    echo -e "  ${YELLOW}${MISSING} job(s) are not installed on this host - nothing would send those.${NC}"
fi
if [ "$FAILED" -eq 0 ]; then
    echo -e "  ${GREEN}${SENT} job(s) reported a delivered message.${NC}"
    echo "  Now count them in Telegram. A job that says 'sent' while no message"
    echo "  arrives means the token is valid but the chat ID points elsewhere."
else
    echo -e "  ${RED}${FAILED} job(s) FAILED - see above, then: journalctl -t <script name>${NC}"
fi
echo "=========================================================================="
echo ""

exit "$FAILED"
