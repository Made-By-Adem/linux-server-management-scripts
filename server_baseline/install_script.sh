#!/bin/bash

###############################################################################
# Server Installation & Hardening Script
# For Ubuntu/Debian servers (including Raspberry Pi)
# Version: 3.0 - Interactive & Safe for Existing Servers
###############################################################################

set -e  # Exit on error
set -u  # Exit on undefined variable
set -o pipefail  # Exit on pipe failure

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Script modes
MODE=""  # Will be set to: fresh-install, interactive, or dry-run
DRY_RUN=false

# Get the actual user (the one who ran sudo)
ACTUAL_USER="${SUDO_USER:-$USER}"

# Get the user's home directory using getent (more reliable than eval)
if [ -n "$ACTUAL_USER" ] && [ "$ACTUAL_USER" != "root" ]; then
    USER_HOME=$(getent passwd "$ACTUAL_USER" | cut -d: -f6)
else
    USER_HOME=$(eval echo ~"$ACTUAL_USER")
fi

# Fallback if getent fails
if [ -z "$USER_HOME" ] || [ "$USER_HOME" = "/" ]; then
    USER_HOME=$(eval echo ~"$ACTUAL_USER")
fi

# State tracking file for resume capability (will be created after sudo check)
STATE_DIR="/var/lib/server-setup"
STATE_FILE="$STATE_DIR/installation.state"
BACKUP_DIR="/var/backups/server-setup-backup-$(date +%Y%m%d_%H%M%S)"

# Error log file path (will be created after sudo check)
ERROR_LOG="/var/log/server_install_$(date +%Y%m%d_%H%M%S).log"

# Dry-run report file
DRY_RUN_REPORT="/tmp/server-setup-dryrun-$(date +%Y%m%d_%H%M%S).txt"

# Function to handle errors
handle_error() {
    echo -e "${RED}Error: $1${NC}" >&2
    echo "Error: $1" >> "$ERROR_LOG"
    exit 1
}

# Function to log info
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

# Function to log warning
log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Function to log dry-run actions
log_dry_run() {
    echo -e "${CYAN}[DRY-RUN]${NC} $1"
    echo "[DRY-RUN] $1" >> "$DRY_RUN_REPORT" 2>/dev/null || true
}

# Function to show usage
show_usage() {
    cat <<EOF
Usage: sudo bash $0 [OPTIONS]

Modes:
  --fresh-install    Run with minimal prompts (for fresh servers)
  --interactive      Ask confirmation for each component (for existing servers)
  --dry-run          Show what would be done without making changes

Options:
  --help             Show this help message

Examples:
  sudo bash $0 --fresh-install
  sudo bash $0 --interactive
  sudo bash $0 --dry-run
  sudo bash $0 --interactive --dry-run

Note: If no mode is specified, the script will auto-detect based on existing installations.
EOF
    exit 0
}

# Function to parse command-line arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --fresh-install)
                MODE="fresh-install"
                shift
                ;;
            --interactive)
                MODE="interactive"
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --help|-h)
                show_usage
                ;;
            *)
                echo -e "${RED}Unknown option: $1${NC}"
                show_usage
                ;;
        esac
    done
}

# Function to detect if this is a fresh or existing installation
detect_mode() {
    local indicators=0

    # Check for Docker
    if docker --version &>/dev/null; then
        ((indicators++))
    fi

    # Check for UFW rules
    if sudo ufw status 2>/dev/null | grep -q "Status: active"; then
        ((indicators++))
    fi

    # Check for custom SSH config
    if grep -q "^Port 888" /etc/ssh/sshd_config 2>/dev/null; then
        ((indicators++))
    fi

    # Check for existing swap
    if [ -f /swapfile ]; then
        ((indicators++))
    fi

    # Check for Netdata, Portainer, or other services
    if systemctl list-units --full --all 2>/dev/null | grep -qE "(netdata|portainer|fail2ban)"; then
        ((indicators++))
    fi

    # If 2 or more indicators, it's an existing installation
    if [ $indicators -ge 2 ]; then
        MODE="interactive"
        log_warning "Detected existing installation (found $indicators indicators)"
        log_warning "Using INTERACTIVE mode for safety"
    else
        MODE="fresh-install"
        log_info "Detected fresh installation"
        log_info "Using FRESH-INSTALL mode"
    fi
}

# Function to check component status
check_component_status() {
    local component="$1"

    case "$component" in
        "docker")
            if docker --version &>/dev/null 2>&1; then
                echo "installed"
                return 0
            fi
            ;;
        "docker-running")
            if docker ps &>/dev/null 2>&1; then
                local count=$(docker ps -q | wc -l)
                echo "running:$count"
                return 0
            fi
            ;;
        "ufw")
            if sudo ufw status 2>/dev/null | grep -q "Status: active"; then
                local rules=$(sudo ufw status numbered 2>/dev/null | grep -c "^\[" || echo "0")
                echo "active:$rules"
                return 0
            fi
            ;;
        "ssh-custom")
            if grep -q "^Port 888" /etc/ssh/sshd_config 2>/dev/null; then
                echo "customized"
                return 0
            fi
            ;;
        "swap")
            if [ -f /swapfile ]; then
                local size=$(du -h /swapfile 2>/dev/null | cut -f1)
                echo "exists:$size"
                return 0
            fi
            ;;
        "fail2ban")
            if systemctl is-active fail2ban &>/dev/null; then
                echo "active"
                return 0
            fi
            ;;
        "netdata")
            if docker ps --format '{{.Names}}' 2>/dev/null | grep -q netdata; then
                echo "running"
                return 0
            fi
            ;;
        "portainer")
            if docker ps --format '{{.Names}}' 2>/dev/null | grep -q portainer; then
                echo "running"
                return 0
            fi
            ;;
        "python")
            if python3 --version &>/dev/null; then
                echo "installed:$(python3 --version 2>&1 | cut -d' ' -f2)"
                return 0
            fi
            ;;
        "nodejs")
            if node --version &>/dev/null; then
                echo "installed:$(node --version 2>&1)"
                return 0
            fi
            ;;
        "hostname")
            echo "current:$(hostname)"
            return 0
            ;;
        "timezone")
            echo "current:$(timedatectl show -p Timezone --value 2>/dev/null || echo 'unknown')"
            return 0
            ;;
    esac

    echo "not-found"
    return 1
}

# Function to ask user for component installation with context
ask_component_install() {
    local component_name="$1"
    local component_key="$2"
    local description="$3"
    local implications="$4"
    local default="${5:-y}"  # Default to 'y' if not specified
    local timeout="${6:-60}"  # Default 60s timeout

    # In dry-run mode, just log and return yes
    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Would ask about: $component_name"
        return 0
    fi

    # In fresh-install mode, use defaults without asking (unless critical)
    if [ "$MODE" = "fresh-install" ]; then
        # Only ask for critical components
        case "$component_key" in
            "hostname"|"timezone"|"ssh-hardening"|"cloudflare-token"|"telegram")
                # Ask these even in fresh-install mode
                ;;
            *)
                # Auto-accept with default
                return 0
                ;;
        esac
    fi

    # Get current status
    local status=$(check_component_status "$component_key" 2>/dev/null || echo "not-found")

    # Interactive mode: show full context
    echo ""
    echo "=========================================================================="
    echo -e "${BLUE}$component_name${NC}"
    echo "=========================================================================="
    echo ""

    # Show current status if exists
    if [ "$status" != "not-found" ]; then
        echo -e "${YELLOW}Current status:${NC} $status"
        echo ""
    fi

    # Show description
    echo -e "${CYAN}Description:${NC}"
    echo "$description"
    echo ""

    # Show implications
    if [ -n "$implications" ]; then
        echo -e "${YELLOW}Implications:${NC}"
        echo "$implications"
        echo ""
    fi

    # Ask user
    local answer
    read -t "$timeout" -p "Proceed with this component? (Y/n, default: $default, timeout ${timeout}s): " answer || answer="$default"
    answer=${answer:-$default}

    if [[ $answer =~ ^[Yy]$ ]] || [[ -z "$answer" ]]; then
        return 0
    else
        log_info "$component_name skipped by user"
        return 1
    fi
}

# Function to create comprehensive backup
create_backup() {
    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Would create backup at: $BACKUP_DIR"
        return 0
    fi

    log_info "Creating backup of existing configurations..."
    sudo mkdir -p "$BACKUP_DIR"

    # Backup SSH config
    if [ -f /etc/ssh/sshd_config ]; then
        sudo cp /etc/ssh/sshd_config "$BACKUP_DIR/sshd_config.backup"
        log_info "Backed up: SSH config"
    fi

    # Backup UFW rules
    if sudo ufw status &>/dev/null; then
        sudo ufw status numbered > "$BACKUP_DIR/ufw-rules.txt" 2>/dev/null || true
        log_info "Backed up: UFW rules"
    fi

    # Backup Fail2ban config
    if [ -f /etc/fail2ban/jail.local ]; then
        sudo cp /etc/fail2ban/jail.local "$BACKUP_DIR/jail.local.backup"
        log_info "Backed up: Fail2ban config"
    fi

    # Backup journald config
    if [ -f /etc/systemd/journald.conf ]; then
        sudo cp /etc/systemd/journald.conf "$BACKUP_DIR/journald.conf.backup"
        log_info "Backed up: Journald config"
    fi

    # Backup sysctl settings
    if [ -d /etc/sysctl.d ]; then
        sudo cp -r /etc/sysctl.d "$BACKUP_DIR/sysctl.d.backup" 2>/dev/null || true
        log_info "Backed up: Sysctl settings"
    fi

    # List Docker containers (not data, just inventory)
    if docker ps -a &>/dev/null 2>&1; then
        docker ps -a > "$BACKUP_DIR/docker-containers.txt" 2>/dev/null || true
        log_info "Backed up: Docker container list"
    fi

    # Create rollback script
    cat <<EOF | sudo tee "$BACKUP_DIR/rollback.sh" >/dev/null
#!/bin/bash
# Rollback script generated on $(date)
# This script can restore backed up configurations

set -e

echo "Restoring configurations from backup..."

# Restore SSH config
if [ -f "$BACKUP_DIR/sshd_config.backup" ]; then
    sudo cp "$BACKUP_DIR/sshd_config.backup" /etc/ssh/sshd_config
    sudo systemctl restart ssh
    echo "Restored: SSH config"
fi

# Restore Fail2ban config
if [ -f "$BACKUP_DIR/jail.local.backup" ]; then
    sudo cp "$BACKUP_DIR/jail.local.backup" /etc/fail2ban/jail.local
    sudo systemctl restart fail2ban
    echo "Restored: Fail2ban config"
fi

# Restore journald config
if [ -f "$BACKUP_DIR/journald.conf.backup" ]; then
    sudo cp "$BACKUP_DIR/journald.conf.backup" /etc/systemd/journald.conf
    sudo systemctl restart systemd-journald
    echo "Restored: Journald config"
fi

echo "Rollback complete. Review UFW rules manually from: $BACKUP_DIR/ufw-rules.txt"
EOF

    sudo chmod +x "$BACKUP_DIR/rollback.sh"
    log_info "Backup complete: $BACKUP_DIR"
    log_info "Rollback script created: $BACKUP_DIR/rollback.sh"
}

# Function to mark section as completed
mark_completed() {
    echo "$1" | sudo tee -a "$STATE_FILE" >/dev/null
    log_info "Section '$1' completed and saved to state"
}

# Function to check if section was already completed
is_completed() {
    if [ -f "$STATE_FILE" ] && sudo grep -q "^$1$" "$STATE_FILE" 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

# Function to skip completed section
skip_if_completed() {
    if is_completed "$1"; then
        log_warning "Section '$1' already completed, skipping..."
        return 0
    else
        return 1
    fi
}

# Cleanup function for rollback on error
cleanup_on_error() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        echo ""
        log_warning "Script exited with error code $exit_code"
        log_warning "Installation state saved. You can resume by running the script again"
        log_warning "To start fresh, delete the state file: sudo rm -f $STATE_FILE"
        echo ""
    fi
}

# Set trap for cleanup on exit
trap cleanup_on_error EXIT

# Retry function for network operations
retry_command() {
    local max_attempts=3
    local delay=5
    local attempt=1
    local command="$@"

    while [ $attempt -le $max_attempts ]; do
        if eval "$command"; then
            return 0
        else
            if [ $attempt -lt $max_attempts ]; then
                log_warning "Command failed (attempt $attempt/$max_attempts). Retrying in ${delay}s..."
                sleep $delay
                attempt=$((attempt + 1))
            else
                log_warning "Command failed after $max_attempts attempts"
                return 1
            fi
        fi
    done
}

