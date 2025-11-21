#!/bin/bash

###############################################################################
# Server Baseline Installation Script
# Automated server hardening & configuration for Ubuntu/Debian and Raspberry Pi
#
# Made By Adem
###############################################################################

set -e
set -u
set -o pipefail

# =============================================================================
# INITIALIZATION
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Script modes
MODE=""
DRY_RUN=false
PROFILE=""

# State and logging
STATE_DIR="/var/lib/server-setup"
STATE_FILE="$STATE_DIR/installation.state"
ERROR_LOG="/var/log/server_baseline_$(date +%Y%m%d_%H%M%S).log"
DRY_RUN_REPORT="/tmp/server-baseline-dryrun-$(date +%Y%m%d_%H%M%S).txt"
BACKUP_DIR="/var/backups/server-setup-backup-$(date +%Y%m%d_%H%M%S)"

# User detection
ACTUAL_USER="${SUDO_USER:-${USER:-$(whoami)}}"
if [ -n "$ACTUAL_USER" ] && [ "$ACTUAL_USER" != "root" ]; then
    if command -v getent &>/dev/null; then
        USER_HOME=$(getent passwd "$ACTUAL_USER" 2>/dev/null | cut -d: -f6)
    else
        USER_HOME=$(grep "^$ACTUAL_USER:" /etc/passwd 2>/dev/null | cut -d: -f6)
    fi
    [ -z "${USER_HOME:-}" ] && USER_HOME=$(eval echo ~"$ACTUAL_USER")
else
    USER_HOME=$(eval echo ~"$ACTUAL_USER")
fi

# Server IP detection
SERVER_IP=$(ip -4 addr show scope global | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1)
[ -z "$SERVER_IP" ] && SERVER_IP="<server-ip>"

# User answers storage
declare -A USER_ANSWERS

# =============================================================================
# LOAD CORE MODULES
# =============================================================================

source "${SCRIPT_DIR}/modules/00-core/common.sh"

if [[ -f "${SCRIPT_DIR}/modules/00-core/config-loader.sh" ]]; then
    source "${SCRIPT_DIR}/modules/00-core/config-loader.sh"
fi

# =============================================================================
# USAGE
# =============================================================================

show_usage() {
    cat <<EOF
$(basename "$0") - Server Baseline Installation

USAGE:
    sudo bash $0 [OPTION]

OPTIONS:
    --dry-run         Show what would happen without making changes
    --interactive     Ask all questions upfront with explanations
    --ubuntu-vps      Production Ubuntu settings (minimal questions)
    --raspberry-pi    Lightweight ARM settings (minimal questions)
    --help            Show this help message

EXAMPLES:
    # Interactive mode - recommended for first-time setup
    sudo bash $0 --interactive

    # Ubuntu VPS with production defaults
    sudo bash $0 --ubuntu-vps

    # Raspberry Pi optimized settings
    sudo bash $0 --raspberry-pi

    # Preview what would happen
    sudo bash $0 --dry-run --ubuntu-vps
EOF
    exit 0
}

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --help|-h)
                show_usage
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --interactive)
                MODE="interactive"
                shift
                ;;
            --ubuntu-vps)
                MODE="ubuntu-vps"
                PROFILE="ubuntu"
                shift
                ;;
            --raspberry-pi)
                MODE="raspberry-pi"
                PROFILE="pi"
                shift
                ;;
            *)
                log_error "Unknown option: $1"
                echo "Use --help for usage information"
                exit 1
                ;;
        esac
    done

    # Require a mode
    if [ -z "$MODE" ]; then
        log_error "No mode specified"
        echo ""
        echo "Please specify one of:"
        echo "  --interactive    Interactive setup with all questions"
        echo "  --ubuntu-vps     Production Ubuntu settings"
        echo "  --raspberry-pi   Lightweight Raspberry Pi settings"
        echo ""
        echo "Use --help for more information"
        exit 1
    fi
}

# =============================================================================
# RESUME CAPABILITY
# =============================================================================

check_resume() {
    # Skip resume check in dry-run mode
    if [ "$DRY_RUN" = true ]; then
        return 0
    fi

    # Check if state file exists (previous run)
    if [ -f "$STATE_FILE" ]; then
        echo ""
        log_warning "Previous installation detected!"
        echo ""
        echo "Completed modules:"
        cat "$STATE_FILE" 2>/dev/null | sed 's/^/  ✓ /'
        echo ""
        echo "Options:"
        echo "  1. Resume (skip completed modules)"
        echo "  2. Start fresh (delete state and restart)"
        echo "  3. Cancel"
        echo ""

        local choice
        read -p "Choose option [1/2/3] (default: 1): " choice
        choice=${choice:-1}

        case "$choice" in
            1)
                log_info "Resuming installation..."
                ;;
            2)
                log_info "Starting fresh installation..."
                rm -f "$STATE_FILE"
                ;;
            3|*)
                log_warning "Installation cancelled"
                exit 0
                ;;
        esac
        echo ""
    fi
}

