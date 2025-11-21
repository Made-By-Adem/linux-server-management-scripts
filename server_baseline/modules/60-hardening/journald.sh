#!/bin/bash

###############################################################################
# Module: Journald Configuration
# Description: Configure systemd journal with log rotation
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${SCRIPT_DIR}/modules/00-core/common.sh"

MODULE_NAME="journald"
MODULE_DESCRIPTION="Journald configuration"

should_run() {
    skip_if_completed "$MODULE_NAME" "$MODULE_DESCRIPTION" && return 1
    return 0
}

run() {
    log_section "Configuring Journald"

    # Get config values
    local max_use="${JOURNAL_MAX_USE:-500M}"
    local max_file="${JOURNAL_MAX_FILE_SIZE:-50M}"
    local retention="${JOURNAL_RETENTION_DAYS:-30}"

    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Would configure journal max size: $max_use"
        log_dry_run "Would set log retention: ${retention} days"
        return 0
    fi

    log_info "Configuring journald..."

    backup_file "/etc/systemd/journald.conf"

    cat > /etc/systemd/journald.conf << JOURNALD
# Server Baseline Journald Configuration

[Journal]
Storage=persistent
Compress=yes
SystemMaxUse=$max_use
SystemMaxFileSize=$max_file
MaxRetentionSec=${retention}d
ForwardToSyslog=yes
JOURNALD

    restart_service "systemd-journald"

    log_info "✓ Journald configured (max: $max_use, retention: ${retention}d)"

    mark_completed "$MODULE_NAME"
    echo ""
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    should_run && run
fi
