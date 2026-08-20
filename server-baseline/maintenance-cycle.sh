#!/bin/bash
###############################################################################
# Maintenance cycle
#
# One command for the round COMMANDS.md calls the closing sequence: pull the
# day's fixes, apply them, absorb every deliberate change into the scanners'
# baselines, prove all five alert paths still reach Telegram, then absorb what
# the proving itself changed.
#
# It exists because the order is not obvious and getting it wrong is quiet:
#
#   - Refresh AIDE before update-baseline and you bake a baseline that those
#     same updates invalidate an instant later.
#   - Update rkhunter's property database after the test rather than before,
#     and the test's rkhunter job reports every binary your apt upgrade
#     replaced.
#   - Run rkhunter or Lynis before the AIDE job and the integrity check
#     reports the scanners' own footprints as findings.
#   - Stop at the first failing step and the scanner footprints stay in the
#     baseline, so tomorrow's 05:00 report opens with an alert this script
#     caused.
#
# Usage:
#   sudo bash maintenance-cycle.sh --reason 'reboot + apt upgrade'
#   sudo bash maintenance-cycle.sh --reason '...' --yes       # no prompts
#   sudo bash maintenance-cycle.sh --reason '...' --no-test   # skip test-alerts
#   sudo bash maintenance-cycle.sh --reason '...' --no-pull   # already pulled
#
# Expect 35-45 minutes on a host with AIDE, and around seven Telegram
# messages: two baseline records and the five job reports. Those messages are
# the evidence the run worked, not noise.
#
# On a host without AIDE - a Raspberry Pi, see RASPBERRY-PI.md - the two
# refresh steps are skipped rather than failed, and the run is much shorter.
###############################################################################

# Deliberately no `set -e`. Every step below is meant to run even when an
# earlier one failed. The second AIDE refresh is what keeps tomorrow's 05:00
# report clean, and a failing test job is the worst possible reason to skip
# it. Failures are collected and reported at the end instead.
set -u

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

REASON=""
ASSUME_YES=false
DO_TEST=true
DO_PULL=true
FAILED=()
SKIPPED=()

while [ $# -gt 0 ]; do
    case "$1" in
        --reason)  REASON="${2:-}"; shift 2 ;;
        --yes|-y)  ASSUME_YES=true; shift ;;
        --no-test) DO_TEST=false; shift ;;
        --no-pull) DO_PULL=false; shift ;;
        --help|-h) sed -n '2,34p' "$0"; exit 0 ;;
        *) echo "Unknown option: $1 (try --help)"; exit 2 ;;
    esac
done

# Arguments are validated before privileges, so running this without sudo
# still tells you what else it needs rather than only that it needs root.
#
# The reason is not decoration. It lands in the Telegram record and in
# /var/log/aide-refresh-*.log, and in a month it is the only thing that
# explains why several hundred files were accepted as the new baseline.
if [ -z "$REASON" ]; then
    echo -e "${RED}--reason is required.${NC}"
    echo "It is recorded with every baseline change, and it is what tells you"
    echo "later whether an absorbed alert was deliberate."
    echo ""
    echo "  sudo bash maintenance-cycle.sh --reason 'reboot + apt upgrade'"
    exit 2
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "This has to run as root - it writes the scanners' baselines."
    exit 1
fi

HAS_AIDE=false
if command -v aide >/dev/null 2>&1 && [ -f /var/lib/aide/aide.db ]; then
    HAS_AIDE=true
fi

step() {
    echo ""
    echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
}

record() {  # record <label> <exit-code>
    if [ "$2" -eq 0 ]; then
        echo -e "  ${GREEN}OK${NC}  $1"
    else
        echo -e "  ${RED}!!${NC}  $1 (exit $2)"
        FAILED+=("$1")
    fi
}

confirm() {  # confirm <question>; true when the user agrees
    [ "$ASSUME_YES" = true ] && return 0
    local answer
    read -r -p "$(echo -e "${YELLOW}$1${NC} (yes/no): ")" answer
    [[ "$answer" =~ ^(yes|y)$ ]]
}

