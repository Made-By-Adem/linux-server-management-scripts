#!/bin/bash

###############################################################################
# Pre-flight Questions System
# Ask ALL questions upfront - no interruptions during installation!
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${SCRIPT_DIR}/modules/00-core/common.sh"

# Associative array to store all answers
declare -gA USER_ANSWERS

# =============================================================================
# QUESTION HELPER FUNCTIONS
# =============================================================================

ask_question() {
    local key="$1"
    local prompt="$2"
    local default="$3"

    local answer
    read -r -p "$(echo -e "${GREEN}${prompt}${NC} [${YELLOW}${default}${NC}]: ")" answer
    answer="${answer:-$default}"
    USER_ANSWERS[$key]="$answer"
}

ask_yes_no() {
    local key="$1"
    local prompt="$2"
    local default="$3"

    while true; do
        read -r -p "$(echo -e "${GREEN}${prompt}${NC} (y/n/s=skip) [${YELLOW}${default}${NC}]: ")" answer
        answer="${answer:-$default}"

        if [[ "$answer" =~ ^[YyNnSs]$ ]]; then
            # Treat 's' (skip) as 'n' (don't install)
            if [[ "$answer" =~ ^[Ss]$ ]]; then
                USER_ANSWERS[$key]="n"
                log_info "Skipped: $key"
            else
                USER_ANSWERS[$key]="${answer,,}"
            fi
            break
        else
            log_error "Please answer 'y', 'n', or 's' (skip)"
        fi
    done
}

# Ask with detailed description (like old script)
ask_component() {
    local key="$1"
    local title="$2"
    local description="$3"
    local implications="$4"
    local default="$5"

    echo ""
    echo -e "${BLUE}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  $title${NC}"
    echo -e "${BLUE}══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${CYAN}Description:${NC}"
    echo "$description"
    echo ""

    if [ -n "$implications" ]; then
        echo -e "${YELLOW}Details:${NC}"
        echo "$implications"
        echo ""
    fi

    while true; do
        read -r -p "$(echo -e "${GREEN}Install/Enable this component?${NC} (y/n/s=skip) [${YELLOW}${default}${NC}]: ")" answer
        answer="${answer:-$default}"

        if [[ "$answer" =~ ^[YyNnSs]$ ]]; then
            if [[ "$answer" =~ ^[Ss]$ ]]; then
                USER_ANSWERS[$key]="n"
                log_info "Skipped: $title"
            else
                USER_ANSWERS[$key]="${answer,,}"
            fi
            break
        else
            log_error "Please answer 'y', 'n', or 's' (skip)"
        fi
    done
}

ask_port() {
    local key="$1"
    local prompt="$2"
    local default="$3"

    while true; do
        read -r -p "$(echo -e "${GREEN}${prompt}${NC} [${YELLOW}${default}${NC}]: ")" answer
        answer="${answer:-$default}"

        if is_valid_port "$answer"; then
            USER_ANSWERS[$key]="$answer"
            break
        else
            log_error "Invalid port number (must be 1-65535)"
        fi
    done
}

ask_optional() {
    local key="$1"
    local prompt="$2"
    local default="${3:-skip}"

    read -r -p "$(echo -e "${GREEN}${prompt}${NC} [${YELLOW}${default}${NC}]: ")" answer
    answer="${answer:-$default}"
    USER_ANSWERS[$key]="$answer"
}

# =============================================================================
# INTERACTIVE MODE - ALL QUESTIONS WITH EXPLANATIONS
# =============================================================================

