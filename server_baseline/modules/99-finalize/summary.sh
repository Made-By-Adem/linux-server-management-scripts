#!/bin/bash

###############################################################################
# Module: Installation Summary
# Description: Display installation summary and next steps
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${SCRIPT_DIR}/modules/00-core/common.sh"

MODULE_NAME="summary"
MODULE_DESCRIPTION="Installation summary"

should_run() {
    # Always run summary
    return 0
}

run() {
    log_section "Installation Summary"

    local ssh_port="$(get_answer 'SSH_NEW_PORT' '888')"

    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║           SERVER BASELINE INSTALLATION COMPLETE               ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    echo -e "${YELLOW}Installed Components:${NC}"
    is_completed "system_packages" && echo "  ✓ System packages and updates"
    is_completed "docker" && echo "  ✓ Docker Engine"
    is_completed "portainer" && echo "  ✓ Portainer (https://$SERVER_IP:9443)"
    is_completed "netdata" && echo "  ✓ Netdata (http://$SERVER_IP:19999)"
    is_completed "cloudflare" && echo "  ✓ Cloudflare Tunnel"
    is_completed "ssh" && echo "  ✓ SSH Hardening (port $ssh_port)"
    is_completed "firewall" && echo "  ✓ UFW Firewall"
    is_completed "fail2ban" && echo "  ✓ Fail2ban"
    is_completed "passwords" && echo "  ✓ Password policies"
    is_completed "kernel" && echo "  ✓ Kernel hardening"
    is_completed "rkhunter" && echo "  ✓ Rkhunter"
    is_completed "lynis" && echo "  ✓ Lynis"
    is_completed "aide" && echo "  ✓ AIDE"
    echo ""

    echo -e "${RED}⚠️  CRITICAL NEXT STEPS:${NC}"
    echo ""
    echo "1. TEST SSH on new port BEFORE disconnecting:"
    echo "   ${CYAN}ssh -p $ssh_port $ACTUAL_USER@$SERVER_IP${NC}"
    echo ""
    echo "2. If SSH works, remove old port 22:"
    echo "   ${CYAN}sudo sed -i '/^Port 22$/d' /etc/ssh/sshd_config${NC}"
    echo "   ${CYAN}sudo systemctl restart ssh${NC}"
    echo ""
    echo "3. Log out and back in to activate docker group"
    echo ""

    if is_completed "portainer"; then
        echo -e "${GREEN}Portainer:${NC} https://$SERVER_IP:9443"
    fi
    if is_completed "netdata"; then
        echo -e "${GREEN}Netdata:${NC} http://$SERVER_IP:19999"
    fi
    echo ""

    echo -e "${YELLOW}Log files:${NC}"
    echo "  • Error log: $ERROR_LOG"
    echo "  • State file: $STATE_FILE"
    echo ""

    # Don't mark as completed - allow re-running summary
    echo ""
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    should_run && run
fi
