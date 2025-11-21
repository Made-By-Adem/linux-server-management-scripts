#!/bin/bash

###############################################################################
# Module: UFW Firewall Configuration
# Description: Configure UFW firewall with security defaults
###############################################################################

# Source common utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${SCRIPT_DIR}/modules/00-core/common.sh"

# Module metadata
MODULE_NAME="firewall"
MODULE_DESCRIPTION="UFW firewall configuration"

# =============================================================================
# CHECK IF MODULE SHOULD RUN
# =============================================================================

should_run() {
    # Skip if already completed
    skip_if_completed "$MODULE_NAME" "$MODULE_DESCRIPTION" && return 1

    # Always run firewall configuration
    return 0
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

run() {
    log_section "Configuring Firewall (UFW)"

    # Get configuration
    local ssh_port="$(get_answer 'SSH_NEW_PORT' "${SSH_NEW_PORT:-888}")"
    local disable_ipv6="$(get_answer 'DISABLE_IPV6' 'y')"
    local extra_ports="$(get_answer 'FIREWALL_EXTRA_PORTS' 'n')"
    local install_netdata="$(get_answer 'INSTALL_NETDATA' 'y')"
    local install_portainer="$(get_answer 'INSTALL_PORTAINER' 'y')"

    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Would install UFW firewall"
        log_dry_run "Would set default deny incoming, allow outgoing"
        log_dry_run "Would allow SSH on port $ssh_port"
        log_dry_run "Would allow HTTP (80), HTTPS (443)"
        [ "$install_portainer" = "y" ] && log_dry_run "Would allow Portainer (9443)"
        [ "$install_netdata" = "y" ] && log_dry_run "Would allow Netdata (19999)"
        [ "$disable_ipv6" = "y" ] && log_dry_run "Would disable IPv6 in UFW"
        [ "$extra_ports" != "n" ] && log_dry_run "Would allow extra ports: $extra_ports"
        return 0
    fi

    # Install UFW
    install_package "ufw" "UFW firewall"

    # Configure UFW defaults
    log_info "Configuring UFW defaults..."
    ufw --force reset >> "$ERROR_LOG" 2>&1
    ufw default deny incoming >> "$ERROR_LOG" 2>&1
    ufw default allow outgoing >> "$ERROR_LOG" 2>&1

    # Disable IPv6 if requested
    if [ "$disable_ipv6" = "y" ]; then
        log_info "Disabling IPv6 in UFW..."
        sed -i 's/IPV6=yes/IPV6=no/' /etc/default/ufw
        log_info "✓ IPv6 disabled in UFW"
    fi

    # Allow SSH (both old and new port temporarily)
    log_info "Allowing SSH access..."
    ufw allow 22/tcp comment 'SSH (temporary - migration)' >> "$ERROR_LOG" 2>&1
    ufw allow "$ssh_port/tcp" comment 'SSH (new secure port)' >> "$ERROR_LOG" 2>&1
    log_info "✓ SSH allowed on ports 22 and $ssh_port"

    # Allow HTTP and HTTPS
    log_info "Allowing web traffic..."
    ufw allow 80/tcp comment 'HTTP' >> "$ERROR_LOG" 2>&1
    ufw allow 443/tcp comment 'HTTPS' >> "$ERROR_LOG" 2>&1
    log_info "✓ HTTP and HTTPS allowed"

    # Allow Portainer
    if [ "$install_portainer" = "y" ]; then
        log_info "Allowing Portainer..."
        ufw allow 9443/tcp comment 'Portainer HTTPS' >> "$ERROR_LOG" 2>&1
        log_info "✓ Portainer port 9443 allowed"
    fi

    # Allow Netdata
    if [ "$install_netdata" = "y" ]; then
        log_info "Allowing Netdata..."
        ufw allow 19999/tcp comment 'Netdata monitoring' >> "$ERROR_LOG" 2>&1
        log_info "✓ Netdata port 19999 allowed"
    fi

    # Allow extra ports
    if [ "$extra_ports" != "n" ] && [ -n "$extra_ports" ]; then
        log_info "Adding extra firewall ports..."
        IFS=',' read -ra PORTS <<< "$extra_ports"
        for port in "${PORTS[@]}"; do
            port=$(echo "$port" | xargs)  # Trim whitespace
            if is_valid_port "$port"; then
                ufw allow "$port/tcp" comment "Custom port $port" >> "$ERROR_LOG" 2>&1
                log_info "✓ Port $port allowed"
            else
                log_warning "Invalid port: $port (skipped)"
            fi
        done
    fi

    # Enable UFW
    log_info "Enabling UFW firewall..."
    ufw --force enable >> "$ERROR_LOG" 2>&1
    log_info "✓ UFW firewall enabled"

    # Show status
    echo ""
    log_info "Firewall rules:"
    ufw status numbered | sed 's/^/  /'

    # Mark as completed
    mark_completed "$MODULE_NAME"
    echo ""
}

# Run if executed directly (for testing)
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    should_run && run
fi