run_interactive_questions() {
    log_section "INTERACTIVE CONFIGURATION"

    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}This wizard asks ALL questions upfront.${NC}"
    echo -e "${YELLOW}After this, installation runs without interruption.${NC}"
    echo -e "${YELLOW}Answer 'y' (yes), 'n' (no), or 's' (skip) for each question.${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    # =========================================================================
    # A: System Basics
    # =========================================================================
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║ A. SYSTEM BASICS                                              ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}Hostname:${NC} Your server's name on the network"
    echo -e "${YELLOW}Domain:${NC} .local is good for home networks, or use your actual domain"
    echo -e "${YELLOW}Timezone:${NC} For correct timestamps in logs and cron jobs"
    echo ""

    ask_question "HOSTNAME" "Hostname" "$(hostname)"
    ask_question "DOMAIN" "Domain suffix" ".local"
    ask_question "TIMEZONE" "Timezone (e.g., Europe/Amsterdam)" "Europe/Amsterdam"
    echo ""

    # =========================================================================
    # B: Telegram Alerts (Optional)
    # =========================================================================
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║ B. TELEGRAM ALERTS (Optional)                                 ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}Description:${NC}"
    echo "  Receive security scan alerts directly on your phone via Telegram."
    echo "  Alerts include: rkhunter rootkit scans, lynis security audits."
    echo ""
    echo -e "${YELLOW}How to setup:${NC}"
    echo "  1. Create bot: Talk to @BotFather on Telegram, use /newbot"
    echo "  2. Get chat ID: Talk to @userinfobot to get your chat ID"
    echo "  3. Enter the bot token and chat ID when prompted"
    echo ""

    ask_yes_no "SETUP_TELEGRAM" "Configure Telegram alerts" "n"
    if [ "${USER_ANSWERS[SETUP_TELEGRAM]}" = "y" ]; then
        ask_optional "TELEGRAM_BOT_TOKEN" "Bot token (or 'skip')" "skip"
        ask_optional "TELEGRAM_CHAT_ID" "Chat ID (or 'skip')" "skip"
    fi
    echo ""

    # =========================================================================
    # C: SSH & Firewall
    # =========================================================================
    ask_component "SSH_HARDENING" "SSH HARDENING" \
"Secure SSH configuration with best practices:
  • Change SSH port from 22 to a non-standard port
  • Disable password authentication (key-only)
  • Limit concurrent sessions
  • Enable strict security settings" \
"Security features:
  • Non-standard port reduces 99% of automated attacks
  • Key-only auth prevents brute-force password attacks
  • MaxSessions limits concurrent connections
  • Additional hardening: TCPKeepAlive=no, X11Forwarding=no

⚠️  IMPORTANT: Make sure you have SSH keys configured before
    enabling key-only authentication, or you may lock yourself out!

Recommended settings:
  • Ubuntu VPS: Port 888, MaxSessions=2
  • Raspberry Pi: Port 888, MaxSessions=3" \
"y"

    if [ "${USER_ANSWERS[SSH_HARDENING]}" = "y" ]; then
        ask_port "SSH_NEW_PORT" "SSH port (non-standard recommended)" "888"
        ask_yes_no "SSH_KEY_ONLY" "Disable password auth (key-only)" "y"
        ask_question "SSH_MAX_SESSIONS" "Max concurrent SSH sessions (1-10)" "2"
    else
        USER_ANSWERS[SSH_NEW_PORT]="22"
        USER_ANSWERS[SSH_KEY_ONLY]="n"
        USER_ANSWERS[SSH_MAX_SESSIONS]="10"
    fi

    ask_component "ENABLE_UFW" "UFW FIREWALL" \
"Configure UFW (Uncomplicated Firewall) to protect your server." \
"What it does:
  • Blocks all incoming connections by default
  • Only allows ports you explicitly open (SSH, HTTP, HTTPS)
  • Rate-limits SSH connections to prevent brute-force attacks
  • Logs blocked connection attempts

Ports that will be opened:
  • 22 (temporary, during SSH migration)
  • Your custom SSH port (e.g., 888)
  • 80 (HTTP)
  • 443 (HTTPS)

⚠️  Highly recommended for all servers!" \
"y"

    ask_component "ENABLE_SYSTEMD_HARDENING" "SYSTEMD SERVICE HARDENING" \
