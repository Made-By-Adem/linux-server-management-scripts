#!/bin/bash

###############################################################################
# Module: System Packages
# Description: Update system and install essential packages
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${SCRIPT_DIR}/modules/00-core/common.sh"

MODULE_NAME="system_packages"
MODULE_DESCRIPTION="System updates and package installation"

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
    log_section "System Updates & Essential Packages"

    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Would update package lists"
        log_dry_run "Would upgrade all packages"
        log_dry_run "Would install essential packages"
        return 0
    fi

    # Update package lists
    log_info "Updating package lists..."
    if apt-get update >> "$ERROR_LOG" 2>&1; then
        log_info "✓ Package lists updated"
    else
        log_error "Failed to update package lists"
        return 1
    fi

    # Upgrade existing packages
    log_info "Upgrading installed packages (this may take a while)..."
    if DEBIAN_FRONTEND=noninteractive apt-get upgrade -y >> "$ERROR_LOG" 2>&1; then
        log_info "✓ System packages upgraded"
    else
        log_warning "Some packages failed to upgrade (continuing anyway)"
    fi

    # Install essential packages
    log_info "Installing essential packages..."

    local essential_packages=(
        # Basic utilities
        "curl"
        "wget"
        "git"
        "net-tools"
        "software-properties-common"
        "apt-transport-https"
        "ca-certificates"
        "gnupg"
        "lsb-release"

        # Monitoring tools
        "htop"
        "iotop"
        "nethogs"

        # Security packages
        "ufw"
        "fail2ban"
        "unattended-upgrades"
        "apt-listchanges"
        "needrestart"

        # System packages
        "acct"
        "auditd"
        "libpam-tmpdir"
    )

    install_packages "essential packages" "${essential_packages[@]}"

    # Configure unattended-upgrades
    log_info "Configuring automatic security updates..."
    dpkg-reconfigure -plow unattended-upgrades >> "$ERROR_LOG" 2>&1
    log_info "✓ Automatic security updates enabled"

    mark_completed "$MODULE_NAME"
    echo ""
}

# Run if executed directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    should_run && run
fi
