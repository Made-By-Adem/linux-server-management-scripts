#!/bin/bash
###############################################################################
# Baseline Update
#
# For servers already provisioned by an older version of install-script.sh.
#
# Detects which of the known problems this host actually has, and offers to fix
# them one at a time. Checks that find nothing are reported and skipped - you are
# only prompted about things that are genuinely wrong here.
#
# Every fix verifies its own result afterwards. "The command succeeded" is not
# the same as "the control works" - that gap is the reason this script exists.
#
# Usage:
#   sudo bash update-baseline.sh              # detect, then prompt per fix
#   sudo bash update-baseline.sh --check      # detect only, change nothing
#   sudo bash update-baseline.sh --dry-run    # show what each fix would do
#   sudo bash update-baseline.sh --yes        # accept the default for every prompt
#
# Safe to run repeatedly. Nothing here closes SSH access.
###############################################################################

set -u

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

MODE="interactive"
DRY_RUN=false
ASSUME_YES=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check)   MODE="check"; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        --yes|-y)  ASSUME_YES=true; shift ;;
        --help|-h) sed -n '2,21p' "$0"; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must run as root: sudo bash $0" >&2
    exit 1
fi

APPLIED=(); SKIPPED=(); FAILED=(); CLEAN=(); ADVISORY=()

# SSH_CLIENT is unset when this runs from the console or from cron, and the
# script uses `set -u`.
CLIENT_IP="${SSH_CLIENT:-}"
CLIENT_IP="${CLIENT_IP%% *}"
CLIENT_IP="${CLIENT_IP:-<your-ip>}"
HOST_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
HOST_IP="${HOST_IP:-<server-ip>}"
LOGIN_USER="${SUDO_USER:-${USER:-root}}"

log()      { echo -e "$1"; }
ok()       { echo -e "  ${GREEN}✓${NC} $1"; }
bad()      { echo -e "  ${RED}✗${NC} $1"; }
note()     { echo -e "  ${YELLOW}!${NC} $1"; }

header() {
    echo ""
    echo -e "${BOLD}══════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  $1${NC}"
    echo -e "${BOLD}══════════════════════════════════════════════════════════════════${NC}"
}

# offer <id> <title> <why> <fix_function>
# The caller has already established that the fix is needed.
offer() {
    local id="$1" title="$2" why="$3" fix_fn="$4"

    echo ""
    echo -e "${YELLOW}▸ $title${NC}"
    echo "$why" | sed 's/^/    /'
    echo ""

    if [ "$MODE" = "check" ]; then
        SKIPPED+=("$id (check mode)")
        return 0
    fi

    if [ "$DRY_RUN" = true ]; then
        echo -e "    ${CYAN}[DRY-RUN] would apply this fix${NC}"
        SKIPPED+=("$id (dry-run)")
        return 0
    fi

    local answer="y"
    if [ "$ASSUME_YES" = false ]; then
        read -r -p "    Apply this fix? (Y/n): " answer </dev/tty
        answer=${answer:-y}
    fi

    if [[ ! $answer =~ ^[Yy]$ ]]; then
        SKIPPED+=("$id (declined)")
        note "Skipped"
        return 0
    fi

    if "$fix_fn"; then
        APPLIED+=("$id")
    else
        FAILED+=("$id")
        bad "Fix did not complete cleanly - see the output above"
    fi
}

###############################################################################
header "Baseline Update - $(hostname) - $(date '+%Y-%m-%d %H:%M')"
###############################################################################

if [ "$MODE" = "check" ]; then
    log "${CYAN}Check mode: detecting only, nothing will be changed.${NC}"
elif [ "$DRY_RUN" = true ]; then
    log "${CYAN}Dry-run: showing what would be done, nothing will be changed.${NC}"
fi

###############################################################################
header "0. Alert credentials"
###############################################################################
#
# There used to be two places credentials could live: baked into each generated
# *-telegram.sh by the installer, and /etc/server-baseline/selfcheck.env for the
# newer tooling. Anything reading the wrong one just stays silent, which is a
# poor property for an alerting system.
#
# One file now. If the old reporters already hold working credentials, they are
# lifted from there rather than asked for again.

PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
CRED_FILE="$PROJECT_ROOT/.env"

# Every script installed into /usr/local/bin loses its link to the checkout, so
# the absolute path to the credential file is recorded inside it at install
# time. This runs after each install below.
bake_env_path() {
    local target="$1"
    [ -f "$target" ] || return 0
    sed -i "s|^ENV_FILE_DEFAULT=.*|ENV_FILE_DEFAULT=\"$CRED_FILE\"   # recorded at install time|" "$target"
}

if [ -r "$CRED_FILE" ] && grep -q 'TELEGRAM_BOT_TOKEN=.' "$CRED_FILE" 2>/dev/null; then
    ok "Alert credentials are configured ($CRED_FILE)"
    CLEAN+=("alert-credentials")
    for t in /usr/local/bin/security-watchdog.sh /usr/local/bin/security-selfcheck.sh \
             /usr/local/bin/aide-refresh.sh /usr/local/bin/aide-telegram.sh \
             /usr/local/bin/rkhunter-telegram.sh /usr/local/bin/lynis-telegram.sh; do
        bake_env_path "$t"
    done
else
    # Recover them from whichever generated reporter still has them
    FOUND_TOKEN=""; FOUND_CHAT=""
    for f in /usr/local/bin/aide-telegram.sh /usr/local/bin/rkhunter-telegram.sh \
             /usr/local/bin/lynis-telegram.sh; do
        [ -r "$f" ] || continue
        [ -z "$FOUND_TOKEN" ] && FOUND_TOKEN=$(grep -oP '^TELEGRAM_BOT_TOKEN="\K[^"]+' "$f" 2>/dev/null | grep -v REPLACE_ | head -1)
        [ -z "$FOUND_CHAT" ]  && FOUND_CHAT=$(grep -oP '^TELEGRAM_CHAT_ID="\K[^"]+' "$f" 2>/dev/null | grep -v REPLACE_ | head -1)
    done

    # Also honour the legacy /etc location as a source
    if [ -z "$FOUND_TOKEN" ] && [ -r /etc/server-baseline/selfcheck.env ]; then
        FOUND_TOKEN=$(grep -oP '^TELEGRAM_BOT_TOKEN=\K.+' /etc/server-baseline/selfcheck.env 2>/dev/null | head -1)
        FOUND_CHAT=$(grep -oP '^TELEGRAM_CHAT_ID=\K.+' /etc/server-baseline/selfcheck.env 2>/dev/null | head -1)
    fi

    write_creds() {
        printf 'TELEGRAM_BOT_TOKEN=%s\nTELEGRAM_CHAT_ID=%s\n' "$1" "$2" > "$CRED_FILE"
        chmod 600 "$CRED_FILE"
        ok "Wrote $CRED_FILE (mode 600)"

        for t in /usr/local/bin/security-watchdog.sh /usr/local/bin/security-selfcheck.sh \
                 /usr/local/bin/aide-refresh.sh /usr/local/bin/aide-telegram.sh \
                 /usr/local/bin/rkhunter-telegram.sh /usr/local/bin/lynis-telegram.sh; do
            bake_env_path "$t"
        done
        ok "Recorded that path in the installed scripts"
        note "'.env' is already in .gitignore, so it cannot be committed."
        note "If you move or re-clone this checkout, copy .env across - otherwise"
        note "alerting goes quiet. The daily self-check fails when it cannot find it."
        return 0
    }

    if [ -n "$FOUND_TOKEN" ] && [ -n "$FOUND_CHAT" ]; then
        echo "    Found working credentials in an existing script on this host."
        echo "    Chat ID: $FOUND_CHAT   Token: ${FOUND_TOKEN:0:12}…(withheld)"

        creds_fix() { write_creds "$FOUND_TOKEN" "$FOUND_CHAT"; }

        offer "alert-credentials" "Alerting has no credentials where the tooling looks" \