"Apply security restrictions to system services via systemd." \
"What it does:
  • Restricts services from accessing sensitive system areas
  • Enables ProtectSystem, ProtectHome, PrivateTmp
  • Limits capabilities for services like postfix, rsyslog
  • Reduces impact if a service is compromised

Services hardened:
  • containerd, networkd-dispatcher, postfix
  • rsyslog, snapd, unattended-upgrades

Lynis recommendation: HRDN-7820" \
"y"
    echo ""

    # =========================================================================
    # D: Cloudflare Tunnel (Optional)
    # =========================================================================
    ask_component "INSTALL_CLOUDFLARE" "CLOUDFLARE TUNNEL" \
"Securely expose services to the internet without port forwarding." \
"What it does:
  • Creates encrypted tunnel between your server and Cloudflare
  • No need to open ports in your router/firewall
  • Built-in DDoS protection
  • Free SSL certificates

Use cases:
  • Expose web apps securely from home network
  • Access services behind NAT/CGNAT
  • Zero-trust access to internal services

Get token from: https://one.dash.cloudflare.com/
(Create tunnel → Install connector → Copy token)" \
"n"

    if [ "${USER_ANSWERS[INSTALL_CLOUDFLARE]}" = "y" ]; then
        ask_optional "CLOUDFLARE_TOKEN" "Tunnel token (or 'skip' to configure later)" "skip"
    fi
    echo ""

    # =========================================================================
    # E: Fail2ban
    # =========================================================================
    ask_component "INSTALL_FAIL2BAN" "FAIL2BAN INTRUSION PREVENTION" \
"Automatically ban IPs that show malicious behavior." \
"What it does:
  • Monitors log files for failed login attempts
  • Automatically bans attacking IPs using iptables
  • Protects SSH, web applications, and other services

Configuration:
  • Ban time: How long to ban (default: 2 hours)
  • Max retry: Failed attempts before ban (default: 3)
  • Find time: Window to count failures (default: 10 min)

Recommendation:
  • Ubuntu VPS: 2h ban, 3 retries (strict)
  • Raspberry Pi: 1h ban, 5 retries (more lenient)

Lynis recommendation: DEB-0880" \
"y"

    if [ "${USER_ANSWERS[INSTALL_FAIL2BAN]}" = "y" ]; then
        ask_question "FAIL2BAN_BANTIME" "Ban time in hours" "2"
        ask_question "FAIL2BAN_MAXRETRY" "Max retries before ban" "3"
    fi
    echo ""

    # =========================================================================
    # F: Docker
    # =========================================================================
    ask_component "INSTALL_DOCKER" "DOCKER & DOCKER COMPOSE" \
"Install Docker Engine and Docker Compose for containerized applications." \
"What it does:
  • Installs Docker CE (Community Edition) from official repository
  • Installs Docker Compose v2 plugin
  • Adds your user to docker group
  • Configures log rotation to prevent disk fill

$(if command -v docker &>/dev/null; then echo -e "${YELLOW}⚠️  Docker is already installed on this system${NC}"; fi)

Required for:
  • Portainer (Docker web UI)
  • Netdata monitoring (Docker deployment)
  • Running containerized applications" \
"y"
    echo ""

    # =========================================================================
    # G: Monitoring
    # =========================================================================
    ask_component "INSTALL_NETDATA" "NETDATA MONITORING" \
"Real-time performance monitoring with beautiful dashboards." \
"What it does:
  • Monitors CPU, RAM, disk, network in real-time
  • Tracks Docker containers, systemd services
  • Alerts on anomalies (disk full, high CPU, etc.)
  • Web dashboard on port 19999

Runs as Docker container for easy updates.
Access at: http://your-server-ip:19999" \
"y"

    ask_component "CONFIGURE_JOURNALD" "JOURNALD LOGGING CONFIGURATION" \
