#!/bin/bash

###############################################################################
# Module: IPv6 Configuration
# Description: Disable or enable IPv6 based on user preference
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${SCRIPT_DIR}/modules/00-core/common.sh"

MODULE_NAME="ipv6"
MODULE_DESCRIPTION="IPv6 configuration"

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
    log_section "Configuring IPv6"

    local disable_ipv6="$(get_answer 'DISABLE_IPV6' 'y')"

    if [ "$disable_ipv6" != "y" ]; then
        log_info "IPv6 will remain enabled"
        mark_completed "$MODULE_NAME"
        echo ""
        return 0
    fi

    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Would disable IPv6 system-wide"
        log_dry_run "Would update sysctl configuration"
        log_dry_run "Would update GRUB configuration"
        return 0
    fi

    log_info "Disabling IPv6..."

    # Disable via sysctl
    cat > /etc/sysctl.d/99-disable-ipv6.conf <<EOF
# Disable IPv6
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF

    # Apply immediately
    sysctl -p /etc/sysctl.d/99-disable-ipv6.conf >> "$ERROR_LOG" 2>&1

    # Also disable in GRUB (persistent across reboots)
    if [ -f /etc/default/grub ]; then
        backup_file "/etc/default/grub"

        if grep -q "GRUB_CMDLINE_LINUX=" /etc/default/grub; then
            sed -i 's/GRUB_CMDLINE_LINUX="/GRUB_CMDLINE_LINUX="ipv6.disable=1 /' /etc/default/grub
            update-grub >> "$ERROR_LOG" 2>&1
        fi
    fi

    log_info "✓ IPv6 disabled"

    mark_completed "$MODULE_NAME"
    echo ""
}

# Run if executed directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    should_run && run
fi