# =============================================================================
# PRE-FLIGHT CHECKS
# =============================================================================

check_prerequisites() {
    log_section "PRE-FLIGHT CHECKS"

    # Root check
    if [ "$EUID" -ne 0 ]; then
        handle_error "This script must be run as root (use sudo)"
    fi
    log_info "Running as root"

    # Internet check
    if ! ping -c 1 -W 2 8.8.8.8 &>/dev/null; then
        handle_error "No internet connection detected"
    fi
    log_info "Internet connection available"

    # Disk space check (10GB minimum)
    local free_space=$(df / | awk 'NR==2 {print $4}')
    if [ "$free_space" -lt 10485760 ]; then
        log_warning "Less than 10GB free disk space"
    else
        log_info "Sufficient disk space"
    fi

    # Create state directory
    mkdir -p "$STATE_DIR"
    log_info "State directory ready"

    # Create log file
    touch "$ERROR_LOG"
    chmod 600 "$ERROR_LOG"
    log_info "Logging to: $ERROR_LOG"

    echo ""
}

# =============================================================================
# CONFIGURATION LOADING
# =============================================================================

load_configuration() {
    log_section "CONFIGURATION"

    local config_file=""

    case "$MODE" in
        ubuntu-vps)
            config_file="${SCRIPT_DIR}/config/ubuntu.conf"
            ;;
        raspberry-pi)
            config_file="${SCRIPT_DIR}/config/pi.conf"
            ;;
        interactive)
            # Load default config, will be overridden by questions
            config_file="${SCRIPT_DIR}/config/default.conf"
            ;;
    esac

    if [[ -f "$config_file" ]]; then
        source "$config_file"
        log_info "Loaded profile: $(basename "$config_file" .conf)"
    else
        log_warning "Config not found: $config_file, using defaults"
    fi

    echo ""
}

# =============================================================================
# QUESTIONS
# =============================================================================

run_questions() {
    source "${SCRIPT_DIR}/modules/01-preflight/questions.sh"

    case "$MODE" in
        interactive)
            run_interactive_questions
            ;;
        ubuntu-vps|raspberry-pi)
            run_profile_questions
            ;;
    esac
}

# =============================================================================
# MODULE EXECUTION
# =============================================================================

execute_modules() {
    log_section "INSTALLATION"

    if [ "$DRY_RUN" = true ]; then
        log_info "DRY-RUN MODE: No changes will be made"
        log_info "Report will be saved to: $DRY_RUN_REPORT"
        echo ""
    fi

    local modules_dir="${SCRIPT_DIR}/modules"

    # Module execution order
    local module_order=(
        # System
        "10-system/packages.sh"
        "10-system/timezone.sh"
        "10-system/hostname.sh"
        "10-system/swap.sh"

        # Security basics
        "20-security/passwords.sh"
        "20-security/kernel.sh"
        "20-security/usb.sh"
        "20-security/permissions.sh"
        "20-security/banners.sh"

        # Network
        "30-network/ipv6.sh"
        "30-network/firewall.sh"
        "30-network/ssh.sh"
        "30-network/fail2ban.sh"

        # Services
        "40-services/docker.sh"
        "40-services/portainer.sh"
        "40-services/cloudflare.sh"
        "40-services/netdata.sh"

        # Monitoring
        "50-monitoring/audit.sh"
        "50-monitoring/rkhunter.sh"
        "50-monitoring/lynis.sh"
        "50-monitoring/aide.sh"
        "50-monitoring/sysstat.sh"

        # Hardening
        "60-hardening/journald.sh"
        "60-hardening/systemd.sh"
        "60-hardening/compiler.sh"

        # Finalize
        "99-finalize/cleanup.sh"
        "99-finalize/summary.sh"
    )

    # Execute modules
    for module in "${module_order[@]}"; do
        local module_path="${modules_dir}/${module}"

        if [ -f "$module_path" ]; then
            if source "$module_path" && should_run; then
                run || log_error "Module failed: $module"
            fi
        else
            log_warning "Module not found: $module"
        fi
    done
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    clear

    # Banner
    cat << "EOF"
 ___  ___ _ ____   _____ _ __   | |__   __ _ ___  ___| (_)_ __   ___
/ __|/ _ \ '__\ \ / / _ \ '__| _| '_ \ / _` / __|/ _ \ | | '_ \ / _ \
\__ \  __/ |   \ V /  __/ |   |_| |_) | (_| \__ \  __/ | | | | |  __/
|___/\___|_|    \_/ \___|_|     |_.__/ \__,_|___/\___|_|_|_| |_|\___|

         Automated Server Hardening for Ubuntu/Debian & Raspberry Pi

         Made by Adem - https://github.com/madebyadem
EOF
    echo ""

    # Parse arguments
    parse_arguments "$@"

    # Pre-flight checks
    check_prerequisites

    # Check for resume capability
    check_resume

    # Load configuration
    load_configuration

    # Run questions
    run_questions

    # Execute modules
    execute_modules

    echo ""
    log_info "Installation complete!"
}

# Execute
main "$@"
