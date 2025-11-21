#!/bin/bash

###############################################################################
# Module: System Cleanup
# Description: Remove deprecated packages and clean up system
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${SCRIPT_DIR}/modules/00-core/common.sh"

MODULE_NAME="cleanup"
MODULE_DESCRIPTION="System cleanup"

should_run() {
    skip_if_completed "$MODULE_NAME" "$MODULE_DESCRIPTION" && return 1
    return 0
}

run() {
    log_section "System Cleanup"

    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Would remove deprecated packages"
        log_dry_run "Would clean apt cache"
        log_dry_run "Would remove orphaned packages"
        return 0
    fi

    # Remove deprecated/insecure packages
    log_info "Removing deprecated packages..."
    local deprecated_packages=(
        "nis"
        "rsh-client"
        "rsh-redone-client"
        "telnet"
        "tftp"
        "xinetd"
    )

    for pkg in "${deprecated_packages[@]}"; do
        if dpkg -l | grep -q "^ii  $pkg "; then
            apt-get purge -y "$pkg" >> "$ERROR_LOG" 2>&1
            log_info "✓ Removed: $pkg"
        fi
    done

    # Clean up orphaned packages
    log_info "Cleaning up orphaned packages..."
    apt-get autoremove -y >> "$ERROR_LOG" 2>&1

    # Clean apt cache
    log_info "Cleaning apt cache..."
    apt-get clean >> "$ERROR_LOG" 2>&1

    # Purge residual config files
    log_info "Purging residual config files..."
    dpkg -l | awk '/^rc/ {print $2}' | xargs -r dpkg --purge >> "$ERROR_LOG" 2>&1

    log_info "✓ System cleanup complete"

    mark_completed "$MODULE_NAME"
    echo ""
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    should_run && run
fi
