#!/bin/bash

###############################################################################
# Module: SSH Hardening
# Description: Configure SSH with security best practices
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${SCRIPT_DIR}/modules/00-core/common.sh"

MODULE_NAME="ssh"
MODULE_DESCRIPTION="SSH hardening"

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
    log_section "SSH Hardening"

    # Get configuration from answers
    local ssh_port="$(get_answer 'SSH_NEW_PORT' "${SSH_NEW_PORT:-888}")"
    local max_sessions="$(get_answer 'SSH_MAX_SESSIONS' "${SSH_MAX_SESSIONS_DEFAULT:-2}")"
    local trusted_ip="$(get_answer 'SSH_TRUSTED_IP' 'n')"
    local disable_forwarding="$(get_answer 'DISABLE_SSH_FORWARDING' 'n')"
    local disable_ipv6="$(get_answer 'DISABLE_IPV6' 'y')"

    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Would harden SSH configuration"
        log_dry_run "Would move SSH to port $ssh_port"
        log_dry_run "Would set MaxSessions to $max_sessions"
        log_dry_run "Would disable password authentication"
        log_dry_run "Would enable key-based authentication only"
        [ "$trusted_ip" != "n" ] && log_dry_run "Would whitelist IP: $trusted_ip"
        [ "$disable_forwarding" = "y" ] && log_dry_run "Would disable SSH forwarding"
        return 0
    fi

    # Check for SSH keys
    check_ssh_keys

    # Backup SSH config
    backup_file "/etc/ssh/sshd_config"

    # Apply SSH hardening
    log_info "Applying SSH hardening configuration..."

    # Remove existing Port directives
    sed -i '/^#\?Port /d' /etc/ssh/sshd_config

    # Basic hardening
    configure_ssh_basic

    # Port configuration (both 22 and new port for migration)
    echo "Port 22" >> /etc/ssh/sshd_config
    echo "Port $ssh_port" >> /etc/ssh/sshd_config
    log_info "✓ SSH listening on ports 22 and $ssh_port"

    # MaxSessions
    if grep -q "^MaxSessions" /etc/ssh/sshd_config; then
        sed -i "s/^MaxSessions .*/MaxSessions $max_sessions/" /etc/ssh/sshd_config
    else
        echo "MaxSessions $max_sessions" >> /etc/ssh/sshd_config
    fi
    log_info "✓ SSH MaxSessions set to $max_sessions"

    # IPv6 configuration
    if [ "$disable_ipv6" = "y" ]; then
        sed -i 's/^#\?AddressFamily .*/AddressFamily inet/' /etc/ssh/sshd_config
        log_info "✓ SSH configured for IPv4 only"
    else
        sed -i 's/^#\?AddressFamily .*/AddressFamily any/' /etc/ssh/sshd_config
        log_info "✓ SSH configured for IPv4 and IPv6"
    fi

    # Forwarding configuration
    if [ "$disable_forwarding" = "y" ]; then
        sed -i 's/^#\?AllowTcpForwarding .*/AllowTcpForwarding no/' /etc/ssh/sshd_config
        sed -i 's/^#\?AllowAgentForwarding .*/AllowAgentForwarding no/' /etc/ssh/sshd_config
        log_info "✓ SSH forwarding disabled"
    else
        sed -i 's/^#\?AllowTcpForwarding .*/AllowTcpForwarding yes/' /etc/ssh/sshd_config
        sed -i 's/^#\?AllowAgentForwarding .*/AllowAgentForwarding yes/' /etc/ssh/sshd_config
        log_info "✓ SSH forwarding enabled"
    fi

    # Banner (if legal banners were configured)
    if [ -f /etc/issue.net ]; then
        sed -i 's/^#\?Banner .*/Banner \/etc\/issue.net/' /etc/ssh/sshd_config
        grep -q "^Banner" /etc/ssh/sshd_config || echo "Banner /etc/issue.net" >> /etc/ssh/sshd_config
        log_info "✓ SSH banner configured"
    fi

    # Test SSH configuration
    if sshd -t 2>/dev/null; then
        log_info "✓ SSH configuration validated"
    else
        log_warning "SSH configuration validation unavailable"
    fi

    # Restart SSH
    restart_service "ssh"

    # Show important information
    echo ""
    log_warning "IMPORTANT: SSH is now on ports 22 AND $ssh_port"
    log_warning "Test the new port before closing port 22!"
    echo ""
    log_info "To test: ssh -p $ssh_port $ACTUAL_USER@$SERVER_IP"
    echo ""

    mark_completed "$MODULE_NAME"
    echo ""
}

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

check_ssh_keys() {
    log_info "Checking for SSH keys..."

    if [ ! -f "$USER_HOME/.ssh/authorized_keys" ] || [ ! -s "$USER_HOME/.ssh/authorized_keys" ]; then
        log_error "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log_error "  ⚠️  CRITICAL: No SSH keys found!"
        log_error "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log_error ""
        log_error "SSH keys are required before hardening!"
        log_error "Please run: ssh-copy-id $ACTUAL_USER@$SERVER_IP"
        log_error ""
        handle_error "SSH keys required for hardening"
    fi

    log_info "✓ SSH keys verified"
}

configure_ssh_basic() {
    # Basic hardening settings
    sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
    sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config
    sed -i 's/^#\?PubkeyAuthentication .*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
    sed -i 's/^#\?ChallengeResponseAuthentication .*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config
    sed -i 's/^#\?X11Forwarding .*/X11Forwarding no/' /etc/ssh/sshd_config
    sed -i 's/^#\?MaxAuthTries .*/MaxAuthTries 3/' /etc/ssh/sshd_config
    sed -i 's/^#\?ClientAliveInterval .*/ClientAliveInterval 300/' /etc/ssh/sshd_config
    sed -i 's/^#\?ClientAliveCountMax .*/ClientAliveCountMax 2/' /etc/ssh/sshd_config
    sed -i 's/^#\?TCPKeepAlive .*/TCPKeepAlive no/' /etc/ssh/sshd_config
    sed -i 's/^#\?LogLevel .*/LogLevel VERBOSE/' /etc/ssh/sshd_config

    # Ensure Protocol 2
    grep -q "^Protocol 2" /etc/ssh/sshd_config || echo "Protocol 2" >> /etc/ssh/sshd_config

    log_info "✓ Basic SSH hardening applied"
}

# Run if executed directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    should_run && run
fi
