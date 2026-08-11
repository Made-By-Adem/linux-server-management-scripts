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
        note "This reporter has to be replaced, not patched in place."
        note "Re-run the installer's AIDE section:"
        echo "      sudo bash $SCRIPT_DIR/install-script.sh --section   # choose 17"
        note "Until then, disable the misleading green reports:"
        if [ -f /etc/cron.d/security-scans ]; then
            sed -i 's|^\([^#].*aide-telegram\.sh\)|# DISABLED - broken reporter: \1|' \
                /etc/cron.d/security-scans
            ok "Commented out the aide-telegram cron entry in /etc/cron.d/security-scans"
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
    echo "    Running aide --check (this can take a while)..."
    aide --check >/tmp/aide-update-check.log 2>&1
    rc=$?
    if [ "$rc" -ge 14 ]; then
        bad "aide --check fails with exit $rc - file integrity is UNVERIFIED"
        ADVISORY+=("aide --check fails (exit $rc). Rebuild the database once the host is known clean: aideinit -y -f && mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db")
    elif [ "$rc" -ne 0 ]; then
        note "aide --check reports differences (exit $rc) - review /tmp/aide-update-check.log"
    else
        ok "aide --check completes cleanly"
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
                note "Configuration errors, which must be resolved first:"
                rkhunter --config-check 2>&1 | head -10 | sed 's/^/      /'
                note "Common cause on Ubuntu: obsolete options left behind by a package upgrade."
                note "Fix /etc/rkhunter.conf, then re-run this script."
                return 1
            fi

            if [ "$RK_REPORTER_BUGGY" = true ]; then
                # Do not leave a reporter running that can only say "all clear"
                if [ -f /etc/cron.d/security-scans ]; then
                    sed -i 's|^\([^#].*rkhunter-telegram\.sh\)|# DISABLED - cannot detect an aborted scan: \1|' \
                        /etc/cron.d/security-scans
                    ok "Disabled the broken rkhunter-telegram cron entry"
                fi
                note "Re-run the installer's security section for the corrected reporter:"
                echo "      sudo bash $SCRIPT_DIR/install-script.sh --section   # choose 17"
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
        local dir
        dir=$(docker inspect --format='{{index .Config.Labels "com.docker.compose.project.working_dir"}}' \
              cloudflared 2>/dev/null)
        if [ -z "$dir" ] || [ "$dir" = "<no value>" ]; then
            dir="$(getent passwd "$LOGIN_USER" | cut -d: -f6)/docker/cloudflare"
        fi

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
    echo "           sudo sed -i '/^Port 22\$/d' /etc/ssh/sshd_config"
    echo "           sudo systemctl restart ssh"
    echo "           sudo ufw delete allow 22/tcp"
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
