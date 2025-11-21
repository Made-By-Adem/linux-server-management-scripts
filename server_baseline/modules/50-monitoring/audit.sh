#!/bin/bash

###############################################################################
# Module: Audit System
# Description: Configure auditd for security monitoring
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${SCRIPT_DIR}/modules/00-core/common.sh"

MODULE_NAME="audit"
MODULE_DESCRIPTION="Audit system configuration"

should_run() {
    skip_if_completed "$MODULE_NAME" "$MODULE_DESCRIPTION" && return 1
    return 0
}

run() {
    log_section "Configuring Audit System"

    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Would configure auditd rules"
        log_dry_run "Would monitor SSH config changes"
        log_dry_run "Would track privileged commands"
        return 0
    fi

    log_info "Configuring audit rules..."

    cat > /etc/audit/rules.d/server-baseline.rules << 'AUDITRULES'
# Server Baseline Audit Rules

# Monitor SSH config changes
-w /etc/ssh/sshd_config -p wa -k sshd_config_changes

# Monitor authentication files
-w /etc/passwd -p wa -k auth_file_changes
-w /etc/shadow -p wa -k auth_file_changes
-w /etc/group -p wa -k auth_file_changes
-w /etc/sudoers -p wa -k auth_file_changes

# Monitor privileged commands
-a always,exit -F arch=b64 -S execve -F euid=0 -k privileged_commands

# Monitor login events
-w /var/log/lastlog -p wa -k login_events
AUDITRULES

    # Reload audit rules
    augenrules --load >> "$ERROR_LOG" 2>&1

    enable_service "auditd"
    restart_service "auditd"

    log_info "✓ Audit system configured"

    mark_completed "$MODULE_NAME"
    echo ""
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    should_run && run
fi
