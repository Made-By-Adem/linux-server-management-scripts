#!/bin/bash

###############################################################################
# Module: AIDE Installation
# Description: Install AIDE file integrity monitoring
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${SCRIPT_DIR}/modules/00-core/common.sh"

MODULE_NAME="aide"
MODULE_DESCRIPTION="AIDE file integrity monitoring"

should_run() {
    skip_if_completed "$MODULE_NAME" "$MODULE_DESCRIPTION" && return 1
    answer_is_yes "ENABLE_AIDE" || return 1
    return 0
}

run() {
    log_section "Installing AIDE"

    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Would install AIDE"
        log_dry_run "Would initialize AIDE database (10-20 min)"
        log_dry_run "Would setup daily integrity checks"
        return 0
    fi

    install_package "aide" "AIDE file integrity monitor"

    log_info "Initializing AIDE database (this takes 10-20 minutes)..."
    aideinit >> "$ERROR_LOG" 2>&1

    # Move new database
    if [ -f /var/lib/aide/aide.db.new ]; then
        mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db
    fi

    # Setup daily check
    echo "0 4 * * * root /usr/bin/aide --check" > /etc/cron.d/aide-check

    log_info "✓ AIDE installed and initialized"

    mark_completed "$MODULE_NAME"
    echo ""
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    should_run && run
fi