"Configure systemd journal for persistent, compressed logging." \
"What it does:
  • Enables persistent logging (survives reboot)
  • Compresses logs to save disk space
  • Sets retention policy (30 days default)
  • Limits max log size (500MB)

Benefits:
  • Better troubleshooting with historical logs
  • Structured logging with filtering (journalctl)
  • Automatic log rotation" \
"y"
    echo ""

    # =========================================================================
    # H: Security Tooling
    # =========================================================================
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║ H. SECURITY SCANNING TOOLS                                    ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    ask_component "INSTALL_LYNIS" "LYNIS SECURITY AUDITING" \
"Professional security auditing tool that scans your system." \
"What it does:
  • Performs 200+ security checks
  • Generates hardening score (0-100)
  • Provides specific recommendations
  • Monthly automated scans with reports

Checks include:
  • Boot & services, kernel hardening
  • Authentication, networking, storage
  • Firewalls, malware scanning, file integrity

Reports sent to Telegram (if configured).
Run manually: sudo lynis audit system" \
"y"

    ask_component "INSTALL_RKHUNTER" "RKHUNTER ROOTKIT SCANNER" \
"Scans for rootkits, backdoors, and local exploits." \
"What it does:
  • Scans for known rootkits and malware
  • Checks for suspicious files and permissions
  • Verifies system binaries haven't been modified
  • Daily automated scans

Alerts sent to Telegram (if configured).
Run manually: sudo rkhunter --check" \
"y"

    ask_component "ENABLE_AIDE" "AIDE FILE INTEGRITY MONITORING" \
"Monitors critical files for unauthorized changes." \
"What it does:
  • Creates database of file checksums
  • Daily scans detect modified/added/deleted files
  • Catches unauthorized changes to system files

⚠️  WARNINGS:
  • I/O intensive - creates significant disk activity
  • NOT recommended for Raspberry Pi / SD cards
  • Initial database creation takes time

Recommended for:
  ✓ Production VPS servers
  ✓ Compliance requirements (PCI-DSS, etc.)
  ✗ Raspberry Pi (SD card wear)
  ✗ Development servers

Lynis recommendation: FINT-4350" \
"n"

    ask_component "ENABLE_UNATTENDED_UPGRADES" "UNATTENDED SECURITY UPGRADES" \
"Automatically install security updates." \
"What it does:
  • Automatically installs security patches
  • Runs daily, minimal system impact
  • Keeps your server protected against known vulnerabilities

⚠️  Note: Only security updates, not full upgrades.
Manual intervention still needed for major updates." \
"y"
    echo ""

    # =========================================================================
    # I: Other Tools
    # =========================================================================
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║ I. DEVELOPMENT & UTILITY TOOLS                                ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    ask_yes_no "INSTALL_PYTHON" "Install Python3 & pip" "y"
    ask_yes_no "INSTALL_NODE" "Install Node.js & npm" "y"
    ask_yes_no "INSTALL_GIT" "Install Git" "y"

    ask_component "INSTALL_PORTAINER" "PORTAINER (Docker Web UI)" \
"Web-based Docker management interface." \
"What it does:
  • Visual management of containers, images, volumes
  • Deploy stacks with docker-compose files
  • View container logs and stats
  • Manage multiple Docker hosts

Access at: https://your-server-ip:9443
Requires Docker to be installed." \
"y"
    echo ""

    # =========================================================================
    # J: Additional Security
    # =========================================================================
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║ J. ADDITIONAL SECURITY HARDENING                              ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    ask_component "DISABLE_IPV6" "DISABLE IPv6" \
"Disable IPv6 protocol system-wide." \
"Why disable:
  • Reduces attack surface if IPv6 not needed
  • Simpler firewall rules (IPv4 only)
  • Many networks don't use IPv6 yet

Keep enabled if:
  • Your network uses IPv6
  • Running IPv6-only services" \
"y"

    ask_component "DISABLE_USB_STORAGE" "DISABLE USB STORAGE DEVICES" \
