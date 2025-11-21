#!/bin/bash

###############################################################################
# Module: Hostname Configuration
# Description: Configure FQDN hostname (.local domain)
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${SCRIPT_DIR}/modules/00-core/common.sh"

MODULE_NAME="hostname"
MODULE_DESCRIPTION="FQDN hostname configuration"

# =============================================================================
# CHECK IF MODULE SHOULD RUN
# =============================================================================

should_run() {
    skip_if_completed "$MODULE_NAME" "$MODULE_DESCRIPTION" && return 1

    # Check if user wants FQDN
    answer_is_yes "ENABLE_FQDN" || return 1

    return 0
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

run() {
    log_section "Configuring FQDN Hostname"

    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Would configure hostname with .local domain"
        log_dry_run "Would update /etc/hosts with FQDN"
        return 0
    fi

    # Get current hostname
    local current_hostname=$(hostname)
    local fqdn_hostname="${current_hostname}.local"

    log_info "Current hostname: $current_hostname"
    log_info "Setting FQDN to: $fqdn_hostname"

    # Set hostname
    hostnamectl set-hostname "$current_hostname" >> "$ERROR_LOG" 2>&1

    # Update /etc/hosts
    backup_file "/etc/hosts"

    log_info "Updating /etc/hosts..."

    # Remove old entries
    sed -i "/127.0.1.1/d" /etc/hosts

    # Add new FQDN entry
    echo "127.0.1.1 $fqdn_hostname $current_hostname" >> /etc/hosts

    # Verify
    if hostname --fqdn | grep -q "\.local$"; then
        log_info "✓ FQDN hostname configured: $fqdn_hostname"
    else
        log_warning "FQDN verification failed (continuing anyway)"
    fi

    mark_completed "$MODULE_NAME"
    echo ""
}

# Run if executed directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    should_run && run
fi
