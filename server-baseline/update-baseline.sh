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

# True when the installed copy differs from the one in this checkout. Without
# this, "already installed" hides every subsequent repo update: the operator
# pulls a fix, the script reports the component as correct, and the stale copy
# keeps running. That is how the watchdog on the first real host kept reading
# the old credential location after the refactor that moved it.
#
# ENV_FILE_DEFAULT is rewritten in the installed copy at install time, so a
# byte-for-byte comparison can never match and every run would reinstall,
# re-bake, and report the component as "fixed" again. That line is excluded.
needs_refresh() {
    local repo_file="$1" installed="$2"
    [ -f "$repo_file" ] || return 1
    [ -f "$installed" ] || return 0
    ! diff -q <(grep -v '^ENV_FILE_DEFAULT=' "$repo_file") \
              <(grep -v '^ENV_FILE_DEFAULT=' "$installed") >/dev/null 2>&1
}

# read_env_value <KEY> <file>
#
# Read one KEY=value out of a .env without sourcing it - these files are not
# ours to execute, and one of them being writable would otherwise be a way to
# run code as root.
#
# Inline comments are the trap. The previous one-liner stripped quotes and
# spaces with tr but left the comment intact, so
#
#     REMOTE_HOST="10.0.0.3" # private ip
#
# came back as 10.0.0.3#privateip. ssh-keyscan then failed against a host that
# does not exist and the check reported it as unreachable - blaming the network
# for a parsing bug, and leaving the real setting unfixed run after run.
#
# bash strips that comment itself when backup.sh sources the same file, which
# is why the backups worked while this check did not.
read_env_value() {
    local key="$1" file="$2" v
    v=$(grep -E "^[[:space:]]*${key}=" "$file" 2>/dev/null | head -1 | cut -d= -f2-)
    v=${v#"${v%%[![:space:]]*}"}          # leading whitespace

    case "$v" in
        \"*) v=${v#\"}; v=${v%%\"*} ;;    # "value"  # comment
        \'*) v=${v#\'}; v=${v%%\'*} ;;    # 'value'  # comment
        *)   v=${v%%#*}                   #  value   # comment
             v=${v%"${v##*[![:space:]]}"} ;;
    esac

    printf %s "$v"
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

# A credential is only a credential once it survives expansion. The repo copies
# of the reporters carry TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}" as a
# placeholder, and that string passes every naive "is there something after the
# = sign" test while expanding to nothing at all. A .env full of placeholders
# therefore looks configured everywhere and sends nowhere.
usable_secret() {
    case "${1:-}" in
        ''|*'$'*|*'{'*|*REPLACE_*|*CHANGEME*|*your_*) return 1 ;;
    esac
    return 0
}

# Read one credential out of a file, and return nothing at all unless it is a
# real value. Handles both the quoted form the generated reporters use and the
# bare KEY=value of an .env, because this reads from both.
harvest_secret() {
    local v
    v="$(read_env_value "$1" "$2")"
    usable_secret "$v" || return 0
    printf %s "$v"
}

if [ -r "$CRED_FILE" ] && usable_secret "$(read_env_value TELEGRAM_BOT_TOKEN "$CRED_FILE")"; then
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
        [ -z "$FOUND_TOKEN" ] && FOUND_TOKEN=$(harvest_secret TELEGRAM_BOT_TOKEN "$f")
        [ -z "$FOUND_CHAT" ]  && FOUND_CHAT=$(harvest_secret TELEGRAM_CHAT_ID "$f")
    done

    # Also honour the legacy /etc location as a source
    if [ -z "$FOUND_TOKEN" ] && [ -r /etc/server-baseline/selfcheck.env ]; then
        FOUND_TOKEN=$(harvest_secret TELEGRAM_BOT_TOKEN /etc/server-baseline/selfcheck.env)
        FOUND_CHAT=$(harvest_secret TELEGRAM_CHAT_ID /etc/server-baseline/selfcheck.env)
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
elif systemctl is-active security-watchdog.timer >/dev/null 2>&1 &&      ! needs_refresh "$SCRIPT_DIR/watchdogs/security-watchdog.sh" /usr/local/bin/security-watchdog.sh; then
    ok "security watchdog timer is active and up to date"
    CLEAN+=("security-watchdog")
else
    watchdog_fix() {
        install -m 700 -o root -g root \
            "$SCRIPT_DIR/watchdogs/security-watchdog.sh" /usr/local/bin/security-watchdog.sh
        ln -sf /usr/local/bin/security-watchdog.sh /usr/local/bin/security-watchdog
        bake_env_path /usr/local/bin/security-watchdog.sh

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

        # Look where the watchdog actually looks. Checking only the legacy
        # location told operators to create a file they did not need, on hosts
        # where section 0 had just written the project .env - and implied the
        # alert path was dead when it was fine.
        if [ -r "$CRED_FILE" ] || [ -r /etc/server-baseline/selfcheck.env ]; then
            note "Verify the alert path now: sudo security-watchdog --test"
        else
            note "No credentials yet. Put TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID in"
            note "$CRED_FILE, then: security-watchdog --test"
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
header "4b. Superseded watchdogs"
###############################################################################
#
# A rebuilt host only ever gets what this repository installs. A host brought up
# to the baseline with this script keeps whatever was already on it - including
# tooling written by hand during an incident, before the repository version
# existed. Nothing here knew about those, so two watchdogs ran side by side,
# both alerting, and the older one's state file made AIDE report a difference
# every single night.
#
# auditd-watchdog is a strict subset of security-watchdog: it tracks only
# whether auditd is active, where security-watchdog tracks four units and
# eleven monitors and already includes the same session count and journal
# excerpt in its alerts. There is nothing to carry over.
#
# The script itself is deliberately left on disk. It lives in no repository, so
# deleting it would be irreversible; only the units and the state file go.

LEGACY_WD=/etc/systemd/system/auditd-watchdog.service

if [ ! -f "$LEGACY_WD" ]; then
    :   # nothing to say on a host that never had it
elif ! systemctl is-active security-watchdog.timer >/dev/null 2>&1; then
    note "auditd-watchdog.service is present but security-watchdog is not active"
    note "  Leaving it alone - removing it now would leave nothing watching auditd."
else
    legacy_wd_fix() {
        systemctl disable --now auditd-watchdog.timer >/dev/null 2>&1 || true
        systemctl disable --now auditd-watchdog.service >/dev/null 2>&1 || true
        rm -f "$LEGACY_WD" /etc/systemd/system/auditd-watchdog.timer
        systemctl daemon-reload
        rm -f /var/lib/auditd-watchdog.state
        ok "Removed the auditd-watchdog units and state file"
        note "The script itself is untouched: /home/scripts/watchdogs/auditd-watchdog.sh"
        note "Its state file was in AIDE's baseline, so refresh it:"
        note "  aide-refresh --reason 'removed the superseded auditd-watchdog'"
        return 0
    }

    offer "legacy-watchdog" "Two watchdogs are watching auditd" \
"auditd-watchdog.service predates security-watchdog and does a strict subset of
its job: it reports only whether auditd is active. security-watchdog covers
auditd, fail2ban, acct and the fail2ban jail, plus eleven state monitors, and
its alerts already carry the same session count and journal excerpt.

Left in place you get two alerts for one event, which is how an alert channel
stops being read. Its state file is rewritten every minute and sits in AIDE's
baseline, so it also produces a file-integrity difference every night.

It also loads credentials from another project's .env, which is a second copy
of a token to rotate and to leak.

Fix: disable and remove the units and the state file. The script itself is left
on disk - it is in no repository, so removing it would be irreversible." \
        legacy_wd_fix
fi

###############################################################################
header "5. AIDE reporting"
###############################################################################

# Exclude paths that change by design. Without these, every run reports
# differences - the watchdog alone rewrites /var/lib/server-baseline every
# minute - and an integrity monitor that always fires is one that gets ignored.
#
# Checked rule by rule rather than against a single marker line. The marker
# approach meant the block could only ever be written once: every later
# addition here would find the marker present, report the component correct,
# and never reach a host that was set up before the addition.
AIDE_EXCLUDES=(
    '!/var/lib/aide'
    '!/var/lib/server-baseline'
    '!/var/lib/containerd'
    '!/var/lib/systemd'
    '!/root/\.vscode-server'
    '!/root/\.cache'
    '!/root/\.copilot'
    '!/root/\.bash_history'

    # backup.sh opens an SSH ControlMaster socket here, so the directory mtime
    # changes on every backup run. Only this subdirectory: the keys and
    # authorized_keys beside it are among the most important things AIDE
    # watches, and the sockets inside are ephemeral and root-only anyway.
    '!/root/\.ssh/cm'

    # Package metadata, refreshed by apt's own timers. Every host reported
    # these on the first real check. Tampering here is not a useful attack:
    # the indexes are signature-verified, so a modified one fails apt rather
    # than installing anything.
    '!/var/lib/apt/lists'
    '!/var/lib/apt/periodic'

    # rkhunter copies /etc/passwd and /etc/group here on every scan to diff
    # them against the previous run. The diff is the control; these are its
    # scratch space. /var/lib/rkhunter/db beside them stays watched.
    '!/var/lib/rkhunter/tmp'
    '!/var/lib/ubuntu-advantage'
    '!/var/lib/landscape'
    '!/var/lib/update-notifier'
    '!/var/lib/PackageKit'
)

# An AIDE rule has to be a literal path prefix - it must start with '/', so
# there is no way to write "any .git anywhere". The first attempt at this used
# !.*/\.git/objects; AIDE refused the whole config and every check exited 17,
# which looks exactly like a broken installation rather than one bad line.
#
# The checkout path is known here, so it is used directly. Regex metacharacters
# in it are escaped: a literal dot would otherwise match any character.
AIDE_GIT_ROOT="${PROJECT_ROOT//./\\.}"
for gp in objects logs refs index FETCH_HEAD ORIG_HEAD COMMIT_EDITMSG \
          packed-refs modules; do
    AIDE_EXCLUDES+=("!${AIDE_GIT_ROOT}/\\.git/${gp}")
done

# A backup destination is a mirror of another host's filesystem, plus an
# .attic/ of everything rsync replaced. Every run rewrites thousands of files
# there by design, and the host it came from is monitoring those same files
# itself - watching the copy adds no coverage and buries the copy's own host in
# noise. AC1 reported 1072 additions the first evening its backup cron ran.
#
# Read from the backup configs rather than hardcoded, so a host that keeps its
# backups somewhere else is still covered. Only when BACKUP_DEST is set
# explicitly: unset means backup.sh writes inside its own directory in this
# checkout, and excluding that would hide backup.sh itself from AIDE.
BACKUP_ENV_DIR="$PROJECT_ROOT/backup-script"
if [ -d "$BACKUP_ENV_DIR" ]; then
    for bf in "$BACKUP_ENV_DIR"/.env "$BACKUP_ENV_DIR"/.env.*; do
        [ -f "$bf" ] || continue
        case "$bf" in *.example) continue ;; esac
        bdest=$(read_env_value BACKUP_DEST "$bf")
        [ -n "$bdest" ] || continue
        bdest="${bdest%/}"
        brule="!${bdest//./\\.}"
        case " ${AIDE_EXCLUDES[*]} " in *" $brule "*) continue ;; esac
        AIDE_EXCLUDES+=("$brule")
    done