echo ""
echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  Maintenance cycle - $(hostname)${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
echo "  Checkout : $PROJECT_ROOT"
echo "  Reason   : $REASON"
if [ "$HAS_AIDE" = true ]; then
    echo "  AIDE     : present - baselines will be refreshed"
    [ "$DO_TEST" = true ] && echo "  Expect   : 35-45 minutes, around 7 Telegram messages"
else
    echo "  AIDE     : not installed - refresh steps will be skipped"
    [ "$DO_TEST" = true ] && echo "  Expect   : 15-25 minutes, around 4 Telegram messages"
fi

###############################################################################
# 1. Files first. Refreshing any baseline before this bakes in a state that
#    the updates immediately invalidate.
###############################################################################
if [ "$DO_PULL" = true ]; then
    step "1. Pulling the checkout"
    git -C "$PROJECT_ROOT" pull --ff-only origin main
    record "git pull" $?
else
    SKIPPED+=("git pull (--no-pull)")
fi

step "2. update-baseline"
bash "$SCRIPT_DIR/update-baseline.sh"
record "update-baseline" $?

###############################################################################
# 2. rkhunter keeps its own baseline, and aide-refresh does not touch it.
#    After an apt upgrade every replaced binary is a finding until propupd
#    runs - so it belongs before the test, not after.
#
#    It is gated on purpose. --propupd declares the current file properties
#    correct, so on a compromised host it makes the compromise the baseline.
#    The warnings from the last scan are shown first: they are what you are
#    about to accept.
###############################################################################
step "3. rkhunter property database"
if command -v rkhunter >/dev/null 2>&1; then
    if [ -f /var/log/rkhunter.log ]; then
        # grep -c prints a count and exits 1 when that count is zero, which is
        # why the number is read rather than the exit status.
        RK_WARNINGS=$(grep -c '^Warning:' /var/log/rkhunter.log 2>/dev/null)
        RK_WARNINGS=${RK_WARNINGS:-0}
        if [ "$RK_WARNINGS" -gt 0 ]; then
            echo "  $RK_WARNINGS warning(s) in the most recent scan - propupd accepts these:"
            grep '^Warning:' /var/log/rkhunter.log | head -20 | sed 's/^/    /'
            [ "$RK_WARNINGS" -gt 20 ] && \
                echo "    ...and $((RK_WARNINGS - 20)) more, see /var/log/rkhunter.log"
        else
            echo "  No warnings in the most recent scan."
        fi
    else
        echo "  No previous scan log to show."
    fi
    echo ""
    if confirm "  Accept these as rkhunter's new baseline?"; then
        rkhunter --propupd --skip-keypress >/dev/null 2>&1
        record "rkhunter --propupd" $?
    else
        SKIPPED+=("rkhunter --propupd (declined)")
        echo "  Skipped. Expect the 03:00 report to list changed binaries."
    fi
else
    SKIPPED+=("rkhunter --propupd (rkhunter not installed)")
fi

###############################################################################
# 3. First refresh: absorb the day's deliberate changes, so the AIDE run
#    inside the test is clean and sends the check mark you actually want.
###############################################################################
step "4. AIDE baseline - before the test"
if [ "$HAS_AIDE" = true ]; then
    aide-refresh --reason "$REASON (pre-test)"
    record "aide-refresh (pre-test)" $?
else
    SKIPPED+=("aide-refresh pre-test (no AIDE on this host)")
fi

###############################################################################
# 4. Every scheduled job, once, now. AIDE runs first inside test-alerts.sh -
#    see the comment there - so the two scanners cannot pollute it.
###############################################################################
step "5. Proving the alert paths"
if [ "$DO_TEST" = true ]; then
    bash "$SCRIPT_DIR/test-alerts.sh"
    record "test-alerts" $?
else
    SKIPPED+=("test-alerts (--no-test)")
fi

###############################################################################
# 5. Second refresh: rkhunter rewrote its properties database and Lynis left
#    the mtime of / changed by its noexec probe. One refresh absorbs both.
#    This runs whatever happened above - that is the whole reason there is no
#    `set -e` in this script.
###############################################################################
step "6. AIDE baseline - after the test"
if [ "$HAS_AIDE" = true ] && [ "$DO_TEST" = true ]; then
    aide-refresh --reason "$REASON (post-test: scanner footprints)"
    record "aide-refresh (post-test)" $?
else
    SKIPPED+=("aide-refresh post-test (nothing ran that would leave footprints)")
fi

###############################################################################
# 6. The verdict on the host itself. Its exit code describes the host, not
#    this script: 0 clean, 1 a failing control, 2 warnings only.
###############################################################################
step "7. Self-check"
security-selfcheck
SELFCHECK_RC=$?
case "$SELFCHECK_RC" in
    0) echo -e "  ${GREEN}Host is clean.${NC}" ;;
    2) echo -e "  ${YELLOW}Warnings only - read them, none of them fail a control.${NC}" ;;
    *) echo -e "  ${RED}A control is failing. This one is real.${NC}"; FAILED+=("security-selfcheck") ;;
esac

echo ""
echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  Summary${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
for s in ${SKIPPED+"${SKIPPED[@]}"}; do echo -e "  ${YELLOW}--${NC}  skipped: $s"; done
if [ ${#FAILED[@]} -eq 0 ]; then
    echo -e "  ${GREEN}Every step completed.${NC}"
    if [ "$HAS_AIDE" = true ]; then
        echo "  Tomorrow's 05:00 check should report no changes."
    fi
    exit 0
fi
echo -e "  ${RED}${#FAILED[@]} step(s) failed:${NC}"
for f in "${FAILED[@]}"; do echo "    - $f"; done
echo ""
echo "  The baselines were still refreshed, so tomorrow's reports are not"
echo "  polluted by this run - but fix the above before trusting them."
exit 1