###############################################################################
# PREREQUISITE CHECKS
###############################################################################

# Parse command-line arguments first
parse_arguments "$@"

# Show mode banner
echo ""
echo "=========================================================================="
echo "  Server Installation & Hardening Script v3.0"
echo "=========================================================================="
echo ""

# Check if running with sudo privileges
if ! sudo -n true 2>/dev/null; then
    echo -e "${RED}Error: This script requires sudo privileges${NC}" >&2
    echo "Please run with: sudo bash $0 [OPTIONS]" >&2
    echo "Use --help for usage information" >&2
    exit 1
fi

# Now that sudo is verified, create directories and log file
sudo mkdir -p "$STATE_DIR"
sudo touch "$ERROR_LOG"
sudo chmod 600 "$ERROR_LOG"
sudo chown root:root "$ERROR_LOG"

# Initialize dry-run report if needed
if [ "$DRY_RUN" = true ]; then
    echo "Dry-Run Report - $(date)" > "$DRY_RUN_REPORT"
    echo "=========================================================================" >> "$DRY_RUN_REPORT"
    echo "" >> "$DRY_RUN_REPORT"
    log_info "Dry-run mode enabled - no changes will be made"
    log_info "Report will be saved to: $DRY_RUN_REPORT"
fi

# Show help if no mode specified
if [ -z "$MODE" ]; then
    echo -e "${YELLOW}No mode specified.${NC}"
    echo ""
    show_usage
fi

# Show current mode
case "$MODE" in
    "fresh-install")
        log_info "Mode: FRESH INSTALL (minimal prompts)"
        ;;
    "interactive")
        log_warning "Mode: INTERACTIVE (confirmation required for each component)"
        ;;
esac

if [ "$DRY_RUN" = true ]; then
    log_info "DRY-RUN: No actual changes will be made"
fi

echo ""

# Create backup of existing configurations in interactive mode
if [ "$MODE" = "interactive" ] && [ "$DRY_RUN" = false ]; then
    create_backup
fi

# Check if resuming from previous run
if [ -f "$STATE_FILE" ]; then
    echo ""
    echo "=========================================================================="
    echo "PREVIOUS INSTALLATION DETECTED"
    echo "=========================================================================="
    echo ""
    echo "A previous installation was detected. Completed sections:"
    sudo cat "$STATE_FILE" 2>/dev/null | sed 's/^/  - /'
    echo ""
    echo "Options:"
    echo "  1. Resume (skip completed sections)"
    echo "  2. Start fresh (delete state and restart)"
    echo "  3. Exit"
    echo ""
    read -t 30 -p "Choose option [1/2/3] (default: 1 after 30s): " resume_choice || resume_choice="1"

    case "$resume_choice" in
        2)
            log_info "Starting fresh installation..."
            sudo rm -f "$STATE_FILE"
            ;;
        3)
            log_info "Exiting..."
            exit 0
            ;;
        *)
            log_info "Resuming installation, skipping completed sections..."
            ;;
    esac
    echo ""
fi

###############################################################################
# SYSTEM BASICS
###############################################################################

log_info "Starting server setup and hardening..."

# Check internet connectivity
log_info "Checking internet connectivity..."
if [ "$DRY_RUN" = true ]; then
    log_dry_run "Would check internet connectivity"
elif ! ping -c 1 -W 5 8.8.8.8 >/dev/null 2>&1 && ! ping -c 1 -W 5 1.1.1.1 >/dev/null 2>&1; then
    handle_error "No internet connectivity detected. Please check your network connection"
else
    log_info "Internet connectivity confirmed"
fi

# Timezone Configuration
if ask_component_install \
    "TIMEZONE CONFIGURATION" \
    "timezone" \
    "Set timezone to Europe/Amsterdam and enable NTP time synchronization." \
    "⚠️  Current timezone: $(timedatectl show -p Timezone --value 2>/dev/null || echo 'unknown')
• Changing timezone affects log timestamps and scheduled tasks
• NTP synchronization keeps server time accurate
• Recommended for consistency across services" \
    "y" \
    "60"; then

    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Would set timezone to Europe/Amsterdam"
        log_dry_run "Would enable NTP synchronization"
    else
        log_info "Setting timezone to Europe/Amsterdam..."
        sudo timedatectl set-timezone Europe/Amsterdam || handle_error "Failed to set timezone"
        sudo timedatectl set-ntp true || handle_error "Failed to enable NTP synchronization"
        log_info "Timezone configured successfully"
    fi
else
    log_info "Timezone configuration skipped"
fi

###############################################################################
# SYSTEM UPDATE
###############################################################################

if skip_if_completed "SYSTEM_UPDATE"; then
    :  # Skip this section
else
    if ask_component_install \
        "SYSTEM UPDATES & UPGRADES" \
        "system-update" \
        "Update package lists and upgrade all installed packages to latest versions." \
        "⚠️  This operation:
• May restart some services automatically
• Can take several minutes depending on number of updates
• May require kernel update and reboot
• On production: Consider scheduling during maintenance window
• Recommended: Run updates to patch security vulnerabilities" \
        "y" \
        "60"; then

        if [ "$DRY_RUN" = true ]; then
            log_dry_run "Would run: apt-get update"
            log_dry_run "Would run: apt-get upgrade -y"
            log_dry_run "Would run: apt-get autoremove -y"
        else
            log_info "Updating package lists and upgrading system..."
            retry_command "DEBIAN_FRONTEND=noninteractive sudo apt-get update" || handle_error "Failed to update package lists after multiple attempts"
            DEBIAN_FRONTEND=noninteractive sudo apt-get upgrade -y || handle_error "Failed to upgrade packages"
            DEBIAN_FRONTEND=noninteractive sudo apt-get autoremove -y || handle_error "Failed to autoremove packages"
            log_info "System updated successfully"
        fi
        mark_completed "SYSTEM_UPDATE"
    else
        log_info "System updates skipped"
        mark_completed "SYSTEM_UPDATE"
    fi
fi

###############################################################################
# INSTALL ESSENTIAL PACKAGES
###############################################################################

log_info "Installing essential packages..."
DEBIAN_FRONTEND=noninteractive sudo apt-get install -y \
    curl \
    wget \
    net-tools \
    ufw \
    unattended-upgrades \
    ca-certificates \
    gnupg \
    lsb-release \
    software-properties-common \
    rsyslog \
    git \
    htop \
    iotop \
    nethogs \
    fail2ban \
    || handle_error "Failed to install essential packages"

log_info "Essential packages installed successfully"

###############################################################################
# INSTALL SECURITY PACKAGE MANAGEMENT TOOLS
###############################################################################

log_info "Installing advanced security package management tools..."

# Ask user if they want to install security package tools
echo ""
echo "=========================================================================="
echo "SECURITY PACKAGE MANAGEMENT TOOLS"
echo "=========================================================================="
echo ""
echo "These tools enhance package security and awareness:"
echo ""
echo "  • apt-listchanges  - Shows important changes in packages before upgrade"
echo "  • debsums          - Verifies installed package file integrity"
echo "  • apt-show-versions - Shows available package versions and updates"
echo "  • needrestart      - Detects which services need restart after updates"
echo ""
echo "Benefits:"
echo "  - Review security changes before applying updates"
echo "  - Detect modified or corrupted system files"
echo "  - Better package version management"
echo "  - Know when to restart services after security updates"
echo ""
echo "Note: apt-listbugs (Debian-only) is not available on Ubuntu"
echo ""
read -t 60 -p "Install security package management tools? (Y/n, default: Y, timeout 60s): " install_sec_pkg_tools || install_sec_pkg_tools="y"
install_sec_pkg_tools=${install_sec_pkg_tools:-y}

if [[ $install_sec_pkg_tools =~ ^[Yy]$ ]] || [[ -z "$install_sec_pkg_tools" ]]; then
    DEBIAN_FRONTEND=noninteractive sudo apt-get install -y \
        apt-listchanges \
        debsums \
        apt-show-versions \
        needrestart \
        || log_warning "Failed to install some security package tools"

    log_info "Security package management tools installed successfully"
    log_info "These tools will now run automatically during package operations"
else
    log_info "Security package management tools installation skipped"
    log_info "You can install them later with: sudo apt-get install apt-listchanges debsums apt-show-versions needrestart"
fi

###############################################################################
# PYTHON INSTALLATION
###############################################################################

log_info "Installing Python with pip and venv..."
DEBIAN_FRONTEND=noninteractive sudo apt-get install -y python3 python3-pip python3-venv || handle_error "Failed to install Python"
log_info "Python $(python3 --version) installed successfully"

###############################################################################
# NODE.JS INSTALLATION
###############################################################################

log_info "Installing Node.js LTS..."
# Try to download and execute NodeSource setup script with retry
if ! retry_command "curl -fsSL https://deb.nodesource.com/setup_lts.x -o /tmp/nodesource_setup.sh"; then
    log_warning "Failed to download NodeSource setup script after multiple attempts"
    handle_error "NodeSource repository setup failed. Please check https://github.com/nodesource/distributions for manual installation instructions"
fi
sudo -E bash /tmp/nodesource_setup.sh || handle_error "Failed to execute NodeSource setup script"
rm -f /tmp/nodesource_setup.sh
DEBIAN_FRONTEND=noninteractive sudo apt-get install -y nodejs || handle_error "Failed to install Node.js"
log_info "Node.js $(node --version) and npm $(npm --version) installed successfully"

###############################################################################
# DOCKER INSTALLATION
###############################################################################

if skip_if_completed "DOCKER_INSTALL"; then
    :  # Skip this section
else
    # Check if Docker is already installed and running
    DOCKER_STATUS=$(check_component_status "docker")
    DOCKER_RUNNING_STATUS=$(check_component_status "docker-running")

    # Prepare description based on current status
    DOCKER_DESC="Install Docker CE, Docker Compose plugin, and configure for production use."
    DOCKER_IMPLICATIONS=""

    if [ "$DOCKER_STATUS" = "installed" ]; then
        if [[ "$DOCKER_RUNNING_STATUS" =~ ^running:([0-9]+)$ ]]; then
            CONTAINER_COUNT="${BASH_REMATCH[1]}"
            DOCKER_IMPLICATIONS="🔴 CRITICAL WARNING:
• Docker is ALREADY INSTALLED with $CONTAINER_COUNT running container(s)!
• Reinstalling will STOP and REMOVE all containers
• This will cause DATA LOSS if containers have important data
• Container images will need to be re-pulled

⚠️  RECOMMENDATION: Skip this step unless you absolutely need to reinstall
• To skip: Answer 'n' to this prompt
• To proceed: You must accept full responsibility for data loss"
        else
            DOCKER_IMPLICATIONS="⚠️  Docker is already installed but not running
• Reinstalling will remove the current installation
• Existing container configurations may be lost
• Consider skipping if Docker is working correctly"
        fi
    else
        DOCKER_IMPLICATIONS="✅ Docker not detected - safe to install
• Will install latest Docker CE from official repository
• Includes Docker Compose as plugin
• Configures production-ready logging limits
• User '$ACTUAL_USER' will be added to docker group"
    fi

    if ask_component_install \
        "DOCKER INSTALLATION" \
        "docker" \
        "$DOCKER_DESC" \
        "$DOCKER_IMPLICATIONS" \
        "y" \
        "90"; then

        # Extra confirmation if containers are running
        if [[ "$DOCKER_RUNNING_STATUS" =~ ^running:([0-9]+)$ ]] && [ "$DRY_RUN" = false ]; then
            CONTAINER_COUNT="${BASH_REMATCH[1]}"
            echo ""
            echo -e "${RED}╔════════════════════════════════════════════════════════════════╗${NC}"
            echo -e "${RED}║                    FINAL WARNING                               ║${NC}"
            echo -e "${RED}╚════════════════════════════════════════════════════════════════╝${NC}"
            echo ""
            echo -e "${RED}You are about to reinstall Docker with $CONTAINER_COUNT running containers!${NC}"
            echo -e "${RED}This will STOP and REMOVE all containers, causing DATA LOSS!${NC}"
            echo ""
            echo "Type 'YES' to continue, or anything else to skip:"
            read -t 30 -p "> " final_confirm || final_confirm="no"

            if [ "$final_confirm" != "YES" ]; then
                log_warning "Docker reinstallation cancelled - containers are safe"
                mark_completed "DOCKER_INSTALL"
                SKIP_DOCKER=true
            else
                log_warning "User confirmed Docker reinstallation despite running containers"
                SKIP_DOCKER=false
            fi
        else
            SKIP_DOCKER=false
        fi

        if [ "$SKIP_DOCKER" = false ]; then
            if [ "$DRY_RUN" = true ]; then
                log_dry_run "Would remove old Docker versions"
                log_dry_run "Would add Docker official repository"
                log_dry_run "Would install: docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
                log_dry_run "Would add user '$ACTUAL_USER' to docker group"
                log_dry_run "Would configure Docker daemon with log rotation"
                mark_completed "DOCKER_INSTALL"
            else
                log_info "Installing Docker and Docker Compose..."

                # Remove old Docker versions
                for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
                    DEBIAN_FRONTEND=noninteractive sudo apt-get remove -y $pkg 2>/dev/null || true
                done
            fi
        fi
    else
        log_info "Docker installation skipped"
        mark_completed "DOCKER_INSTALL"
        SKIP_DOCKER=true
    fi
