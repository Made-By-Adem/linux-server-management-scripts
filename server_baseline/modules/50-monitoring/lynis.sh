#!/bin/bash

###############################################################################
# Module: Lynis Installation
# Description: Install and configure Lynis security auditing
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${SCRIPT_DIR}/modules/00-core/common.sh"

MODULE_NAME="lynis"
MODULE_DESCRIPTION="Lynis security auditing"

should_run() {
    skip_if_completed "$MODULE_NAME" "$MODULE_DESCRIPTION" && return 1
    answer_is_yes "INSTALL_LYNIS" || return 1
    return 0
}

run() {
    log_section "Installing Lynis"

    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Would install lynis"
        log_dry_run "Would setup monthly cron job"
        return 0
    fi

    install_package "lynis" "Lynis security auditor"

    # Setup monthly audit cron
    echo "0 4 1 * * root /usr/sbin/lynis audit system --quiet" > /etc/cron.d/lynis-scan

    log_info "✓ Lynis installed"
    log_info "Run manual audit: sudo lynis audit system"

    mark_completed "$MODULE_NAME"
    echo ""
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    should_run && run
fi
