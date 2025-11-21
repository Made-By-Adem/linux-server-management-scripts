#!/bin/bash

###############################################################################
# Module: Fail2ban Configuration
# Description: Configure Fail2ban intrusion prevention
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${SCRIPT_DIR}/modules/00-core/common.sh"

MODULE_NAME="fail2ban"
MODULE_DESCRIPTION="Fail2ban intrusion prevention"

# =============================================================================
# CHECK IF MODULE SHOULD RUN
# =============================================================================

should_run() {
    skip_if_completed "$MODULE_NAME" "$MODULE_DESCRIPTION" && return 1
    return 0
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

run() {
    log_section "Configuring Fail2ban"

    # Get configuration
    local ssh_port="$(get_answer 'SSH_NEW_PORT' "${SSH_NEW_PORT:-888}")"
    local ban_time="${FAIL2BAN_SSH_BANTIME:-7200}"
    local max_retry="${FAIL2BAN_SSH_MAXRETRY:-3}"
    local find_time="${FAIL2BAN_SSH_FINDTIME:-600}"

    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Would configure Fail2ban"
        log_dry_run "Would set SSH ban time to $ban_time seconds"
        log_dry_run "Would set max retries to $max_retry"
        log_dry_run "Would monitor SSH on ports 22 and $ssh_port"
        return 0
    fi

    # Fail2ban should already be installed by packages module
    log_info "Configuring Fail2ban for SSH protection..."

    # Create jail.d configuration (best practice - Lynis DEB-0880)
    cat > /etc/fail2ban/jail.d/server-baseline.conf <<EOF
# Server Baseline Fail2ban Configuration
# Lynis DEB-0880: Use jail.d instead of jail.local

[DEFAULT]
# Ban duration in seconds
bantime = $ban_time

# Time window for counting retries
findtime = $find_time

# Dest

ination email for ban notifications (if configured)
destemail = root@localhost

# Email sender
sender = fail2ban@localhost

[sshd]
enabled = true
port = 22,$ssh_port
filter = sshd
logpath = /var/log/auth.log
maxretry = $max_retry
bantime = $ban_time
findtime = $find_time
EOF

    log_info "✓ Fail2ban configuration created"

    # Enable and start Fail2ban
    enable_service "fail2ban"
    restart_service "fail2ban"

    # Show status
    sleep 2
    log_info "Fail2ban status:"
    fail2ban-client status sshd 2>/dev/null | sed 's/^/  /' || log_warning "Fail2ban status unavailable"

    mark_completed "$MODULE_NAME"
    echo ""
}

# Run if executed directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    should_run && run
fi