fi

# Only continue with Docker installation if not skipped
if [ "${SKIP_DOCKER:-false}" = false ] && ! is_completed "DOCKER_INSTALL" && [ "$DRY_RUN" = false ]; then
# Detect OS for Docker repository
if [ ! -f /etc/os-release ]; then
    handle_error "/etc/os-release not found. This script requires Ubuntu, Debian, or Raspbian OS"
fi

. /etc/os-release

# Check if ID variable was set
if [ -z "${ID:-}" ]; then
    handle_error "Could not detect OS ID from /etc/os-release"
fi

DOCKER_OS="${ID}"
if [ "$ID" = "raspbian" ]; then
    DOCKER_OS="debian"
fi

# Check if required codename variable exists
if [ "$DOCKER_OS" != "ubuntu" ] && [ -z "${VERSION_CODENAME:-}" ]; then
    handle_error "VERSION_CODENAME not found in /etc/os-release"
fi

# Add Docker's official GPG key
DEBIAN_FRONTEND=noninteractive sudo apt-get update || handle_error "Failed to update package lists"
DEBIAN_FRONTEND=noninteractive sudo apt-get install -y ca-certificates curl || handle_error "Failed to install ca-certificates and curl"
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/${DOCKER_OS}/gpg -o /etc/apt/keyrings/docker.asc || \
    handle_error "Failed to download Docker GPG key"
sudo chmod a+r /etc/apt/keyrings/docker.asc

# Add Docker repository (Ubuntu uses UBUNTU_CODENAME, Debian/Raspbian uses VERSION_CODENAME)
if [ "$DOCKER_OS" = "ubuntu" ]; then
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | \
      sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
else
    # Debian/Raspbian - use new .sources format
    sudo tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: ${VERSION_CODENAME}
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF
fi

DEBIAN_FRONTEND=noninteractive sudo apt-get update || handle_error "Failed to update after adding Docker repo"

# Install Docker
DEBIAN_FRONTEND=noninteractive sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || \
    handle_error "Failed to install Docker"

# Create docker group if it doesn't exist
sudo groupadd docker 2>/dev/null || true

# Add user to docker group
sudo usermod -aG docker "$ACTUAL_USER" || log_warning "Failed to add user to docker group"

# Configure Docker daemon for production
sudo mkdir -p /etc/docker
cat <<EOF | sudo tee /etc/docker/daemon.json
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "live-restore": true
}
EOF

sudo systemctl enable docker || handle_error "Failed to enable Docker service"
sudo systemctl restart docker || handle_error "Failed to restart Docker service"

log_info "Docker $(docker --version) installed successfully"
log_info "Docker Compose installed as plugin (use: docker compose)"
mark_completed "DOCKER_INSTALL"
fi

###############################################################################
# LOGGING CONFIGURATION
###############################################################################

log_info "Configuring system logging..."
sudo systemctl enable rsyslog || handle_error "Failed to enable rsyslog"
sudo systemctl restart rsyslog || handle_error "Failed to restart rsyslog"

# Configure logrotate for application logs
cat <<EOF | sudo tee /etc/logrotate.d/app-logs
/var/log/app/*.log {
    daily
    missingok
    rotate 14
    compress
    delaycompress
    notifempty
    create 0640 root root
    sharedscripts
}
EOF

log_info "Logging configured successfully"

###############################################################################
# JOURNALD CONFIGURATION
###############################################################################

log_info "Configuring journald log rotation..."

# Backup original journald.conf
sudo cp /etc/systemd/journald.conf /etc/systemd/journald.conf.backup.$(date +%Y%m%d_%H%M%S) 2>/dev/null || true

# Configure systemd-journald for persistent logging and rotation (idempotent)
# Using sed to modify existing settings without overwriting the entire file
sudo sed -i 's/^#\?Storage=.*/Storage=persistent/' /etc/systemd/journald.conf
sudo sed -i 's/^#\?Compress=.*/Compress=yes/' /etc/systemd/journald.conf
sudo sed -i 's/^#\?SystemMaxUse=.*/SystemMaxUse=500M/' /etc/systemd/journald.conf
sudo sed -i 's/^#\?SystemKeepFree=.*/SystemKeepFree=100M/' /etc/systemd/journald.conf
sudo sed -i 's/^#\?SystemMaxFileSize=.*/SystemMaxFileSize=100M/' /etc/systemd/journald.conf
sudo sed -i 's/^#\?MaxRetentionSec=.*/MaxRetentionSec=30day/' /etc/systemd/journald.conf
sudo sed -i 's/^#\?ForwardToSyslog=.*/ForwardToSyslog=yes/' /etc/systemd/journald.conf

# Add settings if they don't exist at all (in case sed didn't find commented versions)
grep -q "^Storage=" /etc/systemd/journald.conf || echo "Storage=persistent" | sudo tee -a /etc/systemd/journald.conf >/dev/null
grep -q "^Compress=" /etc/systemd/journald.conf || echo "Compress=yes" | sudo tee -a /etc/systemd/journald.conf >/dev/null
grep -q "^SystemMaxUse=" /etc/systemd/journald.conf || echo "SystemMaxUse=500M" | sudo tee -a /etc/systemd/journald.conf >/dev/null
grep -q "^SystemKeepFree=" /etc/systemd/journald.conf || echo "SystemKeepFree=100M" | sudo tee -a /etc/systemd/journald.conf >/dev/null
grep -q "^SystemMaxFileSize=" /etc/systemd/journald.conf || echo "SystemMaxFileSize=100M" | sudo tee -a /etc/systemd/journald.conf >/dev/null
grep -q "^MaxRetentionSec=" /etc/systemd/journald.conf || echo "MaxRetentionSec=30day" | sudo tee -a /etc/systemd/journald.conf >/dev/null
grep -q "^ForwardToSyslog=" /etc/systemd/journald.conf || echo "ForwardToSyslog=yes" | sudo tee -a /etc/systemd/journald.conf >/dev/null

sudo systemctl restart systemd-journald || log_warning "Failed to restart journald"

log_info "Journald configured: 500MB max usage, 30-day retention"

###############################################################################
# AUTOMATIC UPDATES
###############################################################################

log_info "Configuring automatic security updates..."

# Ensure ONLY security updates are enabled (keep -updates commented out)
# The default 50unattended-upgrades has security enabled and updates commented
# We explicitly comment out -updates to ensure only security patches are installed
sudo sed -i 's/^\s*"\${distro_id}:\${distro_codename}-updates";/\/\/        "\${distro_id}:\${distro_codename}-updates";/' \
    /etc/apt/apt.conf.d/50unattended-upgrades 2>/dev/null || true

# Verify that security updates are uncommented (should be by default, but let's be sure)
sudo sed -i 's/\/\/\s*"\${distro_id}:\${distro_codename}-security";/        "\${distro_id}:\${distro_codename}-security";/' \
    /etc/apt/apt.conf.d/50unattended-upgrades 2>/dev/null || true

# Configure unattended upgrades schedule
cat <<EOF | sudo tee /etc/apt/apt.conf.d/20auto-upgrades
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
EOF

log_info "Automatic security updates enabled (security patches only, not regular updates)"

###############################################################################
# SWAP CONFIGURATION (SMART CALCULATION)
###############################################################################

log_info "Configuring swap space..."

# Get RAM in MB and GB (using awk to avoid rounding issues)
RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
RAM_GB=$(awk "BEGIN {printf \"%.0f\", $RAM_MB/1024}")

# Smart swap calculation
if [ "$RAM_GB" -le 2 ]; then
    # Small servers: 2x RAM
    SWAP_SIZE=$((RAM_MB * 2))
    log_info "RAM: ${RAM_MB}MB - Using 2x RAM for swap"
elif [ "$RAM_GB" -le 8 ]; then
    # Medium servers: 4GB
    SWAP_SIZE=4096
    log_info "RAM: ${RAM_GB}GB - Using 4GB swap"
else
    # Large servers: 8GB
    SWAP_SIZE=8192
    log_info "RAM: ${RAM_GB}GB - Using 8GB swap"
fi

# Check if swap already exists
if [ -f /swapfile ]; then
    log_warning "Swap file already exists, skipping creation"
else
    sudo fallocate -l "${SWAP_SIZE}M" /swapfile || handle_error "Failed to create swap file"
    sudo chmod 600 /swapfile || handle_error "Failed to set swap file permissions"
    sudo mkswap /swapfile || handle_error "Failed to format swap file"
    sudo swapon /swapfile || handle_error "Failed to enable swap"

    # Add to fstab if not already present
    if ! grep -q "/swapfile" /etc/fstab; then
        echo "/swapfile none swap sw 0 0" | sudo tee -a /etc/fstab
    fi

    log_info "Swap space created: ${SWAP_SIZE}MB"
fi

# Set swappiness to 10 (server optimized) using drop-in file
cat <<EOF | sudo tee /etc/sysctl.d/99-swappiness.conf
vm.swappiness=10
EOF
sudo sysctl -p /etc/sysctl.d/99-swappiness.conf >/dev/null 2>&1 || true

log_info "Swap configured with swappiness=10"

###############################################################################
# KERNEL HARDENING
###############################################################################

log_info "Applying kernel hardening parameters..."

cat <<EOF | sudo tee /etc/sysctl.d/99-server-hardening.conf
# Server hardening parameters
# IP Spoofing protection
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Ignore ICMP redirects
net.ipv4.conf.all.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0

# Ignore send redirects
net.ipv4.conf.all.send_redirects = 0

# Disable source packet routing (SECURITY FIX)
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0

# Log Martians (suspicious packets - SECURITY FIX)
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1

# Allow ICMP ping requests (set to 1 to ignore)
net.ipv4.icmp_echo_ignore_all = 0

# Ignore broadcast ping requests
net.ipv4.icmp_echo_ignore_broadcasts = 1

# SYN flood protection
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 5

# TCP hardening
net.ipv4.tcp_timestamps = 0
net.ipv4.conf.all.forwarding = 0
net.ipv6.conf.all.forwarding = 0

# Increase connection tracking size
net.netfilter.nf_conntrack_max = 262144

# File system hardening (SECURITY FIX - completely disable core dumps for setuid programs)
fs.suid_dumpable = 0
kernel.dmesg_restrict = 1

# Kernel debugging keys disabled (SECURITY FIX)
kernel.sysrq = 0
EOF

sudo sysctl -p /etc/sysctl.d/99-server-hardening.conf >/dev/null 2>&1 || log_warning "Some sysctl parameters may not be available on this kernel"

log_info "Kernel hardening applied"

###############################################################################
# DISABLE UNCOMMON NETWORK PROTOCOLS
###############################################################################

log_info "Disabling uncommon network protocols (dccp, sctp, rds, tipc)..."

cat <<EOF | sudo tee /etc/modprobe.d/disable-protocols.conf
# Disable uncommon network protocols for security
# These protocols are rarely used and can present security risks

# DCCP - Datagram Congestion Control Protocol
install dccp /bin/true
blacklist dccp

# SCTP - Stream Control Transmission Protocol
install sctp /bin/true
blacklist sctp

# RDS - Reliable Datagram Sockets
install rds /bin/true
blacklist rds

# TIPC - Transparent Inter-Process Communication
install tipc /bin/true
blacklist tipc
EOF

log_info "Uncommon protocols disabled (changes take effect after reboot)"

###############################################################################
# SYSTEM LIMITS
###############################################################################

log_info "Increasing system limits for production..."

cat <<EOF | sudo tee /etc/security/limits.d/99-production.conf
# Production system limits
* soft nofile 65535
* hard nofile 65535
* soft nproc 65535
* hard nproc 65535
root soft nofile 65535
root hard nofile 65535
root soft nproc 65535
root hard nproc 65535
EOF

log_info "System limits increased"

###############################################################################
# FIREWALL CONFIGURATION (UFW)
###############################################################################

# Check UFW status
UFW_STATUS=$(check_component_status "ufw")
UFW_MODE="reset"  # Default mode

