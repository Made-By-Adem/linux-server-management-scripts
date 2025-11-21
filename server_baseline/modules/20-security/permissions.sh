#!/bin/bash

###############################################################################
# Module: File Permissions Hardening
# Description: Secure permissions on critical system files
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${SCRIPT_DIR}/modules/00-core/common.sh"

MODULE_NAME="permissions"
MODULE_DESCRIPTION="File permissions hardening"

should_run() {
    skip_if_completed "$MODULE_NAME" "$MODULE_DESCRIPTION" && return 1
    return 0
}

run() {
    log_section "File Permissions Hardening"

    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Would secure /etc/crontab (600)"
        log_dry_run "Would secure /etc/cron.* directories (700)"
        log_dry_run "Would secure /etc/ssh/sshd_config (600)"
        log_dry_run "Would enable /proc hidepid=2"
        return 0
    fi

    log_info "Hardening file permissions..."

    # Cron files
    chmod 600 /etc/crontab 2>/dev/null && log_info "✓ /etc/crontab (600)"
    chmod 700 /etc/cron.hourly 2>/dev/null && log_info "✓ /etc/cron.hourly (700)"
    chmod 700 /etc/cron.daily 2>/dev/null && log_info "✓ /etc/cron.daily (700)"
    chmod 700 /etc/cron.weekly 2>/dev/null && log_info "✓ /etc/cron.weekly (700)"
    chmod 700 /etc/cron.monthly 2>/dev/null && log_info "✓ /etc/cron.monthly (700)"
    chmod 700 /etc/cron.d 2>/dev/null && log_info "✓ /etc/cron.d (700)"

    # SSH config
    chmod 600 /etc/ssh/sshd_config 2>/dev/null && log_info "✓ /etc/ssh/sshd_config (600)"

    # At.deny
    [ -f /etc/at.deny ] && chmod 600 /etc/at.deny && log_info "✓ /etc/at.deny (600)"

    # /proc hidepid - always enabled (hide other users' processes)
    log_info "Configuring /proc hidepid..."
    if ! grep -q "proc.*hidepid" /etc/fstab 2>/dev/null; then
        echo "proc /proc proc defaults,hidepid=2 0 0" >> /etc/fstab
        mount -o remount /proc 2>/dev/null || true
        log_info "✓ /proc hidepid=2 enabled"
    else
        log_info "✓ /proc hidepid already configured"
    fi

    mark_completed "$MODULE_NAME"
    echo ""
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    should_run && run
fi
