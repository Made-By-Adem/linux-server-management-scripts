#!/bin/bash

###############################################################################
# Module: Systemd Service Hardening
# Description: Apply security hardening to system services
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${SCRIPT_DIR}/modules/00-core/common.sh"

MODULE_NAME="systemd_hardening"
MODULE_DESCRIPTION="Systemd service hardening"

should_run() {
    skip_if_completed "$MODULE_NAME" "$MODULE_DESCRIPTION" && return 1
    return 0
}

run() {
    log_section "Systemd Service Hardening"

    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Would harden SSH service"
        log_dry_run "Would harden Fail2ban service"
        log_dry_run "Would harden Cron service"
        return 0
    fi

    # Create drop-in directory for SSH
    mkdir -p /etc/systemd/system/ssh.service.d

    # SSH hardening (VSCode compatible)
    cat > /etc/systemd/system/ssh.service.d/hardening.conf << 'SSHHARD'
[Service]
# Systemd hardening for SSH (Lynis BOOT-5264)
# Note: PrivateTmp disabled for VSCode/Lynis/Rkhunter compatibility
ReadWritePaths=/etc/ufw /tmp /var/tmp /etc/systemd/system /etc/docker
SSHHARD

    log_info "✓ SSH service hardened"

    # Fail2ban hardening
    mkdir -p /etc/systemd/system/fail2ban.service.d

    cat > /etc/systemd/system/fail2ban.service.d/hardening.conf << 'F2BHARD'
[Service]
# Systemd hardening for Fail2ban
PrivateTmp=yes
ProtectSystem=full
ProtectHome=read-only
NoNewPrivileges=yes
ReadWritePaths=/var/run/fail2ban /var/lib/fail2ban /var/log /etc/ufw
F2BHARD

    log_info "✓ Fail2ban service hardened"

    # Cron hardening
    mkdir -p /etc/systemd/system/cron.service.d

    cat > /etc/systemd/system/cron.service.d/hardening.conf << 'CRONHARD'
[Service]
# Systemd hardening for Cron
PrivateTmp=yes
ProtectSystem=full
NoNewPrivileges=yes
CRONHARD

    log_info "✓ Cron service hardened"

    # Reload systemd
    systemctl daemon-reload >> "$ERROR_LOG" 2>&1

    log_info "✓ Systemd configuration reloaded"

    mark_completed "$MODULE_NAME"
    echo ""
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    should_run && run
fi
