#!/bin/bash

###############################################################################
# Module: Swap Configuration
# Description: Configure swap file with smart sizing based on RAM
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${SCRIPT_DIR}/modules/00-core/common.sh"

MODULE_NAME="swap"
MODULE_DESCRIPTION="Swap file configuration"

# =============================================================================
# CHECK IF MODULE SHOULD RUN
# =============================================================================

should_run() {
    skip_if_completed "$MODULE_NAME" "$MODULE_DESCRIPTION" && return 1

    # Check if user wants swap
    answer_is_yes "CONFIGURE_SWAP" || return 1

    return 0
}

# =============================================================================
# CALCULATE SWAP SIZE
# =============================================================================

calculate_swap_size() {
    local ram_mb=$(free -m | awk '/^Mem:/{print $2}')
    local swap_size

    # Smart swap sizing based on RAM
    # Using config if available, otherwise calculate
    if [ -n "${SWAP_SIZE:-}" ]; then
        # Use configured value (from profile)
        swap_size="$SWAP_SIZE"
    elif [ "$ram_mb" -lt 2048 ]; then
        swap_size="${ram_mb}M"  # RAM < 2GB: swap = RAM
    elif [ "$ram_mb" -lt 8192 ]; then
        swap_size="$((ram_mb / 2))M"  # 2-8GB: swap = RAM/2
    else
        swap_size="4G"  # RAM > 8GB: swap = 4GB
    fi

    echo "$swap_size"
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

run() {
    log_section "Configuring Swap File"

    # Check if swap already exists
    if swapon --show | grep -q "/swapfile"; then
        log_info "✓ Swap file already configured"
        mark_completed "$MODULE_NAME"
        echo ""
        return 0
    fi

    local swap_size=$(calculate_swap_size)
    log_info "Calculated swap size: $swap_size"

    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Would create swap file: $swap_size"
        log_dry_run "Would configure swap in /etc/fstab"
        log_dry_run "Would set swappiness to 10"
        return 0
    fi

    # Create swap file
    log_info "Creating swap file ($swap_size)..."
    if fallocate -l "$swap_size" /swapfile >> "$ERROR_LOG" 2>&1; then
        log_info "✓ Swap file created"
    else
        log_error "Failed to create swap file"
        return 1
    fi

    # Set permissions
    chmod 600 /swapfile

    # Make swap
    log_info "Setting up swap..."
    mkswap /swapfile >> "$ERROR_LOG" 2>&1
    swapon /swapfile >> "$ERROR_LOG" 2>&1

    # Add to fstab
    if ! grep -q "/swapfile" /etc/fstab; then
        echo "/swapfile none swap sw 0 0" >> /etc/fstab
        log_info "✓ Swap added to /etc/fstab"
    fi

    # Configure swappiness
    local swappiness="${SWAPPINESS:-10}"
    log_info "Setting swappiness to $swappiness..."
    sysctl vm.swappiness="$swappiness" >> "$ERROR_LOG" 2>&1

    if ! grep -q "vm.swappiness" /etc/sysctl.conf; then
        echo "vm.swappiness=$swappiness" >> /etc/sysctl.conf
    fi

    # Show swap status
    log_info "Swap status:"
    swapon --show | sed 's/^/  /'
    free -h | grep -E "(Mem|Swap)" | sed 's/^/  /'

    mark_completed "$MODULE_NAME"
    echo ""
}

# Run if executed directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    should_run && run
fi