"Block USB mass storage devices (drives, external disks)." \
"What it does:
  • Prevents USB drives from mounting
  • Blocks data exfiltration via USB
  • Reduces malware infection risk

⚠️  IMPORTANT:
  ✓ USB keyboards and mice STILL WORK
  ✓ Other USB devices STILL WORK
  ✗ USB drives and external disks will NOT work

Recommended:
  • VPS/Cloud: YES (no physical USB access)
  • Raspberry Pi: NO (often uses USB storage)
  • Production rack server: YES

Lynis recommendation: USB-1000" \
"n"

    ask_component "RESTRICT_COMPILERS" "RESTRICT COMPILER ACCESS" \
"Limit access to compilers (gcc, g++, make) to root only." \
"Why restrict:
  • Prevents attackers from compiling exploits on server
  • Reduces post-exploitation capabilities
  • Common hardening for production servers

⚠️  Only enable on production servers!
  ✗ Don't enable on development machines
  ✗ Don't enable if users need to compile software

Lynis recommendation: HRDN-7222" \
"n"
    echo ""

    # Show summary
    show_configuration_summary
    confirm_proceed
}

# =============================================================================
# PROFILE MODE - MINIMAL QUESTIONS (ubuntu-vps / raspberry-pi)
# =============================================================================

run_profile_questions() {
    log_section "PROFILE CONFIGURATION"

    echo -e "${YELLOW}Using profile defaults. Only essential questions asked.${NC}"
    echo ""

    # A: System basics - always ask
    echo -e "${CYAN}System Basics:${NC}"
    ask_question "HOSTNAME" "Hostname" "$(hostname)"
    ask_question "DOMAIN" "Domain suffix" ".local"
    ask_question "TIMEZONE" "Timezone" "Europe/Amsterdam"
    echo ""

    # B: Telegram - skippable
    echo -e "${CYAN}Telegram Alerts (optional):${NC}"
    ask_yes_no "SETUP_TELEGRAM" "Configure Telegram alerts" "n"
    if [ "${USER_ANSWERS[SETUP_TELEGRAM]}" = "y" ]; then
        ask_optional "TELEGRAM_BOT_TOKEN" "Bot token (or 'skip')" "skip"
        ask_optional "TELEGRAM_CHAT_ID" "Chat ID (or 'skip')" "skip"
    fi
    echo ""

    # C: SSH - always ask port
    echo -e "${CYAN}SSH Configuration:${NC}"
    ask_port "SSH_NEW_PORT" "SSH port" "888"
    echo ""

    # D: Cloudflare - ask if wanted
    echo -e "${CYAN}Cloudflare Tunnel:${NC}"
    ask_yes_no "INSTALL_CLOUDFLARE" "Install Cloudflare Tunnel" "n"
    if [ "${USER_ANSWERS[INSTALL_CLOUDFLARE]}" = "y" ]; then
        ask_optional "CLOUDFLARE_TOKEN" "Tunnel token (or 'skip')" "skip"
    fi
    echo ""

    # Set profile defaults
    set_profile_defaults

    confirm_proceed
}

# =============================================================================
# PROFILE DEFAULTS
# =============================================================================

