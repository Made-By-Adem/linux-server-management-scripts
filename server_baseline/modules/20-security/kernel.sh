#!/bin/bash

###############################################################################
# Module: Kernel Hardening
# Description: Apply sysctl security parameters
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${SCRIPT_DIR}/modules/00-core/common.sh"

MODULE_NAME="kernel"
MODULE_DESCRIPTION="Kernel hardening"

should_run() {
    skip_if_completed "$MODULE_NAME" "$MODULE_DESCRIPTION" && return 1
    return 0
}

run() {
    log_section "Kernel Hardening"

    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Would configure sysctl security parameters"
        log_dry_run "Would disable IP source routing"
        log_dry_run "Would enable SYN flood protection"
        log_dry_run "Would configure network hardening"
        return 0
    fi

    log_info "Applying kernel hardening parameters..."

    cat > /etc/sysctl.d/99-server-hardening.conf <<SYSCTL
# Server Baseline Kernel Hardening

# Network security
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.tcp_syncookies = 1

# Docker/Container compatibility
net.ipv4.conf.all.forwarding = 1
net.ipv6.conf.all.forwarding = 1
net.netfilter.nf_conntrack_max = ${CONNTRACK_MAX:-524288}

# Kernel hardening
kernel.sysrq = 0
kernel.kptr_restrict = 2
kernel.unprivileged_bpf_disabled = 1
net.core.bpf_jit_harden = 1
kernel.perf_event_paranoid = 3
kernel.yama.ptrace_scope = 1

# File system hardening
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.protected_fifos = 2
fs.protected_regular = 2
fs.suid_dumpable = 0

# Performance
vm.swappiness = ${SWAPPINESS:-10}
vm.vfs_cache_pressure = ${VFS_CACHE_PRESSURE:-50}
SYSCTL

    # Apply sysctl settings
    sysctl -p /etc/sysctl.d/99-server-hardening.conf >> "$ERROR_LOG" 2>&1
    log_info "✓ Kernel hardening applied"

    # Disable uncommon protocols
    cat > /etc/modprobe.d/disable-protocols.conf <<MODPROBE
# Disable uncommon network protocols
install dccp /bin/true
install sctp /bin/true
install rds /bin/true
install tipc /bin/true
MODPROBE

    log_info "✓ Uncommon protocols disabled"

    mark_completed "$MODULE_NAME"
    echo ""
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    should_run && run
fi
