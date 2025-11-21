#!/bin/bash

###############################################################################
# Module: Timezone Configuration
# Description: Set system timezone and enable NTP synchronization
###############################################################################

# Source common utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${SCRIPT_DIR}/modules/00-core/common.sh"

# Module metadata
MODULE_NAME="timezone"
MODULE_DESCRIPTION="Timezone configuration"

# =============================================================================
# CHECK IF MODULE SHOULD RUN
# =============================================================================

should_run() {
    # Skip if already completed
    skip_if_completed "$MODULE_NAME" "$MODULE_DESCRIPTION" && return 1

    # Always run timezone configuration
    return 0
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

run() {
    log_section "Configuring Timezone"

    # Get timezone from user answers or config
    local timezone="$(get_answer 'TIMEZONE' "${TIMEZONE:-Europe/Amsterdam}")"

    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Would set timezone to: $timezone"
        log_dry_run "Would enable NTP synchronization"
        return 0
    fi

    # Set timezone
    log_info "Setting timezone to: $timezone"
    if timedatectl set-timezone "$timezone" >> "$ERROR_LOG" 2>&1; then
        log_info "✓ Timezone set to $timezone"
    else
        log_warning "Failed to set timezone (continuing anyway)"
    fi

    # Enable NTP
    log_info "Enabling NTP synchronization..."
    if timedatectl set-ntp true >> "$ERROR_LOG" 2>&1; then
        log_info "✓ NTP synchronization enabled"
    else
        log_warning "Failed to enable NTP (continuing anyway)"
    fi

    # Show current time info
    log_info "Current system time:"
    timedatectl status | grep -E "(Time zone|System clock|NTP)" | sed 's/^/  /'

    # Mark as completed
    mark_completed "$MODULE_NAME"
    echo ""
}

# Run if executed directly (for testing)
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    should_run && run
fi
