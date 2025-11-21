#!/bin/bash

###############################################################################
# Module: USB Storage Control
# Description: Disable USB mass storage for security
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${SCRIPT_DIR}/modules/00-core/common.sh"

MODULE_NAME="usb_storage"
MODULE_DESCRIPTION="USB storage control"

should_run() {
    skip_if_completed "$MODULE_NAME" "$MODULE_DESCRIPTION" && return 1
    answer_is_yes "DISABLE_USB_STORAGE" || return 1
    return 0
}

run() {
    log_section "USB Storage Control"

    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Would disable USB mass storage"
        log_dry_run "Would create /etc/modprobe.d/usb-storage.conf"
        return 0
    fi

    log_info "Disabling USB mass storage..."

    cat > /etc/modprobe.d/usb-storage.conf <<USB
# Disable USB mass storage
install usb-storage /bin/true
blacklist usb-storage
USB

    log_info "✓ USB mass storage disabled"
    log_info "Note: USB keyboards and mice still work"

    mark_completed "$MODULE_NAME"
    echo ""
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    should_run && run
fi
