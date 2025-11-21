#!/bin/bash

###############################################################################
# Module: Rkhunter Installation
# Description: Install and configure rootkit hunter
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${SCRIPT_DIR}/modules/00-core/common.sh"

MODULE_NAME="rkhunter"
MODULE_DESCRIPTION="Rkhunter rootkit scanner"

should_run() {
    skip_if_completed "$MODULE_NAME" "$MODULE_DESCRIPTION" && return 1
    answer_is_yes "INSTALL_RKHUNTER" || return 1
    return 0
}

run() {
    log_section "Installing Rkhunter"

    local ssh_port="$(get_answer 'SSH_NEW_PORT' '888')"
    local telegram_token="$(get_answer 'TELEGRAM_BOT_TOKEN' '')"
    local telegram_chat="$(get_answer 'TELEGRAM_CHAT_ID' '')"

    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Would install rkhunter"
        log_dry_run "Would configure for SSH port $ssh_port"
        log_dry_run "Would setup daily cron job"
        [ -n "$telegram_token" ] && log_dry_run "Would configure Telegram alerts"
        return 0
    fi

    install_package "rkhunter" "Rootkit Hunter"

    # Update Rkhunter
    rkhunter --update >> "$ERROR_LOG" 2>&1
    rkhunter --propupd >> "$ERROR_LOG" 2>&1

    # Configure Rkhunter
    backup_file "/etc/rkhunter.conf"
    sed -i "s/^#\?ALLOW_SSH_ROOT_USER=.*/ALLOW_SSH_ROOT_USER=prohibit-password/" /etc/rkhunter.conf

    if grep -q "^PORT_NUMBER=" /etc/rkhunter.conf; then
        sed -i "s/^PORT_NUMBER=.*/PORT_NUMBER=$ssh_port/" /etc/rkhunter.conf
    else
        echo "PORT_NUMBER=$ssh_port" >> /etc/rkhunter.conf
    fi

    log_info "✓ Rkhunter installed and configured"

    # Setup cron job
    echo "0 3 * * * root /usr/bin/rkhunter --check --skip-keypress --quiet" > /etc/cron.d/rkhunter-scan
    log_info "✓ Daily scan configured"

    mark_completed "$MODULE_NAME"
    echo ""
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    should_run && run
fi
