#!/bin/bash

###############################################################################
# Module: Sysstat Installation
# Description: Install system performance monitoring tools
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${SCRIPT_DIR}/modules/00-core/common.sh"

MODULE_NAME="sysstat"
MODULE_DESCRIPTION="Sysstat performance monitoring"

should_run() {
    skip_if_completed "$MODULE_NAME" "$MODULE_DESCRIPTION" && return 1
    return 0
}

run() {
    log_section "Installing Sysstat"

    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Would install sysstat"
        log_dry_run "Would enable performance data collection"
        return 0
    fi

    install_package "sysstat" "System performance monitoring"

    # Enable sysstat
    sed -i 's/^ENABLED="false"/ENABLED="true"/' /etc/default/sysstat 2>/dev/null

    enable_service "sysstat"
    restart_service "sysstat"

    log_info "✓ Sysstat installed (tools: sar, iostat, mpstat, pidstat)"

    mark_completed "$MODULE_NAME"
    echo ""
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    should_run && run
fi