"Credentials exist on this host, but only inside the old generated reporter
scripts. The watchdog, the daily self-check and aide-refresh look for
$CRED_FILE, which is absent - so they install, run, and say nothing. An alerting
system that is silent for a configuration reason looks exactly like one with
nothing to report.

Fix: copy the existing credentials into the project .env. Nothing is retyped and
no new token is needed." \
            creds_fix

    elif [ "$MODE" = "check" ] || [ "$DRY_RUN" = true ] || [ "$ASSUME_YES" = true ]; then
        bad "No alert credentials found anywhere - every alert will be silent"
        ADVISORY+=("No Telegram credentials in $CRED_FILE - run this script interactively to enter them")

    else
        # Nothing to recover, so ask. Silent alerting is the failure mode this
        # whole branch exists to remove; it should not be the default outcome
        # of not having a file.
        bad "No alert credentials found anywhere on this host"
        echo ""
        echo "    Without them the watchdog and the daily self-check run but stay silent."
        echo "    Enter them now, or leave blank to skip."
        echo ""
        read -r -p "    Telegram bot token: " NEW_TOKEN </dev/tty
        if [ -n "$NEW_TOKEN" ]; then
            read -r -p "    Telegram chat ID:   " NEW_CHAT </dev/tty
        fi

        if [ -n "$NEW_TOKEN" ] && [ -n "${NEW_CHAT:-}" ]; then
            if write_creds "$NEW_TOKEN" "$NEW_CHAT"; then
                APPLIED+=("alert-credentials")
                if [ -x /usr/local/bin/security-watchdog.sh ]; then
                    note "Sending a test alert to confirm they work..."
                    /usr/local/bin/security-watchdog.sh --test || \
                        bad "Test alert failed - check the token and chat ID"
                fi
            fi
        else
            SKIPPED+=("alert-credentials (declined)")
            ADVISORY+=("No Telegram credentials in $CRED_FILE - the watchdog and self-check cannot alert")
        fi
    fi
fi

###############################################################################
header "1. Fail2ban SSH jail"
###############################################################################

f2b_needs_fix() {
    command -v fail2ban-client >/dev/null 2>&1 || return 1

    # jail.local that is a verbatim copy of jail.conf overrides jail.d/*.conf
    cmp -s /etc/fail2ban/jail.local /etc/fail2ban/jail.conf 2>/dev/null && return 0
    # config in a .conf file is overridden by any jail.local
    [ -f /etc/fail2ban/jail.d/server-baseline.conf ] && return 0
    # jail pointed at a log file that does not exist
    fail2ban-client get sshd logpath 2>/dev/null | grep -q '/var/log/auth.log' && \
        [ ! -s /var/log/auth.log ] && return 0
    # jail not up at all
    fail2ban-client status sshd >/dev/null 2>&1 || return 0
    return 1
}

f2b_fix() {
    if cmp -s /etc/fail2ban/jail.local /etc/fail2ban/jail.conf 2>/dev/null; then
        cp /etc/fail2ban/jail.local "/etc/fail2ban/jail.local.bak.$(date +%Y%m%d_%H%M%S)"
        rm -f /etc/fail2ban/jail.local
        ok "Removed jail.local (was a verbatim copy of jail.conf)"
    fi

    rm -f /etc/fail2ban/jail.d/server-baseline.conf
    mkdir -p /etc/fail2ban/jail.d

    # backend = systemd needs the python3-systemd bindings. They are only a
    # Recommends of fail2ban, so on a minimal image the jail would fail to
    # initialise - the same silent failure this fix is meant to remove.
    if ! python3 -c "import systemd.journal" >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y python3-systemd >/dev/null 2>&1 && \
            ok "Installed python3-systemd (required for backend = systemd)" || \
            bad "Could not install python3-systemd - the jail will not start"
    fi

    cat > /etc/fail2ban/jail.d/zz-server-baseline.local <<'EOF'
# Server Baseline Fail2ban Configuration
# Read order: jail.conf -> jail.d/*.conf -> jail.local -> jail.d/*.local
# This file uses .local so it is read last and actually takes effect.

[DEFAULT]
backend  = systemd
bantime  = 3600
findtime = 600
maxretry = 5

[sshd]
enabled      = true
port         = 22,888
filter       = sshd
backend      = systemd
journalmatch = _SYSTEMD_UNIT=ssh.service
maxretry     = 3
bantime      = 7200
findtime     = 600
EOF

    systemctl restart fail2ban || return 1

    local up=false
    for _ in $(seq 1 10); do
        if fail2ban-client status sshd >/dev/null 2>&1; then up=true; break; fi
        sleep 2
    done

    if [ "$up" = true ]; then
        ok "sshd jail is active"

        # Confirm the read order came out right by asking fail2ban what it
        # resolved, not by trusting the files we just wrote.
        if fail2ban-client get sshd journalmatch 2>/dev/null | grep -q '_SYSTEMD_UNIT'; then
            ok "Jail resolved to the systemd backend (journalmatch is set)"
        else
            bad "Jail is up but did NOT resolve to the systemd backend"
            note "Something later in the read order is overriding it."
            note "Inspect with: fail2ban-client -d | grep sshd"
            return 1
        fi

        fail2ban-client status sshd | sed 's/^/    /'

        local attempts
        attempts=$(journalctl -u ssh --since "-7 days" --no-pager 2>/dev/null | \
                   grep -iE 'Failed password|Invalid user' | wc -l)
        note "The jail now reads the journal. Over the last 7 days this host saw"
        note "$attempts failed logins - bans should start appearing within the hour."
        return 0
    fi

    bad "fail2ban restarted but the sshd jail did not come up"
    echo "    Diagnose: fail2ban-client -d | grep sshd ; journalctl -u fail2ban -n 50"
    return 1
}

if ! command -v fail2ban-client >/dev/null 2>&1; then
    note "fail2ban is not installed - skipping"
    SKIPPED+=("fail2ban (not installed)")
elif f2b_needs_fix; then
    offer "fail2ban" "The SSH jail cannot ban" \