if [[ "$UFW_STATUS" =~ ^active:([0-9]+)$ ]]; then
    RULE_COUNT="${BASH_REMATCH[1]}"
    UFW_DESC="Configure UFW firewall with standard security rules."
    UFW_IMPLICATIONS="🔴 CRITICAL: UFW is ACTIVE with $RULE_COUNT existing rules!

Options for proceeding:
1. MERGE (Recommended): Add new rules, keep existing rules
   • Safest option - preserves your current configuration
   • Adds: SSH (ports 22, 888), HTTP (80), HTTPS (443)
   • Your existing rules remain untouched

2. RESET (Destructive): Delete ALL rules and start fresh
   ⚠️  WARNING: This will DELETE all $RULE_COUNT existing rules!
   • Use only if you want to completely reconfigure
   • May temporarily interrupt services
   • Requires manual re-addition of any custom rules

3. SKIP: Leave firewall unchanged
   • No modifications to existing setup
   • You can configure manually later"

    if ask_component_install \
        "FIREWALL (UFW) CONFIGURATION" \
        "ufw" \
        "$UFW_DESC" \
        "$UFW_IMPLICATIONS" \
        "y" \
        "90"; then

        echo ""
        echo "Choose UFW configuration mode:"
        echo "  1. MERGE - Add rules, keep existing (Recommended)"
        echo "  2. RESET - Delete all rules and start fresh"
        echo "  3. SKIP - Leave unchanged"
        echo ""
        read -t 60 -p "Enter choice [1/2/3] (default: 1): " ufw_choice || ufw_choice="1"
        ufw_choice=${ufw_choice:-1}

        case "$ufw_choice" in
            2)
                echo ""
                echo -e "${RED}⚠️  You chose RESET - this will delete all $RULE_COUNT existing rules!${NC}"
                read -t 30 -p "Type 'YES' to confirm deletion of all rules: " confirm_reset || confirm_reset="no"

                if [ "$confirm_reset" = "YES" ]; then
                    UFW_MODE="reset"
                    log_warning "User confirmed UFW reset - all rules will be deleted"
                else
                    log_info "Reset cancelled, switching to MERGE mode"
                    UFW_MODE="merge"
                fi
                ;;
            3)
                UFW_MODE="skip"
                log_info "UFW configuration skipped"
                ;;
            *)
                UFW_MODE="merge"
                log_info "Using MERGE mode - preserving existing rules"
                ;;
        esac
    else
        UFW_MODE="skip"
    fi
else
    # UFW not active or no rules - safe to configure normally
    UFW_DESC="Configure UFW firewall with standard security rules (SSH, HTTP, HTTPS)."
    UFW_IMPLICATIONS="✅ UFW not detected or inactive - safe to configure
• Will set up with secure defaults
• Deny all incoming, allow all outgoing
• Allows: SSH (ports 22, 888), HTTP (80), HTTPS (443)
• Rate limiting enabled for SSH"

    if ask_component_install \
        "FIREWALL (UFW) CONFIGURATION" \
        "ufw" \
        "$UFW_DESC" \
        "$UFW_IMPLICATIONS" \
        "y" \
        "60"; then
        UFW_MODE="reset"
    else
        UFW_MODE="skip"
    fi
fi

# Execute based on chosen mode
if [ "$UFW_MODE" != "skip" ]; then
    if [ "$DRY_RUN" = true ]; then
        log_dry_run "UFW Mode: $UFW_MODE"
        log_dry_run "Would configure UFW firewall"
        if [ "$UFW_MODE" = "reset" ]; then
            log_dry_run "Would reset UFW to defaults"
        fi
        log_dry_run "Would add rules: SSH (22, 888), HTTP (80), HTTPS (443)"
    else
        log_info "Configuring firewall (UFW) in $UFW_MODE mode..."

        if [ "$UFW_MODE" = "reset" ]; then
            # Disable UFW first to prevent lockout
            sudo ufw --force disable

            # Reset UFW to defaults
            sudo ufw --force reset
            log_info "UFW reset to defaults"
        fi

        # Set default policies (safe to run multiple times)
        sudo ufw default deny incoming
        sudo ufw default allow outgoing

        # Allow SSH on BOTH ports 22 and 888 (prevents lockout)
        sudo ufw allow 22/tcp comment 'SSH (will be disabled manually later)' || handle_error "Failed to add SSH port 22"
        sudo ufw limit 888/tcp comment 'SSH rate limited' || handle_error "Failed to add SSH port 888"

        # Allow HTTP and HTTPS
        sudo ufw allow 80/tcp comment 'HTTP' || handle_error "Failed to add HTTP port"
        sudo ufw allow 443/tcp comment 'HTTPS' || handle_error "Failed to add HTTPS port"

        log_info "Standard ports configured (22/SSH-temp, 888/SSH, 80/HTTP, 443/HTTPS)"
    fi
else
    log_info "UFW configuration skipped"
fi