fi

# A stale entry from the version that shipped the unparseable rules. Left in
# place, AIDE stays dead however many correct rules are added after it.
AIDE_BROKEN=$(grep -c '^![^/]' /etc/aide/aide.conf 2>/dev/null || true)

AIDE_MISSING=()
if [ -f /etc/aide/aide.conf ]; then
    for rule in "${AIDE_EXCLUDES[@]}"; do
        grep -qxF "$rule" /etc/aide/aide.conf || AIDE_MISSING+=("$rule")
    done
fi

if [ -f /etc/aide/aide.conf ] && \
   { [ ${#AIDE_MISSING[@]} -gt 0 ] || [ "${AIDE_BROKEN:-0}" -gt 0 ]; }; then
    aide_excludes_fix() {
        local backup="/etc/aide/aide.conf.bak.$(date +%Y%m%d_%H%M%S)"
        cp /etc/aide/aide.conf "$backup"

        # Rules that do not start with '/' make AIDE reject the entire file.
        if [ "${AIDE_BROKEN:-0}" -gt 0 ]; then
            sed -i '\|^![^/]|d' /etc/aide/aide.conf
            ok "Removed ${AIDE_BROKEN} rule(s) that AIDE cannot parse"
        fi

        {
            echo ""
            echo "# Added by update-baseline $(date +%Y-%m-%d): paths that change by design."
            echo "# The trade-off is explicit: an attacker could alter these unnoticed."
            echo "# They change legitimately every minute or every pull, so AIDE could"
            echo "# never have told tampering from normal operation there anyway."
            printf '%s\n' "${AIDE_MISSING[@]}"
        } >> /etc/aide/aide.conf

        # The local block is written once and never again, so anything the
        # operator added under it survives a later top-up.
        if ! grep -q '^# LOCAL EXCLUSIONS' /etc/aide/aide.conf; then
            cat >> /etc/aide/aide.conf <<'EOF'

# ---------------------------------------------------------------------
# LOCAL EXCLUSIONS - add your own below this line.
#
# Application log and data directories churn every day and will otherwise
# make every run report differences. Exclude the directories that change,
# NOT the whole application tree: the code and configs beside them are
# exactly what an integrity monitor is for.
#
# Example, for services laid out as /home/<service>/<instance>/:
#   !/home/pos-servers/[^/]+/logs
#   !/home/pos-servers/[^/]+/scanapp-data
# ---------------------------------------------------------------------
EOF
        fi

        # Verify before claiming success. Writing a config AIDE cannot read
        # means exit 17 on every scheduled run from now on, and the operator
        # finds out from a 5am alert rather than from the tool that did it.
        if ! aide --config=/etc/aide/aide.conf --config-check >/dev/null 2>&1; then
            bad "AIDE rejects the resulting config - restoring $backup"
            cp "$backup" /etc/aide/aide.conf
            return 1
        fi

        ok "Added ${#AIDE_MISSING[@]} exclusion(s), and AIDE parses the result"
        note "Application log/data directories are site-specific - see the LOCAL"
        note "EXCLUSIONS block at the end of /etc/aide/aide.conf to add yours."
        note "How to work out which ones: docs/AIDE-TUNING.md in this checkout."
        note "Rebuild the baseline afterwards so they take effect:"
        note "  aide-refresh --reason 'after adding exclusions'"
        return 0
    }

    echo "    Missing from /etc/aide/aide.conf:"
    printf '      %s\n' "${AIDE_MISSING[@]}"

    offer "aide-excludes" "AIDE reports the same churn on every run" \
"These paths change constantly by design: the security watchdog rewrites its
state in /var/lib/server-baseline every minute, AIDE leaves aide.db.new behind,
containerd rewrites snapshot contents, an open editor session writes logs under
/root, and every 'git pull' in a checkout rewrites thousands of objects under
.git - including this repository's own checkout on this host.

Left in, every scheduled check reports differences forever. That is how a
working integrity monitor becomes one nobody reads.

Fix: exclude them from /etc/aide/aide.conf. The file is backed up first, and
.git/hooks and .git/config stay monitored - a hook is executable code." \
        aide_excludes_fix
else
    [ -f /etc/aide/aide.conf ] && { ok "AIDE excludes the paths that change by design"; CLEAN+=("aide-excludes"); }
fi

# Keep every installed reporter in step with this checkout. Without it, a
# `git pull` that fixes a reporter leaves the old copy running while this
# script reports the component as correct.
for r in aide rkhunter lynis; do
    if [ -f "/usr/local/bin/${r}-telegram.sh" ] && \
       needs_refresh "$SCRIPT_DIR/reporters/${r}-telegram.sh" "/usr/local/bin/${r}-telegram.sh"; then

        # This loop sits outside offer(), so it used to run in --check and
        # --dry-run as well - while the header promised nothing would change.
        #
        # That was not a cosmetic violation. On a host that has not been
        # migrated to a .env yet, the generated reporters hold the ONLY copy of
        # the Telegram credentials. Overwriting them with the repo copies
        # destroys that copy, and section 0 then has nothing left to recover
        # from: it harvests the placeholder out of the fresh reporter and
        # writes a .env that expands to an empty token. The host goes silent,
        # and the cautious "run --check first" is what caused it.
        if [ "$MODE" = "check" ] || [ "$DRY_RUN" = true ]; then
            note "${r}-telegram.sh differs from this checkout - would refresh it"
            continue
        fi

        install -m 700 -o root -g root \
            "$SCRIPT_DIR/reporters/${r}-telegram.sh" "/usr/local/bin/${r}-telegram.sh"
        ok "Refreshed the ${r} reporter from this checkout"
        bake_env_path "/usr/local/bin/${r}-telegram.sh"
    fi
done

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
            bake_env_path /usr/local/bin/aide-telegram.sh
            ok "Installed the corrected AIDE reporter"
            note "It decides on the exit code, refuses to refresh the database on an"
            note "AIDE error, and reads credentials from $CRED_FILE"

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

        # Only logs written AFTER the current database say anything about the
        # present. Earlier ones describe a baseline that no longer exists, so
        # judging by them reports failures that a rebuild already resolved.
        # A log only says something about the present if it was written BOTH after
        # the current database AND by the current reporter. A log from the old
        # broken reporter post-dates the database on any host where the database
        # was never rebuilt, and reporting its error describes a defect that has
        # since been fixed.
        AIDE_CUTOFF=/var/lib/aide/aide.db
        if [ -f /usr/local/bin/aide-telegram.sh ] &&                [ /usr/local/bin/aide-telegram.sh -nt /var/lib/aide/aide.db ]; then
                AIDE_CUTOFF=/usr/local/bin/aide-telegram.sh
        fi
        # A refresh log never survives an -newer test against the database:
        # aide-refresh checks first and writes the database last, and aide
        # closes that database after it has finished printing. So the log of
        # the run that produced the database is always a moment older than it.
        # Testing both kinds the same way reported "no AIDE run" on precisely
        # the hosts that had just refreshed. A refresh log is evidence by
        # construction; a check log still has to beat the cutoff.
        local_last=$( { find /var/log -maxdepth 1 -name 'aide-refresh-*.log' 2>/dev/null
                        find /var/log -maxdepth 1 -name 'aide-check-*.log' \
                            -newer "$AIDE_CUTOFF" 2>/dev/null
                      } | xargs -r ls -1t 2>/dev/null | head -1)
        if [ -z "$local_last" ]; then
            note "No AIDE run since the database was built - the first scheduled run is pending."
        elif grep -qE '^(ERROR|.*missing configuration|.*Invalid configure|.*Configuration error)' "$local_last" 2>/dev/null; then
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

    # A second, dumber way to be silent: build the message and never send it.
    # The clean-scan branch shipped without its send_telegram call, so hosts
    # with nothing to report said nothing at all - indistinguishable from a
    # reporter that had stopped running. Checked separately from the drift test
    # below because it deserves to be named when it fires.
    if [ -f /usr/local/bin/rkhunter-telegram.sh ] && \
       ! grep -q '^[[:space:]]*send_telegram "' /usr/local/bin/rkhunter-telegram.sh 2>/dev/null; then
        RK_REPORTER_BUGGY=true
        bad "rkhunter-telegram.sh builds a report but never sends it"
    fi

    # Drift from the checkout is not tested here: the reporter refresh loop
    # further up already reinstalled it before this section runs. The named
    # check above stays because it fires on the case that loop cannot fix -
    # a checkout that is itself old or missing.

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
                cp /etc/rkhunter.conf "/etc/rkhunter.conf.bak.$(date +%Y%m%d_%H%M%S)"

                local unknown opt
                unknown=$(rkhunter --config-check 2>&1 | \
                          grep -oE 'Unknown configuration file option: [A-Z_]+' | \
                          awk '{print $NF}' | sort -u)

                for opt in $unknown; do
                    sed -i "s/^${opt}=/# DISABLED - not a valid rkhunter option: ${opt}=/" /etc/rkhunter.conf
                    ok "Commented out invalid option: $opt"
                done

                # WEB_CMD is rejected in a different way and needs its own fix.
                # This repo's installer writes /bin/false to stop rkhunter
                # fetching anything; on a usrmerge system - /bin is a symlink
                # into /usr/bin - some builds refuse it as a "relative
                # pathname" and abort every scan from then on.
                #
                # The value only has to be something this build accepts and
                # will not download with, so try the merged path, then drop the
                # option and let the packaged default stand.
                if ! rkhunter --config-check >/dev/null 2>&1 && \
                   rkhunter --config-check 2>&1 | grep -q 'WEB_CMD'; then
                    local candidate
                    for candidate in /usr/bin/false ""; do
                        if [ -n "$candidate" ]; then
                            sed -i "s|^WEB_CMD=.*|WEB_CMD=$candidate|" /etc/rkhunter.conf
                        else
                            sed -i 's|^WEB_CMD=|# DISABLED - rejected by this rkhunter build: WEB_CMD=|' \
                                /etc/rkhunter.conf
                        fi
                        if rkhunter --config-check >/dev/null 2>&1; then
                            ok "WEB_CMD accepted as '${candidate:-(removed)}'"
                            break
                        fi
                    done
                fi

                if rkhunter --config-check >/dev/null 2>&1; then
                    ok "Configuration is valid again"
                    RK_CONFIG_OK=true
                else
                    bad "Still invalid - the remaining errors need a hand:"
                    rkhunter --config-check 2>&1 | head -10 | sed 's/^/      /'
                    note "The previous config is at /etc/rkhunter.conf.bak.*"
                    return 1
                fi
            fi

            if [ "$RK_REPORTER_BUGGY" = true ]; then
                if [ -f "$SCRIPT_DIR/reporters/rkhunter-telegram.sh" ]; then
                    install -m 700 -o root -g root \
                        "$SCRIPT_DIR/reporters/rkhunter-telegram.sh" /usr/local/bin/rkhunter-telegram.sh
                    # The repo copy ships ENV_FILE_DEFAULT empty; without this
                    # the refreshed reporter loses its way to the credentials
                    # and goes quiet - fixing one silence by causing another.
                    bake_env_path /usr/local/bin/rkhunter-telegram.sh
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
                bake_env_path /usr/local/bin/lynis-telegram.sh
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
    # All three are noexec right now - but on /dev/shm that is often only a
    # runtime remount with nothing to re-apply it after a reboot. "Correct
    # today, gone on Monday" is the state this whole repository exists to catch,
    # so it counts as needing a fix.
    if ! systemctl list-units -t mount --all 2>/dev/null | grep -q 'dev-shm\.mount' && \
       ! systemctl is-enabled shm-noexec.service >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

mounts_fix() {
    cp /etc/fstab "/etc/fstab.bak.$(date +%Y%m%d_%H%M%S)"

    # More than one entry for the same mount point is worse than none: the flags
    # stop surviving a daemon-reload, and nothing says so. Collapse duplicates
    # before touching anything, rather than adding a third line to the pile.
    _dedupe_fstab() {
        local target="$1" dupes
        dupes=$(awk -v t="$target" '$1 !~ /^#/ && $2 == t' /etc/fstab 2>/dev/null | wc -l)
        [ "${dupes:-0}" -gt 1 ] || return 0

        awk -v t="$target" '$1 ~ /^#/ || $2 != t || !seen++' /etc/fstab > /etc/fstab.dedupe 2>/dev/null
        if [ -s /etc/fstab.dedupe ] && \
           [ "$(awk -v t="$target" '$1 !~ /^#/ && $2 == t' /etc/fstab.dedupe | wc -l)" -eq 1 ]; then
            mv /etc/fstab.dedupe /etc/fstab
            ok "Collapsed $((dupes - 1)) duplicate fstab entry/entries for $target"
        else
            rm -f /etc/fstab.dedupe
            note "Could not safely deduplicate the $target entries in /etc/fstab - do it by hand"
        fi
    }

    _harden() {
        local target="$1" line="$2"
        _dedupe_fstab "$target"
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

    _persist_shm_noexec

    note "To undo: mount -o remount,exec /tmp  and remove the line from /etc/fstab"
    return 0
}

# /dev/shm is not like the other two. systemd mounts it itself, early, as an
# API filesystem, and on these hosts the fstab entry generates no unit at all -
# `systemctl list-units -t mount --all` knows no dev-shm.mount and
# /run/systemd/generator holds nothing for it. So the remount above is the only
# thing applying noexec, and it is gone after the next reboot, silently.
#
# /tmp and /var/tmp do get units from fstab, which is why their flags hold.
#
# A remount service rather than a replacement dev-shm.mount unit: overriding
# systemd's own mount means unmounting it, which takes down everything holding
# shared memory - databases in particular. A remount changes the flags on the
# live mount and interrupts nothing.
_persist_shm_noexec() {
    [ -d /run/systemd/system ] || return 0

    if systemctl list-units -t mount --all 2>/dev/null | grep -q 'dev-shm\.mount'; then
        note "/dev/shm has a mount unit on this host - its flags already survive a reboot"
        return 0
    fi

    cat > /etc/systemd/system/shm-noexec.service <<'EOF'
[Unit]
Description=Apply noexec,nosuid,nodev to /dev/shm
Documentation=https://github.com/Made-By-Adem/linux-server-management-scripts
After=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/mount -o remount,noexec,nosuid,nodev /dev/shm

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 /etc/systemd/system/shm-noexec.service
    systemctl daemon-reload
    if systemctl enable --now shm-noexec.service >/dev/null 2>&1 && \
       findmnt -no OPTIONS /dev/shm 2>/dev/null | grep -q noexec; then
        ok "shm-noexec.service installed - /dev/shm is re-hardened at every boot"
    else
        bad "shm-noexec.service did not take effect - check: systemctl status shm-noexec"
    fi
}

if mounts_need_fix; then
    offer "noexec-mounts" "/tmp, /var/tmp or /dev/shm allow execution, now or after a reboot" \
"Dropper malware writes a payload to a world-writable directory and runs it.
noexec removes the second half. This blocks the staging path outright rather
than detecting it afterwards (Lynis FILE-6310).

Note: 'bash /tmp/script.sh' keeps working - noexec blocks execve(), not an
interpreter reading a file. /dev/shm noexec breaks Chromium and Electron apps;
harmless on a headless server.

/dev/shm is the awkward one: systemd mounts it itself and the fstab entry
generates no unit on these hosts, so a remount holds only until the next
reboot. That half gets a small oneshot service instead.

Fix: bind mounts with noexec,nosuid,nodev in /etc/fstab for /tmp and /var/tmp,
applied now, plus shm-noexec.service to re-apply /dev/shm at every boot." \
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

        # The detection for this section reads `ps`, not the file. So the file
        # can already be correct while the RUNNING container still carries the
        # old argv - which is exactly what happens after `docker restart`:
        # that reuses the container's existing configuration and never re-reads
        # docker-compose.yaml. Only `docker compose up -d` recreates it.
        if ! grep -q 'command:.*--token' "$cf"; then
            if grep -q 'TUNNEL_TOKEN' "$cf"; then
                ok "The compose file is already correct - the running container is not"
                note "It was created from the previous file. 'docker restart' reuses the"
                note "existing container config; only 'up -d' rebuilds it from compose."
                echo ""
                echo "    Recreating briefly drops the tunnel - a few seconds of downtime"
                echo "    for anything routed through it."
                echo ""
                read -r -p "    Recreate the cloudflared container now? (y/N): " do_recreate </dev/tty

                if [[ "${do_recreate:-n}" =~ ^[Yy]$ ]]; then
                    ( cd "$dir" && docker compose up -d ) || { bad "docker compose up -d failed"; return 1; }
                    sleep 4
                    if ps -eo args 2>/dev/null | grep -i cloudflared | grep -q -- '--token'; then
                        bad "The token is still on the command line after recreating"
                        return 1
                    fi
                    ok "Container recreated; the token is no longer in its argv"
                    echo ""
                    echo -e "    ${RED}${BOLD}ROTATE THE TUNNEL TOKEN.${NC} It was readable through /proc"
                    echo "    for as long as it was on the command line."
                    return 0
                fi

                note "Skipped. Recreate it yourself with:  cd $dir && docker compose up -d"
                return 1
            fi

            bad "No --token and no TUNNEL_TOKEN in $cf - patch it manually"
            return 1
        fi

        cp "$cf" "${cf}.bak.$(date +%Y%m%d_%H%M%S)"

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
                    local host port
                    host=$(read_env_value REMOTE_HOST "$env_file")
                    port=$(read_env_value SSH_PORT "$env_file")
                    port=${port:-22}

                    if [ -z "$host" ]; then
                        note "$(basename "$env_file"): no REMOTE_HOST, skipping"
                        continue
                    fi

                    # -F: an IP is full of dots, and as a regex those match any
                    # character - 10.0.0.3 would happily match 100003 or a
                    # neighbouring address in the file.
                    if ssh-keyscan -T 10 -p "$port" "$host" >>"$kh" 2>/dev/null && \
                       grep -qF "$host" "$kh"; then
                        # A .env without a trailing newline would otherwise get
                        # this glued onto its last setting.
                        [ -n "$(tail -c1 "$env_file")" ] && echo >> "$env_file"
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
header "8c. SSH port configured in two places"
###############################################################################
#
# With socket activation, Port directives in sshd_config are ignored entirely.
# Leaving them there is not merely untidy: it is a trap. Deleting "Port 22" from
# sshd_config on such a host looks like it closed the port and changes nothing.

# Three mechanisms, needing opposite advice - and this section used to see only
# two of them:
#
#   1. no ssh.socket                  sshd_config, restart ssh
#   2. ssh.socket + sshd-socket-generator (Ubuntu 24.04's default)
#                                     sshd_config IS the source; the generator
#                                     compiles its Port lines into the socket
#                                     at every daemon-reload
#   3. ssh.socket + a drop-in in /etc  the drop-in wins, sshd_config is dead
#                                     weight and safe to clean up
#
# Case 2 was treated as case 3, which deleted the only place the port was
# defined. Nothing changed at the time - the socket was already listening - so
# it verified clean. The damage would surface at the next reboot, with sshd
# back on 22 and the custom port gone, on a host whose firewall only allows the
# custom port. A remediation script that arranges a lockout weeks later is
# worse than the untidiness it set out to fix.
SSH_GEN=/run/systemd/generator/ssh.socket.d/addresses.conf
SSH_ETC_DROPIN=$(grep -rlE '^[[:space:]]*ListenStream=' /etc/systemd/system/ssh.socket.d/ 2>/dev/null | head -1)

if ! systemctl is-active ssh.socket >/dev/null 2>&1; then
    ok "No socket activation - sshd_config is the only place ports are set"
    CLEAN+=("ssh-port-single-source")
elif [ -f "$SSH_GEN" ] && [ -z "$SSH_ETC_DROPIN" ]; then
    if grep -qE '^Port +[0-9]+' /etc/ssh/sshd_config 2>/dev/null; then
        ok "Ports come from sshd_config, compiled into ssh.socket by sshd-socket-generator"
        note "Change them there, then: systemctl daemon-reload && systemctl restart ssh.socket"
        note "Restarting ssh.service alone changes nothing. Do NOT delete the Port lines:"
        note "they are the source, not a leftover."
        CLEAN+=("ssh-port-single-source")
    else
        # No Port line at all is not "one source of truth", it is none: the
        # generator falls back to sshd's default of 22 at the next
        # daemon-reload, whatever the socket is serving today.
        bad "sshd_config sets no Port - the generator falls back to 22 on the next reload"
        note "  Listening now: $(ss -tlnpH 2>/dev/null | grep -i sshd | grep -oE ':[0-9]+ ' | tr -d ': ' | sort -u | tr '\n' ' ')"
        note "  Generated:     $(grep -oE ':[0-9]+' "$SSH_GEN" 2>/dev/null | tr -d ':' | sort -u | tr '\n' ' ')"
        note "  Put the port you actually use in /etc/ssh/sshd_config, then, from a"
        note "  SECOND session: systemctl daemon-reload && systemctl restart ssh.socket"
        ADVISORY+=("ssh-port-single-source")
    fi
elif [ -f "$SSH_GEN" ] && [ -n "$SSH_ETC_DROPIN" ]; then
    bad "Ports are set in two places that both feed ssh.socket"
    note "  generated from sshd_config: $SSH_GEN"
    note "  drop-in in /etc:            $SSH_ETC_DROPIN"
    note "Which one wins depends on drop-in ordering and on whether the /etc file"
    note "resets the list with a bare 'ListenStream='. Untangle this by hand - no"
    note "automatic edit here is safe enough, and being wrong locks you out."
    ADVISORY+=("ssh-port-single-source")
elif ! grep -qE '^Port +[0-9]+' /etc/ssh/sshd_config 2>/dev/null; then
    ok "Ports are configured in one place only (ssh.socket)"
    CLEAN+=("ssh-port-single-source")
else
    echo "    sshd_config still contains: $(grep -E '^Port +[0-9]+' /etc/ssh/sshd_config | tr '\n' ' ')"
    echo "    Actually listening on:      $(ss -tlnpH 2>/dev/null | grep -i sshd | grep -oE ':[0-9]+ ' | tr -d ': ' | sort -u | tr '\n' ' ')"

    ssh_port_fix() {
        cp /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak.$(date +%Y%m%d_%H%M%S)"
        sed -i '/^#\?Port [0-9]/d' /etc/ssh/sshd_config
        if ! grep -q '^# Listening ports are managed by ssh.socket' /etc/ssh/sshd_config; then
            {
                echo ""
                echo "# Listening ports are managed by ssh.socket, not by this file."
                echo "# A Port directive here has NO effect. Change ports in:"
                echo "#   /etc/systemd/system/ssh.socket.d/ports.conf"
                echo "# then: systemctl daemon-reload && systemctl restart ssh.socket"
            } >> /etc/ssh/sshd_config
        fi

        # Removing an ignored directive cannot change what is listening, but
        # verify anyway - this is the one file where being wrong locks you out.
        if sshd -t 2>/dev/null; then
            ok "Removed the ignored Port directives; sshd config still validates"
            note "Nothing was restarted. Listening ports are unchanged:"
            note "  $(ss -tlnpH 2>/dev/null | grep -i sshd | grep -oE ':[0-9]+ ' | tr -d ': ' | sort -u | tr '\n' ' ')"
            return 0
        fi
        bad "sshd -t failed after the edit - restoring the backup"
        cp "$(ls -1t /etc/ssh/sshd_config.bak.* | head -1)" /etc/ssh/sshd_config
        return 1
    }

    offer "ssh-port-single-source" "The SSH port is configured in two places" \
"ssh.socket is active, so systemd opens the listening socket and hands it to
sshd. The Port directives still sitting in sshd_config are ignored completely.

That is a trap rather than a cosmetic issue: the standard advice for closing
port 22 is to delete its Port line from sshd_config, which on this host would
appear to work and change nothing at all.

Fix: remove the ignored directives and leave a comment saying where the ports
really live. Nothing is restarted and no listening port changes - the file being
edited has no effect on them, which is the entire point." \
        ssh_port_fix
fi

###############################################################################
header "8d. cloud-init crashes on Docker interfaces"
###############################################################################
#
# Starting a container makes Docker create a veth pair. udev fires cloud-init's
# network hotplug hook for it, which asks the cloud datasource what this
# interface is. It is not a provider NIC, so detect_hotplugged_device() finds
# nothing, raises, and apport writes /var/crash/_usr_bin_cloud-init.0.crash.
#
# So every container restart leaves a crash dump behind. That matters here for
# a specific reason: /var/crash is monitored on purpose, because a crash
# appearing is real information. A recurring benign one trains you to dismiss
# the whole directory, and the next crash - the one that is not benign - gets
# dismissed with it.
#
# The hook has no function on these hosts. Networking is static and everything
# else is Docker. Overriding the rule with a symlink to /dev/null in /etc is
# the standard systemd/udev way: it wins over the packaged rule and survives a
# cloud-init upgrade.

CI_RULE=""
for d in /lib/udev/rules.d /usr/lib/udev/rules.d; do
    [ -f "$d/10-cloud-init-hook-hotplug.rules" ] && CI_RULE="10-cloud-init-hook-hotplug.rules" && break
done

if [ -z "$CI_RULE" ]; then
    :   # cloud-init's hotplug hook is not installed on this host
elif ! command -v docker >/dev/null 2>&1; then
    :   # no Docker, so no veth churn to trip over
elif [ -L "/etc/udev/rules.d/$CI_RULE" ]; then
    ok "cloud-init's network hotplug hook is disabled"
    CLEAN+=("cloudinit-hotplug")
else
    CI_CRASHES=$(ls -1 /var/crash/_usr_bin_cloud-init*.crash 2>/dev/null | wc -l)
    [ "${CI_CRASHES:-0}" -gt 0 ] && \
        note "Already ${CI_CRASHES} cloud-init crash dump(s) in /var/crash"

    cloudinit_hotplug_fix() {
        ln -sf /dev/null "/etc/udev/rules.d/$CI_RULE"
        udevadm control --reload-rules 2>/dev/null || \
            note "udevadm reload failed - the override applies after the next boot"
        ok "Disabled cloud-init's network hotplug hook"

        # Only cloud-init's own dumps, and only after the cause is fixed.
        # Everything else in /var/crash stays: those are somebody's evidence.
        if [ "${CI_CRASHES:-0}" -gt 0 ]; then
            rm -f /var/crash/_usr_bin_cloud-init*.crash
            ok "Removed ${CI_CRASHES} cloud-init crash dump(s)"
            note "Other crash dumps in /var/crash were left alone."
        fi

        note "Verify: restart one container and check /var/crash stays empty."
        note "AIDE tracked those files, so refresh afterwards:"
        note "  aide-refresh --reason 'cloud-init hotplug hook disabled'"
        return 0
    }

    offer "cloudinit-hotplug" "Every container restart crashes cloud-init" \
"Docker creates a veth pair when a container starts. udev hands it to
cloud-init's network hotplug hook, which asks the cloud datasource to identify
it, finds nothing - it is not a provider NIC - and crashes. apport writes a
dump to /var/crash each time.

/var/crash is monitored deliberately: a crash dump appearing is information. A
recurring harmless one teaches you to ignore the directory, and then the crash
that matters is ignored too.

The hook does nothing useful here - networking is static and the rest is
Docker. Fix: override the udev rule with a symlink to /dev/null in /etc, which
wins over the packaged rule and survives a cloud-init upgrade. Existing
cloud-init dumps are removed; any other crash dumps are left untouched." \
        cloudinit_hotplug_fix
fi

###############################################################################
header "8e. Docker obeys UFW"
###############################################################################
#
# Exposure is currently described in two places, in two syntaxes: `ufw status`
# for host ports, and a hand-maintained list of RETURN rules inside
# /etc/ufw/after.rules for container ports. The second list does not appear in
# `ufw status` at all.
#
# That is not a cosmetic split. It is how a port ends up believed-closed and
# open at the same time: you read `ufw status`, it does not mention 21118, and
# the conclusion is wrong. Every layer you have to remember separately is a
# layer you will eventually forget.
#
# Pointing DOCKER-USER at ufw-user-forward collapses the two into one. After
# this, `ufw route allow ...` is how a container port gets opened, and
# `ufw status` lists every open port on the machine, host or container.

if ! command -v docker >/dev/null 2>&1 || ! command -v ufw >/dev/null 2>&1; then
    note "Docker or UFW not present - skipping"
elif ! grep -q 'BEGIN SERVER-BASELINE DOCKER-USER' /etc/ufw/after.rules 2>/dev/null; then
    note "No DOCKER-USER block yet - section 8 installs it first"
elif grep -q 'j ufw-user-forward' /etc/ufw/after.rules 2>/dev/null; then
    ok "Container ports go through UFW (ufw route rules)"
    CLEAN+=("ufw-docker")
else
    # The ports the current block lets through. These are exactly what has to
    # exist as ufw route rules before the jump replaces them, or the switch
    # takes working services down with it.
    ROUTE_PORTS=$(sed -n '/# BEGIN SERVER-BASELINE DOCKER-USER/,/# END SERVER-BASELINE DOCKER-USER/p' \
                      /etc/ufw/after.rules 2>/dev/null | \
                  grep -oE '\-\-dport [0-9]+' | awk '{print $2}' | sort -un | tr '\n' ' ')
    ROUTE_PORTS=$(echo "$ROUTE_PORTS" | sed 's/ *$//')

    # Published container ports, one per line, ranges expanded. Ranges have to
    # be expanded: "21115-21119" collapsed to its first port understates by
    # four exactly which ports stay closed, and a plan that quietly understates
    # what it leaves shut is worse than no plan.
    published_ports() {   # $1 = tcp | udp
        docker ps --format '{{.Ports}}' 2>/dev/null | tr ',' '\n' | \
            awk -v want="$1" '
                $0 !~ /^[[:space:]]*(0\.0\.0\.0|\[?::+\]?):/ { next }
                {
                    proto = ($0 ~ /\/udp/) ? "udp" : "tcp"
                    if (proto != want) next
                    if (match($0, /:[0-9]+(-[0-9]+)?->/)) {
                        s = substr($0, RSTART + 1, RLENGTH - 3)
                        n = split(s, a, "-")
                        lo = a[1] + 0; hi = (n > 1) ? a[2] + 0 : lo
                        if (hi > lo + 1024) hi = lo + 1024
                        for (p = lo; p <= hi; p++) print p
                    }
                }' | sort -un | tr '\n' ' ' | sed 's/ *$//'
    }

    # Published but with no exception: dropped today, dropped after. Listed so
    # the plan accounts for every published port rather than only the open ones.
    PUB_TCP=$(published_ports tcp)
    STILL_DROPPED=""
    for p in $PUB_TCP; do
        case " $ROUTE_PORTS " in *" $p "*) ;; *) STILL_DROPPED="$STILL_DROPPED $p" ;; esac
    done

    PUB_UDP=$(published_ports udp)

    if [ -z "$ROUTE_PORTS" ]; then
        UFWDOCKER_PLAN="The current block opens no container ports at all, so there is nothing
  to carry over - only the chain itself changes.
"
    else
        UFWDOCKER_PLAN="These rules are created first, while the current ones still apply:
"
        for p in $ROUTE_PORTS; do
            UFWDOCKER_PLAN="${UFWDOCKER_PLAN}      ufw route allow proto tcp from any to any port $p
"
        done
    fi
    UFWDOCKER_PLAN="${UFWDOCKER_PLAN}
  Then DOCKER-USER is rewritten to hand container traffic to ufw-user-forward,
  and the port list disappears from /etc/ufw/after.rules.

  Reachability does not change. These stay open: ${ROUTE_PORTS:-none}"
    [ -n "$STILL_DROPPED" ] && UFWDOCKER_PLAN="${UFWDOCKER_PLAN}
  Published but dropped today, and still dropped after:$STILL_DROPPED"
    [ -n "$PUB_UDP" ] && UFWDOCKER_PLAN="${UFWDOCKER_PLAN}
  Published over UDP:$PUB_UDP - the current rules are all -p tcp, so these are
  dropped now and stay dropped. Open one with: ufw route allow proto udp ..."

    ufwdocker_fix() {
        local ext_if p bk
        ext_if=$(ip -4 route show default | awk '{print $5; exit}')
        if [ -z "$ext_if" ]; then
            bad "Could not detect the external interface"
            return 1
        fi

        # `ufw reload` prints "Firewall not enabled (skipping reload)" and exits
        # 0 when ufw is disabled. Every check after it would then be reading the
        # chains that happen to still be resident in the kernel from an earlier
        # load - a firewall that is not running, described by rules that are.
        #
        # Both signals are needed. On AC3 `ufw status` said "Status: active"
        # while ufw.conf said ENABLED=no, because status reports on the loaded
        # chains and reload reads the config. Asking only the first is how this
        # guard got written too weak the first time.
        if ! ufw status 2>/dev/null | grep -q '^Status: active' || \
           ! grep -qi '^ENABLED=yes' /etc/ufw/ufw.conf 2>/dev/null; then
            bad "UFW is not enabled, so nothing here would survive a reload"
            note "'ufw status' can say active on stale kernel rules - ufw.conf is the truth"
            note "Enable it first:  ufw enable"
            return 1
        fi

        # Route rules FIRST, while the explicit RETURNs are still in place.
        # The other order leaves a window in which every container port on the
        # host is dropped, and "briefly" is not a property you can promise.
        for p in $ROUTE_PORTS; do
            if ! ufw route allow proto tcp from any to any port "$p" >/dev/null; then
                bad "ufw route allow for port $p failed - nothing was switched over"
                return 1
            fi
            ok "ufw route allow tcp/$p"
        done

        # Verify they landed before removing what they replace. An empty
        # ufw-user-forward plus the new jump is a host with every container
        # port closed.
        for p in $ROUTE_PORTS; do
            if ! iptables -S ufw-user-forward 2>/dev/null | grep -qE -- "--dports? [0-9,:]*\b$p\b"; then
                bad "port $p is not in ufw-user-forward - refusing to switch over"
                note "The route rules added above are left in place. They change nothing"
                note "while DOCKER-USER still has its own list, and re-running is safe."
                return 1
            fi
        done

        bk="/etc/ufw/after.rules.bak.$(date +%Y%m%d_%H%M%S)"
        cp /etc/ufw/after.rules "$bk"

        # Restoring is itself an operation that can fail, and a rollback whose
        # result is thrown away leaves a half-loaded firewall looking like a
        # clean abort. Say which of the two happened.
        ufwdocker_rollback() {
            cp "$bk" /etc/ufw/after.rules
            if ufw reload >/dev/null 2>&1; then
                note "Restored $bk - the firewall is back to its previous state"
            else
                bad "THE RESTORE ALSO FAILED. The firewall may be partially loaded."
                bad "Run now:  cp $bk /etc/ufw/after.rules && ufw reload && ufw status"
            fi
        }

        sed -i '/# BEGIN SERVER-BASELINE DOCKER-USER/,/# END SERVER-BASELINE DOCKER-USER/d' \
            /etc/ufw/after.rules
        {
            echo ""
            echo "# BEGIN SERVER-BASELINE DOCKER-USER"
            echo "# Docker bypasses UFW's INPUT chain. This hands container traffic to"
            echo "# ufw-user-forward instead, so 'ufw route allow' is the one place a"
            echo "# container port is opened and 'ufw status' shows every open port."
            echo "*filter"
            # after.rules is restored as its own pass, and a chain it references
            # has to be declared in it or iptables-restore refuses the whole
            # file with "Chain 'ufw-user-forward' does not exist". Declaring it
            # does NOT empty it: ufw restores with --noflush, under which a
            # chain line creates a missing chain and leaves an existing one -
            # and the route rules in it - alone.
            echo ":ufw-user-forward - [0:0]"
            echo ":DOCKER-USER - [0:0]"
            echo "-A DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN"
            echo "-A DOCKER-USER -s 10.0.0.0/8 -j RETURN"
            echo "-A DOCKER-USER -s 172.16.0.0/12 -j RETURN"
            echo "-A DOCKER-USER -s 192.168.0.0/16 -j RETURN"
            echo "-A DOCKER-USER -j ufw-user-forward"
            echo "-A DOCKER-USER -i $ext_if -j DROP"
            echo "-A DOCKER-USER -j RETURN"
            echo "COMMIT"
            echo "# END SERVER-BASELINE DOCKER-USER"
        } >> /etc/ufw/after.rules

        local reload_out
        if ! reload_out=$(ufw reload 2>&1); then
            bad "ufw reload failed - restoring $bk"
            echo "$reload_out" | sed 's/^/      /'
            ufwdocker_rollback
            return 1
        fi

        # Exit code 0 is not the same as "it did something". This is the case
        # the guard above is meant to have caught already; if it shows up here
        # anyway, ufw was disabled somewhere between then and now, and the
        # right move is to stop rather than to describe stale chains.
        case "$reload_out" in
            *"not enabled"*|*"skipping reload"*)
                bad "ufw reload did nothing: ${reload_out}"
                ufwdocker_rollback
                return 1 ;;
        esac

        # The switch only counts if the chain actually jumps. A reload that
        # succeeds while the block was written wrong is the failure this whole
        # repository keeps running into.
        #
        # Sampled twice, three seconds apart. dockerd reconciles its own
        # iptables state when it notices its chains were rebuilt, and if that
        # is what wipes the jump then the two samples differ - which is a
        # different problem with a different fix than a block that never
        # applied at all. Guessing between the two on a live host is how you
        # break something while trying to describe it.
        if ! iptables -S DOCKER-USER 2>/dev/null | grep -q -- '-j ufw-user-forward'; then
            bad "DOCKER-USER does not jump to ufw-user-forward - restoring $bk"
            echo "    ---- DOCKER-USER right after the reload:"
            iptables -S DOCKER-USER 2>&1 | sed 's/^/      /'
            sleep 3
            echo "    ---- DOCKER-USER three seconds later:"
            iptables -S DOCKER-USER 2>&1 | sed 's/^/      /'
            echo "    ---- ufw-user-forward:"
            iptables -S ufw-user-forward 2>&1 | head -20 | sed 's/^/      /'
            echo "    ---- the block as written to after.rules:"
            sed -n '/# BEGIN SERVER-BASELINE DOCKER-USER/,/# END SERVER-BASELINE DOCKER-USER/p' \
                /etc/ufw/after.rules | sed 's/^/      /'
            echo "    ---- ufw reload said:"
            printf '%s\n' "${reload_out:-(nothing)}" | sed 's/^/      /'
            ufwdocker_rollback
            return 1
        fi

        # The jump is worth nothing if the rules it jumps to were emptied. This
        # is the failure the ":ufw-user-forward - [0:0]" line above could cause
        # if ufw ever restored without --noflush, and it would present as every
        # container port silently going dark.
        for p in $ROUTE_PORTS; do
            if ! iptables -S ufw-user-forward 2>/dev/null | grep -qE -- "--dports? [0-9,:]*\b$p\b"; then
                bad "port $p vanished from ufw-user-forward during the switch - restoring $bk"
                ufwdocker_rollback
                return 1
            fi
        done

        ok "Container ports now go through UFW"
        note "Open one later with: ufw route allow proto tcp from any to any port <port>"
        note "Close one with:      ufw route delete allow proto tcp from any to any port <port>"
        note "Previous rules kept at: $bk"
        note "Verify FROM ANOTHER MACHINE - from here everything looks reachable."
        return 0
    }

    offer "ufw-docker" "Container ports are open in a list UFW never shows you" \
"$UFWDOCKER_PLAN" \
        ufwdocker_fix
fi

###############################################################################
header "9. Security self-check"
###############################################################################

if [ ! -f "$SCRIPT_DIR/security-selfcheck.sh" ]; then
    note "security-selfcheck.sh not found next to this script - skipping"
elif [ -f /etc/cron.d/security-selfcheck ] &&      ! needs_refresh "$SCRIPT_DIR/security-selfcheck.sh" /usr/local/bin/security-selfcheck.sh &&      ! needs_refresh "$SCRIPT_DIR/aide-refresh.sh" /usr/local/bin/aide-refresh.sh; then
    ok "Daily self-check is scheduled and up to date"
    CLEAN+=("selfcheck")
else
    selfcheck_fix() {
        install -m 700 -o root -g root \
            "$SCRIPT_DIR/security-selfcheck.sh" /usr/local/bin/security-selfcheck.sh
        ln -sf /usr/local/bin/security-selfcheck.sh /usr/local/bin/security-selfcheck
        bake_env_path /usr/local/bin/security-selfcheck.sh

        # Baseline refresh helper - run after deliberate changes, never on a timer
        if [ -f "$SCRIPT_DIR/aide-refresh.sh" ]; then
            install -m 700 -o root -g root \
                "$SCRIPT_DIR/aide-refresh.sh" /usr/local/bin/aide-refresh.sh
            ln -sf /usr/local/bin/aide-refresh.sh /usr/local/bin/aide-refresh
            bake_env_path /usr/local/bin/aide-refresh.sh
            ok "Installed aide-refresh (run after upgrades: aide-refresh --reason '...')"
        fi

        # --telegram is decided by whether credentials resolve ANYWHERE, not by
        # whether the legacy /etc file happens to exist. Testing only the old
        # path meant the daily job was scheduled without --telegram on every
        # host set up after credentials moved into the checkout - so the
        # self-check ran, found things, and told no one.
        local args="--quiet"
        if [ -r "$CRED_FILE" ] || [ -r /etc/server-baseline/selfcheck.env ]; then
            args="--quiet --telegram"
        fi

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

    # A rebuild costs 10-20 minutes. Offering it again on a database that was
    # built an hour ago wastes that time and trains the operator to answer
    # without reading - which is how a genuinely important prompt gets skipped
    # later.
    AIDE_DB_AGE=99999
    if [ -f /var/lib/aide/aide.db ]; then
        AIDE_DB_AGE=$(( ( $(date +%s) - $(stat -c %Y /var/lib/aide/aide.db) ) / 86400 ))
    fi

    if [ -n "$DIRTY" ]; then
        bad "Compromise indicators present:$DIRTY"
        bad "NOT offering a baseline rebuild - that would make this state the reference."
        ADVISORY+=("Compromise indicators found ($DIRTY). Investigate before rebuilding the AIDE baseline.")
    elif [ -f /var/lib/aide/aide.db ] && [ "$AIDE_DB_AGE" -lt 1 ]; then
        ok "AIDE baseline was rebuilt today - nothing to do"
        note "Keep it current with 'aide-refresh --reason ...' after deliberate changes."
        CLEAN+=("aide-rebuild")
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