"On Ubuntu 24.04 sshd logs only to the journal; a jail reading /var/log/auth.log
starts, reports enabled, and bans nothing. On top of that, a jail.local copied
from jail.conf is read AFTER jail.d/*.conf and silently overrides everything.

Fix: write the config to jail.d/zz-server-baseline.local with backend=systemd,
remove the overriding jail.local, restart, then verify the jail is really up." \
        f2b_fix
else
    ok "sshd jail is active and reading a live log source"
    CLEAN+=("fail2ban")
fi

###############################################################################
header "2. Audit rules for persistence paths"
###############################################################################

audit_needs_fix() {
    command -v auditctl >/dev/null 2>&1 || return 1
    auditctl -l 2>/dev/null | grep -q -- '-w /etc/profile' && return 1
    return 0
}

audit_fix() {
    cat > /etc/audit/rules.d/10-persistence.rules <<'EOF'
# --- Shell profile / PATH injection ---
-w /etc/profile -p wa -k profile_tampering -k persist
-w /etc/profile.d/ -p wa -k profile_tampering -k persist
-w /etc/bash.bashrc -p wa -k profile_tampering -k persist
-w /etc/environment -p wa -k profile_tampering -k persist
-w /root/.profile -p wa -k profile_tampering -k persist
-w /root/.bashrc -p wa -k profile_tampering -k persist

# --- Scheduled execution ---
-w /etc/crontab -p wa -k cron_tampering -k persist
-w /etc/cron.d/ -p wa -k cron_tampering -k persist
-w /etc/cron.hourly/ -p wa -k cron_tampering -k persist
-w /etc/cron.daily/ -p wa -k cron_tampering -k persist
-w /etc/cron.weekly/ -p wa -k cron_tampering -k persist
-w /etc/cron.monthly/ -p wa -k cron_tampering -k persist
-w /var/spool/cron/crontabs/ -p wa -k cron_tampering -k persist
-a always,exit -F arch=b64 -S execve -F path=/usr/bin/crontab -k cron_tampering -k persist

# --- Service persistence ---
-w /etc/systemd/system/ -p wa -k systemd_tampering -k persist
-w /lib/systemd/system/ -p wa -k systemd_tampering -k persist
-w /usr/lib/systemd/system/ -p wa -k systemd_tampering -k persist
-a always,exit -F arch=b64 -S execve -F path=/usr/bin/systemctl -k systemd_tampering -k persist

# --- Loader / library hijacking ---
-w /etc/ld.so.preload -p wa -k preload_tampering -k persist
-w /etc/ld.so.conf -p wa -k preload_tampering -k persist
-w /etc/ld.so.conf.d/ -p wa -k preload_tampering -k persist

# --- Remote access / identity ---
-w /root/.ssh/ -p wa -k ssh_key_tampering -k persist
-w /etc/passwd -p wa -k identity_tampering -k persist
-w /etc/shadow -p wa -k identity_tampering -k persist
-w /etc/sudoers -p wa -k identity_tampering -k persist
-w /etc/sudoers.d/ -p wa -k identity_tampering -k persist

# --- Anti-forensics ---
-a always,exit -F arch=b64 -S execve -F path=/usr/bin/touch -F uid=0 -k timestomp -k persist

# --- Execution from writable locations ---
-a always,exit -F arch=b64 -S execve -F dir=/tmp -k exec_from_tmp -k persist
-a always,exit -F arch=b64 -S execve -F dir=/var/tmp -k exec_from_tmp -k persist
-a always,exit -F arch=b64 -S execve -F dir=/dev/shm -k exec_from_tmp -k persist
EOF

    # Drop the dead auth.log watch from the older rule set
    if [ -f /etc/audit/rules.d/ssh-security.rules ]; then
        sed -i '/\/var\/log\/auth\.log/d' /etc/audit/rules.d/ssh-security.rules
    fi

    systemctl enable auditd >/dev/null 2>&1 || true
    systemctl restart auditd >/dev/null 2>&1 || true
    augenrules --load || return 1

    local count
    count=$(auditctl -l 2>/dev/null | wc -l)
    if [ "${count:-0}" -gt 25 ]; then
        ok "$count audit rules loaded"
        note "Search everything at once with: ausearch -k persist -i"
        return 0
    fi
    bad "Only ${count} rules loaded - expected 30+"
    return 1
}

if ! command -v auditctl >/dev/null 2>&1; then
    note "auditd is not installed"
    ADVISORY+=("auditd not installed - install with: apt-get install -y auditd audispd-plugins")
elif audit_needs_fix; then
    offer "auditd-rules" "No audit coverage of persistence paths" \
"The original rule set watched sshd_config, /home, root execve and
/var/log/auth.log. None of those catch a PATH hijack in /etc/profile, a cron
entry, a self-deleting systemd unit, or a dropped SSH key.

Fix: install 10-persistence.rules covering shell profiles, cron, systemd units,
the dynamic loader, SSH keys, timestomping and execution from temp directories,
then load them with augenrules and verify the count." \
        audit_fix
else
    ok "Persistence paths are covered by audit watches"
    CLEAN+=("auditd-rules")
fi

###############################################################################
header "3. Process accounting"
###############################################################################

if ! command -v accton >/dev/null 2>&1; then
    note "acct is not installed"
    ADVISORY+=("acct not installed - install with: apt-get install -y acct")
elif systemctl is-active acct >/dev/null 2>&1; then
    ok "Process accounting is active"
    CLEAN+=("acct")
else
    acct_fix() {
        systemctl enable --now acct || return 1
        systemctl is-active acct >/dev/null 2>&1 || return 1
        ok "Process accounting is now active"
        return 0
    }
    offer "acct" "Process accounting is not running" \
"Without it there is no command history for the window that matters. 'systemctl
enable' alone is not enough - it has to be started as well.

Fix: systemctl enable --now acct" \
        acct_fix
fi

###############################################################################
header "4. security watchdog"
###############################################################################

if [ ! -f "$SCRIPT_DIR/watchdogs/security-watchdog.sh" ]; then
    note "watchdogs/security-watchdog.sh not found next to this script - skipping"
    SKIPPED+=("security-watchdog (source missing)")
elif systemctl is-active security-watchdog.timer >/dev/null 2>&1; then
    ok "security watchdog timer is active"
    CLEAN+=("security-watchdog")
else
    watchdog_fix() {
        install -m 700 -o root -g root \
            "$SCRIPT_DIR/watchdogs/security-watchdog.sh" /usr/local/bin/security-watchdog.sh
        ln -sf /usr/local/bin/security-watchdog.sh /usr/local/bin/security-watchdog

        cat > /etc/systemd/system/security-watchdog.service <<'EOF'
[Unit]
Description=Alert on auditd state changes

[Service]
Type=oneshot
ExecStart=/usr/local/bin/security-watchdog.sh
# Exit 1 means "auditd is down" - that is the alert, not a unit failure
SuccessExitStatus=0 1
EOF

        cat > /etc/systemd/system/security-watchdog.timer <<'EOF'
[Unit]
Description=Check auditd state every minute

[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
AccuracySec=10s
Unit=security-watchdog.service

[Install]
WantedBy=timers.target
EOF

        systemctl daemon-reload
        systemctl enable --now security-watchdog.timer || return 1

        # Establish the baseline so the first scheduled run does not false-alert
        /usr/local/bin/security-watchdog.sh >/dev/null 2>&1 || true

        echo '0 9 1 * * root /usr/local/bin/security-watchdog.sh --test' \
            > /etc/cron.d/security-watchdog-test
        chmod 644 /etc/cron.d/security-watchdog-test

        systemctl is-active security-watchdog.timer >/dev/null 2>&1 || return 1
        ok "Watchdog timer active (checks every minute)"

        if [ -r /etc/server-baseline/selfcheck.env ]; then
            note "Verify the alert path now: sudo security-watchdog --test"
        else
            note "No credentials yet. Create /etc/server-baseline/selfcheck.env with"
            note "TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID, then: security-watchdog --test"
        fi
        return 0
    }
    offer "security-watchdog" "No alert when auditd stops" \
"auditd being stopped is the first move in this class of compromise and it takes
under a second. A daily check reports that hours later. This watchdog is
edge-triggered: it alerts within the minute, in both directions, and stays
silent while nothing changes.

Fix: install the watchdog plus a systemd timer, seed the state baseline, and
schedule a monthly test alert so a dead alert chain is noticed." \
        watchdog_fix
fi

###############################################################################
header "5. AIDE reporting"
###############################################################################

if [ ! -f /usr/local/bin/aide-telegram.sh ]; then
    if command -v aide >/dev/null 2>&1; then
        ok "No Telegram AIDE reporter installed (the cron.daily variant is unaffected)"
        CLEAN+=("aide-reporter")
    else
        note "AIDE is not installed"
    fi
elif grep -q 'grep "\^Added:"' /usr/local/bin/aide-telegram.sh 2>/dev/null; then
    aide_fix() {
        # Replace the reporter outright rather than telling the operator to go
        # and re-run the installer. Both scripts deploy the identical file from
        # server-baseline/reporters/, so there is one version to maintain.
        if [ -f "$SCRIPT_DIR/reporters/aide-telegram.sh" ]; then
            install -m 700 -o root -g root \
                "$SCRIPT_DIR/reporters/aide-telegram.sh" /usr/local/bin/aide-telegram.sh
            ok "Installed the corrected AIDE reporter"
            note "It decides on the exit code, refuses to refresh the database on an"
            note "AIDE error, and reads credentials from /etc/server-baseline/selfcheck.env"

            # Re-enable a cron entry an earlier run of this script disabled
            if [ -f /etc/cron.d/security-scans ] && \
               grep -q '^# DISABLED.*aide-telegram' /etc/cron.d/security-scans; then
                sed -i 's|^# DISABLED[^:]*: \(.*aide-telegram.*\)|\1|' /etc/cron.d/security-scans
                ok "Re-enabled the aide-telegram cron entry"
            fi
            return 0
        fi

        note "reporters/aide-telegram.sh not found in this checkout."
        note "Disabling the misleading green reports instead:"
        if [ -f /etc/cron.d/security-scans ]; then
            sed -i 's|^\([^#].*aide-telegram\.sh\)|# DISABLED - broken reporter: \1|' \
                /etc/cron.d/security-scans
            ok "Commented out the aide-telegram cron entry"
        fi
        note "A missing report is honest; a false green one is not."
        return 0
    }
    offer "aide-reporter" "AIDE reports 'no changes' even when files changed" \
"The installed reporter counts lines matching '^Added:'. AIDE writes
'Added entries:', so the counter is always zero, the alert branch never fires,
and every run falls through to the all-clear branch - which also runs
'aide --update', folding any tampering into the baseline.

Fix: disable the broken cron entry now, then re-run the installer's AIDE
section to get the corrected reporter." \
        aide_fix
else
    ok "AIDE reporter does not have the counting bug"
    CLEAN+=("aide-reporter")
fi

# Independent of the reporter: does the check itself even work?
if command -v aide >/dev/null 2>&1 && [ -f /var/lib/aide/aide.db ]; then
    # Debian/Ubuntu need aide.wrapper or an explicit --config; a bare
    # `aide --check` always fails with "missing configuration" (exit 17) there.
    AIDE_BIN=""
    if command -v aide.wrapper >/dev/null 2>&1; then
        AIDE_BIN="aide.wrapper"
    elif [ -x /usr/sbin/aide.wrapper ]; then
        AIDE_BIN="/usr/sbin/aide.wrapper"
    elif [ -f /var/lib/aide/aide.conf.autogenerated ]; then
        AIDE_BIN="aide --config=/var/lib/aide/aide.conf.autogenerated"
    elif [ -f /etc/aide/aide.conf ]; then
        AIDE_BIN="aide --config=/etc/aide/aide.conf"
    fi

    if [ -z "$AIDE_BIN" ]; then
        # The binary is there but the configuration layer is not, so AIDE has
        # never produced a result on this host. That is an install problem, not
        # a config problem, and it has a concrete fix.
        bad "AIDE is installed but has no usable configuration - it cannot run at all"

        aide_bootstrap_fix() {
            note "Installing aide-common and building the initial database..."
            DEBIAN_FRONTEND=noninteractive apt-get install -y aide-common || {
                bad "Could not install aide-common"; return 1; }

            command -v aide.wrapper >/dev/null 2>&1 || [ -x /usr/sbin/aide.wrapper ] || {
                bad "aide-common installed but aide.wrapper is still missing"; return 1; }

            note "Running aideinit - this takes 10-20 minutes..."
            if aideinit -y -f >/tmp/aideinit.log 2>&1 && [ -f /var/lib/aide/aide.db.new ]; then
                mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db
                ok "AIDE configured and baselined for the first time"
                return 0
            fi
            bad "aideinit did not produce a database - see /tmp/aideinit.log"
            return 1
        }

        offer "aide-bootstrap" "AIDE cannot run: no configuration present" \
"The aide binary is installed but aide-common is not, so there is no
aide.wrapper and no generated config. On Debian and Ubuntu a bare
'aide --check' fails with 'missing configuration' every time.

This means AIDE has never produced a result on this host - the nightly report
saying 'no changes detected' was reporting on a scan that never started.

Fix: install aide-common and build the initial database. Takes 10-20 minutes." \
            aide_bootstrap_fix
    else
        # A full `aide --check` takes 10-20 minutes. Running it here would make
        # every pass of this script - including --check mode, and including
        # runs where the operator declined the AIDE fix - block for that long.
        # The evidence that AIDE completes lives in its last run's log instead.
        ok "AIDE resolves to: $AIDE_BIN"

        local_last=$(ls -1t /var/log/aide-check-*.log /var/log/aide-refresh-*.log 2>/dev/null | head -1)
        if [ -z "$local_last" ]; then
            note "No AIDE run has ever produced a log on this host."
            note "Verify once, when you have the time:  aide-refresh --check-only"
            ADVISORY+=("AIDE has never produced a run log - verify with: aide-refresh --check-only")
        elif grep -qE 'missing configuration|Invalid|error' "$local_last" 2>/dev/null; then
            bad "The last AIDE run ended in an error - integrity is UNVERIFIED"
            note "See: $local_last"
            ADVISORY+=("Last AIDE run errored ($local_last)")
        else
            ok "Last AIDE run completed: $local_last"
        fi
    fi
fi

###############################################################################
header "5b. Rootkit scanning (rkhunter)"
###############################################################################

if ! command -v rkhunter >/dev/null 2>&1; then
    note "rkhunter is not installed"
else
    RK_CONFIG_OK=true
    rkhunter --config-check >/dev/null 2>&1 || RK_CONFIG_OK=false

    RK_LOG=""
    for f in /var/log/rkhunter.log /var/log/rkhunter/rkhunter.log; do
        [ -f "$f" ] && RK_LOG="$f" && break
    done

    RK_COMPLETED=false
    [ -n "$RK_LOG" ] && grep -q "System checks summary" "$RK_LOG" 2>/dev/null && RK_COMPLETED=true

    # The installed reporter has the same class of bug as the AIDE one: it tests
    # for the presence of "Warning" lines and ignores whether the scan ran at
    # all, so an aborted scan produces "✅ All Clear".
    RK_REPORTER_BUGGY=false
    if [ -f /usr/local/bin/rkhunter-telegram.sh ] && \
       grep -q -- '--report-warnings-only' /usr/local/bin/rkhunter-telegram.sh 2>/dev/null && \
       ! grep -q 'System checks summary' /usr/local/bin/rkhunter-telegram.sh 2>/dev/null; then
        RK_REPORTER_BUGGY=true
    fi

    if [ "$RK_CONFIG_OK" = true ] && [ "$RK_COMPLETED" = true ] && [ "$RK_REPORTER_BUGGY" = false ]; then
        ok "rkhunter config is valid and the last scan ran to completion"
        CLEAN+=("rkhunter")
    else
        [ "$RK_CONFIG_OK" = false ]    && bad "rkhunter --config-check fails"
        [ "$RK_COMPLETED" = false ]    && bad "No completed scan in the rkhunter log"
        [ "$RK_REPORTER_BUGGY" = true ] && bad "rkhunter-telegram.sh reports 'All Clear' on an aborted scan"

        rkhunter_fix() {
            if [ "$RK_CONFIG_OK" = false ]; then
                note "Configuration errors reported by rkhunter:"
                rkhunter --config-check 2>&1 | head -10 | sed 's/^/      /'

                # rkhunter names the options it does not understand. Commenting
                # those out is safe by definition - it is already refusing to
                # act on them - and it is what stands between this host and a
                # working rootkit scan.
                #
                # PORT_NUMBER in particular was written by an earlier version of
                # THIS repo's install script. It is not an rkhunter option, and
                # its presence aborted every scan while the daily report kept
                # saying "All Clear".
                local unknown
                unknown=$(rkhunter --config-check 2>&1 | \
                          grep -oE 'Unknown configuration file option: [A-Z_]+' | \
                          awk '{print $NF}' | sort -u)

                if [ -z "$unknown" ]; then
                    note "The errors above are not unknown-option errors - fix them by hand,"
                    note "then re-run this script."
                    return 1
                fi

                cp /etc/rkhunter.conf "/etc/rkhunter.conf.bak.$(date +%Y%m%d_%H%M%S)"
                for opt in $unknown; do
                    sed -i "s/^${opt}=/# DISABLED - not a valid rkhunter option: ${opt}=/" /etc/rkhunter.conf
                    ok "Commented out invalid option: $opt"
                done

                if rkhunter --config-check >/dev/null 2>&1; then
                    ok "Configuration is valid again"
                    RK_CONFIG_OK=true
                else
                    bad "Still invalid after removing the unknown options:"
                    rkhunter --config-check 2>&1 | head -10 | sed 's/^/      /'
                    return 1
                fi
            fi

            if [ "$RK_REPORTER_BUGGY" = true ]; then
                if [ -f "$SCRIPT_DIR/reporters/rkhunter-telegram.sh" ]; then
                    install -m 700 -o root -g root \
                        "$SCRIPT_DIR/reporters/rkhunter-telegram.sh" /usr/local/bin/rkhunter-telegram.sh
                    ok "Installed the corrected rkhunter reporter"
                    note "It requires the 'System checks summary' line as proof the scan"
                    note "completed, so an aborted scan can no longer report All Clear."

                    if [ -f /etc/cron.d/security-scans ] && \
                       grep -q '^# DISABLED.*rkhunter-telegram' /etc/cron.d/security-scans; then
                        sed -i 's|^# DISABLED[^:]*: \(.*rkhunter-telegram.*\)|\1|' /etc/cron.d/security-scans
                        ok "Re-enabled the rkhunter-telegram cron entry"
                    fi
                else
                    # No replacement available - never leave a reporter running
                    # that can only ever say "all clear"
                    if [ -f /etc/cron.d/security-scans ]; then
                        sed -i 's|^\([^#].*rkhunter-telegram\.sh\)|# DISABLED - cannot detect an aborted scan: \1|' \
                            /etc/cron.d/security-scans
                        ok "Disabled the broken rkhunter-telegram cron entry"
                    fi
                    note "reporters/rkhunter-telegram.sh not found in this checkout."
                fi
            fi

            # Lynis uses the same credential file and the same install path
            if [ -f "$SCRIPT_DIR/reporters/lynis-telegram.sh" ] && \
               [ -f /usr/local/bin/lynis-telegram.sh ]; then
                install -m 700 -o root -g root \
                    "$SCRIPT_DIR/reporters/lynis-telegram.sh" /usr/local/bin/lynis-telegram.sh
                ok "Refreshed the Lynis reporter (same credential file)"
            fi

            note "Refreshing the file property database and running one scan..."
            rkhunter --propupd >/dev/null 2>&1 || note "rkhunter --propupd reported a problem"

            # The exit code alone is not the signal here - the summary line is
            # the evidence that the scan reached the end.
            rkhunter --check --skip-keypress --nocolors >/tmp/rkhunter-verify.log 2>&1 || true

            if grep -q "System checks summary" /tmp/rkhunter-verify.log 2>/dev/null; then
                local warns
                warns=$(grep -c "^Warning:" /tmp/rkhunter-verify.log 2>/dev/null || true)
                ok "Scan ran to completion (${warns:-0} warnings) - see /tmp/rkhunter-verify.log"
                return 0
            fi

            bad "The scan still does not complete - see /tmp/rkhunter-verify.log"
            return 1
        }

        offer "rkhunter" "rkhunter is not producing scan results" \
"An aborted scan writes its error and stops: no warnings, no findings. The
installed reporter tests only for the presence of 'Warning' lines, so it sends
'✅ All Clear' for a scan that never ran. A rootkit scanner that has been quiet
for months looks identical to one that keeps finding nothing.

Fix: disable the broken reporter, refresh the property database, and run one
scan to verify it reaches the 'System checks summary' line." \
            rkhunter_fix
    fi
fi

###############################################################################
header "6. Writable filesystem hardening"
###############################################################################

mounts_need_fix() {
    for m in /tmp /var/tmp /dev/shm; do
        findmnt -no OPTIONS "$m" 2>/dev/null | grep -q noexec || return 0
    done
    return 1
}

mounts_fix() {
    cp /etc/fstab "/etc/fstab.bak.$(date +%Y%m%d_%H%M%S)"

    _harden() {
        local target="$1" line="$2"
        grep -qE "^[^#]*[[:space:]]${target}[[:space:]]" /etc/fstab || \
            echo "$line" >> /etc/fstab
        mountpoint -q "$target" 2>/dev/null || mount --bind "$target" "$target" 2>/dev/null
        mount -o remount,noexec,nosuid,nodev "$target" 2>/dev/null
        if findmnt -no OPTIONS "$target" 2>/dev/null | grep -q noexec; then
            ok "$target is noexec"
        else
            note "$target will be noexec after the next reboot"
        fi
    }

    _harden /tmp     "/tmp     /tmp     none  rw,noexec,nosuid,nodev,bind  0 0"
    _harden /var/tmp "/var/tmp /var/tmp none  rw,noexec,nosuid,nodev,bind  0 0"
    _harden /dev/shm "tmpfs    /dev/shm tmpfs rw,noexec,nosuid,nodev       0 0"

    note "To undo: mount -o remount,exec /tmp  and remove the line from /etc/fstab"
    return 0
}

if mounts_need_fix; then
    offer "noexec-mounts" "/tmp, /var/tmp or /dev/shm allow execution" \
"Dropper malware writes a payload to a world-writable directory and runs it.
noexec removes the second half. This blocks the staging path outright rather
than detecting it afterwards (Lynis FILE-6310).

Note: 'bash /tmp/script.sh' keeps working - noexec blocks execve(), not an
interpreter reading a file. /dev/shm noexec breaks Chromium and Electron apps;
harmless on a headless server.

Fix: add bind mounts with noexec,nosuid,nodev to /etc/fstab and apply now." \
        mounts_fix
else
    ok "/tmp, /var/tmp and /dev/shm are all noexec"
    CLEAN+=("noexec-mounts")
fi

###############################################################################
header "7. Secrets on process command lines"
###############################################################################

CF_TOKEN_EXPOSED=$(ps -eo args 2>/dev/null | grep -i 'cloudflared' | grep -c -- '--token' || true)
OTHER_SECRETS=$(ps -eo args 2>/dev/null | grep -iE -- '--token[= ]|--password[= ]|apikey=|api_key=' | grep -v grep | grep -vi cloudflared || true)

if [ "${CF_TOKEN_EXPOSED:-0}" -gt 0 ]; then
    cf_fix() {
        # Find the container by IMAGE, not by an assumed name, and ask compose
        # where its project lives. Guessing "$HOME/docker/cloudflare" fails as
        # soon as the stack lives anywhere else - or, when running as root
        # without sudo, looks under /root for a stack owned by someone else.
        local cname dir
        cname=$(docker ps --format '{{.Names}} {{.Image}}' 2>/dev/null | \
                awk '/cloudflared/{print $1; exit}')

        dir=""
        if [ -n "$cname" ]; then
            dir=$(docker inspect --format='{{index .Config.Labels "com.docker.compose.project.working_dir"}}' \
                  "$cname" 2>/dev/null)
            [ "$dir" = "<no value>" ] && dir=""
        fi

        # Fall back to locating the compose file that actually mentions cloudflared
        if [ -z "$dir" ] || [ ! -d "$dir" ]; then
            local found
            found=$(find /root /home /opt /srv -maxdepth 5 -name 'docker-compose.y*ml' \
                    -exec grep -l cloudflared {} + 2>/dev/null | head -1)
            [ -n "$found" ] && dir=$(dirname "$found")
        fi

        if [ -z "$dir" ]; then
            bad "Could not locate a cloudflared compose file anywhere under /root /home /opt /srv"
            note "Patch it manually: replace the --token argument with"
            note "  command: tunnel --no-autoupdate run"
            note "  environment:"
            note "    - TUNNEL_TOKEN=\${CF_TOKEN}"
            return 1
        fi
        ok "Found the cloudflared stack in $dir"

        local cf=""
        for f in "$dir/docker-compose.yaml" "$dir/docker-compose.yml"; do
            [ -f "$f" ] && cf="$f" && break
        done

        if [ -z "$cf" ]; then
            bad "Could not locate the cloudflared compose file (looked in $dir)"
            note "Patch it manually: replace the --token argument with"
            note "  command: tunnel --no-autoupdate run"
            note "  environment:"
            note "    - TUNNEL_TOKEN=\${CF_TOKEN}"
            return 1
        fi

        cp "$cf" "${cf}.bak.$(date +%Y%m%d_%H%M%S)"

        if ! grep -q 'command:.*--token' "$cf"; then
            bad "No --token found in $cf - patch it manually"
            return 1
        fi

        sed -i 's|^\(\s*\)command:.*--token.*|\1command: tunnel --no-autoupdate run\n\1environment:\n\1  - TUNNEL_TOKEN=${CF_TOKEN}|' "$cf"

        ok "Patched $cf (backup alongside it)"
        echo "    New service definition:"
        sed -n '/cloudflared:/,/^$/p' "$cf" | sed 's/^/      /'
        echo ""
        note "Apply with:  cd $dir && docker compose up -d"
        note "Then verify: ps -eo args | grep cloudflared"
        echo ""
        echo -e "    ${RED}${BOLD}ROTATE THE TUNNEL TOKEN.${NC} It has been readable through /proc"
        echo "    for as long as it was on the command line."
        return 0
    }
    offer "cloudflared-token" "The Cloudflare tunnel token is in the process argv" \
"docker compose interpolates \${CF_TOKEN} into 'command:', so the token ends up
in the container's argv - readable via ps, /proc and 'docker inspect' by
anything on the host, including any container running with pid: host.

Fix: pass it as TUNNEL_TOKEN in the environment instead. The compose file is
backed up first and the container is NOT restarted automatically." \
        cf_fix
else
    ok "No cloudflared token on a command line"
    CLEAN+=("cloudflared-token")
fi

if [ -n "$OTHER_SECRETS" ]; then
    bad "Other secrets visible in process command lines:"
    echo "$OTHER_SECRETS" | cut -c1-120 | sed 's/^/      /'
    ADVISORY+=("Secrets on process command lines - move them to environment variables or files")
fi

###############################################################################
header "8. Docker network filtering"
###############################################################################

if ! command -v docker >/dev/null 2>&1 || ! command -v ufw >/dev/null 2>&1; then
    note "Docker or UFW not present - skipping"
elif grep -q 'BEGIN SERVER-BASELINE DOCKER-USER' /etc/ufw/after.rules 2>/dev/null; then
    ok "DOCKER-USER filtering is configured"
    CLEAN+=("docker-user")
else
    PUBLIC=$(docker ps --format '{{.Names}}  {{.Ports}}' 2>/dev/null | grep -E '0\.0\.0\.0:|:::' || true)

    if [ -z "$PUBLIC" ]; then
        ok "No containers published on all interfaces"
        CLEAN+=("docker-user")
    else
        echo "    Containers currently reachable from the internet:"
        echo "$PUBLIC" | sed 's/^/      /'

        docker_fix() {
            local ext_if
            ext_if=$(ip -4 route show default | awk '{print $5; exit}')
            if [ -z "$ext_if" ]; then
                bad "Could not detect the external interface"
                return 1
            fi

            # Published container ports that are in use right now. Offering them
            # as the default means the common case - "keep what already works" -
            # does not require the operator to retype anything, while still
            # forcing a conscious decision about each one.
            local suggested extra
            suggested=$(docker ps --format '{{.Ports}}' 2>/dev/null | \
                        grep -oE '0\.0\.0\.0:[0-9]+' | cut -d: -f2 | sort -un | tr '\n' ' ')
            suggested=$(echo "$suggested" | sed 's/ *$//')

            echo ""
            echo "    Ports 80 and 443 stay reachable by default."
            echo "    Currently published on all interfaces: ${suggested:-none}"
            echo "    Anything you leave out here becomes unreachable from the internet."
            echo ""
            read -r -p "    Additional ports to keep reachable [${suggested:-none}]: " extra </dev/tty
            extra=${extra:-$suggested}

            local allow_lines=""
            for p in $extra; do
                case "$p" in
                    ''|none) continue ;;
                    *[!0-9]*) note "Ignoring invalid port '$p'"; continue ;;
                esac
                allow_lines="${allow_lines}-A DOCKER-USER -i $ext_if -p tcp --dport $p -j RETURN
"
                ok "Keeping port $p reachable"
            done

            cp /etc/ufw/after.rules "/etc/ufw/after.rules.bak.$(date +%Y%m%d_%H%M%S)"
            sed -i '/# BEGIN SERVER-BASELINE DOCKER-USER/,/# END SERVER-BASELINE DOCKER-USER/d' \
                /etc/ufw/after.rules

            {
                echo ""
                echo "# BEGIN SERVER-BASELINE DOCKER-USER"
                echo "# Docker bypasses UFW's INPUT chain; DOCKER-USER is consulted first."
                echo "*filter"
                echo ":DOCKER-USER - [0:0]"
                echo "-A DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN"
                echo "-A DOCKER-USER -s 10.0.0.0/8 -j RETURN"
                echo "-A DOCKER-USER -s 172.16.0.0/12 -j RETURN"
                echo "-A DOCKER-USER -s 192.168.0.0/16 -j RETURN"
                echo "-A DOCKER-USER -i $ext_if -p tcp --dport 80 -j RETURN"
                echo "-A DOCKER-USER -i $ext_if -p tcp --dport 443 -j RETURN"
                [ -n "$allow_lines" ] && printf '%s' "$allow_lines"
                echo "-A DOCKER-USER -i $ext_if -j DROP"
                echo "-A DOCKER-USER -j RETURN"
                echo "COMMIT"
                echo "# END SERVER-BASELINE DOCKER-USER"
            } >> /etc/ufw/after.rules

            ufw reload || { bad "ufw reload failed - a backup is in /etc/ufw/"; return 1; }

            ok "DOCKER-USER filter applied (external inbound dropped except 80/443)"
            note "Verify FROM ANOTHER MACHINE - from here everything looks reachable:"
            note "  nc -zv $HOST_IP 9443    # should now fail"
            note "To add a port: edit /etc/ufw/after.rules between the markers, then ufw reload"
            return 0
        }
        offer "docker-user" "Container ports are reachable regardless of UFW" \
"Docker writes its own DNAT and FORWARD rules and does not traverse UFW's INPUT
chain. The ports listed above are reachable from the internet whatever
'ufw status' says - and 'I never opened that port in UFW' is not a defence.

Fix: add a DOCKER-USER filter that drops external inbound to containers by
default, keeping 80/443, private ranges and established connections. This does
NOT affect SSH (that is host traffic, not container traffic)." \
            docker_fix
    fi
fi

###############################################################################
header "8b. Backup host key trust"
###############################################################################
#
# Retention needs no action: backup.sh defaults to RETENTION_DAYS=30 and moves
# anything it would delete or overwrite into <backup-dir>/.attic/<timestamp>/.
#
# The host key policy does. It defaults to accept-new, which trusts any host not
# yet in known_hosts on first contact. For a scheduled job that is a blind trust
# decision, and it matters when a provider IP is released and re-issued to
# someone else. It cannot simply be defaulted to "yes": without a seeded
# known_hosts that breaks the backup on the next run.

BACKUP_DIR_REPO="$(dirname "$SCRIPT_DIR")/backup-script"

if [ ! -d "$BACKUP_DIR_REPO" ]; then
    note "No backup-script directory in this checkout - skipping"
else
    ENV_FILES=$(find "$BACKUP_DIR_REPO" -maxdepth 1 -name '.env' -o -maxdepth 1 -name '.env.*' 2>/dev/null | grep -v '\.example$' || true)

    if [ -z "$ENV_FILES" ]; then
        note "No backup .env files configured - nothing to check"
    else
        NEEDS_TRUST=""
        for env_file in $ENV_FILES; do
            grep -qE '^[[:space:]]*STRICT_HOST_KEY=["'"'"']?yes' "$env_file" 2>/dev/null && continue
            NEEDS_TRUST="$NEEDS_TRUST $env_file"
        done

        if [ -z "$NEEDS_TRUST" ]; then
            ok "All backup configs pin the host key (STRICT_HOST_KEY=yes)"
            CLEAN+=("backup-host-key")
        else
            echo "    Configs still on 'accept-new':"
            for e in $NEEDS_TRUST; do echo "      $(basename "$e")"; done

            backup_trust_fix() {
                local home_dir kh done_any=false
                home_dir=$(getent passwd "$LOGIN_USER" | cut -d: -f6)
                if [ -z "$home_dir" ]; then
                    bad "Could not resolve the home directory for $LOGIN_USER"
                    return 1
                fi
                kh="$home_dir/.ssh/known_hosts"
                mkdir -p "$home_dir/.ssh"
                touch "$kh"

                for env_file in $NEEDS_TRUST; do
                    # Read only the two values needed, without sourcing the file
                    local host port
                    host=$(grep -E '^[[:space:]]*REMOTE_HOST=' "$env_file" | head -1 | cut -d= -f2- | tr -d '"'"'"' ')
                    port=$(grep -E '^[[:space:]]*SSH_PORT=' "$env_file" | head -1 | cut -d= -f2- | tr -d '"'"'"' ')
                    port=${port:-22}

                    if [ -z "$host" ]; then
                        note "$(basename "$env_file"): no REMOTE_HOST, skipping"
                        continue
                    fi

                    if ssh-keyscan -T 10 -p "$port" "$host" >>"$kh" 2>/dev/null && \
                       grep -q "$host" "$kh"; then
                        echo 'STRICT_HOST_KEY="yes"' >> "$env_file"
                        ok "$(basename "$env_file"): seeded $host:$port and pinned the key"
                        done_any=true
                    else
                        # Never set 'yes' when the key could not be fetched - that
                        # would break the backup on its next scheduled run.
                        bad "$(basename "$env_file"): could not reach $host:$port"
                        note "  Left on accept-new. Seed it manually when the host is reachable:"
                        note "  ssh-keyscan -p $port $host >> $kh"
                    fi
                done

                chown -R "$LOGIN_USER" "$home_dir/.ssh" 2>/dev/null || true
                [ "$done_any" = true ] && return 0
                return 1
            }

            offer "backup-host-key" "Backups trust unknown host keys on first contact" \
"StrictHostKeyChecking=accept-new trusts any host not yet in known_hosts. From
cron that is a blind first-contact trust decision - and a provider IP that gets
released and re-issued to someone else is trusted silently.

Fix: fetch each backup source's host key into ${LOGIN_USER}'s known_hosts, then
set STRICT_HOST_KEY=\"yes\" in that config. A host that cannot be reached is
left on accept-new rather than pinned to nothing, so this cannot break a
working backup.

Retention needs no action: it is already on by default (30 days, in .attic/)." \
                backup_trust_fix
        fi
    fi
fi

###############################################################################
header "9. Security self-check"
###############################################################################

if [ ! -f "$SCRIPT_DIR/security-selfcheck.sh" ]; then
    note "security-selfcheck.sh not found next to this script - skipping"
elif [ -f /etc/cron.d/security-selfcheck ]; then
    ok "Daily self-check is scheduled"
    CLEAN+=("selfcheck")
else
    selfcheck_fix() {
        install -m 700 -o root -g root \
            "$SCRIPT_DIR/security-selfcheck.sh" /usr/local/bin/security-selfcheck.sh
        ln -sf /usr/local/bin/security-selfcheck.sh /usr/local/bin/security-selfcheck

        # Baseline refresh helper - run after deliberate changes, never on a timer
        if [ -f "$SCRIPT_DIR/aide-refresh.sh" ]; then
            install -m 700 -o root -g root \
                "$SCRIPT_DIR/aide-refresh.sh" /usr/local/bin/aide-refresh.sh
            ln -sf /usr/local/bin/aide-refresh.sh /usr/local/bin/aide-refresh
            ok "Installed aide-refresh (run after upgrades: aide-refresh --reason '...')"
        fi

        local args="--quiet"
        [ -r /etc/server-baseline/selfcheck.env ] && args="--quiet --telegram"

        {
            echo "# Daily security self-check - only speaks up when something fails"
            echo "0 6 * * * root /usr/local/bin/security-selfcheck.sh $args"
        } > /etc/cron.d/security-selfcheck
        chmod 644 /etc/cron.d/security-selfcheck

        ok "Installed and scheduled daily at 06:00"
        return 0
    }
    offer "selfcheck" "No daily verification that the controls work" \
"Installed is not the same as working. Every check in this script exists because
a control was installed, reported healthy, and did nothing.

Fix: install security-selfcheck.sh and schedule it daily. It stays silent unless
something fails." \
        selfcheck_fix
fi

###############################################################################
header "10. Stale SSH allowlist entries"
###############################################################################

if ! command -v ufw >/dev/null 2>&1; then
    note "UFW not installed - skipping"
else
    STALE=$(ufw status numbered 2>/dev/null | grep -i 'whitelist\|trusted home' || true)
    if [ -z "$STALE" ]; then
        ok "No IP allowlist entries in UFW"
        CLEAN+=("ssh-allowlist")
    else
        echo "    Found:"
        echo "$STALE" | sed 's/^/      /'
        echo ""
        echo "    Your current SSH client address: $CLIENT_IP"

        stale_fix() {
            # Delete highest number first so the numbering does not shift
            local nums
            nums=$(ufw status numbered 2>/dev/null | grep -i 'whitelist\|trusted home' | \
                   grep -oE '^\[\s*[0-9]+\]' | grep -oE '[0-9]+' | sort -rn)
            for n in $nums; do
                yes | ufw delete "$n" >/dev/null 2>&1 && ok "Deleted rule [$n]"
            done
            note "Rate limiting on 888 still applies to everyone, including you."
            note "SSH access is unchanged - this only removed an exemption."
            return 0
        }
        offer "ssh-allowlist" "A permanent IP allowlist entry is present" \
"Home and mobile addresses are not permanent, but the rule is. The address gets
reassigned to someone else and the exemption stays - a standing grant to a
stranger that nothing ever prompts you to review.

Removing it does NOT remove your SSH access: port 888 stays open to everyone
with rate limiting. It only removes the rate-limit exemption.

If you genuinely need one, add it back with a date in the comment:
  ufw allow from <ip> to any port 888 comment 'SSH exemption $(date +%F) - review quarterly'" \
            stale_fix
    fi
fi

###############################################################################
header "11. SSH port 22 exposure (advisory only)"
###############################################################################
#
# Deliberately not automated. Closing port 22 is the single easiest way to lock
# yourself out of a remote server, and it must be done from a session that is
# not the one you would lose. This script will not do that for you.

if ! command -v ufw >/dev/null 2>&1; then
    note "UFW not installed - skipping"
elif ufw status 2>/dev/null | grep -qE '^22/tcp\s+ALLOW\s+Anywhere'; then
    note "Port 22 is open to the world (alongside 888)"
    echo ""
    echo "    This is the intended fallback, and this script will NOT change it."
    echo "    But it is meant to be temporary, and it is easy to leave open forever."
    echo ""
    echo -e "    ${BOLD}If you want to close it, do it exactly like this:${NC}"
    echo ""
    echo -e "      ${RED}Never close port 22 from the only session you have.${NC}"
    echo ""
    echo "      1. KEEP your current terminal open. Do not log out."
    echo "      2. Open a SECOND terminal:"
    echo "           ssh -p 888 $LOGIN_USER@$HOST_IP"
    echo "      3. Only if that works, run IN THAT SECOND SESSION:"
    if systemctl is-active ssh.socket >/dev/null 2>&1; then
        echo "           # Socket activation is in use on this host: the port lives in"
        echo "           # ssh.socket. Editing sshd_config would do NOTHING here."
        echo "           sudo sed -i '/:22\$/d' /etc/systemd/system/ssh.socket.d/ports.conf"
        echo "           sudo systemctl daemon-reload && sudo systemctl restart ssh.socket"
    else
        echo "           sudo sed -i '/^Port 22\$/d' /etc/ssh/sshd_config"
        echo "           sudo systemctl restart ssh"
    fi
    echo "           sudo ufw delete allow 22/tcp"
    echo "           sudo ss -tlnp | grep ':22 '     # must print nothing"
    echo "      4. Open a THIRD terminal, confirm 888 still works,"
    echo "         and only then close the first."
    echo ""
    echo "      If step 2 fails, change nothing - you still have your session."
    echo "      Check: ss -tlnp | grep 888   and   ufw status"
    echo "      On a VPS also check the provider firewall; it sits above UFW."
    echo ""
    echo "      A softer option that keeps the fallback but narrows it:"
    echo "           sudo ufw delete allow 22/tcp"
    echo "           sudo ufw allow from $CLIENT_IP to any port 22 comment 'SSH fallback $(date +%F)'"
    echo ""
    ADVISORY+=("Port 22 is open to the world - see section 11 for the safe way to close it")
else
    ok "Port 22 is not open to the world"
    CLEAN+=("ssh-port-22")
fi

###############################################################################
header "12. AIDE baseline rebuild"
###############################################################################
#
# Runs last, on purpose. Rebuilding the baseline declares "this filesystem is
# now the truth", and that is only defensible once the fixes above have been
# applied and the host shows no compromise indicators. Doing it first would
# bake an unknown state into the reference.
#
# It is also why this does NOT live in update-containers.sh: that runs on a
# schedule, often unattended, at an hour when nobody is looking. "Make this the
# new truth" is not a decision to take at 03:00 without a human.

if ! command -v aide >/dev/null 2>&1; then
    note "AIDE is not installed - nothing to rebuild"
elif [ "$MODE" = "check" ] || [ "$DRY_RUN" = true ]; then
    note "Would offer to rebuild the AIDE baseline (skipped in check/dry-run mode)"
else
    # Fast compromise-indicator gate. No AIDE, no filesystem scan - just the
    # signals that say "do not trust this host's current state".
    DIRTY=""
    grep -qs '/bin/\.local/bin\|/usr/bin/\.local/bin' \
        /etc/profile /etc/profile.d/* /etc/environment /root/.bashrc /root/.profile 2>/dev/null \
        && DIRTY="$DIRTY PATH-injection"
    for d in /usr/bin/.local /bin/.local /usr/bin/wbin /bin/wbin /var/.i.* /tmp/.t.*; do
        [ -e "$d" ] && DIRTY="$DIRTY $d"
    done
    [ -s /etc/ld.so.preload ] && DIRTY="$DIRTY ld.so.preload"
    ps -eo args 2>/dev/null | grep -E '(^|/)(dockerd|containerd)( |$)' | grep -v grep | \
        grep -qvE -- '-H fd://|--config /etc/containerd|^/usr/bin/containerd$|containerd-shim' \
        && DIRTY="$DIRTY second-docker-daemon"
    if command -v docker >/dev/null 2>&1; then
        docker ps -a --format '{{.Image}}' 2>/dev/null | \
            grep -qiE 'repocket|packetstream|psclient|bitping|proxyrack|earnfm|wipter|antgain|traffmonetizer|pawns' \
            && DIRTY="$DIRTY proxyware-container"
    fi

    if [ -n "$DIRTY" ]; then
        bad "Compromise indicators present:$DIRTY"
        bad "NOT offering a baseline rebuild - that would make this state the reference."
        ADVISORY+=("Compromise indicators found ($DIRTY). Investigate before rebuilding the AIDE baseline.")
    elif [ ${#FAILED[@]} -gt 0 ]; then
        note "Some fixes above did not complete - resolve those first, then rebuild:"
        note "  sudo aideinit -y -f && sudo mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db"
        ADVISORY+=("AIDE baseline not rebuilt because some fixes failed")
    else
        aide_rebuild() {
            note "Rebuilding - this takes 10-20 minutes and cannot be interrupted safely."
            if aideinit -y -f >/tmp/aideinit.log 2>&1 && [ -f /var/lib/aide/aide.db.new ]; then
                mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db
                ok "Baseline rebuilt from the current filesystem"
                note "From now on, run 'sudo aide-refresh --reason ...' after deliberate changes"
                note "rather than rebuilding again - it reports what it absorbs."
                return 0
            fi
            bad "aideinit did not produce a database - see /tmp/aideinit.log"
            return 1
        }

        offer "aide-rebuild" "The AIDE baseline still reflects the old state" \
"No compromise indicators were found and the fixes above completed, so the
current filesystem is a defensible reference point.

A stale baseline produces so much noise that it gets ignored, which is the same
outcome as having none. Rebuilding it once here resets that.

This takes 10-20 minutes. Afterwards, keep it current with 'aide-refresh' after
each deliberate change instead of rebuilding again - that reports which files it
accepts, so nothing is absorbed silently." \
            aide_rebuild
    fi
fi

###############################################################################
header "Summary"
###############################################################################

echo ""
[ ${#CLEAN[@]}    -gt 0 ] && { echo -e "${GREEN}Already correct (${#CLEAN[@]}):${NC}";   printf '  ✓ %s\n' "${CLEAN[@]}"; echo ""; }
[ ${#APPLIED[@]}  -gt 0 ] && { echo -e "${GREEN}Fixed (${#APPLIED[@]}):${NC}";           printf '  ✓ %s\n' "${APPLIED[@]}"; echo ""; }
[ ${#SKIPPED[@]}  -gt 0 ] && { echo -e "${YELLOW}Skipped (${#SKIPPED[@]}):${NC}";        printf '  - %s\n' "${SKIPPED[@]}"; echo ""; }
[ ${#FAILED[@]}   -gt 0 ] && { echo -e "${RED}Failed (${#FAILED[@]}):${NC}";             printf '  ✗ %s\n' "${FAILED[@]}"; echo ""; }
[ ${#ADVISORY[@]} -gt 0 ] && { echo -e "${YELLOW}Needs your attention:${NC}";            printf '  ! %s\n' "${ADVISORY[@]}"; echo ""; }

if [ "$MODE" != "check" ] && [ "$DRY_RUN" = false ] && [ ${#APPLIED[@]} -gt 0 ]; then
    echo "Run the full self-check to confirm the result:"
    echo "  sudo bash $SCRIPT_DIR/security-selfcheck.sh"
    echo ""
fi

[ ${#FAILED[@]} -gt 0 ] && exit 1
exit 0