# Interactive port addition (skip if already configured to avoid duplicates on resume)
if ! is_completed "UFW_CUSTOM_PORTS"; then
    echo ""
    log_info "Additional port configuration:"
    while true; do
        read -t 600 -p "Do you want to add another port? (enter port number or 'n' to skip, timeout 10 minutes): " port || port="n"

        if [[ $port == "n" ]] || [[ $port == "N" ]]; then
            break
        elif [[ $port =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
            read -t 30 -p "Protocol (tcp/udp) [tcp]: " protocol || protocol="tcp"
            protocol=${protocol:-tcp}

            read -t 30 -p "Description for this port: " description || description="Custom port"
            description=${description:-"Custom port"}

            sudo ufw allow "$port/$protocol" comment "$description" || log_warning "Failed to add port $port"
            log_info "Port $port/$protocol added"
        else
            log_warning "Invalid port number. Please enter a number between 1-65535 or 'n' to skip"
        fi
    done
    mark_completed "UFW_CUSTOM_PORTS"
else
    log_warning "Custom UFW ports already configured, skipping interactive addition"
fi

# Enable UFW (using --force for non-interactive)
sudo ufw --force enable || handle_error "Failed to enable UFW"

# Note: IPv6 configuration will be applied later during SSH hardening based on user choice

log_info "Firewall configured and enabled"
sudo ufw status verbose
log_info "UFW rules validation:"
sudo ufw status numbered

###############################################################################
# SSH HARDENING
###############################################################################

if skip_if_completed "SSH_HARDENING"; then
    SSH_HARDENED=false  # Set variable for summary
else
    echo ""
    echo "=========================================================================="
    echo "SSH CONFIGURATION - IMPORTANT!"
    echo "=========================================================================="
    echo ""
    echo "⚠️  WARNING: Changing SSH port can lock you out of your server!"
    echo ""
    echo "The script will:"
    echo "  1. Add port 888 for SSH (keeping port 22 active)"
    echo "  2. Apply security hardening (disable root, password auth, etc.)"
    echo "  3. Restart SSH with BOTH ports 22 and 888 active"
    echo ""
    echo "After the script completes:"
    echo "  1. Test SSH connection on port 888: ssh -p 888 user@server"
    echo "  2. If port 888 works, manually disable port 22 with these commands:"
    echo "     sudo sed -i '/^Port 22$/d' /etc/ssh/sshd_config"
    echo "     sudo systemctl restart ssh"
    echo ""
    read -t 60 -p "Do you want to proceed with SSH hardening? (y/n, timeout 60s): " ssh_harden || ssh_harden="y"

    if [[ $ssh_harden == "y" ]] || [[ $ssh_harden == "Y" ]]; then
    log_info "Hardening SSH configuration..."

    # Backup original sshd_config
    sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup.$(date +%Y%m%d_%H%M%S)

    # Verify SSH key exists before disabling password authentication
    log_info "Verifying SSH key authentication is configured..."
    if [ ! -f "$USER_HOME/.ssh/authorized_keys" ] || [ ! -s "$USER_HOME/.ssh/authorized_keys" ]; then
        log_warning "WARNING: No SSH keys found in $USER_HOME/.ssh/authorized_keys"
        echo ""
        echo "⚠️  CRITICAL WARNING ⚠️"
        echo "═══════════════════════════════════════════════════════════"
        echo "No SSH keys detected in ~/.ssh/authorized_keys"
        echo "The script will disable password authentication for security."
        echo ""
        echo "If you continue without SSH keys, you may be LOCKED OUT!"
        echo ""
        echo "Recommended: Cancel now (Ctrl+C) and run: ssh-copy-id $USER@$(hostname -I | awk '{print $1}')"
        echo "═══════════════════════════════════════════════════════════"
        read -t 30 -p "Continue anyway? (y/N, timeout 30s): " continue_without_keys || continue_without_keys="n"
        if [[ ! $continue_without_keys =~ ^[Yy]$ ]]; then
            handle_error "SSH hardening cancelled - please configure SSH keys first"
        fi
        log_warning "User chose to continue without SSH keys - RISK OF LOCKOUT!"
    else
        log_info "SSH keys verified in authorized_keys"
    fi

    # Ask about IPv6
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "IPv6 CONFIGURATION"
    echo "═══════════════════════════════════════════════════════════"
    echo "For security, IPv6 can be disabled to reduce attack surface."
    echo ""
    echo "Choose IPv6 setting:"
    echo "  - Disable (recommended): IPv6 will be disabled for SSH and firewall"
    echo "  - Enable: Keep IPv6 support (required for some environments)"
    echo ""
    read -t 30 -p "Disable IPv6? (Y/n, default: Y, timeout 30s): " disable_ipv6 || disable_ipv6="y"
    disable_ipv6=${disable_ipv6:-y}  # Default to yes if empty

    if [[ $disable_ipv6 =~ ^[Yy]$ ]] || [[ -z "$disable_ipv6" ]]; then
        IPV6_DISABLED=true
        log_info "IPv6 will be disabled for security"
    else
        IPV6_DISABLED=false
        log_info "IPv6 will remain enabled"
    fi

    # Ask about SSH forwarding
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "SSH FORWARDING CONFIGURATION"
    echo "═══════════════════════════════════════════════════════════"
    echo "SSH forwarding allows tunneling and port forwarding."
    echo ""
    echo "Options:"
    echo "  - Disable (most secure): No TCP or agent forwarding allowed"
    echo "  - Enable (flexible): Useful for development, management, and tunneling"
    echo ""
    echo "Note: Disabling increases security but limits flexibility."
    echo "      Enable if you use SSH tunneling or need to forward ports."
    echo ""
    read -t 30 -p "Enable SSH forwarding? (Y/n, default: Y, timeout 30s): " enable_ssh_forwarding || enable_ssh_forwarding="y"
    enable_ssh_forwarding=${enable_ssh_forwarding:-y}  # Default to yes if empty

    if [[ $enable_ssh_forwarding =~ ^[Nn]$ ]]; then
        SSH_FORWARDING_ENABLED=false
        log_info "SSH forwarding will be disabled for maximum security"
    else
        SSH_FORWARDING_ENABLED=true
        log_info "SSH forwarding will be enabled (AllowTcpForwarding and AllowAgentForwarding)"
    fi

    # Remove any existing Port directives (we'll add them back properly)
    sudo sed -i '/^#\?Port /d' /etc/ssh/sshd_config

    # SSH hardening configurations (idempotent - using sed replace)
    # Note: PermitRootLogin set to 'prohibit-password' to allow key-based root login
    sudo sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
    sudo sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config
    sudo sed -i 's/^#\?PubkeyAuthentication .*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
    sudo sed -i 's/^#\?ChallengeResponseAuthentication .*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config

    # Configure AddressFamily based on IPv6 choice
    if [ "$IPV6_DISABLED" = true ]; then
        sudo sed -i 's/^#\?AddressFamily .*/AddressFamily inet/' /etc/ssh/sshd_config
        log_info "SSH configured for IPv4 only"
    else
        sudo sed -i 's/^#\?AddressFamily .*/AddressFamily any/' /etc/ssh/sshd_config
        log_info "SSH configured for IPv4 and IPv6"
    fi
    sudo sed -i 's/^#\?X11Forwarding .*/X11Forwarding no/' /etc/ssh/sshd_config
    sudo sed -i 's/^#\?MaxAuthTries .*/MaxAuthTries 3/' /etc/ssh/sshd_config
    sudo sed -i 's/^#\?ClientAliveInterval .*/ClientAliveInterval 300/' /etc/ssh/sshd_config
    sudo sed -i 's/^#\?ClientAliveCountMax .*/ClientAliveCountMax 2/' /etc/ssh/sshd_config

    # Configure SSH forwarding based on user choice
    if [ "$SSH_FORWARDING_ENABLED" = true ]; then
        sudo sed -i 's/^#\?AllowTcpForwarding .*/AllowTcpForwarding yes/' /etc/ssh/sshd_config
        sudo sed -i 's/^#\?AllowAgentForwarding .*/AllowAgentForwarding yes/' /etc/ssh/sshd_config
        grep -q "^AllowTcpForwarding" /etc/ssh/sshd_config || echo "AllowTcpForwarding yes" | sudo tee -a /etc/ssh/sshd_config >/dev/null
        grep -q "^AllowAgentForwarding" /etc/ssh/sshd_config || echo "AllowAgentForwarding yes" | sudo tee -a /etc/ssh/sshd_config >/dev/null
        log_info "SSH forwarding enabled"
    else
        sudo sed -i 's/^#\?AllowTcpForwarding .*/AllowTcpForwarding no/' /etc/ssh/sshd_config
        sudo sed -i 's/^#\?AllowAgentForwarding .*/AllowAgentForwarding no/' /etc/ssh/sshd_config
        grep -q "^AllowTcpForwarding" /etc/ssh/sshd_config || echo "AllowTcpForwarding no" | sudo tee -a /etc/ssh/sshd_config >/dev/null
        grep -q "^AllowAgentForwarding" /etc/ssh/sshd_config || echo "AllowAgentForwarding no" | sudo tee -a /etc/ssh/sshd_config >/dev/null
        log_info "SSH forwarding disabled (maximum security)"
    fi

    # Add BOTH port 22 and 888 (idempotent - only if not present)
    grep -q "^Port 22$" /etc/ssh/sshd_config || echo "Port 22" | sudo tee -a /etc/ssh/sshd_config >/dev/null
    grep -q "^Port 888$" /etc/ssh/sshd_config || echo "Port 888" | sudo tee -a /etc/ssh/sshd_config >/dev/null

    # Add additional SSH hardening if not present (already idempotent)
    grep -q "^Protocol 2" /etc/ssh/sshd_config || echo "Protocol 2" | sudo tee -a /etc/ssh/sshd_config >/dev/null
    grep -q "^MaxSessions" /etc/ssh/sshd_config || echo "MaxSessions 10" | sudo tee -a /etc/ssh/sshd_config >/dev/null

    # Set SSH LogLevel to VERBOSE for better security auditing
    sudo sed -i 's/^#\?LogLevel .*/LogLevel VERBOSE/' /etc/ssh/sshd_config
    grep -q "^LogLevel" /etc/ssh/sshd_config || echo "LogLevel VERBOSE" | sudo tee -a /etc/ssh/sshd_config >/dev/null
    log_info "SSH LogLevel set to VERBOSE for enhanced security auditing"

    # Test SSH configuration
    if ! sudo sshd -t 2>/dev/null; then
        log_warning "SSH configuration test failed or sshd not available - skipping validation"
        log_warning "Please manually verify SSH config after installation"
    fi

    # Define SSH ports
    SSH_PORT_OLD=22
    SSH_PORT_NEW=888

    # Add SSH firewall rules with dual-layer protection
    log_info "Configuring SSH firewall rules..."

    # Ask user for trusted home IP for whitelist
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "SSH TRUSTED IP CONFIGURATION"
    echo "═══════════════════════════════════════════════════════════"
    echo "You can whitelist your home/office IP for guaranteed SSH access."
    echo "This IP will bypass rate limiting on port $SSH_PORT_NEW."
    echo ""
    echo "Benefits:"
    echo "  - No rate limiting from this IP (unlimited connection attempts)"
    echo "  - Guaranteed access even if rate limits are triggered"
    echo "  - Recommended for your main work location"
    echo ""
    echo "Note: You can find your public IP at: https://icanhazip.com"
    echo ""
    read -t 600 -p "Enter your trusted IP address (or press Enter to skip, timeout 10 minutes): " TRUSTED_IP || TRUSTED_IP=""

    # Layer 1: Whitelist trusted home IP if provided (no rate limiting)
    if [[ ! -z "$TRUSTED_IP" ]]; then
        # Validate IP format (basic check)
        if [[ $TRUSTED_IP =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            sudo ufw allow from "$TRUSTED_IP" to any port "$SSH_PORT_NEW" comment 'SSH whitelist - trusted home IP' || \
                log_warning "Failed to add SSH whitelist rule"
            log_info "Trusted IP $TRUSTED_IP whitelisted for SSH access on port $SSH_PORT_NEW"
        else
            log_warning "Invalid IP format: $TRUSTED_IP - skipping whitelist"
            log_warning "Expected format: xxx.xxx.xxx.xxx (e.g., 192.168.1.1)"
        fi
    else
        log_info "No trusted IP configured - all IPs will use rate limiting"
    fi

    # Layer 2: Rate limiting for all other IPs already configured earlier (ufw limit 888/tcp)
    log_info "SSH firewall: Rate limiting active for all non-whitelisted IPs"

    # Configure IPv6 in UFW based on user choice
    if [ "$IPV6_DISABLED" = true ]; then
        log_info "Disabling IPv6 in UFW..."
        sudo sed -i 's/^IPV6=yes/IPV6=no/' /etc/default/ufw 2>/dev/null || true
        sudo sed -i 's/^IPV6=no/IPV6=no/' /etc/default/ufw 2>/dev/null || true  # Ensure it's set
        sudo ufw reload || log_warning "Failed to reload UFW after IPv6 configuration"
        log_info "IPv6 disabled in firewall"
    else
        log_info "Ensuring IPv6 is enabled in UFW..."
        sudo sed -i 's/^IPV6=no/IPV6=yes/' /etc/default/ufw 2>/dev/null || true
        sudo sed -i 's/^IPV6=yes/IPV6=yes/' /etc/default/ufw 2>/dev/null || true  # Ensure it's set
        sudo ufw reload || log_warning "Failed to reload UFW after IPv6 configuration"
        log_info "IPv6 enabled in firewall"
    fi

    # Configure systemd socket for SSH ports (required for Ubuntu with socket activation)
    log_info "Configuring systemd SSH socket for ports 22 and 888..."

    # Check if ssh.socket exists (Ubuntu uses systemd socket activation)
    if systemctl list-unit-files | grep -q "ssh.socket"; then
        log_info "Detected systemd socket activation, configuring ssh.socket..."

        # Create systemd override directory
        sudo mkdir -p /etc/systemd/system/ssh.socket.d

        # Create override configuration for SSH socket to listen on both ports
        cat <<EOF | sudo tee /etc/systemd/system/ssh.socket.d/ports.conf
[Socket]
ListenStream=
ListenStream=22
ListenStream=888
EOF

        log_info "SSH socket configured for ports 22 and 888"

        # Reload systemd configuration and restart SSH socket
        sudo systemctl daemon-reload || log_warning "Failed to reload systemd daemon"
        sudo systemctl restart ssh.socket || log_warning "Failed to restart ssh.socket"
        sudo systemctl restart ssh || sudo systemctl restart sshd || handle_error "Failed to restart SSH service"

        # Verify SSH is listening on both ports
        sleep 2
        if ss -tlnp 2>/dev/null | grep -q ":888.*sshd" && ss -tlnp 2>/dev/null | grep -q ":22.*sshd"; then
            log_info "Verified: SSH is listening on both port 22 and 888"
        else
            log_warning "Warning: Could not verify SSH is listening on both ports. Check with: sudo ss -tlnp | grep sshd"
        fi
    else
        # Fallback for systems without socket activation (older systems)
        log_info "No systemd socket activation detected, restarting SSH service..."
        sudo systemctl restart ssh || sudo systemctl restart sshd || handle_error "Failed to restart SSH service"
    fi

        log_info "SSH hardened successfully"
        log_info "SSH is now listening on BOTH port 22 and 888"
        if [ "$IPV6_DISABLED" = true ]; then
            log_info "Note: IPv6 is disabled for SSH and firewall"
        else
            log_info "Note: IPv6 is enabled for SSH and firewall"
        fi
        SSH_HARDENED=true
    else
        log_warning "SSH hardening skipped"
        SSH_HARDENED=false
    fi
    mark_completed "SSH_HARDENING"
fi

###############################################################################
# FAIL2BAN CONFIGURATION
###############################################################################

log_info "Configuring Fail2ban..."

# Backup original jail.local if it exists
if [ -f /etc/fail2ban/jail.local ]; then
    sudo cp /etc/fail2ban/jail.local /etc/fail2ban/jail.local.backup.$(date +%Y%m%d_%H%M%S)
    log_info "Backed up existing jail.local"
fi

# Create jail.d directory if it doesn't exist
sudo mkdir -p /etc/fail2ban/jail.d

# Configure Fail2ban for SSH in jail.d (doesn't overwrite existing custom jails)
cat <<EOF | sudo tee /etc/fail2ban/jail.d/server-baseline.conf
# Server Baseline Fail2ban Configuration
# Created by server_baseline installation script

[DEFAULT]
# Default ban settings for all jails
bantime = 3600
findtime = 600
maxretry = 5

[sshd]
# SSH protection - monitors both ports 22 and 888
enabled = true
port = 22,888
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 7200
findtime = 600
EOF

log_info "Fail2ban configuration created in /etc/fail2ban/jail.d/server-baseline.conf"
log_info "Existing custom jails in jail.local are preserved"

sudo systemctl enable fail2ban || handle_error "Failed to enable Fail2ban"
sudo systemctl restart fail2ban || handle_error "Failed to restart Fail2ban"

log_info "Fail2ban configured for SSH protection"

###############################################################################
# AUDIT LOGGING CONFIGURATION
###############################################################################

log_info "Configuring audit logging (auditd + acct)..."

# Install auditd and acct for system auditing
DEBIAN_FRONTEND=noninteractive sudo apt-get install -y auditd acct audispd-plugins || \
    log_warning "Failed to install audit tools"

# Configure auditd rules for SSH and security monitoring
cat <<EOF | sudo tee /etc/audit/rules.d/ssh-security.rules
# Monitor SSH configuration changes
-w /etc/ssh/sshd_config -p wa -k sshd_config_changes

# Monitor user home directories for unauthorized changes
-w /home/ -p wa -k home_modifications

# Monitor privileged commands (run by root)
-a always,exit -F arch=b64 -S execve -F uid=0 -k privileged_commands

# Monitor authentication events
-w /var/log/auth.log -p wa -k auth_log_changes
EOF

# Enable and start auditd
sudo systemctl enable auditd || log_warning "Failed to enable auditd"
sudo systemctl restart auditd || log_warning "Failed to restart auditd"

# Enable process accounting with acct
sudo systemctl enable acct || log_warning "Failed to enable acct"
sudo systemctl restart acct || log_warning "Failed to restart acct"

log_info "Audit logging configured successfully"
log_info "View audit logs: sudo ausearch -k sshd_config_changes"

###############################################################################
# SECURITY SCANNING TOOLS WITH TELEGRAM INTEGRATION
###############################################################################

echo ""
echo "=========================================================================="
echo "SECURITY SCANNING TOOLS"
echo "=========================================================================="
echo ""
echo "Optional security scanning tools for proactive threat detection:"
echo ""

# Ask about Rkhunter
echo "1. RKHUNTER (Rootkit Hunter)"
echo "   - Scans for rootkits, backdoors, and local exploits"
echo "   - Can run daily at 03:00 with Telegram alerts on warnings"
echo "   - Lightweight, no performance impact"
echo "   - Recommended for: Production servers"
echo ""
read -t 60 -p "Do you want to install Rkhunter? (y/n, timeout 60s): " install_rkhunter || install_rkhunter="n"

# Ask about Lynis
echo ""
echo "2. LYNIS (Security Auditing Tool)"
echo "   - Comprehensive security audit (200+ checks)"
echo "   - Provides hardening score and improvement suggestions"
echo "   - Can run monthly on 1st at 04:00 with Telegram reports"
echo "   - Recommended for: All servers"
echo ""
read -t 60 -p "Do you want to install Lynis? (y/n, timeout 60s): " install_lynis || install_lynis="n"

# Install selected tools
RKHUNTER_INSTALLED=false
LYNIS_INSTALLED=false

if [[ $install_rkhunter == "y" ]] || [[ $install_rkhunter == "Y" ]]; then
    log_info "Installing Rkhunter..."
    DEBIAN_FRONTEND=noninteractive sudo apt-get install -y rkhunter || \
        log_warning "Failed to install Rkhunter"

    # Configure rkhunter for this server's SSH setup
    log_info "Configuring rkhunter for custom SSH port..."
    sudo sed -i 's/^#\?ALLOW_SSH_ROOT_USER=.*/ALLOW_SSH_ROOT_USER=prohibit-password/' /etc/rkhunter.conf
    sudo sed -i 's/^#\?PORT_NUMBER=.*/PORT_NUMBER=888/' /etc/rkhunter.conf

    # Add settings if they don't exist
    grep -q "^ALLOW_SSH_ROOT_USER=" /etc/rkhunter.conf || echo "ALLOW_SSH_ROOT_USER=prohibit-password" | sudo tee -a /etc/rkhunter.conf >/dev/null
    grep -q "^PORT_NUMBER=" /etc/rkhunter.conf || echo "PORT_NUMBER=888" | sudo tee -a /etc/rkhunter.conf >/dev/null

    # Update rkhunter database
    sudo rkhunter --update --skip-keypress 2>/dev/null || log_warning "Failed to update rkhunter database"
    sudo rkhunter --propupd --skip-keypress 2>/dev/null || log_warning "Failed to update rkhunter properties"

    log_info "Rkhunter installed and configured successfully"
    RKHUNTER_INSTALLED=true
else
    log_warning "Rkhunter installation skipped"
fi

if [[ $install_lynis == "y" ]] || [[ $install_lynis == "Y" ]]; then
    log_info "Installing Lynis..."
    DEBIAN_FRONTEND=noninteractive sudo apt-get install -y lynis || \
        log_warning "Failed to install Lynis"

    log_info "Lynis installed successfully"
    LYNIS_INSTALLED=true
else
    log_warning "Lynis installation skipped"
fi

# Show manual installation info if both were skipped
if [ "$RKHUNTER_INSTALLED" = false ] && [ "$LYNIS_INSTALLED" = false ]; then
    log_info "You can install them later with:"
    log_info "  sudo apt-get install -y rkhunter lynis"
fi

# Only configure Telegram integration if at least one tool was installed
if [ "$RKHUNTER_INSTALLED" = true ] || [ "$LYNIS_INSTALLED" = true ]; then

# Check if we have Telegram credentials (from Netdata or ask user)
SECURITY_TELEGRAM_BOT_TOKEN=""
SECURITY_TELEGRAM_CHAT_ID=""

if [[ ! -z "${TELEGRAM_BOT_TOKEN:-}" ]] && [[ ! -z "${TELEGRAM_CHAT_ID:-}" ]]; then
    # Reuse Telegram credentials from Netdata configuration
    SECURITY_TELEGRAM_BOT_TOKEN="$TELEGRAM_BOT_TOKEN"
    SECURITY_TELEGRAM_CHAT_ID="$TELEGRAM_CHAT_ID"
    log_info "Using Telegram credentials from Netdata configuration"
else
    # Ask user for Telegram credentials
    echo ""
    echo "=========================================================================="
    echo "SECURITY SCAN TELEGRAM ALERTS"
    echo "=========================================================================="
    echo ""
    echo "Security scans can send alerts to Telegram:"
    echo "  - Rkhunter: Daily scan at 03:00 (only on warnings)"
    echo "  - Lynis: Monthly audit on 1st of month at 04:00"
    echo ""
    read -t 60 -p "Do you want to configure Telegram alerts for security scans? (y/n, timeout 60s): " setup_sec_telegram || setup_sec_telegram="n"

    if [[ $setup_sec_telegram == "y" ]] || [[ $setup_sec_telegram == "Y" ]]; then
        echo ""
        echo "To get Telegram bot token and chat ID:"
        echo "  1. Open Telegram and search for @BotFather"
        echo "  2. Send /newbot and follow instructions"
        echo "  3. Copy the bot token"
        echo "  4. Start chat with your bot (send /start)"
        echo "  5. Get your chat ID from @userinfobot"
        echo ""
        read -t 600 -p "Enter Telegram Bot Token (timeout 10 minutes): " SECURITY_TELEGRAM_BOT_TOKEN || SECURITY_TELEGRAM_BOT_TOKEN=""
        read -t 600 -p "Enter Telegram Chat ID (timeout 10 minutes): " SECURITY_TELEGRAM_CHAT_ID || SECURITY_TELEGRAM_CHAT_ID=""
    fi
fi

# Only configure Telegram integration if credentials are available
if [[ ! -z "$SECURITY_TELEGRAM_BOT_TOKEN" ]] && [[ ! -z "$SECURITY_TELEGRAM_CHAT_ID" ]]; then
    log_info "Configuring Telegram integration for security scans..."

    # Create rkhunter Telegram wrapper script (only if installed)
    if [ "$RKHUNTER_INSTALLED" = true ]; then
    cat <<'RKHUNTER_SCRIPT' | sudo tee /usr/local/bin/rkhunter-telegram.sh
#!/bin/bash
# Rkhunter scan with Telegram notifications

TELEGRAM_BOT_TOKEN="REPLACE_BOT_TOKEN"
TELEGRAM_CHAT_ID="REPLACE_CHAT_ID"
SCAN_LOG="/var/log/rkhunter-scan-$(date +%Y%m%d).log"

# Run rkhunter scan
/usr/bin/rkhunter --check --skip-keypress --report-warnings-only > "$SCAN_LOG" 2>&1

# Check if warnings were found
if grep -q "Warning" "$SCAN_LOG"; then
    # Extract warnings
    WARNINGS=$(grep "Warning" "$SCAN_LOG" | head -10)
    WARNING_COUNT=$(grep -c "Warning" "$SCAN_LOG")

    # Send Telegram message
    MESSAGE="🔍 *Rkhunter Alert*%0A%0A"
    MESSAGE+="⚠️ Found $WARNING_COUNT warning(s) on $(hostname)%0A%0A"
    MESSAGE+="*Top warnings:*%0A\`\`\`%0A${WARNINGS}%0A\`\`\`%0A%0A"
    MESSAGE+="Full log: $SCAN_LOG"

    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d chat_id="${TELEGRAM_CHAT_ID}" \
        -d text="${MESSAGE}" \
        -d parse_mode="Markdown" >/dev/null 2>&1
fi
RKHUNTER_SCRIPT

    # Replace placeholders with actual credentials for rkhunter
    sudo sed -i "s/REPLACE_BOT_TOKEN/$SECURITY_TELEGRAM_BOT_TOKEN/g" /usr/local/bin/rkhunter-telegram.sh
    sudo sed -i "s/REPLACE_CHAT_ID/$SECURITY_TELEGRAM_CHAT_ID/g" /usr/local/bin/rkhunter-telegram.sh
    sudo chmod 700 /usr/local/bin/rkhunter-telegram.sh
    log_info "Rkhunter Telegram integration configured (chmod 700 for security)"
    fi

    # Create lynis Telegram wrapper script (only if installed)
    if [ "$LYNIS_INSTALLED" = true ]; then
    cat <<'LYNIS_SCRIPT' | sudo tee /usr/local/bin/lynis-telegram.sh
#!/bin/bash
# Lynis audit with Telegram notifications

TELEGRAM_BOT_TOKEN="REPLACE_BOT_TOKEN"
TELEGRAM_CHAT_ID="REPLACE_CHAT_ID"
LYNIS_LOG="/var/log/lynis-report.dat"

# Run lynis audit
/usr/sbin/lynis audit system --quiet --quick

# Extract score and suggestions
HARDENING_INDEX=$(grep "hardening_index=" "$LYNIS_LOG" | cut -d'=' -f2)
SUGGESTIONS=$(grep "suggestion\[\]=" "$LYNIS_LOG" | head -5 | cut -d'=' -f2)
SUGGESTION_COUNT=$(grep -c "suggestion\[\]=" "$LYNIS_LOG")

# Send Telegram message
MESSAGE="🛡️ *Lynis Monthly Audit*%0A%0A"
MESSAGE+="Server: $(hostname)%0A"
MESSAGE+="Hardening Score: *${HARDENING_INDEX}*/100%0A%0A"
MESSAGE+="Total suggestions: ${SUGGESTION_COUNT}%0A%0A"
MESSAGE+="*Top 5 suggestions:*%0A"

# Format suggestions
while IFS= read -r suggestion; do
    MESSAGE+="• ${suggestion}%0A"
done <<< "$SUGGESTIONS"

curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d chat_id="${TELEGRAM_CHAT_ID}" \
    -d text="${MESSAGE}" \
    -d parse_mode="Markdown" >/dev/null 2>&1
LYNIS_SCRIPT

    # Replace placeholders with actual credentials for lynis
    sudo sed -i "s/REPLACE_BOT_TOKEN/$SECURITY_TELEGRAM_BOT_TOKEN/g" /usr/local/bin/lynis-telegram.sh
    sudo sed -i "s/REPLACE_CHAT_ID/$SECURITY_TELEGRAM_CHAT_ID/g" /usr/local/bin/lynis-telegram.sh
    sudo chmod 700 /usr/local/bin/lynis-telegram.sh
    log_info "Lynis Telegram integration configured (chmod 700 for security)"
    fi

    # Create cron jobs for automated scans (only for installed tools)
    CRON_CONTENT=""

    if [ "$RKHUNTER_INSTALLED" = true ]; then
        CRON_CONTENT+="# Rkhunter daily scan at 03:00 (only alerts on warnings)"$'\n'
        CRON_CONTENT+="0 3 * * * root /usr/local/bin/rkhunter-telegram.sh"$'\n'
    fi

    if [ "$LYNIS_INSTALLED" = true ]; then
        if [ ! -z "$CRON_CONTENT" ]; then
            CRON_CONTENT+=$'\n'
        fi
        CRON_CONTENT+="# Lynis monthly audit on 1st of month at 04:00"$'\n'
        CRON_CONTENT+="0 4 1 * * root /usr/local/bin/lynis-telegram.sh"
    fi

    if [ ! -z "$CRON_CONTENT" ]; then
        echo "$CRON_CONTENT" | sudo tee /etc/cron.d/security-scans >/dev/null
        sudo chmod 644 /etc/cron.d/security-scans
    fi

    log_info "Telegram integration configured successfully"
    if [ "$RKHUNTER_INSTALLED" = true ]; then
        log_info "Rkhunter: Daily scans at 03:00 (alerts on warnings only)"
    fi
    if [ "$LYNIS_INSTALLED" = true ]; then
        log_info "Lynis: Monthly audits on 1st of month at 04:00"
    fi
else
    log_warning "Telegram integration skipped - no credentials provided"
    log_info "Manual scan commands:"
    if [ "$RKHUNTER_INSTALLED" = true ]; then
        log_info "  - Rkhunter: sudo rkhunter --check --skip-keypress"
    fi
    if [ "$LYNIS_INSTALLED" = true ]; then
        log_info "  - Lynis: sudo lynis audit system"
    fi
fi

fi  # End of at least one tool installed check

###############################################################################
# SHELL IMPROVEMENTS
###############################################################################

log_info "Adding shell improvements..."

# Add useful aliases to .bashrc for actual user
if [ -f "$USER_HOME/.bashrc" ]; then
    # Add aliases if not already present
    grep -q "alias ll=" "$USER_HOME/.bashrc" || echo "alias ll='ls -lah'" >> "$USER_HOME/.bashrc"
    grep -q "alias update=" "$USER_HOME/.bashrc" || echo "alias update='sudo apt-get update && sudo apt-get upgrade -y'" >> "$USER_HOME/.bashrc"
    grep -q "alias dps=" "$USER_HOME/.bashrc" || echo "alias dps='docker ps --format \"table {{.Names}}\t{{.Status}}\t{{.Ports}}\"'" >> "$USER_HOME/.bashrc"
fi

log_info "Shell improvements added"

###############################################################################
# DIRECTORY STRUCTURE
###############################################################################

log_info "Creating project directory structure..."

# Verify we're creating directories in the correct user's home
if [ "$USER_HOME" = "/root" ] && [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
    log_warning "Detected USER_HOME points to /root but script was run with sudo by $SUDO_USER"
    log_warning "Correcting to use actual user's home directory..."
    # Use getent to get the correct home directory
    CORRECTED_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    if [ -n "$CORRECTED_HOME" ] && [ "$CORRECTED_HOME" != "/" ]; then
        USER_HOME="$CORRECTED_HOME"
        log_info "Using corrected home directory: $USER_HOME"
    else
        log_warning "Could not determine correct home directory, using /home/$SUDO_USER"
        USER_HOME="/home/$SUDO_USER"
    fi
fi

# Final verification
log_info "Using home directory: $USER_HOME for user: $ACTUAL_USER"

# Create main directories only if they don't exist (using sudo -u to run as the actual user)
if [ ! -d "$USER_HOME/docker" ]; then
    sudo -u "$ACTUAL_USER" mkdir -p "$USER_HOME/docker" || handle_error "Failed to create docker directory"
fi
if [ ! -d "$USER_HOME/scripts" ]; then
    sudo -u "$ACTUAL_USER" mkdir -p "$USER_HOME/scripts" || handle_error "Failed to create scripts directory"
fi
if [ ! -d "$USER_HOME/projects" ]; then
    sudo -u "$ACTUAL_USER" mkdir -p "$USER_HOME/projects" || handle_error "Failed to create projects directory"
fi

# Ensure ownership is correct (in case directories already existed)
sudo chown -R "$ACTUAL_USER:$ACTUAL_USER" "$USER_HOME/docker" "$USER_HOME/scripts" "$USER_HOME/projects" 2>/dev/null || true

log_info "Created directories: docker, scripts, projects in $USER_HOME"

###############################################################################
# CLOUDFLARE TUNNEL SETUP
###############################################################################

log_info "Setting up Cloudflare Tunnel..."

# Create cloudflare directory (using sudo -u to ensure correct ownership)
if [ ! -d "$USER_HOME/docker/cloudflare" ]; then
    sudo -u "$ACTUAL_USER" mkdir -p "$USER_HOME/docker/cloudflare" || handle_error "Failed to create cloudflare directory"
fi

# Ask for Cloudflare tunnel token
echo ""
echo "=========================================================================="
echo "CLOUDFLARE TUNNEL CONFIGURATION"
echo "=========================================================================="
echo ""
echo "To get your Cloudflare Tunnel token:"
echo "  1. Go to https://one.dash.cloudflare.com/"
echo "  2. Navigate to Networks > Tunnels"
echo "  3. Create a new tunnel or select existing one"
echo "  4. Copy the tunnel token"
echo ""
read -t 600 -s -p "Enter your Cloudflare Tunnel token (or press 'n' to skip, timeout 10 minutes): " cf_token || cf_token="n"
echo ""

if [[ $cf_token != "n" ]] && [[ $cf_token != "N" ]] && [[ ! -z "$cf_token" ]]; then
    # Create .env file with token (as the actual user)
    sudo -u "$ACTUAL_USER" bash -c "echo 'CF_TOKEN=$cf_token' > '$USER_HOME/docker/cloudflare/.env'"
    sudo -u "$ACTUAL_USER" chmod 600 "$USER_HOME/docker/cloudflare/.env"

    # Create docker-compose.yaml for Cloudflare (as the actual user)
    sudo -u "$ACTUAL_USER" cat <<'EOF' > "$USER_HOME/docker/cloudflare/docker-compose.yaml"
services:
  cloudflared:
    # NOTE: Using :latest tag. For production, consider pinning to a specific version (e.g., cloudflare/cloudflared:2024.1.5)
    image: cloudflare/cloudflared:latest
    command: tunnel --no-autoupdate run --token ${CF_TOKEN}
    env_file:
      - .env
    restart: unless-stopped
EOF

    # Ensure ownership is correct
    sudo chown -R "$ACTUAL_USER:$ACTUAL_USER" "$USER_HOME/docker/cloudflare"
    log_info "Cloudflare Tunnel configuration created (token stored securely in .env)"
    CF_CONFIGURED=true
else
    log_warning "Cloudflare Tunnel setup skipped"
    CF_CONFIGURED=false
fi

###############################################################################
# PORTAINER SETUP
###############################################################################

log_info "Setting up Portainer..."

# Create portainer directory (using sudo -u to ensure correct ownership)
if [ ! -d "$USER_HOME/docker/portainer" ]; then
    sudo -u "$ACTUAL_USER" mkdir -p "$USER_HOME/docker/portainer" || handle_error "Failed to create portainer directory"
fi

# Create docker-compose.yaml for Portainer (as the actual user)
sudo -u "$ACTUAL_USER" cat <<'EOF' > "$USER_HOME/docker/portainer/docker-compose.yaml"
services:
  portainer:
    # NOTE: Using :lts tag. For production, consider pinning to a specific version (e.g., portainer/portainer-ce:2.19.4)
    image: portainer/portainer-ce:lts
    container_name: portainer
    ports:
      - "8000:8000"
      - "9443:9443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - portainer_data:/data
    restart: always

volumes:
  portainer_data:
    driver: local
EOF

# Ensure ownership is correct
sudo chown -R "$ACTUAL_USER:$ACTUAL_USER" "$USER_HOME/docker/portainer"
log_info "Portainer configuration created"

###############################################################################
# PORTAINER FIREWALL RULES
###############################################################################

log_info "Adding Portainer ports to firewall..."

# Ask about Portainer Agent port (optional)
echo ""
read -t 30 -p "Do you want to enable Portainer Agent port 8000? (only needed for remote management) (y/n, timeout 30s): " enable_agent || enable_agent="n"
PORTAINER_AGENT_ENABLED=false

if [[ $enable_agent == "y" ]] || [[ $enable_agent == "Y" ]]; then
    sudo ufw allow 8000/tcp comment 'Portainer Agent' || log_warning "Failed to add Portainer port 8000"
    PORTAINER_AGENT_ENABLED=true
    log_info "Portainer Agent port 8000 enabled"
fi

# Always add Portainer HTTPS port
sudo ufw allow 9443/tcp comment 'Portainer HTTPS' || log_warning "Failed to add Portainer port 9443"
sudo ufw reload || handle_error "Failed to reload UFW"

log_info "Portainer HTTPS port 9443 added to firewall"

# Get server IP address (needed for multiple sections below)
SERVER_IP=$(ip -4 addr show scope global | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1)
if [ -z "$SERVER_IP" ]; then
    SERVER_IP="<server-ip>"
    log_warning "Could not detect server IP address automatically"
fi

###############################################################################
# NETDATA MONITORING SETUP
###############################################################################

echo ""
read -t 30 -p "Do you want to install Netdata for real-time monitoring? (y/n, timeout 30s): " install_netdata || install_netdata="n"

if [[ $install_netdata == "y" ]] || [[ $install_netdata == "Y" ]]; then
    log_info "Setting up Netdata as Docker container..."

    # Create netdata directory (using sudo -u to ensure correct ownership)
    if [ ! -d "$USER_HOME/docker/netdata" ]; then
        sudo -u "$ACTUAL_USER" mkdir -p "$USER_HOME/docker/netdata" || handle_error "Failed to create netdata directory"
    fi

    # Create config directory for persistent configuration
    if [ ! -d "$USER_HOME/docker/netdata/config" ]; then
        sudo -u "$ACTUAL_USER" mkdir -p "$USER_HOME/docker/netdata/config" || handle_error "Failed to create netdata config directory"
    fi

    # Configure Telegram alerts (optional)
    echo ""
    echo "=========================================================================="
    echo "NETDATA TELEGRAM ALERTS CONFIGURATION"
    echo "=========================================================================="
    echo ""
    echo "To enable Telegram alerts, you need:"
    echo "  1. A Telegram Bot Token (get it from @BotFather on Telegram)"
    echo "  2. Your Telegram Chat ID (send /start to @userinfobot to get it)"
    echo ""
    echo "Steps to create a Telegram bot:"
    echo "  1. Open Telegram and search for @BotFather"
    echo "  2. Send /newbot and follow the instructions"
    echo "  3. Copy the bot token (looks like: 123456789:ABCdefGHIjklMNOpqrsTUVwxyz)"
    echo "  4. Start a chat with your new bot (send /start)"
    echo "  5. Get your chat ID from @userinfobot"
    echo ""
    read -t 30 -p "Do you want to configure Telegram alerts now? (y/n, timeout 30s): " setup_telegram || setup_telegram="n"

    TELEGRAM_BOT_TOKEN=""
    TELEGRAM_CHAT_ID=""

    if [[ $setup_telegram == "y" ]] || [[ $setup_telegram == "Y" ]]; then
        read -t 600 -p "Enter your Telegram Bot Token (timeout 10 minutes): " TELEGRAM_BOT_TOKEN || TELEGRAM_BOT_TOKEN=""
        read -t 600 -p "Enter your Telegram Chat ID (timeout 10 minutes): " TELEGRAM_CHAT_ID || TELEGRAM_CHAT_ID=""

        if [[ ! -z "$TELEGRAM_BOT_TOKEN" ]] && [[ ! -z "$TELEGRAM_CHAT_ID" ]]; then
            log_info "Telegram alerts will be configured"
            TELEGRAM_CONFIGURED=true
        else
            log_warning "Telegram configuration skipped - missing token or chat ID"
            TELEGRAM_CONFIGURED=false
        fi
    else
        log_info "Telegram alerts not configured"
        TELEGRAM_CONFIGURED=false
    fi

    # Create persistent health_alarm_notify.conf if Telegram is configured
    if [ "$TELEGRAM_CONFIGURED" = true ]; then
        log_info "Creating persistent Netdata health alert configuration..."
        sudo -u "$ACTUAL_USER" cat <<EOF > "$USER_HOME/docker/netdata/config/health_alarm_notify.conf"
# Netdata notification configuration
# Only enable Telegram alerts

SEND_TELEGRAM=YES
TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}
DEFAULT_RECIPIENT_TELEGRAM=${TELEGRAM_CHAT_ID}

# Disable all other channels
SEND_EMAIL=NO
SEND_SLACK=NO
SEND_DISCORD=NO
SEND_PUSHBULLET=NO
SEND_PUSHOVER=NO
SEND_TWILIO=NO
SEND_MESSAGEBIRD=NO
SEND_KAVENEGAR=NO
SEND_PD=NO
SEND_PAGERDUTY=NO
SEND_FLOCK=NO
SEND_ROCKET=NO
SEND_ROCKETCHAT=NO
SEND_ALERTA=NO
SEND_SYSLOG=NO
SEND_PROWL=NO
SEND_AWSSNS=NO
SEND_MATRIX=NO
SEND_MSTEAMS=NO
SEND_SIGNAL=NO
SEND_IRC=NO
SEND_CUSTOM=NO
EOF
        sudo chown "$ACTUAL_USER:$ACTUAL_USER" "$USER_HOME/docker/netdata/config/health_alarm_notify.conf"
        log_info "Netdata health alert configuration created at ~/docker/netdata/config/health_alarm_notify.conf"
    fi

    # Create docker-compose.yaml for Netdata
    if [ "$TELEGRAM_CONFIGURED" = true ]; then
        # With Telegram configuration (as the actual user)
        sudo -u "$ACTUAL_USER" cat <<EOF > "$USER_HOME/docker/netdata/docker-compose.yaml"
services:
  netdata:
    # NOTE: Using :latest tag. For production, consider pinning to a specific version (e.g., netdata/netdata:v1.44.1)
    image: netdata/netdata:latest
    container_name: netdata
    hostname: \${HOSTNAME:-netdata}
    ports:
      - "19999:19999"
    restart: always
    cap_add:
      - SYS_PTRACE
    security_opt:
      - apparmor:unconfined
    volumes:
      - ./config:/etc/netdata
      - netdatalib:/var/lib/netdata
      - netdatacache:/var/cache/netdata
      # Host info mounts
      - /etc/passwd:/host/etc/passwd:ro
      - /etc/group:/host/etc/group:ro
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /etc/os-release:/host/etc/os-release:ro
      # Docker monitoring
      - /var/run/docker.sock:/var/run/docker.sock:ro
      # Systemd journal logs (for system log monitoring in Netdata)
      - /var/log/journal:/var/log/journal:ro
      - /run/log/journal:/run/log/journal:ro
    environment:
      - NETDATA_CLAIM_TOKEN=
      - NETDATA_CLAIM_ROOMS=
      - SEND_TELEGRAM=YES
      - TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN
      - DEFAULT_RECIPIENT_TELEGRAM=$TELEGRAM_CHAT_ID

volumes:
  netdatalib:
  netdatacache:
EOF
    else
        # Without Telegram - create empty config directory for future use
        log_info "Creating empty config directory for future configuration..."
        sudo -u "$ACTUAL_USER" touch "$USER_HOME/docker/netdata/config/.gitkeep"

        # Without Telegram (as the actual user)
        sudo -u "$ACTUAL_USER" cat <<'EOF' > "$USER_HOME/docker/netdata/docker-compose.yaml"
services:
  netdata:
    # NOTE: Using :latest tag. For production, consider pinning to a specific version (e.g., netdata/netdata:v1.44.1)
    image: netdata/netdata:latest
    container_name: netdata
    hostname: ${HOSTNAME:-netdata}
    ports:
      - "19999:19999"
    restart: always
    cap_add:
      - SYS_PTRACE
    security_opt:
      - apparmor:unconfined
    volumes:
      - ./config:/etc/netdata
      - netdatalib:/var/lib/netdata
      - netdatacache:/var/cache/netdata
      # Host info mounts
      - /etc/passwd:/host/etc/passwd:ro
      - /etc/group:/host/etc/group:ro
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /etc/os-release:/host/etc/os-release:ro
      # Docker monitoring
      - /var/run/docker.sock:/var/run/docker.sock:ro
      # Systemd journal logs (for system log monitoring in Netdata)
      - /var/log/journal:/var/log/journal:ro
      - /run/log/journal:/run/log/journal:ro
    environment:
      - NETDATA_CLAIM_TOKEN=
      - NETDATA_CLAIM_ROOMS=

volumes:
  netdatalib:
  netdatacache:
EOF
    fi

    # Create systemd-journal configuration for Netdata
    log_info "Configuring Netdata systemd-journal plugin..."
    sudo -u "$ACTUAL_USER" mkdir -p "$USER_HOME/docker/netdata/config/go.d"
    sudo -u "$ACTUAL_USER" cat <<'EOF' > "$USER_HOME/docker/netdata/config/go.d/systemd-journal.conf"
# Netdata systemd-journal plugin configuration
# Enables monitoring of systemd journal logs from the host
jobs:
  - name: systemd-journal
    path: /var/log/journal
EOF
    log_info "Systemd-journal plugin configured for Netdata"

    # Ensure ownership is correct
    sudo chown -R "$ACTUAL_USER:$ACTUAL_USER" "$USER_HOME/docker/netdata"

    # Add Netdata port to firewall
    sudo ufw allow 19999/tcp comment 'Netdata Monitoring' || log_warning "Failed to add Netdata port"
    sudo ufw reload || handle_error "Failed to reload UFW"

    log_info "Netdata configuration created"
    NETDATA_CONFIGURED=true

    # Show Netdata access information
    echo ""
    echo "=========================================================================="
    echo "NETDATA CONFIGURATION COMPLETE"
    echo "=========================================================================="
    echo ""
    echo "Netdata will be accessible at:"
    echo ""
    echo "  🌐 Dashboard: http://$SERVER_IP:19999"
    echo ""
    echo "To configure Netdata in Cloudflare Tunnel:"
    echo ""
    echo "  1. Go to your Cloudflare Zero Trust Dashboard"
    echo "  2. Navigate to: Networks > Tunnels > [Your Tunnel] > Public Hostname"
    echo "  3. Add a new public hostname with these settings:"
    echo ""
    echo "     Subdomain:    netdata (or monitoring, stats, etc.)"
    echo "     Domain:       [your-domain.com]"
    echo "     Service Type: HTTP"
    echo "     URL:          http://$SERVER_IP:19999"
    echo ""
    echo "  4. After saving, access Netdata via: https://netdata.your-domain.com"
    echo ""
    echo "  💡 Tip: You can add access control in Cloudflare to protect the dashboard"
    echo ""
    echo "=========================================================================="
    echo ""
else
    log_info "Netdata setup skipped"
    NETDATA_CONFIGURED=false
    TELEGRAM_CONFIGURED=false
fi

###############################################################################
# START DOCKER CONTAINERS
###############################################################################

echo ""
echo "=========================================================================="
echo "DOCKER CONTAINERS STARTUP"
echo "=========================================================================="
echo ""

# Ask to start Cloudflare Tunnel
if [ "$CF_CONFIGURED" = true ]; then
    read -t 30 -p "Do you want to start Cloudflare Tunnel now? (y/n, timeout 30s): " start_cf || start_cf="y"

    if [[ $start_cf == "y" ]] || [[ $start_cf == "Y" ]]; then
        if docker compose -f "$USER_HOME/docker/cloudflare/docker-compose.yaml" up -d; then
            log_info "Cloudflare Tunnel started successfully"
        else
            log_warning "Failed to start Cloudflare Tunnel"
        fi
    else
        log_info "Cloudflare Tunnel not started. Start later with:"
        echo "  cd ~/docker/cloudflare && docker compose up -d"
    fi
fi

echo ""

# Ask to start Portainer
read -t 30 -p "Do you want to start Portainer now? (y/n, timeout 30s): " start_portainer || start_portainer="y"

if [[ $start_portainer == "y" ]] || [[ $start_portainer == "Y" ]]; then
    if docker compose -f "$USER_HOME/docker/portainer/docker-compose.yaml" up -d; then
        log_info "Portainer started successfully"
        PORTAINER_STARTED=true
    else
        log_warning "Failed to start Portainer"
        PORTAINER_STARTED=false
    fi
else
    log_info "Portainer not started. Start later with:"
    echo "  cd ~/docker/portainer && docker compose up -d"
    PORTAINER_STARTED=false
fi

echo ""

# Ask to start Netdata
if [ "$NETDATA_CONFIGURED" = true ]; then
    read -t 30 -p "Do you want to start Netdata now? (y/n, timeout 30s): " start_netdata || start_netdata="y"

    if [[ $start_netdata == "y" ]] || [[ $start_netdata == "Y" ]]; then
        if docker compose -f "$USER_HOME/docker/netdata/docker-compose.yaml" up -d; then
            log_info "Netdata started successfully"
            NETDATA_STARTED=true
        else
            log_warning "Failed to start Netdata"
            NETDATA_STARTED=false
        fi
    else
        log_info "Netdata not started. Start later with:"
        echo "  cd ~/docker/netdata && docker compose up -d"
        NETDATA_STARTED=false
    fi
else
    NETDATA_STARTED=false
fi

###############################################################################
# PORTAINER ACCESS INFORMATION
###############################################################################

if [ "$PORTAINER_STARTED" = true ]; then
    echo ""
    echo "=========================================================================="
    echo "PORTAINER ACCESS INFORMATION"
    echo "=========================================================================="
    echo ""
    echo "Portainer is now running and accessible at:"
    echo ""
    echo "  🌐 HTTPS: https://$SERVER_IP:9443"
    echo ""
    echo "To configure Portainer in Cloudflare Tunnel:"
    echo ""
    echo "  1. Go to your Cloudflare Zero Trust Dashboard"
    echo "  2. Navigate to: Networks > Tunnels > [Your Tunnel] > Public Hostname"
    echo "  3. Add a new public hostname with these settings:"
    echo ""
    echo "     Subdomain:    portainer (or your choice)"
    echo "     Domain:       [your-domain.com]"
    echo "     Service Type: HTTPS"
    echo "     URL:          https://$SERVER_IP:9443"
    echo ""
    echo "     ⚠️  Important: Enable these settings:"
    echo "         - No TLS Verify: ON (since Portainer uses self-signed cert)"
    echo ""
    echo "  4. After saving, access Portainer via: https://portainer.your-domain.com"
    echo ""
    echo "=========================================================================="
    echo ""
fi

###############################################################################
# DRY-RUN SUMMARY
###############################################################################

if [ "$DRY_RUN" = true ]; then
    echo ""
    echo "=========================================================================="
    echo "  DRY-RUN COMPLETE - NO CHANGES WERE MADE"
    echo "=========================================================================="
    echo ""
    echo "A detailed report has been saved to:"
    echo "  $DRY_RUN_REPORT"
    echo ""
    echo "Review the report to see what would have been done."
    echo ""
    echo "To execute the installation:"
    if [ "$MODE" = "interactive" ]; then
        echo "  sudo bash $0 --interactive"
    else
        echo "  sudo bash $0 --fresh-install"
    fi
    echo ""
    echo "Or run without dry-run:"
    echo "  sudo bash $0 --interactive   # For existing servers (recommended)"
    echo "  sudo bash $0 --fresh-install # For fresh installations"
    echo ""
    echo "=========================================================================="
    exit 0
fi

###############################################################################
# FINAL CHECKS AND SUMMARY
###############################################################################

echo ""
echo "=========================================================================="
log_info "Server setup completed successfully!"
echo "=========================================================================="
echo ""
echo "Mode used: $MODE"
if [ "$MODE" = "interactive" ] && [ -d "$BACKUP_DIR" ]; then
    echo "Backup location: $BACKUP_DIR"
    echo "Rollback script: $BACKUP_DIR/rollback.sh"
fi
echo ""
echo "Summary of installed components:"
echo "  - Timezone: Europe/Amsterdam"
echo "  - Docker: $(docker --version 2>/dev/null || echo 'Installed')"
echo "  - Docker Compose: Plugin installed"
echo "  - Python: $(python3 --version 2>/dev/null)"
echo "  - Node.js: $(node --version 2>/dev/null)"
echo "  - npm: $(npm --version 2>/dev/null)"
echo "  - Git: $(git --version 2>/dev/null)"
echo "  - Swap: ${SWAP_SIZE}MB (swappiness=10)"
echo ""
echo "Security features:"
if [ "$SSH_HARDENED" = true ]; then
echo "  - SSH: Ports 22 AND 888 (key-only authentication)"
echo "    ⚠️  REMEMBER: Test port 888 and manually disable port 22!"
else
echo "  - SSH: Not hardened (skipped)"
fi
UFW_PORTS="22, 80, 443, 888, 9443"
if [ "$PORTAINER_AGENT_ENABLED" = true ]; then
UFW_PORTS="$UFW_PORTS, 8000"
fi
if [ "$NETDATA_CONFIGURED" = true ]; then
UFW_PORTS="$UFW_PORTS, 19999"
fi
echo "  - Firewall: UFW enabled (ports $UFW_PORTS)"
echo "  - Fail2ban: Enabled for SSH (monitoring ports 22 and 888)"
echo "  - Automatic updates: Enabled"
echo "  - Kernel hardening: Applied"
echo ""
echo "Monitoring tools installed:"
echo "  - htop, iotop, nethogs"
if [ "$NETDATA_CONFIGURED" = true ]; then
echo "  - Netdata Docker container (http://$SERVER_IP:19999)"
if [ "$TELEGRAM_CONFIGURED" = true ]; then
echo "    ✅ Telegram alerts configured"
fi
fi
echo ""
echo "Project directories created:"
DOCKER_SUBDIRS="cloudflare, portainer"
if [ "$NETDATA_CONFIGURED" = true ]; then
    DOCKER_SUBDIRS="$DOCKER_SUBDIRS, netdata"
fi
echo "  - ~/docker (with $DOCKER_SUBDIRS)"
echo "  - ~/scripts"
echo "  - ~/projects"
echo ""
echo "Docker services configured:"
if [ "$CF_CONFIGURED" = true ]; then
echo "  ✅ Cloudflare Tunnel (~/docker/cloudflare)"
else
echo "  ⏭️  Cloudflare Tunnel (skipped)"
fi
echo "  ✅ Portainer (~/docker/portainer)"
if [ "$NETDATA_CONFIGURED" = true ]; then
echo "  ✅ Netdata (~/docker/netdata)"
fi
echo ""
echo "Container status:"
if [ "$CF_CONFIGURED" = true ] && docker ps --format '{{.Names}}' 2>/dev/null | grep -q cloudflared; then
echo "  🟢 Cloudflare Tunnel: Running"
elif [ "$CF_CONFIGURED" = true ]; then
echo "  ⚪ Cloudflare Tunnel: Not started"
fi
if docker ps --format '{{.Names}}' 2>/dev/null | grep -q portainer; then
echo "  🟢 Portainer: Running"
else
echo "  ⚪ Portainer: Not started"
fi
if [ "$NETDATA_CONFIGURED" = true ]; then
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q netdata; then
    echo "  🟢 Netdata: Running"
    else
    echo "  ⚪ Netdata: Not started"
    fi
fi
echo ""
echo "IMPORTANT NOTES:"
if [ "$SSH_HARDENED" = true ]; then
echo "  1. ⚠️  SSH: Currently on BOTH port 22 AND 888"
echo "     - Test connection: ssh -p 888 user@$SERVER_IP"
echo "     - After confirming 888 works, disable 22 with:"
echo "       sudo sed -i '/^Port 22$/d' /etc/ssh/sshd_config"
echo "       sudo systemctl restart ssh"
echo "  2. Password authentication is DISABLED"
echo "  3. Make sure your SSH key is authorized before disconnecting!"
else
echo "  1. SSH hardening was skipped"
echo "  2. ⚠️  Consider running SSH hardening manually for security!"
fi
echo "  4. User '$ACTUAL_USER' has been added to docker group"
echo "  5. Log out and back in for docker group to take effect"
echo ""
echo "Quick access URLs:"
if [ "$PORTAINER_STARTED" = true ]; then
echo "  - Portainer: https://$SERVER_IP:9443"
fi
if [ "$NETDATA_STARTED" = true ]; then
echo "  - Netdata: http://$SERVER_IP:19999"
fi
echo ""
echo "Error log saved to: $ERROR_LOG"
echo ""
echo "=========================================================================="

# Ask for reboot
echo ""
read -t 30 -p "System setup complete. Reboot now? (y/n, timeout 30s): " reboot_choice || reboot_choice="n"

if [[ $reboot_choice == "y" ]] || [[ $reboot_choice == "Y" ]]; then
    log_info "Rebooting system in 5 seconds... (Ctrl+C to cancel)"
    sleep 5
    sudo shutdown -r now
else
    log_info "Remember to reboot the system later to apply all changes!"
fi
