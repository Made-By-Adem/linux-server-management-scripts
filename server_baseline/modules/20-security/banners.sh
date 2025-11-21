#!/bin/bash

###############################################################################
# Module: Legal Warning Banners
# Description: Configure legal warning banners for SSH login
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${SCRIPT_DIR}/modules/00-core/common.sh"

MODULE_NAME="banners"
MODULE_DESCRIPTION="Legal warning banners"

should_run() {
    skip_if_completed "$MODULE_NAME" "$MODULE_DESCRIPTION" && return 1
    # Legal banners are always enabled for security compliance
    return 0
}

run() {
    log_section "Legal Warning Banners"

    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Would create /etc/issue with legal banner"
        log_dry_run "Would create /etc/issue.net for SSH"
        return 0
    fi

    log_info "Creating legal warning banners..."

    backup_file "/etc/issue"
    backup_file "/etc/issue.net"

    cat > /etc/issue << 'BANNER'
***********************************************************************
*                         AUTHORIZED ACCESS ONLY                      *
***********************************************************************

This system is for authorized use only. Individuals accessing this
system without authority or exceeding their access authority are
subject to having all of their activities on this system monitored
and recorded.

Any unauthorized access or use of this system is prohibited and may
be subject to criminal and/or civil penalties.

All activities on this system are logged and monitored.

***********************************************************************
BANNER

    cp /etc/issue /etc/issue.net

    log_info "✓ Legal banners created"

    mark_completed "$MODULE_NAME"
    echo ""
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    should_run && run
fi