set_profile_defaults() {
    # Common defaults from profile
    USER_ANSWERS[SSH_KEY_ONLY]="y"
    USER_ANSWERS[SSH_MAX_SESSIONS]="${SSH_MAX_SESSIONS:-2}"
    USER_ANSWERS[ENABLE_UFW]="y"
    USER_ANSWERS[ENABLE_SYSTEMD_HARDENING]="y"
    USER_ANSWERS[INSTALL_FAIL2BAN]="y"
    USER_ANSWERS[FAIL2BAN_BANTIME]="${FAIL2BAN_SSH_BANTIME:-7200}"
    USER_ANSWERS[FAIL2BAN_MAXRETRY]="${FAIL2BAN_SSH_MAXRETRY:-3}"
    USER_ANSWERS[INSTALL_DOCKER]="y"
    USER_ANSWERS[INSTALL_NETDATA]="y"
    USER_ANSWERS[CONFIGURE_JOURNALD]="y"
    USER_ANSWERS[INSTALL_LYNIS]="y"
    USER_ANSWERS[INSTALL_RKHUNTER]="y"
    USER_ANSWERS[ENABLE_AIDE]="${AIDE_ENABLED:-false}"
    USER_ANSWERS[ENABLE_UNATTENDED_UPGRADES]="y"
    USER_ANSWERS[INSTALL_PYTHON]="y"
    USER_ANSWERS[INSTALL_NODE]="y"
    USER_ANSWERS[INSTALL_GIT]="y"
    USER_ANSWERS[INSTALL_PORTAINER]="y"
    USER_ANSWERS[DISABLE_IPV6]="y"
    USER_ANSWERS[DISABLE_USB_STORAGE]="${DISABLE_USB_STORAGE:-false}"
    USER_ANSWERS[RESTRICT_COMPILERS]="n"

    # Always-on features
    USER_ANSWERS[ENABLE_LEGAL_BANNERS]="y"
    USER_ANSWERS[PROC_HIDEPID]="y"
}

# =============================================================================
# SUMMARY & CONFIRMATION
# =============================================================================

show_configuration_summary() {
    echo ""
    echo -e "${BLUE}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║ CONFIGURATION SUMMARY                                         ║${NC}"
    echo -e "${BLUE}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    echo -e "${GREEN}System:${NC}"
    echo "  Hostname: ${USER_ANSWERS[HOSTNAME]:-$(hostname)}${USER_ANSWERS[DOMAIN]:-.local}"
    echo "  Timezone: ${USER_ANSWERS[TIMEZONE]:-Europe/Amsterdam}"
    echo ""

    echo -e "${GREEN}SSH & Network:${NC}"
    echo "  SSH port: ${USER_ANSWERS[SSH_NEW_PORT]:-888}"
    echo "  Max sessions: ${USER_ANSWERS[SSH_MAX_SESSIONS]:-2}"
    echo "  IPv6: $([ "${USER_ANSWERS[DISABLE_IPV6]}" = "y" ] && echo "Disabled" || echo "Enabled")"
    echo ""

    echo -e "${GREEN}Security:${NC}"
    echo "  Fail2ban: ${USER_ANSWERS[INSTALL_FAIL2BAN]:-y}"
    echo "  Rkhunter: ${USER_ANSWERS[INSTALL_RKHUNTER]:-y}"
    echo "  AIDE: ${USER_ANSWERS[ENABLE_AIDE]:-n}"
    echo "  USB storage: $([ "${USER_ANSWERS[DISABLE_USB_STORAGE]}" = "y" ] && echo "Disabled" || echo "Enabled")"
    echo ""

    echo -e "${GREEN}Services:${NC}"
    echo "  Docker: ${USER_ANSWERS[INSTALL_DOCKER]:-y}"
    echo "  Portainer: ${USER_ANSWERS[INSTALL_PORTAINER]:-y}"
    echo "  Netdata: ${USER_ANSWERS[INSTALL_NETDATA]:-y}"
    echo "  Cloudflare: ${USER_ANSWERS[INSTALL_CLOUDFLARE]:-n}"
    echo ""

    if [ "${USER_ANSWERS[SETUP_TELEGRAM]}" = "y" ]; then
        echo -e "${GREEN}Telegram:${NC} Configured"
        echo ""
    fi
}

confirm_proceed() {
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}After confirmation, installation runs WITHOUT interruption.${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    read -r -p "$(echo -e "${GREEN}Proceed with installation? [y/N]:${NC} ")" confirm

    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo ""
        log_warning "Installation cancelled by user"
        exit 0
    fi

    echo ""
    log_info "Starting installation..."
    sleep 1
}

# Export for other scripts
export USER_ANSWERS
