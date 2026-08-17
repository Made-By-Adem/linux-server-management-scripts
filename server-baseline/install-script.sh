#!/bin/bash

###############################################################################
# System Installation & Hardening Script
# For Ubuntu/Debian/Kali servers and desktops (including Raspberry Pi)
# Version: 3.1 - Interactive & Safe for Existing Servers + Desktop Mode
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
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m' # No Color

# Script modes
MODE=""  # Will be set to: fresh-install, interactive, or dry-run
DRY_RUN=false
SECTION_SELECT=false  # Set to true when --section is used
SELECTED_SECTIONS=()  # Array to store selected section IDs
CLOUDFLARE_ONLY=false  # When true, all Docker services bind to 127.0.0.1 and are only accessible via Cloudflare Tunnel
DESKTOP_MODE=false     # When true, adapts script for Ubuntu Desktop (less restrictive security, desktop-friendly defaults)

# Resolve this script's own location ONCE, before anything changes directory.
# Several sections cd elsewhere (the Lynis install goes to /usr/local and never
# comes back), after which any path derived from a relative $0 resolves against
# the wrong directory - silently. That put the credential file in /usr/.env and
# made the bundled reporters "not found".
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Get the actual user (the one who ran sudo)
# If running as root directly (not via sudo), find the first regular user
ACTUAL_USER="${SUDO_USER:-}"

if [ -z "$ACTUAL_USER" ] || [ "$ACTUAL_USER" = "root" ]; then
    # Not running via sudo, or SUDO_USER is root
    # Find the first regular user (UID >= 1000, has a home in /home/)
    ACTUAL_USER=$(awk -F: '$3 >= 1000 && $6 ~ /^\/home\// {print $1; exit}' /etc/passwd)

    if [ -z "$ACTUAL_USER" ]; then
        # Fallback: use current user
        ACTUAL_USER="${USER:-$(whoami)}"
    fi
fi

# Get the user's home directory
# Try multiple methods for compatibility across Ubuntu, Debian, and Raspberry Pi
if [ -n "$ACTUAL_USER" ] && [ "$ACTUAL_USER" != "root" ]; then
    # Method 1: Try getent if available (most reliable on modern systems)
    if command -v getent &>/dev/null; then
        USER_HOME=$(getent passwd "$ACTUAL_USER" 2>/dev/null | cut -d: -f6)
    fi

    # Method 2: Fallback to /etc/passwd if getent not available or failed
    if [ -z "${USER_HOME:-}" ] || [ "$USER_HOME" = "/" ]; then
        USER_HOME=$(grep "^$ACTUAL_USER:" /etc/passwd 2>/dev/null | cut -d: -f6)
    fi

    # Method 3: Final fallback using tilde expansion
    if [ -z "${USER_HOME:-}" ] || [ "$USER_HOME" = "/" ]; then
        USER_HOME=$(eval echo ~"$ACTUAL_USER")
    fi
else
    # Running as root with no regular user account - common on a freshly built
    # cloud server reached over an SSH key.
    #
    # The service directories go under /home, not /root. /root is mode 700 and
    # is the administrator's private directory; docker stacks, compose files and
    # backup jobs are referenced by absolute path from cron, from other hosts
    # and from this repo's own tooling. Putting them somewhere that depends on
    # which account happened to run the installer makes those paths differ
    # between servers that are otherwise identical.
    ACTUAL_USER="root"
    USER_HOME="/home"
fi

# Final check: if USER_HOME is still /root but we have a regular user, fix it
if [ "$USER_HOME" = "/root" ] && [ "$ACTUAL_USER" != "root" ]; then
    USER_HOME="/home/$ACTUAL_USER"
fi

# Verify we got a valid home directory
if [ -z "${USER_HOME:-}" ] || [ "$USER_HOME" = "/" ]; then
    USER_HOME="/home/$ACTUAL_USER"
fi

# Log the detected user for transparency
echo "Detected user: $ACTUAL_USER (home: $USER_HOME)"

# Get server IP address (needed for multiple sections below)
SERVER_IP=$(ip -4 addr show scope global | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1)
if [ -z "$SERVER_IP" ]; then
    SERVER_IP="<server-ip>"
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
  --section          Select specific sections to run (shows interactive menu)
  --dry-run          Show what would be done without making changes
  --verify           Change nothing; only check whether the controls WORK

Options:
  --desktop            Adapt for Ubuntu Desktop (keeps password auth, USB, printing)
  --help               Show this help message

Examples:
  sudo bash $0 --fresh-install
  sudo bash $0 --interactive
  sudo bash $0 --section
  sudo bash $0 --section --dry-run
  sudo bash $0 --dry-run
  sudo bash $0 --verify
  sudo bash $0 --fresh-install --desktop
  sudo bash $0 --interactive --desktop --dry-run

About --verify:
  Installing a control and having it work are different things. This mode
  installs nothing and asks only whether each control produces a result:
  is fail2ban banning (not just running), is sshd listening on the expected
  port only, does auditd have rules loaded, is anything on 0.0.0.0 that does
  not belong there, does 'aide --check' complete, has PATH been hijacked.

  Read-only and safe on production. Run it monthly, and after every change.
  Exit codes: 0 = all passed, 1 = at least one failure, 2 = warnings only.

Note: If no mode is specified, the script will auto-detect based on existing installations.
Desktop mode skips server-only features (Telegram, Cloudflare, AIDE) and uses desktop-friendly defaults.
EOF
    exit 0
}

# --verify delegates to security-selfcheck.sh so there is exactly one
# implementation of "does this control actually work". Kept next to this script.
run_verify_mode() {
    local selfcheck="$SCRIPT_DIR/security-selfcheck.sh"

    if [ ! -f "$selfcheck" ]; then
        echo -e "${RED}Error: security-selfcheck.sh not found at $selfcheck${NC}" >&2
        echo "It ships alongside this script; re-clone or copy it across." >&2
        exit 1
    fi

    exec sudo bash "$selfcheck" "$@"
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
            --section)
                MODE="interactive"
                SECTION_SELECT=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --verify)
                # Handled immediately: this mode changes nothing and must not
                # fall through into the installation flow.
                shift
                run_verify_mode "$@"
                ;;
            --desktop)
                DESKTOP_MODE=true
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

    # Check for custom SSH config (server only — desktop never uses port 888)
    if [ "$DESKTOP_MODE" = false ] && grep -q "^Port 888" /etc/ssh/sshd_config 2>/dev/null; then
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
    return 0  # Always return 0 to prevent set -e exit; caller checks output string
}

# Function to show section selection menu
show_section_menu() {
    echo ""
    echo "══════════════════════════════════════════════════════════════"
    echo "  Section Selection Menu"
    echo "══════════════════════════════════════════════════════════════"
    echo ""
    echo "Available sections:"
    echo ""
    echo "  1. system-update           - System package updates"
    echo "  2. hostname                - Configure hostname"
    echo "  3. timezone                - Configure timezone"
    echo "  4. swap                    - Configure swap file"
    echo "  5. dev-environment         - Install development tools (Python, Node.js, Git)"
    echo "  6. docker                  - Install Docker & Docker Compose"
    echo "  7. security-repository     - Add security package repository"
    echo "  8. password-hardening      - Password & authentication hardening"
    echo "  9. deprecated-cleanup      - Remove deprecated packages"
    echo " 10. kernel-hardening        - Kernel security hardening"
    echo " 11. core-dump-disable       - Disable core dumps"
    echo " 12. umask-hardening         - Umask security hardening"
    echo " 13. ssh-hardening           - SSH configuration & hardening"
    echo " 14. ufw-firewall            - UFW firewall configuration"
    echo " 15. fail2ban                - Install & configure Fail2ban"
    echo " 16. lynis                   - Install Lynis security auditing"
    echo " 17. rkhunter                - Install & configure Rkhunter"
    echo " 18. systemd-hardening       - Systemd service hardening"
    echo " 19. audit-logging           - Audit logging configuration"
    echo " 20. netdata                 - Install Netdata monitoring"
    echo " 21. portainer               - Install Portainer"
    if [ "$DESKTOP_MODE" = true ]; then
        echo " 22. cloudflare-tunnel       - Configure Cloudflare Tunnel       [server only — skipped]"
        echo " 23. telegram                - Configure Telegram notifications   [server only — skipped]"
        echo " 24. legal-banners           - Legal warning banners              [server only — skipped]"
        echo " 25. custom-motd             - Custom MOTD (Message of the Day)   [server only — skipped]"
    else
        echo " 22. cloudflare-tunnel       - Configure Cloudflare Tunnel"
        echo " 23. telegram                - Configure Telegram notifications"
        echo " 24. legal-banners           - Legal warning banners"
        echo " 25. custom-motd             - Custom MOTD (Message of the Day)"
    fi
    echo ""
    echo "Enter section numbers separated by spaces (e.g., 1 3 18)"
    echo "Or press ENTER to cancel"
    echo ""
    read -p "Select sections: " selection

    if [ -z "$selection" ]; then
        echo "Selection canceled"
        return 1
    fi

    # Map numbers to section keys
    declare -A section_map=(
        [1]="system-update"
        [2]="hostname"
        [3]="timezone"
        [4]="swap"
        [5]="dev-environment"
        [6]="docker"
        [7]="security-repository"
        [8]="password-hardening"
        [9]="deprecated-cleanup"
        [10]="kernel-hardening"
        [11]="core-dump-disable"
        [12]="umask-hardening"
        [13]="ssh-hardening"
        [14]="ufw-firewall"
        [15]="fail2ban"
        [16]="lynis"
        [17]="rkhunter"
        [18]="systemd-hardening"
        [19]="audit-logging"
        [20]="netdata"
        [21]="portainer"
        [22]="cloudflare-tunnel"
        [23]="telegram"
        [24]="legal-banners"
        [25]="custom-motd"
    )

    # Parse selection
    SELECTED_SECTIONS=()
    for num in $selection; do
        if [ -n "${section_map[$num]}" ]; then
            local section_key="${section_map[$num]}"
            if [ "$DESKTOP_MODE" = true ]; then
                case "$section_key" in
                    "cloudflare-tunnel"|"telegram"|"legal-banners"|"custom-motd")
                        log_warning "Section '$section_key' is server only, skipping in desktop mode"
                        continue
                        ;;
                esac
            fi
            SELECTED_SECTIONS+=("$section_key")
        else
            log_warning "Invalid section number: $num"
        fi
    done

    if [ ${#SELECTED_SECTIONS[@]} -eq 0 ]; then
        echo "No valid sections selected"
        return 1
    fi

    echo ""
    log_info "Selected sections: ${SELECTED_SECTIONS[*]}"
    echo ""
    read -p "Proceed with these sections? (Y/n): " confirm
    confirm=${confirm:-y}

    if [[ ! $confirm =~ ^[Yy]$ ]]; then
        echo "Selection canceled"
        SELECTED_SECTIONS=()
        return 1
    fi

    return 0
}

# Function to ask user for component installation with context
ask_component_install() {
    local component_name="$1"
    local component_key="$2"
    local description="$3"
    local implications="$4"
    local default="${5:-y}"  # Default to 'y' if not specified

    # Desktop mode: auto-skip server-only components
    if [ "$DESKTOP_MODE" = true ]; then
        case "$component_key" in
            "cloudflare-tunnel"|"cloudflare-token"|"telegram"|"legal-banners"|"custom-motd"|"compiler-restrictions"|"aide")
                log_info "$component_name skipped (desktop mode — server only)"
                return 1
                ;;
        esac
    fi

    # In dry-run mode, just log and return yes
    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Would ask about: $component_name"
        return 0
    fi

    # In section-select mode, check if this section is selected
    if [ "$SECTION_SELECT" = true ]; then
        # If SELECTED_SECTIONS is empty, skip everything (user canceled)
        if [ ${#SELECTED_SECTIONS[@]} -eq 0 ]; then
            return 1
        fi

        # Check if this component_key is in selected sections
        local found=false
        for section in "${SELECTED_SECTIONS[@]}"; do
            if [ "$section" = "$component_key" ]; then
                found=true
                break
            fi
        done

        if [ "$found" = false ]; then
            return 1  # Skip this section
        fi
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

    # Ask user (no timeout - wait for user input)
    local answer
    read -p "Proceed with this component? (Y/n, default: $default): " answer
    answer=${answer:-$default}

    if [[ $answer =~ ^[Yy]$ ]] || [[ -z "$answer" ]]; then
        return 0
    else
        log_info "$component_name skipped by user"
        return 1
    fi
}

# Simple prompt function for yes/no questions
# Usage: prompt_user "Question text" "default_answer"
prompt_user() {
    local prompt_text="$1"
    local default="${2:-y}"

    # In dry-run mode, just return yes
    if [ "$DRY_RUN" = true ]; then
        return 0
    fi

    # In fresh-install mode, use defaults without asking
    if [ "$MODE" = "fresh-install" ]; then
        if [[ "$default" =~ ^[Yy]$ ]]; then
            return 0
        else
            return 1
        fi
    fi

    # Interactive mode: show prompt and ask
    echo ""
    echo "=========================================================================="
    echo "$prompt_text"
    echo "=========================================================================="
    echo ""

    local answer
    read -p "Proceed? (Y/n, default: $default): " answer
    answer=${answer:-$default}

    if [[ $answer =~ ^[Yy]$ ]] || [[ -z "$answer" ]]; then
        return 0
    else
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
if [ "$DESKTOP_MODE" = true ]; then
    echo "  System Installation & Hardening Script v3.1 (Desktop Mode)"
else
    echo "  System Installation & Hardening Script v3.1"
fi
echo "=========================================================================="
echo ""

# Privilege check.
#
# Running as root does not guarantee that `sudo` works. On a freshly rebuilt
# server reached over an SSH key, the root account often has no usable password,
# and sudo then tries to authenticate, fails, and asks to change the password -
# "Authentication token manipulation error". Demanding sudo from a root shell
# turns a working situation into a blocked one.
#
# When already root, replace sudo with a shim so the script never depends on it.
if [ "$(id -u)" -eq 0 ] && ! sudo -n true 2>/dev/null; then
    echo -e "${YELLOW}[INFO]${NC} Running as root; sudo is unusable on this host, bypassing it"

    sudo() {
        local run_as=""
        while [ $# -gt 0 ]; do
            case "$1" in
                -u) run_as="$2"; shift 2 ;;
                -u*) run_as="${1#-u}"; shift ;;
                -E|-H|-n) shift ;;   # meaningless when already root
                --) shift; break ;;
                *) break ;;
            esac
        done

        if [ -n "$run_as" ]; then
            # runuser is util-linux, always present, and needs no authentication
            runuser -u "$run_as" -- "$@"
        else
            "$@"
        fi
    }
    export -f sudo 2>/dev/null || true
fi

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

# Auto-detect mode if not specified
if [ -z "$MODE" ]; then
    if [ "$DRY_RUN" = true ]; then
        # In dry-run mode, default to fresh-install to show full preview
        MODE="fresh-install"
        log_info "No mode specified, using fresh-install mode for dry-run preview"
    else
        echo -e "${YELLOW}No mode specified.${NC}"
        echo ""
        show_usage
    fi
fi

# Show section selection menu if --section was used
if [ "$SECTION_SELECT" = true ]; then
    if ! show_section_menu; then
        log_info "Script canceled by user"
        exit 0
    fi
fi

# Show current mode
case "$MODE" in
    "fresh-install")
        log_info "Mode: FRESH INSTALL (minimal prompts)"
        ;;
    "interactive")
        if [ "$SECTION_SELECT" = true ]; then
            log_info "Mode: SECTION SELECT (running selected sections only)"
        else
            log_warning "Mode: INTERACTIVE (confirmation required for each component)"
        fi
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
    read -p "Choose option [1/2/3] (default: 1): " resume_choice
    resume_choice=${resume_choice:-1}

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

# Check that the package manager is in a usable state.
#
# An interrupted dpkg transaction makes every subsequent apt call fail. Without
# this check the script carries on regardless, reporting a long list of failed
# package installs that all share one cause and none of which say what it is -
# which is how twenty minutes get spent on the wrong problem.
if [ "$DRY_RUN" != true ]; then
    log_info "Checking package manager state..."
    if ! DEBIAN_FRONTEND=noninteractive sudo dpkg --audit >/dev/null 2>&1 || \
       [ -n "$(ls -A /var/lib/dpkg/updates/ 2>/dev/null)" ] || \
       sudo apt-get check 2>&1 | grep -q 'dpkg was interrupted'; then

        log_warning "dpkg is in an interrupted state - every package install will fail"
        echo ""
        echo "This usually means a previous transaction was cut short, often by a"
        echo "configuration dialog that was closed or answered unexpectedly."
        echo ""
        echo "The repair runs with DEBIAN_FRONTEND=noninteractive, so any pending"
        echo "dialog takes its default answer. For the GRUB removal question that"
        echo "default is 'No', which is the safe one."
        echo ""
        read -p "Repair it now with 'dpkg --configure -a'? (Y/n): " fix_dpkg
        fix_dpkg=${fix_dpkg:-y}

        if [[ $fix_dpkg =~ ^[Yy]$ ]]; then
            DEBIAN_FRONTEND=noninteractive sudo dpkg --configure -a || \
                log_warning "dpkg --configure -a reported problems"
            DEBIAN_FRONTEND=noninteractive sudo apt-get -f install -y >/dev/null 2>&1 || true

            if sudo apt-get check >/dev/null 2>&1; then
                log_info "✓ Package manager repaired"
            else
                handle_error "Package manager is still broken. Fix it by hand before re-running: sudo dpkg --configure -a"
            fi
        else
            handle_error "Cannot continue with a broken package manager. Run: sudo dpkg --configure -a"
        fi
    else
        log_info "Package manager state is clean"
    fi
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
    "y"; then

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
# HOSTNAME FQDN CONFIGURATION
###############################################################################

if ! check_component_status "HOSTNAME_FQDN"; then
    if prompt_user \
    "Configure hostname with FQDN (Fully Qualified Domain Name)?

A properly configured FQDN improves system identification and security.

Configuration:
• Sets hostname to include .local domain (e.g., server.local)
• Updates /etc/hosts with FQDN mapping
• Required for proper DNS resolution
• Improves Lynis security score

Benefits:
• Better system identification in logs and monitoring
• Required for some services (mail servers, certificates)
• Prevents hostname resolution warnings
• Compliance with networking best practices

Current hostname: $(hostname)
Current FQDN: $(hostname --fqdn 2>/dev/null || echo 'not set')

Lynis recommendation: NAME-4404" \
    "y"; then

    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Would configure hostname with .local FQDN"
        log_dry_run "Would update /etc/hosts with FQDN entry"
    else
        CURRENT_HOSTNAME=$(hostname)

        # Check if hostname already has a domain
        if [[ "$CURRENT_HOSTNAME" == *.* ]]; then
            log_info "Hostname already has FQDN: $CURRENT_HOSTNAME"
        else
            log_info "Configuring FQDN for hostname: $CURRENT_HOSTNAME"

            # Set hostname with .local domain
            FQDN_HOSTNAME="${CURRENT_HOSTNAME}.local"
            sudo hostnamectl set-hostname "$FQDN_HOSTNAME"
            log_info "Hostname set to: $FQDN_HOSTNAME"

            # Update /etc/hosts
            # Remove old hostname entry if exists
            sudo sed -i "/127.0.1.1/d" /etc/hosts

            # Add new FQDN entry
            echo "127.0.1.1 $FQDN_HOSTNAME $CURRENT_HOSTNAME" | sudo tee -a /etc/hosts >/dev/null
            log_info "Updated /etc/hosts with FQDN entry"

            # Verify configuration
            if hostname --fqdn &>/dev/null; then
                NEW_FQDN=$(hostname --fqdn)
                log_info "FQDN configured successfully: $NEW_FQDN"
                echo ""
                echo "══════════════════════════════════════════════════════════"
                echo "Hostname: $(hostname)"
                echo "FQDN: $NEW_FQDN"
                echo "══════════════════════════════════════════════════════════"
                echo ""
            else
                log_warning "FQDN verification failed, but configuration completed"
            fi
        fi
    fi
        mark_completed "HOSTNAME_FQDN"
    else
        log_info "FQDN hostname configuration skipped"
        mark_completed "HOSTNAME_FQDN"
    fi
fi

###############################################################################
# DNS DOMAIN NAME CONFIGURATION
###############################################################################

if ! check_component_status "DNS_DOMAIN_NAME"; then
    # Check if dnsdomainname is already configured
    CURRENT_DNS_DOMAIN=$(dnsdomainname 2>/dev/null || echo "")

    if [ -n "$CURRENT_DNS_DOMAIN" ] && [ "$CURRENT_DNS_DOMAIN" != "(none)" ]; then
        log_info "DNS domain name already configured: $CURRENT_DNS_DOMAIN"
        mark_completed "DNS_DOMAIN_NAME"
    else
        if prompt_user \
    "Configure DNS domain name?

The DNS domain name (dnsdomainname) is used for hostname resolution and
service identification. Lynis recommends setting this for proper system
identification.

Configuration:
• Sets the search domain in /etc/resolv.conf
• Updates /etc/hosts with domain information
• Improves DNS resolution for local services

Current status:
• Hostname: $(hostname)
• DNS domain: ${CURRENT_DNS_DOMAIN:-not set}

Examples of domain names:
• local (for home networks)
• internal (for private networks)
• yourdomain.com (for corporate networks)

Lynis recommendation: NAME-4028" \
    "y"; then

        if [ "$DRY_RUN" = true ]; then
            log_dry_run "Would configure DNS domain name"
            log_dry_run "Would update /etc/hosts and /etc/resolv.conf"
        else
            echo ""
            echo "Enter the DNS domain name for this server."
            echo "Examples: local, internal, home.lan, company.com"
            echo ""
            read -p "DNS domain name (default: local): " DNS_DOMAIN
            DNS_DOMAIN=${DNS_DOMAIN:-local}

            log_info "Configuring DNS domain name: $DNS_DOMAIN"

            # Update /etc/hosts with domain
            CURRENT_HOSTNAME=$(hostname -s 2>/dev/null || hostname)
            FQDN_WITH_DOMAIN="${CURRENT_HOSTNAME}.${DNS_DOMAIN}"

            # Update the 127.0.1.1 line in /etc/hosts
            if grep -q "127.0.1.1" /etc/hosts; then
                sudo sed -i "s/^127.0.1.1.*/127.0.1.1 $FQDN_WITH_DOMAIN $CURRENT_HOSTNAME/" /etc/hosts
            else
                echo "127.0.1.1 $FQDN_WITH_DOMAIN $CURRENT_HOSTNAME" | sudo tee -a /etc/hosts >/dev/null
            fi
            log_info "Updated /etc/hosts with: 127.0.1.1 $FQDN_WITH_DOMAIN $CURRENT_HOSTNAME"

            # Add search domain to /etc/resolv.conf if not using systemd-resolved
            if [ ! -L /etc/resolv.conf ] || ! systemctl is-active systemd-resolved &>/dev/null; then
                # Only add if not already present
                if ! grep -q "^search.*$DNS_DOMAIN" /etc/resolv.conf 2>/dev/null; then
                    if grep -q "^search" /etc/resolv.conf 2>/dev/null; then
                        sudo sed -i "s/^search.*/search $DNS_DOMAIN/" /etc/resolv.conf
                    else
                        echo "search $DNS_DOMAIN" | sudo tee -a /etc/resolv.conf >/dev/null
                    fi
                    log_info "Added search domain to /etc/resolv.conf"
                fi
            else
                log_info "systemd-resolved detected - search domain managed by systemd"
                # For systemd-resolved, we can set the search domain via resolvectl
                if command -v resolvectl &>/dev/null; then
                    # Note: This is temporary and won't persist across reboots
                    # For persistent config, need to edit /etc/systemd/resolved.conf
                    if [ -f /etc/systemd/resolved.conf ]; then
                        if ! grep -q "^Domains=" /etc/systemd/resolved.conf; then
                            echo "Domains=$DNS_DOMAIN" | sudo tee -a /etc/systemd/resolved.conf >/dev/null
                            sudo systemctl restart systemd-resolved
                            log_info "Added search domain to systemd-resolved"
                        fi
                    fi
                fi
            fi

            # Verify configuration
            NEW_DNS_DOMAIN=$(dnsdomainname 2>/dev/null || echo "")
            if [ -n "$NEW_DNS_DOMAIN" ] && [ "$NEW_DNS_DOMAIN" != "(none)" ]; then
                log_info "DNS domain name configured successfully: $NEW_DNS_DOMAIN"
            else
                log_info "DNS domain configured in /etc/hosts (dnsdomainname may require re-login to update)"
            fi

            echo ""
            echo "══════════════════════════════════════════════════════════"
            echo "DNS Domain Configuration Summary:"
            echo "══════════════════════════════════════════════════════════"
            echo "✓ Domain: $DNS_DOMAIN"
            echo "✓ FQDN: $FQDN_WITH_DOMAIN"
            echo "✓ /etc/hosts updated"
            echo ""
            echo "Verify with: dnsdomainname"
            echo "══════════════════════════════════════════════════════════"
            echo ""
        fi
            mark_completed "DNS_DOMAIN_NAME"
        else
            log_info "DNS domain name configuration skipped"
            mark_completed "DNS_DOMAIN_NAME"
        fi
    fi
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
        "y"; then

        if [ "$DRY_RUN" = true ]; then
            log_dry_run "Would run: apt-get update"
            log_dry_run "Checking for upgradeable packages (based on current cache)..."
            log_dry_run "Note: Package list may be stale if apt-get update hasn't been run recently"
            upgradable=$(apt list --upgradable 2>/dev/null | grep -v "Listing" | wc -l || echo "0")
            if [ "$upgradable" -gt 0 ]; then
                log_dry_run "Found $upgradable packages to upgrade:"
                apt list --upgradable 2>/dev/null | grep -v "Listing" | while read line; do
                    log_dry_run "  - $line"
                done || true
            else
                log_dry_run "No packages need upgrading (based on current cache)"
            fi
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
# SECURITY REPOSITORY CONFIGURATION
###############################################################################

if skip_if_completed "SECURITY_REPOSITORY"; then
    log_info "Security repository already configured, skipping"
else
    if ask_component_install \
        "SECURITY REPOSITORY VERIFICATION" \
        "security-repository" \
        "Verify and configure security update repositories for timely security patches." \
        "Security features:
• Enables official security update repository
• Ensures critical security patches are received
• Required for automatic security updates

Repositories:
• Ubuntu: security.ubuntu.com
• Debian: security.debian.org

⚠️  Critical for production servers!" \
        "y"; then

        if [ "$DRY_RUN" = true ]; then
            log_dry_run "Would verify security repository configuration"
            log_dry_run "Would add security repository if missing"
        else
            log_info "Verifying security repository configuration..."

            # Detect OS
            if [ -f /etc/os-release ]; then
                . /etc/os-release
                OS_ID="$ID"
                OS_CODENAME="$VERSION_CODENAME"
            else
                log_warning "Cannot detect OS version"
                OS_ID="unknown"
            fi

            if [ "$OS_ID" = "ubuntu" ]; then
                # Ubuntu security repo
                if ! grep -qr "^deb.*security.ubuntu.com" /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null; then
                    log_warning "Ubuntu security repository not found, adding it..."
                    echo "deb http://security.ubuntu.com/ubuntu ${OS_CODENAME}-security main restricted universe multiverse" | \
                        sudo tee -a /etc/apt/sources.list >/dev/null
                    log_info "Added Ubuntu security repository"
                    log_info "Running apt-get update..."
                    sudo apt-get update >/dev/null 2>&1 || log_warning "apt-get update had errors"
                else
                    log_info "Ubuntu security repository already configured"
                fi
            elif [ "$OS_ID" = "debian" ]; then
                # Debian security repo
                if ! grep -qr "^deb.*security.debian.org" /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null; then
                    log_warning "Debian security repository not found, adding it..."
                    echo "deb http://security.debian.org/debian-security ${OS_CODENAME}-security main contrib non-free" | \
                        sudo tee -a /etc/apt/sources.list >/dev/null
                    log_info "Added Debian security repository"
                    log_info "Running apt-get update..."
                    sudo apt-get update >/dev/null 2>&1 || log_warning "apt-get update had errors"
                else
                    log_info "Debian security repository already configured"
                fi
            elif [ "$OS_ID" = "kali" ]; then
                log_info "Kali Linux detected - security updates included in kali-rolling repository"
            else
                log_warning "Unknown OS: $OS_ID - skipping security repository configuration"
            fi

            log_info "Security repository configuration verified"
        fi
        mark_completed "SECURITY_REPOSITORY"
    else
        log_info "Security repository verification skipped"
        mark_completed "SECURITY_REPOSITORY"
    fi
fi

###############################################################################
# INSTALL ESSENTIAL PACKAGES
###############################################################################

if ask_component_install \
    "ESSENTIAL PACKAGES INSTALLATION" \
    "essential-packages" \
    "Install essential system packages required for server management and security." \
    "Available packages:
• curl, wget - Download tools
• net-tools - Network utilities
• ufw - Firewall management
• unattended-upgrades - Automatic security updates
• ca-certificates, gnupg - Security certificates
• lsb-release, software-properties-common - Repository management
• rsyslog - System logging
• git - Version control
• htop, atop, iotop, nethogs - System monitoring tools
• tree - Directory structure visualization
• lm-sensors - Hardware monitoring (temperature, voltage, fans)
• smartmontools, nvme-cli - Disk health monitoring (SMART/NVMe diagnostics)
• fail2ban - Intrusion prevention
• libpam-tmpdir - Per-user temporary directories (security)

Note: You will be able to select individual packages in the next step" \
    "y"; then

    # Define package groups with descriptions
    # Package descriptions (short name for prompt)
    declare -A ESSENTIAL_PACKAGES=(
        ["curl"]="Download tool (curl)"
        ["wget"]="Download tool (wget)"
        ["net-tools"]="Network utilities (ifconfig, netstat, etc.)"
        ["ufw"]="Firewall management"
        ["unattended-upgrades"]="Automatic security updates"
        ["ca-certificates"]="Security certificates"
        ["gnupg"]="GPG encryption tool"
        ["lsb-release"]="Linux Standard Base version reporting"
        ["software-properties-common"]="Repository management"
        ["rsyslog"]="System logging"
        ["git"]="Version control system"
        ["htop"]="Interactive process viewer"
        ["atop"]="Advanced system and process monitor"
        ["iotop"]="I/O monitoring tool"
        ["nethogs"]="Network bandwidth monitor per process"
        ["tree"]="Directory structure visualization"
        ["lm-sensors"]="Hardware monitoring (temperature, voltage, fans)"
        ["smartmontools"]="Disk health monitoring (SMART data)"
        ["nvme-cli"]="NVMe SSD management and diagnostics"
        ["fail2ban"]="Intrusion prevention system"
        ["libpam-tmpdir"]="Per-user temporary directories (Lynis security recommendation)"
    )

    # Detailed package descriptions (shown after selection)
    declare -A PACKAGE_DETAILS=(
        ["curl"]="Command-line tool for transferring data with URLs. Essential for downloading files, testing APIs, and scripting web requests."
        ["wget"]="Non-interactive network downloader. Supports recursive downloads, resuming interrupted transfers, and mirroring websites."
        ["net-tools"]="Classic network utilities including ifconfig (network interfaces), netstat (connections), route (routing table), and arp (ARP cache)."
        ["ufw"]="Uncomplicated Firewall - easy-to-use frontend for iptables. Allows simple rules like 'ufw allow ssh' to manage network access."
        ["unattended-upgrades"]="Automatically installs security updates in the background. Keeps your server protected without manual intervention."
        ["ca-certificates"]="Root certificates for SSL/TLS verification. Required for secure HTTPS connections to websites and package repositories."
        ["gnupg"]="GNU Privacy Guard - encrypts files and emails, verifies package signatures. Essential for secure package management."
        ["lsb-release"]="Reports Linux distribution info (e.g., 'lsb_release -a'). Used by scripts to detect OS version and compatibility."
        ["software-properties-common"]="Tools to manage APT repositories. Enables 'add-apt-repository' command for adding PPAs and third-party repos."
        ["rsyslog"]="System logging daemon. Collects and stores logs from system services. Essential for troubleshooting and security auditing."
        ["git"]="Distributed version control system. Track code changes, collaborate with others, and deploy from repositories."
        ["htop"]="Interactive process viewer with CPU/memory graphs, process tree, and easy process management (kill, renice, etc.)."
        ["atop"]="Advanced system monitor that logs CPU, memory, disk, and network activity over time. Unlike htop, atop stores historical data allowing you to analyze past performance. Great for post-incident analysis and long-term monitoring."
        ["iotop"]="Shows disk I/O usage per process. Helps identify which processes are causing disk bottlenecks or high I/O wait."
        ["nethogs"]="Groups network bandwidth by process (unlike iftop which shows per-connection). Find which program is using your bandwidth."
        ["tree"]="Displays directory structures in a tree-like format. Useful for visualizing project layouts, documenting folder hierarchies, and quickly understanding codebase organization. Use 'tree -L 2' to limit depth."
        ["lm-sensors"]="Monitors hardware sensors: CPU temperature, fan speeds, voltages. Use 'sensors' command to check system health."
        ["smartmontools"]="Monitors disk health using S.M.A.R.T. data. Detects failing drives before data loss. Use 'smartctl -a /dev/sdX' to check disk status, or 'smartctl -t short /dev/sdX' for self-tests. Essential for early warning of disk failures."
        ["nvme-cli"]="Management tool for NVMe SSDs. Check health with 'nvme smart-log /dev/nvme0n1', view firmware info, and monitor wear level. Recommended for servers with NVMe drives (including Raspberry Pi 5 with NVMe HAT)."
        ["fail2ban"]="Scans log files for malicious patterns (e.g., failed SSH logins) and temporarily bans offending IPs via firewall rules."
        ["libpam-tmpdir"]="Creates per-user private /tmp directories. Prevents users from accessing each other's temp files (security hardening)."
    )

    # Collect selected packages
    SELECTED_PACKAGES=()

    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Would ask for individual package selection"
        log_dry_run "Available packages: ${!ESSENTIAL_PACKAGES[@]}"
        # In dry-run, assume all packages selected for summary
        for pkg in "${!ESSENTIAL_PACKAGES[@]}"; do
            SELECTED_PACKAGES+=("$pkg")
        done
    else
        # In fresh-install mode, auto-select all packages
        if [ "$MODE" = "fresh-install" ]; then
            log_info "Fresh-install mode: Auto-selecting all essential packages"
            for pkg in "${!ESSENTIAL_PACKAGES[@]}"; do
                SELECTED_PACKAGES+=("$pkg")
            done
        else
            # Interactive mode: ask for each package
            echo ""
            echo "=========================================================================="
            echo "SELECT INDIVIDUAL PACKAGES"
            echo "=========================================================================="
            echo ""
            echo "You can now select which packages to install."
            echo "Each package includes a description of what it does and why it's useful."
            echo "Press Enter to accept the default (Y = install, n = skip)"
            echo ""

            for pkg in curl wget net-tools ufw unattended-upgrades ca-certificates gnupg lsb-release software-properties-common rsyslog git htop atop iotop nethogs tree lm-sensors smartmontools nvme-cli fail2ban libpam-tmpdir; do
                desc="${ESSENTIAL_PACKAGES[$pkg]}"
                details="${PACKAGE_DETAILS[$pkg]}"

                # Check if package is already installed
                if dpkg -l | grep -q "^ii  $pkg "; then
                    echo -e "${GREEN}✓${NC} ${BOLD}$pkg${NC} - Already installed"
                    echo -e "  ${DIM}$details${NC}"
                    SELECTED_PACKAGES+=("$pkg")
                else
                    echo ""
                    echo -e "${BOLD}$desc${NC} (package: $pkg)"
                    echo -e "  ${DIM}$details${NC}"
                    read -p "  Install $pkg? (Y/n): " install_pkg
                    install_pkg=${install_pkg:-y}

                    if [[ $install_pkg =~ ^[Yy]$ ]] || [[ -z "$install_pkg" ]]; then
                        SELECTED_PACKAGES+=("$pkg")
                        echo -e "  ${CYAN}→${NC} Will install: $pkg"
                    else
                        echo -e "  ${YELLOW}→${NC} Skipped: $pkg"
                    fi
                fi
            done
        fi
    fi

    # Install selected packages
    if [ ${#SELECTED_PACKAGES[@]} -gt 0 ]; then
        if [ "$DRY_RUN" = true ]; then
            log_dry_run "Would install ${#SELECTED_PACKAGES[@]} packages:"
            for pkg in "${SELECTED_PACKAGES[@]}"; do
                log_dry_run "  - $pkg"
            done
        else
            echo ""
            log_info "Installing ${#SELECTED_PACKAGES[@]} selected packages..."

            # Install packages one by one to handle failures gracefully
            FAILED_PACKAGES=()
            for pkg in "${SELECTED_PACKAGES[@]}"; do
                if dpkg -l | grep -q "^ii  $pkg "; then
                    log_info "$pkg already installed, skipping"
                else
                    echo -n "Installing $pkg... "
                    if DEBIAN_FRONTEND=noninteractive sudo apt-get install -y "$pkg" >/dev/null 2>&1; then
                        echo -e "${GREEN}✓${NC}"
                    else
                        echo -e "${RED}✗${NC}"
                        FAILED_PACKAGES+=("$pkg")
                    fi
                fi
            done

            # Report results
            if [ ${#FAILED_PACKAGES[@]} -eq 0 ]; then
                log_info "All selected packages installed successfully"
            else
                log_warning "Failed to install ${#FAILED_PACKAGES[@]} packages: ${FAILED_PACKAGES[*]}"
                log_warning "You can try installing them manually later"
            fi
        fi
    else
        log_warning "No packages selected for installation"
    fi
else
    log_info "Essential packages installation skipped"
fi

###############################################################################
# INSTALL SECURITY PACKAGE MANAGEMENT TOOLS
###############################################################################

if ask_component_install \
    "SECURITY PACKAGE MANAGEMENT TOOLS" \
    "security-pkg-tools" \
    "Install advanced security package management tools for enhanced package awareness." \
    "Available tools:
• apt-listchanges - Shows important changes in packages before upgrade
• debsums - Verifies installed package file integrity
• apt-show-versions - Shows available package versions and updates
• needrestart - Detects which services need restart after updates
• apt-listbugs - Display critical bugs before package installation (Debian only)

Benefits:
• Review security changes before applying updates
• Detect modified or corrupted system files
• Better package version management
• Know when to restart services after security updates
• Prevent installation of packages with known critical bugs (Debian)

Note: You will be able to select individual tools in the next step
Lynis recommendation: DEB-0810 (Debian systems only)" \
    "y"; then

    # Detect OS for apt-listbugs availability
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="${ID:-unknown}"
    else
        OS_ID="unknown"
    fi

    # Define security tools with short descriptions
    declare -A SECURITY_TOOLS=(
        ["apt-listchanges"]="Package changelog viewer"
        ["debsums"]="Package integrity checker"
        ["apt-show-versions"]="Package version reporter"
        ["needrestart"]="Service restart detector"
    )

    # Detailed descriptions for security tools
    declare -A SECURITY_TOOL_DETAILS=(
        ["apt-listchanges"]="Displays important changes (changelogs, NEWS) in packages before upgrading. Helps you understand what's changing before applying updates."
        ["debsums"]="Verifies MD5 checksums of installed package files against the package database. Detects modified or corrupted system files."
        ["apt-show-versions"]="Lists installed packages with their versions and shows which ones have updates available. Useful for version management."
        ["needrestart"]="Checks which system services need to be restarted after package updates. Ensures security patches are actually applied."
        ["apt-listbugs"]="Shows critical bugs filed against packages before installation. Prevents installing packages with known serious issues (Debian only)."
    )

    # Add apt-listbugs only on Debian systems
    if [ "$OS_ID" = "debian" ]; then
        SECURITY_TOOLS["apt-listbugs"]="Critical bug checker (Debian only)"
    fi

    # Collect selected tools
    SELECTED_SECURITY_TOOLS=()

    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Would ask for individual security tool selection"
        log_dry_run "Available tools: ${!SECURITY_TOOLS[@]}"
        # In dry-run, assume all tools selected for summary
        for tool in "${!SECURITY_TOOLS[@]}"; do
            SELECTED_SECURITY_TOOLS+=("$tool")
        done
    else
        # In fresh-install mode, auto-select all tools
        if [ "$MODE" = "fresh-install" ]; then
            log_info "Fresh-install mode: Auto-selecting all security tools"
            for tool in "${!SECURITY_TOOLS[@]}"; do
                SELECTED_SECURITY_TOOLS+=("$tool")
            done
        else
            # Interactive mode: ask for each tool
            echo ""
            echo "=========================================================================="
            echo "SELECT SECURITY TOOLS"
            echo "=========================================================================="
            echo ""
            echo "Select which security package management tools to install."
            echo "Each tool includes a description of what it does and why it's useful."
            echo "Press Enter to accept the default (Y = install, n = skip)"
            echo ""

            # Iterate over all tools in SECURITY_TOOLS array
            for tool in "${!SECURITY_TOOLS[@]}"; do
                desc="${SECURITY_TOOLS[$tool]}"
                details="${SECURITY_TOOL_DETAILS[$tool]}"

                # Check if tool is already installed
                if dpkg -l | grep -q "^ii  $tool "; then
                    echo -e "${GREEN}✓${NC} ${BOLD}$tool${NC} - Already installed"
                    echo -e "  ${DIM}$details${NC}"
                    SELECTED_SECURITY_TOOLS+=("$tool")
                else
                    echo ""
                    echo -e "${BOLD}$desc${NC} (package: $tool)"
                    echo -e "  ${DIM}$details${NC}"
                    read -p "  Install $tool? (Y/n): " install_tool
                    install_tool=${install_tool:-y}

                    if [[ $install_tool =~ ^[Yy]$ ]] || [[ -z "$install_tool" ]]; then
                        SELECTED_SECURITY_TOOLS+=("$tool")
                        echo -e "  ${CYAN}→${NC} Will install: $tool"
                    else
                        echo -e "  ${YELLOW}→${NC} Skipped: $tool"
                    fi
                fi
            done
        fi
    fi

    # Install selected tools
    if [ ${#SELECTED_SECURITY_TOOLS[@]} -gt 0 ]; then
        if [ "$DRY_RUN" = true ]; then
            log_dry_run "Would install ${#SELECTED_SECURITY_TOOLS[@]} security tools:"
            for tool in "${SELECTED_SECURITY_TOOLS[@]}"; do
                log_dry_run "  - $tool"
            done
        else
            echo ""
            log_info "Installing ${#SELECTED_SECURITY_TOOLS[@]} selected security tools..."

            # Install tools one by one to handle failures gracefully
            FAILED_TOOLS=()
            for tool in "${SELECTED_SECURITY_TOOLS[@]}"; do
                if dpkg -l | grep -q "^ii  $tool "; then
                    log_info "$tool already installed, skipping"
                else
                    echo -n "Installing $tool... "
                    if DEBIAN_FRONTEND=noninteractive sudo apt-get install -y "$tool" >/dev/null 2>&1; then
                        echo -e "${GREEN}✓${NC}"
                    else
                        echo -e "${RED}✗${NC}"
                        FAILED_TOOLS+=("$tool")
                    fi
                fi
            done

            # Report results
            if [ ${#FAILED_TOOLS[@]} -eq 0 ]; then
                log_info "All selected security tools installed successfully"
                log_info "These tools will now run automatically during package operations"
            else
                log_warning "Failed to install ${#FAILED_TOOLS[@]} tools: ${FAILED_TOOLS[*]}"
                log_warning "You can try installing them manually later"
            fi
        fi
    else
        log_warning "No security tools selected for installation"
    fi
else
    log_info "Security package management tools installation skipped"
fi

###############################################################################
# PASSWORD POLICIES & PAM HARDENING
###############################################################################

if skip_if_completed "PASSWORD_POLICIES"; then
    log_info "Password policies already configured, skipping"
else
    if ask_component_install \
        "PASSWORD POLICIES & PAM SECURITY" \
        "password-policies" \
        "Configure strong password policies and PAM security settings." \
        "Security features:
• SHA-512 password hashing with 65536 rounds (slow brute-force)
• Password quality requirements (minimum 12 chars, complexity)
• Password aging policies (7 days min, 365 days max, 30 days warning)
• Per-user temporary directories (libpam-tmpdir)

Benefits:
• Stronger password hashing (resistant to attacks)
• Enforced password complexity when setting passwords
• Automatic password expiration for compliance
• Isolated tmp directories per user session

Note: Only affects password-based logins (SSH keys unaffected)
Lynis recommendations: AUTH-9230, AUTH-9262, AUTH-9286, DEB-0280" \
        "y"; then

    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Would install libpam-pwquality"
        log_dry_run "Would configure SHA-512 rounds in /etc/pam.d/common-password"
        log_dry_run "Would configure SHA-512 rounds in /etc/login.defs (ENCRYPT_METHOD, SHA_CRYPT_MIN_ROUNDS, SHA_CRYPT_MAX_ROUNDS)"
        log_dry_run "Would set password quality requirements in /etc/security/pwquality.conf"
        log_dry_run "Would configure password aging in /etc/login.defs (PASS_MIN_DAYS=7, PASS_MAX_DAYS=365, PASS_WARN_AGE=30)"
        log_dry_run "Would configure UMASK to 027 in /etc/login.defs (Lynis AUTH-9328)"
        log_dry_run "Would apply password aging to existing user accounts (UID>=1000) using chage"
    else
        log_info "Configuring password policies and PAM hardening..."

        # Install libpam-pwquality if not already installed
        if ! dpkg -l | grep -q "^ii  libpam-pwquality "; then
            log_info "Installing libpam-pwquality..."
            DEBIAN_FRONTEND=noninteractive sudo apt-get install -y libpam-pwquality || \
                log_warning "Failed to install libpam-pwquality"
        else
            log_info "libpam-pwquality already installed"
        fi

        # Backup PAM configs
        if [ -f /etc/pam.d/common-password ]; then
            sudo cp /etc/pam.d/common-password /etc/pam.d/common-password.backup.$(date +%Y%m%d_%H%M%S)
            log_info "Backed up /etc/pam.d/common-password"
        fi

        # Configure SHA-512 with rounds (Lynis AUTH-9230)
        log_info "Configuring SHA-512 password hashing with 65536 rounds..."

        # Check if pam_unix.so line exists and add rounds parameter
        if grep -q "pam_unix.so" /etc/pam.d/common-password; then
            # Check if rounds already configured
            if grep "pam_unix.so" /etc/pam.d/common-password | grep -q "rounds="; then
                log_info "Password hashing rounds already configured"
            else
                # Add rounds parameter to existing pam_unix.so line
                sudo sed -i '/pam_unix.so/ s/$/ rounds=65536/' /etc/pam.d/common-password
                log_info "Added rounds=65536 to pam_unix.so"
            fi
        else
            log_warning "pam_unix.so not found in /etc/pam.d/common-password"
        fi

        # Configure password quality requirements (Lynis AUTH-9262)
        log_info "Configuring password quality requirements..."

        if [ -f /etc/security/pwquality.conf ]; then
            sudo cp /etc/security/pwquality.conf /etc/security/pwquality.conf.backup.$(date +%Y%m%d_%H%M%S)
        fi

        if [ "$DESKTOP_MODE" = true ]; then
            cat <<'EOF' | sudo tee /etc/security/pwquality.conf >/dev/null
# Password quality requirements - Desktop mode (less restrictive)
# Configured by system baseline script

# Minimum password length
minlen = 8

# Minimum number of character classes (lower, upper, digit, special)
minclass = 2

# Maximum number of allowed consecutive same characters
maxrepeat = 4

# Require at least one digit
dcredit = -1

# Require at least one lowercase letter
lcredit = -1
EOF
        else
            cat <<'EOF' | sudo tee /etc/security/pwquality.conf >/dev/null
# Password quality requirements - Lynis AUTH-9262
# Configured by server baseline script

# Minimum password length
minlen = 12

# Minimum number of character classes (lower, upper, digit, special)
minclass = 3

# Maximum number of allowed consecutive same characters
maxrepeat = 3

# Require at least one digit
dcredit = -1

# Require at least one uppercase letter
ucredit = -1

# Require at least one lowercase letter
lcredit = -1

# Require at least one special character
ocredit = -1

# Check password against dictionary
# dictcheck = 1

# Reject passwords containing username
# usercheck = 1
EOF
        fi

        log_info "Password quality requirements configured"

        # Ensure pam_pwquality is enabled in PAM
        if ! grep -q "pam_pwquality.so" /etc/pam.d/common-password; then
            log_info "Enabling pam_pwquality in /etc/pam.d/common-password..."
            # Add pam_pwquality before pam_unix
            sudo sed -i '/pam_unix.so/i password requisite pam_pwquality.so retry=3' /etc/pam.d/common-password
            log_info "pam_pwquality enabled"
        else
            log_info "pam_pwquality already enabled"
        fi

        # Configure /etc/login.defs for password hashing (Lynis AUTH-9230 complete compliance)
        log_info "Configuring /etc/login.defs for SHA-512 password hashing..."

        if [ -f /etc/login.defs ]; then
            sudo cp /etc/login.defs /etc/login.defs.backup.$(date +%Y%m%d_%H%M%S)
            log_info "Backed up /etc/login.defs"

            # Set ENCRYPT_METHOD to SHA512 if not already set
            if grep -q "^ENCRYPT_METHOD" /etc/login.defs; then
                sudo sed -i 's/^ENCRYPT_METHOD.*/ENCRYPT_METHOD SHA512/' /etc/login.defs
                log_info "Updated ENCRYPT_METHOD to SHA512"
            else
                echo "ENCRYPT_METHOD SHA512" | sudo tee -a /etc/login.defs >/dev/null
                log_info "Added ENCRYPT_METHOD SHA512"
            fi

            # Set SHA_CRYPT_MIN_ROUNDS and SHA_CRYPT_MAX_ROUNDS
            if grep -q "^SHA_CRYPT_MIN_ROUNDS" /etc/login.defs; then
                sudo sed -i 's/^SHA_CRYPT_MIN_ROUNDS.*/SHA_CRYPT_MIN_ROUNDS 65536/' /etc/login.defs
            else
                echo "SHA_CRYPT_MIN_ROUNDS 65536" | sudo tee -a /etc/login.defs >/dev/null
            fi

            if grep -q "^SHA_CRYPT_MAX_ROUNDS" /etc/login.defs; then
                sudo sed -i 's/^SHA_CRYPT_MAX_ROUNDS.*/SHA_CRYPT_MAX_ROUNDS 65536/' /etc/login.defs
            else
                echo "SHA_CRYPT_MAX_ROUNDS 65536" | sudo tee -a /etc/login.defs >/dev/null
            fi

            log_info "Configured SHA-512 hashing rounds in /etc/login.defs"

            # Configure password aging (Lynis AUTH-9286)
            log_info "Configuring password aging policies..."

            # PASS_MIN_DAYS: Minimum days between password changes
            if grep -q "^PASS_MIN_DAYS" /etc/login.defs; then
                sudo sed -i 's/^PASS_MIN_DAYS.*/PASS_MIN_DAYS 7/' /etc/login.defs
            else
                echo "PASS_MIN_DAYS 7" | sudo tee -a /etc/login.defs >/dev/null
            fi

            # PASS_MAX_DAYS: Maximum password age
            if grep -q "^PASS_MAX_DAYS" /etc/login.defs; then
                sudo sed -i 's/^PASS_MAX_DAYS.*/PASS_MAX_DAYS 365/' /etc/login.defs
            else
                echo "PASS_MAX_DAYS 365" | sudo tee -a /etc/login.defs >/dev/null
            fi

            # PASS_WARN_AGE: Days of warning before password expires
            if grep -q "^PASS_WARN_AGE" /etc/login.defs; then
                sudo sed -i 's/^PASS_WARN_AGE.*/PASS_WARN_AGE 30/' /etc/login.defs
            else
                echo "PASS_WARN_AGE 30" | sudo tee -a /etc/login.defs >/dev/null
            fi

            log_info "Password aging policies configured"

            # Configure UMASK to 027 (Lynis AUTH-9328)
            log_info "Configuring default UMASK to 027..."
            if grep -q "^UMASK" /etc/login.defs; then
                sudo sed -i 's/^UMASK.*/UMASK 027/' /etc/login.defs
                log_info "Updated UMASK to 027"
            else
                echo "UMASK 027" | sudo tee -a /etc/login.defs >/dev/null
                log_info "Added UMASK 027"
            fi

            # Apply password aging to existing user accounts (except system accounts and root)
            log_info "Applying password aging to existing user accounts..."
            AGING_COUNT=0
            sudo awk -F: '($2!="!" && $2!="*" && $3>=1000){print $1}' /etc/shadow | while read u; do
                sudo chage -M 365 -m 7 -W 30 "$u" 2>/dev/null && AGING_COUNT=$((AGING_COUNT + 1))
            done
            log_info "Password aging applied to user accounts (365 days max age, 7 days min age, 30 days warning)"

            # Explicitly disable password aging for root (root should use SSH keys, not passwords)
            log_info "Disabling password aging for root account..."
            sudo chage -M -1 -m 0 -W 7 root 2>/dev/null || true
            log_info "Root account excluded from password aging"

        else
            log_warning "/etc/login.defs not found, skipping login.defs configuration"
        fi

        log_info "Password policies and PAM hardening configured successfully"
        echo ""
        echo "══════════════════════════════════════════════════════════"
        echo "Password Policy Configuration Summary:"
        echo "══════════════════════════════════════════════════════════"
        echo "✓ SHA-512 hashing with 65536 rounds (PAM + login.defs)"
        echo "✓ UMASK set to 027 (new files: owner=rwx, group=rx, others=none)"
        echo "✓ Minimum password length: 12 characters"
        echo "✓ Required: 3 different character classes"
        echo "✓ Required: At least 1 digit, 1 uppercase, 1 lowercase, 1 special char"
        echo "✓ Maximum 3 consecutive same characters"
        echo ""
        echo "Note: These policies only apply when setting new passwords"
        echo "      SSH key authentication is not affected"
        echo "══════════════════════════════════════════════════════════"
        echo ""
    fi
        mark_completed "PASSWORD_POLICIES"
    else
        log_info "Password policies configuration skipped"
        mark_completed "PASSWORD_POLICIES"
    fi
fi

###############################################################################
# PYTHON INSTALLATION
###############################################################################

if ask_component_install \
    "PYTHON INSTALLATION" \
    "python" \
    "Install Python 3 with pip package manager and virtual environment support." \
    "Packages:
• python3 - Python programming language
• python3-pip - Package installer for Python
• python3-venv - Virtual environment support

Useful for running Python applications and scripts" \
    "y"; then

    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Would run: apt-get update"
        log_dry_run "Would install: python3, python3-pip, python3-venv"
    else
        log_info "Installing Python with pip and venv..."
        # Refresh package lists in case the system-update section was skipped
        DEBIAN_FRONTEND=noninteractive sudo apt-get update -qq || log_warning "apt-get update reported issues, continuing"
        DEBIAN_FRONTEND=noninteractive sudo apt-get install -y python3 python3-pip python3-venv || handle_error "Failed to install Python"
        log_info "Python $(python3 --version) installed successfully"
    fi
else
    log_info "Python installation skipped"
fi

###############################################################################
# NODE.JS INSTALLATION
###############################################################################

if ask_component_install \
    "NODE.JS INSTALLATION" \
    "nodejs" \
    "Install Node.js LTS (Long Term Support) version with npm package manager." \
    "Useful for:
• Running JavaScript applications
• Modern web development
• Package management with npm

Note: Installs from NodeSource repository for latest LTS version" \
    "y"; then

    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Would install Node.js LTS from NodeSource repository"
        log_dry_run "Would remove pre-installed libnode*/nodejs-doc packages if present (Ubuntu Desktop conflict)"
        log_dry_run "Would install npm package manager"
    else
        log_info "Installing Node.js LTS..."
        # Try to download and execute NodeSource setup script with retry
        if ! retry_command "curl -fsSL https://deb.nodesource.com/setup_lts.x -o /tmp/nodesource_setup.sh"; then
            log_warning "Failed to download NodeSource setup script after multiple attempts"
            handle_error "NodeSource repository setup failed. Please check https://github.com/nodesource/distributions for manual installation instructions"
        fi
        sudo -E bash /tmp/nodesource_setup.sh || handle_error "Failed to execute NodeSource setup script"
        rm -f /tmp/nodesource_setup.sh

        # Ubuntu Desktop ships libnode-dev / libnodeXX which clash with NodeSource nodejs
        # (apt-get install would fail with "trying to overwrite '/usr/include/node/...'")
        # Use awk (not grep) for filtering: awk exits 0 on no matches, so the
        # pipeline stays clean under `set -o pipefail`.
        CONFLICTING_NODE_PKGS=$(dpkg-query -W -f='${Package}\n' 2>/dev/null | awk '/^(libnode[0-9]*(-dev)?|nodejs-doc)$/' | tr '\n' ' ')
        if [ -n "${CONFLICTING_NODE_PKGS// /}" ]; then
            log_info "Removing pre-installed packages that conflict with NodeSource: $CONFLICTING_NODE_PKGS"
            DEBIAN_FRONTEND=noninteractive sudo apt-get remove -y $CONFLICTING_NODE_PKGS || log_warning "Could not remove conflicting packages, install may fail"
        fi

        DEBIAN_FRONTEND=noninteractive sudo apt-get install -y nodejs || handle_error "Failed to install Node.js"
        log_info "Node.js $(node --version) and npm $(npm --version) installed successfully"
    fi
else
    log_info "Node.js installation skipped"
fi

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
        "y"; then

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
            read -p "> " final_confirm

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
    handle_error "/etc/os-release not found. This script requires Ubuntu, Debian, Kali, or Raspbian OS"
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
if [ "$ID" = "kali" ]; then
    DOCKER_OS="debian"
    # Kali rolling is based on Debian testing/sid; Docker only ships stable suites
    VERSION_CODENAME="bookworm"
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

# Deliberately NOT set here, because both have real breakage potential and this
# script runs against live servers:
#   "no-new-privileges": true  - blocks gaining privileges through setuid binaries
#                               and file capabilities. Netdata's plugins rely on
#                               file capabilities, so this breaks apps.plugin.
#   "icc": false               - blocks container-to-container traffic on the
#                               default bridge, which breaks most compose stacks.
# See "Optional Docker daemon hardening" in README.md before enabling either.

sudo systemctl enable docker || handle_error "Failed to enable Docker service"
sudo systemctl restart docker || handle_error "Failed to restart Docker service"

log_info "Docker $(docker --version) installed successfully"
log_info "Docker Compose installed as plugin (use: docker compose)"

# Starting a container makes Docker create a veth pair. udev hands it to
# cloud-init's network hotplug hook, which asks the cloud datasource what this
# interface is, finds nothing - it is not a provider NIC - and crashes. apport
# then writes a dump to /var/crash on every single container start.
#
# That matters because /var/crash is deliberately monitored by AIDE: a crash
# dump appearing is real information. A recurring harmless one teaches the
# operator to dismiss the directory, and the crash that is not harmless goes
# with it.
#
# The hook has no purpose on a server with static networking. Overriding the
# rule with a symlink to /dev/null in /etc is the standard udev mechanism: it
# takes precedence over the packaged rule and survives a cloud-init upgrade.
for _cidir in /lib/udev/rules.d /usr/lib/udev/rules.d; do
    if [ -f "$_cidir/10-cloud-init-hook-hotplug.rules" ]; then
        sudo ln -sf /dev/null /etc/udev/rules.d/10-cloud-init-hook-hotplug.rules
        sudo udevadm control --reload-rules 2>/dev/null || true
        log_info "Disabled cloud-init's network hotplug hook (it crashes on Docker veth devices)"
        break
    fi
done

mark_completed "DOCKER_INSTALL"
fi

###############################################################################
# LOGGING CONFIGURATION
###############################################################################

if ask_component_install \
    "SYSTEM LOGGING CONFIGURATION" \
    "logging" \
    "Configure rsyslog and logrotate for system and application logging." \
    "Configuration:
• Enable and configure rsyslog for system logging
• Setup logrotate for application logs in /var/log/app/
• Daily rotation with 14-day retention
• Compress old logs to save disk space

Benefits:
• Centralized logging for troubleshooting
• Automatic log rotation prevents disk space issues
• Structured log management" \
    "y"; then

    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Would enable and restart rsyslog"
        log_dry_run "Would configure logrotate for application logs:"
        log_dry_run "  - Daily rotation, 14-day retention"
        log_dry_run "  - Compression enabled"
        log_dry_run "  - Target: /var/log/app/*.log"
    else
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
    fi
else
    log_info "System logging configuration skipped"
fi

###############################################################################
# JOURNALD CONFIGURATION
###############################################################################

if ask_component_install \
    "JOURNALD LOG ROTATION" \
    "journald" \
    "Configure systemd-journald for persistent logging with size limits and rotation." \
    "Configuration:
• Persistent storage for system logs
• Max usage: 500MB, keep 100MB free
• Max file size: 100MB
• Retention: 30 days
• Compression enabled
• Forward to syslog enabled

Benefits:
• Prevents logs from consuming all disk space
• Automatic rotation and cleanup
• Persistent logs survive reboots
• Integration with syslog" \
    "y"; then

    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Would backup /etc/systemd/journald.conf"
        log_dry_run "Would configure journald with:"
        log_dry_run "  - Storage=persistent, Compress=yes"
        log_dry_run "  - SystemMaxUse=500M, SystemKeepFree=100M"
        log_dry_run "  - SystemMaxFileSize=100M"
        log_dry_run "  - MaxRetentionSec=30day"
        log_dry_run "  - ForwardToSyslog=yes"
        log_dry_run "Would restart systemd-journald"
    else
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
    fi
else
    log_info "Journald configuration skipped"
fi

###############################################################################
# AUTOMATIC UPDATES
###############################################################################

if ask_component_install \
    "AUTOMATIC SECURITY UPDATES" \
    "auto-updates" \
    "Enable automatic installation of security updates using unattended-upgrades." \
    "Configuration:
• ONLY security patches will be auto-installed
• Regular updates require manual approval
• Daily package list updates
• Auto-clean old packages weekly

Benefits:
• Critical security patches applied automatically
• Reduces exposure to known vulnerabilities
• No manual intervention needed for security fixes
• Regular updates still require review" \
    "y"; then

    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Would configure unattended-upgrades for security-only updates"
        log_dry_run "Would modify /etc/apt/apt.conf.d/50unattended-upgrades"
        log_dry_run "Would create /etc/apt/apt.conf.d/20auto-upgrades with:"
        log_dry_run "  - Daily package list updates"
        log_dry_run "  - Daily security patch downloads"
        log_dry_run "  - Weekly auto-clean"
        log_dry_run "  - Daily unattended upgrade execution"
    else
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
    fi
else
    log_info "Automatic security updates configuration skipped"
fi

###############################################################################
# SWAP CONFIGURATION (SMART CALCULATION)
###############################################################################

if ask_component_install \
    "SWAP SPACE CONFIGURATION" \
    "swap" \
    "Configure swap space with intelligent sizing based on available RAM." \
    "Smart swap sizing:
• ≤2GB RAM: 2x RAM size
• 2-8GB RAM: 4GB swap
• >8GB RAM: 8GB swap
• Swappiness set to 10 (server optimized)

Current RAM: $(free -h | awk '/^Mem:/{print $2}')

Benefits:
• Prevents out-of-memory crashes
• Enables hibernation support
• Better memory management
• Optimized for server workloads" \
    "y"; then

    if [ "$DRY_RUN" = true ]; then
        # Get RAM for dry-run calculation
        RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
        RAM_GB=$(awk "BEGIN {printf \"%.0f\", $RAM_MB/1024}")

        if [ "$RAM_GB" -le 2 ]; then
            SWAP_SIZE=$((RAM_MB * 2))
        elif [ "$RAM_GB" -le 8 ]; then
            SWAP_SIZE=4096
        else
            SWAP_SIZE=8192
        fi

        log_dry_run "Detected RAM: ${RAM_GB}GB (${RAM_MB}MB)"
        log_dry_run "Would create swap file: /swapfile (${SWAP_SIZE}MB)"
        log_dry_run "Would set permissions: 600"
        log_dry_run "Would format and enable swap"
        log_dry_run "Would add to /etc/fstab if not present"
        log_dry_run "Would configure vm.swappiness=10 in /etc/sysctl.d/99-swappiness.conf"
    else
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
    fi
else
    log_info "Swap configuration skipped"
    SWAP_SIZE="N/A"  # Set to N/A if swap is skipped
fi

###############################################################################
# KERNEL HARDENING
###############################################################################

if ask_component_install \
    "KERNEL SECURITY HARDENING" \
    "kernel-hardening" \
    "Apply kernel-level security hardening parameters via sysctl." \
    "Security features:
• IP spoofing protection (rp_filter)
• ICMP redirect protection
• Source packet routing disabled
• SYN flood protection
• TCP hardening
• Core dump restrictions
• Kernel debugging keys disabled
• Log suspicious packets (Martians)
• BPF JIT hardening (value: 1 for QUIC compatibility)
• Extended sysctl parameters (15+ Lynis recommendations)

⚠️  DOCKER & CONTAINER COMPATIBILITY:
• IP forwarding is ENABLED (net.ipv4/ipv6.conf.all.forwarding = 1)
  Required for Docker, especially containers using network_mode: host
  Examples: Cloudflare Tunnel, Netdata, VPN clients, reverse proxies
• Connection tracking increased to 524288 (supports QUIC protocol)
• BPF JIT set to 1 (not 2) to allow QUIC while maintaining security

If you run Docker or containerized services, these settings ensure
they work correctly while maintaining strong kernel-level security.

Benefits:
• Protection against network-based attacks
• Reduced attack surface
• Better resilience against DDoS
• Enhanced system security posture
• Docker and container compatibility" \
    "y"; then

    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Would create /etc/sysctl.d/99-server-hardening.conf with:"
        log_dry_run "  - IP spoofing protection (rp_filter)"
        log_dry_run "  - ICMP redirect protection"
        log_dry_run "  - Source routing disabled"
        log_dry_run "  - SYN flood protection (tcp_syncookies)"
        log_dry_run "  - TCP hardening (timestamps disabled)"
        log_dry_run "  - IP forwarding ENABLED (Docker compatibility)"
        log_dry_run "  - Connection tracking: 524288 (QUIC support)"
        log_dry_run "  - BPF JIT hardening: 1 (allows QUIC protocol)"
        log_dry_run "  - Extended Lynis recommendations (15+ parameters)"
        log_dry_run "  - Core dumps disabled for setuid programs"
        log_dry_run "  - Kernel sysrq disabled"
        log_dry_run "Would apply settings with sysctl -p"
    else
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

# IP forwarding - Keep enabled for Docker (especially network_mode: host)
# Required for containers like Cloudflare Tunnel to route packets
# Disabling this breaks Docker networking and QUIC protocol
net.ipv4.conf.all.forwarding = 1
net.ipv6.conf.all.forwarding = 1

# Increase connection tracking size
# Increased to 524288 to support QUIC protocol (many short-lived UDP connections)
net.netfilter.nf_conntrack_max = 524288

# File system hardening (SECURITY FIX - completely disable core dumps for setuid programs)
fs.suid_dumpable = 0
kernel.dmesg_restrict = 1

# Kernel debugging keys disabled (SECURITY FIX)
kernel.sysrq = 0

# ===================================================================
# ADDITIONAL LYNIS RECOMMENDATIONS (KRNL-6000)
# ===================================================================

# Kernel hardening - Information disclosure prevention
# Hide kernel pointers from unprivileged users (LYNIS recommendation)
kernel.kptr_restrict = 2

# Disable unprivileged BPF to prevent exploit development (LYNIS recommendation)
kernel.unprivileged_bpf_disabled = 1

# Harden BPF JIT compiler against side-channel attacks (LYNIS recommendation)
# NOTE: Set to 1 instead of 2 to allow QUIC protocol (used by Cloudflare Tunnel)
# Value 2 completely disables JIT for unprivileged users, breaking QUIC
# Value 1 enables constant blinding for unprivileged users (still secure)
net.core.bpf_jit_harden = 1

# Restrict perf events to prevent information leakage (LYNIS recommendation)
kernel.perf_event_paranoid = 3

# Filesystem hardening
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.protected_fifos = 2
fs.protected_regular = 2

# Additional network security
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# IPv6 hardening
net.ipv6.conf.all.accept_ra = 0
net.ipv6.conf.default.accept_ra = 0

# ICMP hardening
net.ipv4.icmp_ignore_bogus_error_responses = 1

# Process tracing restrictions
kernel.yama.ptrace_scope = 1

# Memory hardening
vm.swappiness = 10
vm.vfs_cache_pressure = 50
EOF

        if [ "$DESKTOP_MODE" = true ]; then
            sudo sed -i 's/^kernel.yama.ptrace_scope = 1/kernel.yama.ptrace_scope = 0/' /etc/sysctl.d/99-server-hardening.conf
            sudo sed -i 's/^vm.swappiness = 10/vm.swappiness = 60/' /etc/sysctl.d/99-server-hardening.conf
            sudo sed -i 's/^vm.vfs_cache_pressure = 50/vm.vfs_cache_pressure = 100/' /etc/sysctl.d/99-server-hardening.conf
            log_info "Desktop mode: adjusted ptrace_scope=0, swappiness=60, vfs_cache_pressure=100"
        fi

        sudo sysctl -p /etc/sysctl.d/99-server-hardening.conf >/dev/null 2>&1 || log_warning "Some sysctl parameters may not be available on this kernel"

        log_info "Kernel hardening applied"
    fi
else
    log_info "Kernel hardening skipped"
fi

###############################################################################
# DISABLE UNCOMMON NETWORK PROTOCOLS
###############################################################################

if ask_component_install \
    "DISABLE UNCOMMON NETWORK PROTOCOLS" \
    "disable-protocols" \
    "Disable rarely-used network protocols that can present security risks." \
    "Protocols to disable:
• DCCP - Datagram Congestion Control Protocol
• SCTP - Stream Control Transmission Protocol
• RDS - Reliable Datagram Sockets
• TIPC - Transparent Inter-Process Communication

Note: These protocols are rarely used in typical server environments
⚠️  Changes require reboot to take effect" \
    "y"; then

    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Would create /etc/modprobe.d/disable-protocols.conf"
        log_dry_run "Would blacklist protocols: dccp, sctp, rds, tipc"
        log_dry_run "Note: Changes would require reboot to take effect"
    else
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
    fi
else
    log_info "Disabling uncommon protocols skipped"
fi

###############################################################################
# USB STORAGE DEVICE CONTROL
###############################################################################

if skip_if_completed "DISABLE_USB_STORAGE"; then
    log_info "USB storage control already configured, skipping"
elif [ "$DESKTOP_MODE" = true ]; then
    log_info "USB storage control skipped (desktop mode — USB drives needed)"
    mark_completed "DISABLE_USB_STORAGE"
else
    if ask_component_install \
        "DISABLE USB STORAGE DEVICES" \
        "disable-usb-storage" \
        "Disable USB mass storage devices to prevent data exfiltration and malware." \
        "Security features:
• Blocks USB mass storage devices (drives, external disks)
• Prevents unauthorized data copying
• Reduces malware infection risk via USB

⚠️  IMPORTANT NOTES:
✓ USB keyboards and mice will STILL WORK
✓ Other USB devices (webcams, printers) will STILL WORK
✗ USB drives and external hard disks will NOT WORK

⚠️  Raspberry Pi users: Usually say NO if you use USB storage
⚠️  Changes require reboot to take effect

Recommended:
• VPS/Cloud servers: YES (no physical USB access)
• Raspberry Pi: NO (often uses USB storage for backups)
• Desktop/Laptop: NO (needs USB drives)
• Production server rack: YES (security over convenience)

Lynis recommendation: USB-1000" \
        "n"; then

    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Would create /etc/modprobe.d/disable-usb-storage.conf"
        log_dry_run "Would blacklist usb-storage kernel module"
        log_dry_run "Note: USB keyboards/mice would still work"
        log_dry_run "Note: Changes would require reboot"
    else
        log_info "Disabling USB storage devices..."

        cat <<'EOF' | sudo tee /etc/modprobe.d/disable-usb-storage.conf >/dev/null
# Disable USB storage devices for security (Lynis USB-1000)
# USB keyboards, mice, and other devices will still work
# Only mass storage devices (USB drives, external disks) are blocked

install usb-storage /bin/true
blacklist usb-storage
EOF

        log_info "USB storage disabled"
        echo ""
        echo "══════════════════════════════════════════════════════════"
        echo "USB Storage Control Summary:"
        echo "══════════════════════════════════════════════════════════"
        echo "✓ USB storage devices (drives, disks) will be BLOCKED"
        echo "✓ USB keyboards and mice will STILL WORK"
        echo "✓ Other USB devices will STILL WORK"
        echo ""
        echo "⚠️  Changes take effect after REBOOT"
        echo "══════════════════════════════════════════════════════════"
        echo ""
    fi
        mark_completed "DISABLE_USB_STORAGE"
    else
        log_info "USB storage disabling skipped"
        mark_completed "DISABLE_USB_STORAGE"
    fi
fi

###############################################################################
# DISABLE FIREWIRE STORAGE
###############################################################################

if skip_if_completed "DISABLE_FIREWIRE_STORAGE"; then
    log_info "Firewire storage control already configured, skipping"
else
    if ask_component_install \
        "DISABLE FIREWIRE STORAGE DEVICES" \
        "disable-firewire-storage" \
        "Disable Firewire (IEEE 1394) storage devices to prevent data exfiltration." \
        "Security features:
• Blocks Firewire storage devices
• Prevents unauthorized data copying via Firewire
• Reduces DMA attack surface (Firewire has direct memory access)

⚠️  IMPORTANT NOTES:
✓ Modern servers rarely use Firewire
✓ Disabling reduces attack surface significantly
✗ Firewire devices will NOT work after this

Recommended:
• VPS/Cloud servers: YES (no physical Firewire access)
• Modern servers: YES (Firewire is legacy technology)
• Older workstations with Firewire: NO

Lynis recommendation: STRG-1846" \
        "y"; then

    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Would create /etc/modprobe.d/disable-firewire.conf"
        log_dry_run "Would blacklist firewire-core, firewire-ohci, firewire-sbp2 kernel modules"
        log_dry_run "Note: Changes would require reboot"
    else
        log_info "Disabling Firewire storage devices..."

        cat <<'EOF' | sudo tee /etc/modprobe.d/disable-firewire.conf >/dev/null
# Disable Firewire (IEEE 1394) for security (Lynis STRG-1846)
# Firewire has DMA capabilities which can be exploited for attacks
# Most modern servers don't need Firewire support

# Core Firewire modules
install firewire-core /bin/true
blacklist firewire-core

# Firewire OHCI controller
install firewire-ohci /bin/true
blacklist firewire-ohci

# Firewire storage (SBP-2 protocol)
install firewire-sbp2 /bin/true
blacklist firewire-sbp2

# Legacy IEEE 1394 modules (older kernels)
install ohci1394 /bin/true
blacklist ohci1394
install sbp2 /bin/true
blacklist sbp2
install dv1394 /bin/true
blacklist dv1394
install raw1394 /bin/true
blacklist raw1394
install video1394 /bin/true
blacklist video1394
EOF

        log_info "Firewire storage disabled"
        echo ""
        echo "══════════════════════════════════════════════════════════"
        echo "Firewire Storage Control Summary:"
        echo "══════════════════════════════════════════════════════════"
        echo "✓ Firewire storage devices will be BLOCKED"
        echo "✓ DMA attack surface reduced"
        echo ""
        echo "⚠️  Changes take effect after REBOOT"
        echo "══════════════════════════════════════════════════════════"
        echo ""
    fi
        mark_completed "DISABLE_FIREWIRE_STORAGE"
    else
        log_info "Firewire storage disabling skipped"
        mark_completed "DISABLE_FIREWIRE_STORAGE"
    fi
fi

###############################################################################
# DISABLE CORE DUMPS
###############################################################################

if skip_if_completed "DISABLE_CORE_DUMPS"; then
    log_info "Core dumps already disabled, skipping"
else
    if ask_component_install \
        "DISABLE CORE DUMPS COMPLETELY" \
        "disable-core-dumps" \
        "Completely disable core dumps to prevent sensitive data exposure." \
        "Security features:
• Prevents core dump files from being created
• Protects against memory dump exploitation
• Reduces disk space usage
• Prevents sensitive data leakage (passwords, keys, etc.)

Core dumps can contain:
• Passwords and encryption keys in memory
• Sensitive application data
• System configuration details

Configuration:
• limits.d: hard/soft core limits to 0
• systemd: DumpCore=no for all services
• profile: ulimit -c 0 for all users

Lynis recommendation: KRNL-5820" \
        "y"; then

    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Would create /etc/security/limits.d/10-disable-core-dumps.conf"
        log_dry_run "Would add 'ulimit -c 0' to /etc/profile"
        log_dry_run "Would create /etc/systemd/system.conf.d/10-disable-core-dumps.conf"
    else
        log_info "Disabling core dumps completely..."

        # Disable via limits.conf
        cat <<'EOF' | sudo tee /etc/security/limits.d/10-disable-core-dumps.conf >/dev/null
# Disable core dumps completely for all users (Lynis KRNL-5820)
# Core dumps can contain sensitive information like passwords and keys
* hard core 0
* soft core 0
EOF

        log_info "Created limits.d configuration"

        # Add to profile
        if ! grep -q "ulimit -c 0" /etc/profile 2>/dev/null; then
            echo "" | sudo tee -a /etc/profile >/dev/null
            echo "# Disable core dumps (security hardening)" | sudo tee -a /etc/profile >/dev/null
            echo "ulimit -c 0" | sudo tee -a /etc/profile >/dev/null
            log_info "Added ulimit to /etc/profile"
        else
            log_info "ulimit already configured in /etc/profile"
        fi

        # Disable for systemd services
        sudo mkdir -p /etc/systemd/system.conf.d

        cat <<'EOF' | sudo tee /etc/systemd/system.conf.d/10-disable-core-dumps.conf >/dev/null
[Manager]
# Disable core dumps for all systemd services
DumpCore=no
EOF

        log_info "Created systemd configuration"

        # Reload systemd
        sudo systemctl daemon-reload

        log_info "Core dumps completely disabled"
    fi
        mark_completed "DISABLE_CORE_DUMPS"
    else
        log_info "Core dump disabling skipped"
        mark_completed "DISABLE_CORE_DUMPS"
    fi
fi

###############################################################################
# DISABLE CUPS PRINTING SERVICE
###############################################################################

if skip_if_completed "DISABLE_CUPS"; then
    log_info "CUPS configuration already processed, skipping"
elif [ "$DESKTOP_MODE" = true ]; then
    log_info "CUPS disabling skipped (desktop mode — printing needed)"
    mark_completed "DISABLE_CUPS"
else
    # Check if CUPS is installed
    if systemctl list-unit-files cups.service &>/dev/null 2>&1 || dpkg -l cups 2>/dev/null | grep -q "^ii"; then
        if ask_component_install \
            "DISABLE CUPS PRINTING SERVICE" \
            "disable-cups" \
            "Disable CUPS (Common Unix Printing System) if printing is not needed." \
            "Security features:
• Disables unnecessary printing service
• Reduces attack surface (CUPS has had security vulnerabilities)
• Frees up system resources

⚠️  IMPORTANT NOTES:
✓ Most servers don't need printing capability
✓ Can be re-enabled later if needed
✗ Local and network printing will NOT work after this

Recommended:
• VPS/Cloud servers: YES (no printing needed)
• Headless servers: YES (no printing needed)
• Desktop/Workstation: NO (may need printing)

Lynis recommendation: PRNT-2307" \
            "y"; then

        if [ "$DRY_RUN" = true ]; then
            log_dry_run "Would disable CUPS service: sudo systemctl disable --now cups"
            log_dry_run "Would disable cups-browsed if present"
        else
            log_info "Disabling CUPS printing service..."

            # Disable and stop CUPS
            if systemctl is-active cups &>/dev/null; then
                sudo systemctl stop cups
                log_info "Stopped CUPS service"
            fi
            sudo systemctl disable cups 2>/dev/null || true
            log_info "Disabled CUPS service"

            # Also disable cups-browsed if present (browsing for network printers)
            if systemctl list-unit-files cups-browsed.service &>/dev/null 2>&1; then
                if systemctl is-active cups-browsed &>/dev/null; then
                    sudo systemctl stop cups-browsed
                fi
                sudo systemctl disable cups-browsed 2>/dev/null || true
                log_info "Disabled cups-browsed service"
            fi

            # Mask the services to prevent accidental re-enabling
            sudo systemctl mask cups.service 2>/dev/null || true
            sudo systemctl mask cups.socket 2>/dev/null || true
            log_info "Masked CUPS services"

            echo ""
            echo "══════════════════════════════════════════════════════════"
            echo "CUPS Printing Service Disabled:"
            echo "══════════════════════════════════════════════════════════"
            echo "✓ CUPS service stopped and disabled"
            echo "✓ Service masked to prevent accidental re-enabling"
            echo ""
            echo "To re-enable printing later:"
            echo "  sudo systemctl unmask cups.service cups.socket"
            echo "  sudo systemctl enable --now cups"
            echo "══════════════════════════════════════════════════════════"
            echo ""
        fi
            mark_completed "DISABLE_CUPS"
        else
            log_info "CUPS disabling skipped"
            mark_completed "DISABLE_CUPS"
        fi
    else
        log_info "CUPS is not installed, skipping"
        mark_completed "DISABLE_CUPS"
    fi
fi

###############################################################################
# SYSTEM LIMITS
###############################################################################

if ask_component_install \
    "INCREASE SYSTEM LIMITS" \
    "system-limits" \
    "Increase system limits for file descriptors and processes for production workloads." \
    "Limits to increase:
• File descriptors (nofile): 65535
• Process count (nproc): 65535
• Applied to all users including root

Current limits: $(ulimit -n) file descriptors, $(ulimit -u) processes

Benefits:
• Support for high-concurrency applications
• Better performance for web servers
• Accommodate Docker containers and services
• Prevent \"too many open files\" errors" \
    "y"; then

    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Would create /etc/security/limits.d/99-production.conf"
        log_dry_run "Would set limits:"
        log_dry_run "  - nofile (file descriptors): 65535"
        log_dry_run "  - nproc (processes): 65535"
        log_dry_run "  - Applied to all users and root"
    else
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
    fi
else
    log_info "System limits configuration skipped"
fi

###############################################################################
# FILE PERMISSIONS HARDENING
###############################################################################

if skip_if_completed "FILE_PERMISSIONS"; then
    log_info "File permissions already hardened, skipping"
else
    if ask_component_install \
        "FILE PERMISSIONS HARDENING" \
        "file-permissions" \
        "Harden file permissions for security-critical files and directories." \
        "Files/directories to secure:
• /etc/crontab → 600 (root only read/write)
• /etc/cron.* directories → 700 (root only access)
• /etc/ssh/sshd_config → 600 (root only read/write)
• /etc/at.deny → 600 (if exists)

Benefits:
• Prevents unauthorized access to cron configurations
• Protects SSH configuration from tampering
• Restricts at/cron access control files
• Reduces privilege escalation risks

Lynis recommendation: FILE-7524" \
        "y"; then

    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Would set permissions:"
        log_dry_run "  - /etc/crontab: 600"
        log_dry_run "  - /etc/cron.*: 700"
        log_dry_run "  - /etc/ssh/sshd_config: 600"
        log_dry_run "  - /etc/at.deny: 600 (if exists)"
    else
        log_info "Hardening file permissions..."

        # Crontab
        if [ -f /etc/crontab ]; then
            sudo chmod 600 /etc/crontab
            log_info "Set /etc/crontab to 600"
        fi

        # Cron directories
        for crondir in /etc/cron.hourly /etc/cron.daily /etc/cron.weekly /etc/cron.monthly /etc/cron.d; do
            if [ -d "$crondir" ]; then
                sudo chmod 700 "$crondir"
                log_info "Set $crondir to 700"
            fi
        done

        # SSH config
        if [ -f /etc/ssh/sshd_config ]; then
            sudo chmod 600 /etc/ssh/sshd_config
            log_info "Set /etc/ssh/sshd_config to 600"
        fi

        # at.deny
        if [ -f /etc/at.deny ]; then
            sudo chmod 600 /etc/at.deny
            log_info "Set /etc/at.deny to 600"
        fi

        log_info "File permissions hardened"
    fi
        mark_completed "FILE_PERMISSIONS"
    else
        log_info "File permissions hardening skipped"
        mark_completed "FILE_PERMISSIONS"
    fi
fi

###############################################################################
# FIREWALL CONFIGURATION (UFW)
###############################################################################

# Check UFW status
UFW_STATUS=$(check_component_status "ufw")
UFW_MODE="reset"  # Default mode

if [[ "$UFW_STATUS" =~ ^active:([0-9]+)$ ]]; then
    RULE_COUNT="${BASH_REMATCH[1]}"
    UFW_DESC="Configure UFW firewall with standard security rules."
    if [ "$DESKTOP_MODE" = true ]; then
        UFW_IMPLICATIONS="🔴 CRITICAL: UFW is ACTIVE with $RULE_COUNT existing rules!

Options for proceeding:
1. MERGE (Recommended): Add new rules, keep existing rules
   • Safest option - preserves your current configuration
   • Adds: SSH (port 22)
   • Your existing rules remain untouched

2. RESET (Destructive): Delete ALL rules and start fresh
   ⚠️  WARNING: This will DELETE all $RULE_COUNT existing rules!
   • Use only if you want to completely reconfigure

3. SKIP: Leave firewall unchanged
   • No modifications to existing setup"
    else
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
    fi

    if ask_component_install \
        "FIREWALL (UFW) CONFIGURATION" \
        "ufw" \
        "$UFW_DESC" \
        "$UFW_IMPLICATIONS" \
        "y"; then

        echo ""
        echo "Choose UFW configuration mode:"
        echo "  1. MERGE - Add rules, keep existing (Recommended)"
        echo "  2. RESET - Delete all rules and start fresh"
        echo "  3. SKIP - Leave unchanged"
        echo ""
        read -p "Enter choice [1/2/3] (default: 1): " ufw_choice
        ufw_choice=${ufw_choice:-1}

        case "$ufw_choice" in
            2)
                echo ""
                echo -e "${RED}⚠️  You chose RESET - this will delete all $RULE_COUNT existing rules!${NC}"
                read -p "Type 'YES' to confirm deletion of all rules: " confirm_reset

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
    if [ "$DESKTOP_MODE" = true ]; then
        UFW_DESC="Configure UFW firewall with desktop security rules (SSH only)."
        UFW_IMPLICATIONS="✅ UFW not detected or inactive - safe to configure
• Will set up with secure defaults
• Deny all incoming, allow all outgoing
• Allows: SSH (port 22)"
    else
        UFW_DESC="Configure UFW firewall with standard security rules (SSH, HTTP, HTTPS)."
        UFW_IMPLICATIONS="✅ UFW not detected or inactive - safe to configure
• Will set up with secure defaults
• Deny all incoming, allow all outgoing
• Allows: SSH (ports 22, 888), HTTP (80), HTTPS (443)
• Rate limiting enabled for SSH"
    fi

    if ask_component_install \
        "FIREWALL (UFW) CONFIGURATION" \
        "ufw" \
        "$UFW_DESC" \
        "$UFW_IMPLICATIONS" \
        "y"; then
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
        if [ "$DESKTOP_MODE" = true ]; then
            log_dry_run "Would add rules: SSH (22)"
        else
            log_dry_run "Would add rules: SSH (22, 888), HTTP (80), HTTPS (443)"
        fi
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

        if [ "$DESKTOP_MODE" = true ]; then
            # Desktop: only SSH on port 22
            sudo ufw allow 22/tcp comment 'SSH' || handle_error "Failed to add SSH port 22"
            log_info "Desktop firewall configured (22/SSH only)"
        else
            # Server: SSH on ports 22 and 888 with rate limiting, plus HTTP/HTTPS
            sudo ufw allow 22/tcp comment 'SSH (will be disabled manually later)' || handle_error "Failed to add SSH port 22"
            sudo ufw limit 888/tcp comment 'SSH rate limited' || handle_error "Failed to add SSH port 888"
            sudo ufw allow 80/tcp comment 'HTTP' || handle_error "Failed to add HTTP port"
            sudo ufw allow 443/tcp comment 'HTTPS' || handle_error "Failed to add HTTPS port"
            log_info "Standard ports configured (22/SSH-temp, 888/SSH, 80/HTTP, 443/HTTPS)"
        fi
    fi
else
    log_info "UFW configuration skipped"
fi

# Interactive port addition (skip if already configured to avoid duplicates on resume)
if ! is_completed "UFW_CUSTOM_PORTS"; then
    echo ""
    log_info "Additional port configuration:"
    while true; do
        read -p "Do you want to add another port? (enter port number or 'n' to skip): " port

        if [[ $port == "n" ]] || [[ $port == "N" ]]; then
            break
        elif [[ $port =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
            read -p "Protocol (tcp/udp) [tcp]: " protocol
            protocol=${protocol:-tcp}

            read -p "Description for this port: " description
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
# LEGAL WARNING BANNERS
###############################################################################

if skip_if_completed "LEGAL_BANNERS"; then
    log_info "Legal banners already configured, skipping"
else
    if ask_component_install \
        "LEGAL WARNING BANNERS" \
        "legal-banners" \
        "Configure legal warning banners for SSH and console login." \
        "Security features:
• Display legal warning before login
• Establish no expectation of privacy
• Legal protection for monitoring activities
• Compliance with security policies

Banners displayed:
• SSH login (before authentication)
• Console login (local terminal)
• After login message

Note: Customize banner text for your organization
Lynis recommendations: BANN-7126, BANN-7130

⚠️  Recommended for business/production servers
    Optional for personal servers" \
        "n"; then

    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Would create /etc/issue with legal banner"
        log_dry_run "Would create /etc/issue.net with legal banner"
        log_dry_run "Would configure SSH to use banner"
    else
        log_info "Configuring legal warning banners..."

        # Backup existing banners
        [ -f /etc/issue ] && sudo cp /etc/issue /etc/issue.backup.$(date +%Y%m%d_%H%M%S)
        [ -f /etc/issue.net ] && sudo cp /etc/issue.net /etc/issue.net.backup.$(date +%Y%m%d_%H%M%S)

        # Create legal warning banner
        cat <<'EOF' | sudo tee /etc/issue >/dev/null
***********************************************************************
*                         AUTHORIZED ACCESS ONLY                      *
***********************************************************************

This system is for authorized use only. Individuals accessing this
system without authority or exceeding their access authority are
subject to having all of their activities on this system monitored
and recorded.

Any unauthorized access or use of this system is prohibited and may
be subject to criminal and/or civil penalties.

All activities on this system are logged and monitored. By accessing
this system, you consent to such monitoring and recording.

If you do not consent to these terms, disconnect now.

***********************************************************************
EOF

        log_info "Created /etc/issue"

        # Copy to issue.net for SSH
        sudo cp /etc/issue /etc/issue.net
        log_info "Created /etc/issue.net"

        # Configure SSH to use banner (will be applied when SSH config is written)
        log_info "Legal warning banners configured"
        log_info "Banner will be enabled in SSH configuration"
    fi
        mark_completed "LEGAL_BANNERS"
    else
        log_info "Legal warning banners skipped"
        mark_completed "LEGAL_BANNERS"
    fi
fi

###############################################################################
# CUSTOM MOTD (Message of the Day)
###############################################################################

if skip_if_completed "CUSTOM_MOTD"; then
    log_info "Custom MOTD already configured, skipping"
else
    if ask_component_install \
        "CUSTOM MOTD" \
        "custom-motd" \
        "Configure a custom Message of the Day (MOTD) shown after login." \
        "Features:
• Displays hostname prominently after login
• Shows server purpose/usage description
• Helps identify servers in multi-server environments
• Professional server identification

The MOTD is displayed after successful SSH login.
You will be asked to provide a description of the server's purpose.

💡 Recommended for all servers to improve identification" \
        "y"; then

    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Would ask for server usage description"
        log_dry_run "Would create /etc/update-motd.d/01-custom with custom MOTD"
    else
        log_info "Configuring custom MOTD..."

        # Ask user for server usage description
        echo ""
        echo "Enter a description of this server's purpose/usage."
        echo "Examples: Docker Host, Web Server, Database Server, Development, Monitoring"
        echo ""
        read -p "Server usage description: " SERVER_USAGE
        SERVER_USAGE=${SERVER_USAGE:-General Purpose Server}

        # Create custom MOTD script
        cat <<EOF | sudo tee /etc/update-motd.d/01-custom >/dev/null
#!/bin/sh
HOST=\$(hostname)

cat <<MOTD
***********************************************************************
*                         \$HOST
*                         USED FOR: $SERVER_USAGE
***********************************************************************
MOTD
EOF

        # Make the script executable
        sudo chmod +x /etc/update-motd.d/01-custom
        log_info "Created /etc/update-motd.d/01-custom"
        log_info "Server usage set to: $SERVER_USAGE"

        # Disable default MOTD components that may clutter the output (optional)
        # Users can re-enable these if desired
        if [ -f /etc/update-motd.d/10-help-text ]; then
            sudo chmod -x /etc/update-motd.d/10-help-text 2>/dev/null || true
            log_info "Disabled default help-text MOTD"
        fi
    fi
        mark_completed "CUSTOM_MOTD"
    else
        log_info "Custom MOTD skipped"
        mark_completed "CUSTOM_MOTD"
    fi
fi

###############################################################################
# /PROC FILESYSTEM HARDENING
###############################################################################

if skip_if_completed "PROC_HIDEPID"; then
    log_info "/proc filesystem already hardened, skipping"
else
    if ask_component_install \
        "/PROC FILESYSTEM HARDENING" \
        "proc-hidepid" \
        "Configure /proc with hidepid=2 to prevent users from seeing other users' processes." \
        "Security features:
• Users can only see their own processes
• Prevents information leakage about running processes
• Reduces reconnaissance possibilities for attackers
• Protects process command-line arguments and environment

Benefits:
• Better user isolation on multi-user systems
• Prevents privilege escalation reconnaissance
• Hides sensitive command-line data from other users
• Root can still see all processes

⚠️  IMPORTANT:
• Recommended for multi-user systems
• Safe for single-user VPS servers
• Docker/containers work fine
• System monitoring as root works fine
• Requires reboot to take full effect

Lynis recommendation: FILE-6000" \
        "$([ "$DESKTOP_MODE" = true ] && echo 'n' || echo 'y')"; then

    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Would add 'proc /proc proc defaults,hidepid=2 0 0' to /etc/fstab"
        log_dry_run "Would attempt to remount /proc with hidepid=2"
        log_dry_run "Note: Full effect requires reboot"
    else
        log_info "Configuring /proc with hidepid=2..."

        # Backup fstab
        sudo cp /etc/fstab /etc/fstab.backup.$(date +%Y%m%d_%H%M%S)
        log_info "Backed up /etc/fstab"

        # Check if /proc entry exists in fstab
        if grep -q "^proc.*/proc" /etc/fstab; then
            # Update existing entry
            sudo sed -i 's|^proc.*/proc.*|proc /proc proc defaults,hidepid=2 0 0|' /etc/fstab
            log_info "Updated existing /proc entry in fstab"
        else
            # Add new entry
            echo "proc /proc proc defaults,hidepid=2 0 0" | sudo tee -a /etc/fstab >/dev/null
            log_info "Added /proc with hidepid=2 to fstab"
        fi

        # Try to remount immediately
        if sudo mount -o remount,hidepid=2 /proc 2>/dev/null; then
            log_info "/proc remounted with hidepid=2 (active now)"
        else
            log_warning "Could not remount /proc immediately"
            log_warning "Changes will take effect on next reboot"
        fi

        log_info "/proc filesystem hardening configured"
    fi
        mark_completed "PROC_HIDEPID"
    else
        log_info "/proc filesystem hardening skipped"
        mark_completed "PROC_HIDEPID"
    fi
fi

###############################################################################
# WRITABLE FILESYSTEM HARDENING (noexec on /tmp, /var/tmp, /dev/shm)
###############################################################################
#
# /tmp, /var/tmp and /dev/shm are world-writable and, by default, executable.
# That combination is the standard staging ground for dropper malware: write a
# payload somewhere anyone can write, then run it. Mounting them noexec removes
# the second half. Lynis flags this as FILE-6310.
#
# noexec blocks execve() on files under the mount. It does NOT block
# `bash /tmp/script.sh` (the interpreter reads the file, it is never exec'd), so
# installers that are invoked through an interpreter keep working.

if skip_if_completed "MOUNT_HARDENING"; then
    log_info "Writable filesystem hardening already applied, skipping"
else
    if ask_component_install \
        "WRITABLE FILESYSTEM HARDENING" \
        "kernel-hardening" \
        "Mount /tmp, /var/tmp and /dev/shm as noexec,nosuid,nodev." \
        "Configuration:
• /tmp      -> noexec, nosuid, nodev (self bind mount, stays on disk)
• /var/tmp  -> noexec, nosuid, nodev (self bind mount, stays on disk)
• /dev/shm  -> noexec, nosuid, nodev (tmpfs)
• Applied immediately and persisted in /etc/fstab
• /etc/fstab is backed up first

Benefits:
• Payloads dropped into world-writable directories cannot be executed
• Blocks the most common staging path for dropper and proxyjacking kits
• Lynis FILE-6310

Known trade-offs:
• Some third-party installers extract to /tmp and exec directly. If one fails,
  run it from another directory or temporarily remount without noexec.
• /dev/shm noexec can break Chromium-based and Electron applications. It is
  safe on a headless server; consider skipping this on a desktop." \
        "$([ "$DESKTOP_MODE" = true ] && echo 'n' || echo 'y')"; then

        if [ "$DRY_RUN" = true ]; then
            log_dry_run "Would back up /etc/fstab"
            log_dry_run "Would add noexec,nosuid,nodev mounts for /tmp, /var/tmp, /dev/shm"
            log_dry_run "Would apply them immediately with mount --bind / mount -o remount"
            log_dry_run "Would verify the flags with findmnt"
        else
            log_info "Hardening writable filesystems..."

            sudo cp /etc/fstab /etc/fstab.backup.$(date +%Y%m%d_%H%M%S)
            log_info "Backed up /etc/fstab"

            harden_writable_mount() {
                local target="$1"
                local fstab_line="$2"

                # More than one entry for the same mount point is worse than
                # none: the flags stop surviving a daemon-reload, and nothing
                # reports it. Collapse duplicates before adding anything.
                local dupes
                dupes=$(awk -v t="$target" '$1 !~ /^#/ && $2 == t' /etc/fstab 2>/dev/null | wc -l)
                if [ "${dupes:-0}" -gt 1 ]; then
                    awk -v t="$target" '$1 ~ /^#/ || $2 != t || !seen++' /etc/fstab | \
                        sudo tee /etc/fstab.dedupe >/dev/null
                    if [ -s /etc/fstab.dedupe ] && \
                       [ "$(awk -v t="$target" '$1 !~ /^#/ && $2 == t' /etc/fstab.dedupe | wc -l)" -eq 1 ]; then
                        sudo mv /etc/fstab.dedupe /etc/fstab
                        log_info "Collapsed $((dupes - 1)) duplicate fstab entry/entries for $target"
                    else
                        sudo rm -f /etc/fstab.dedupe
                        log_warning "Could not safely deduplicate the $target entries in /etc/fstab"
                    fi
                fi

                if grep -qE "^[^#]*[[:space:]]${target}[[:space:]]" /etc/fstab; then
                    log_info "$target already has an fstab entry - leaving it alone"
                else
                    echo "$fstab_line" | sudo tee -a /etc/fstab >/dev/null
                    log_info "Added fstab entry for $target"
                fi

                # Apply now, without waiting for a reboot. For /tmp and /var/tmp
                # (normally part of the root filesystem) a self bind mount is
                # needed before the flags can be set.
                if ! mountpoint -q "$target" 2>/dev/null; then
                    sudo mount --bind "$target" "$target" 2>/dev/null || \
                        log_warning "Could not bind-mount $target"
                fi
                sudo mount -o remount,noexec,nosuid,nodev "$target" 2>/dev/null || \
                    log_warning "Could not apply noexec to $target - it will take effect after reboot"

                if findmnt -no OPTIONS "$target" 2>/dev/null | grep -q noexec; then
                    log_info "✓ $target is mounted noexec"
                else
                    log_warning "✗ $target is NOT noexec yet (applies after reboot)"
                fi
            }

            harden_writable_mount /tmp     "/tmp     /tmp     none  rw,noexec,nosuid,nodev,bind  0 0"
            harden_writable_mount /var/tmp "/var/tmp /var/tmp none  rw,noexec,nosuid,nodev,bind  0 0"
            harden_writable_mount /dev/shm "tmpfs    /dev/shm tmpfs rw,noexec,nosuid,nodev       0 0"

            # /dev/shm is not like the other two. systemd mounts it itself,
            # early, as an API filesystem, and on Ubuntu 24.04 the fstab entry
            # generates no unit at all: `systemctl list-units -t mount --all`
            # knows no dev-shm.mount and /run/systemd/generator holds nothing
            # for it. The remount above is then the only thing applying noexec,
            # and it is gone after the next reboot without a word.
            #
            # A remount service rather than a replacement dev-shm.mount unit:
            # overriding systemd's own mount means unmounting it, which takes
            # down everything holding shared memory. A remount interrupts
            # nothing.
            if [ -d /run/systemd/system ] && \
               ! systemctl list-units -t mount --all 2>/dev/null | grep -q 'dev-shm\.mount'; then
                cat <<'EOF' | sudo tee /etc/systemd/system/shm-noexec.service >/dev/null
[Unit]
Description=Apply noexec,nosuid,nodev to /dev/shm
Documentation=https://github.com/Made-By-Adem/linux-server-management-scripts
After=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/mount -o remount,noexec,nosuid,nodev /dev/shm

[Install]
WantedBy=multi-user.target
EOF
                sudo chmod 644 /etc/systemd/system/shm-noexec.service
                sudo systemctl daemon-reload
                if sudo systemctl enable --now shm-noexec.service >/dev/null 2>&1 && \
                   findmnt -no OPTIONS /dev/shm 2>/dev/null | grep -q noexec; then
                    log_info "✓ shm-noexec.service installed - /dev/shm is re-hardened at every boot"
                else
                    log_warning "shm-noexec.service did not take effect - check: systemctl status shm-noexec"
                fi
            fi

            log_info "Writable filesystem hardening applied"
            log_info "To undo:  sudo mount -o remount,exec /tmp   (and remove the line from /etc/fstab)"
        fi
        mark_completed "MOUNT_HARDENING"
    else
        log_info "Writable filesystem hardening skipped"
        mark_completed "MOUNT_HARDENING"
    fi
fi

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
    if [ "$DESKTOP_MODE" = true ]; then
        echo "Desktop mode: SSH will be hardened with password authentication ENABLED."
        echo ""
        echo "The script will:"
        echo "  1. Keep SSH on port 22 (no port 888)"
        echo "  2. Apply security hardening (keep password auth, enable X11Forwarding)"
        echo "  3. Restart SSH service"
    else
        echo "⚠️  WARNING: Changing SSH port can lock you out of your server!"
        echo ""
        echo "The script will:"
        echo "  1. Add port 888 for SSH (keeping port 22 active)"
        echo "  2. Apply security hardening (disable root, password auth, etc.)"
        echo "  3. Restart SSH with BOTH ports 22 and 888 active"
        echo ""
        echo "Port 22 stays open deliberately, as your way back in if something"
        echo "about port 888 turns out to be wrong. Closing it is a separate,"
        echo "manual step - and one you should only take after proving 888 works."
        echo ""
        echo "══════════════════════════════════════════════════════════════════"
        echo "  HOW TO CLOSE PORT 22 WITHOUT LOCKING YOURSELF OUT"
        echo "══════════════════════════════════════════════════════════════════"
        echo ""
        echo "  The rule: NEVER close port 22 from the only session you have."
        echo "  If the new port does not work, that session is your only way"
        echo "  back in - and you will have just cut it."
        echo ""
        echo "  1. KEEP THIS TERMINAL OPEN. Do not log out. Do not close it."
        echo ""
        echo "  2. Open a SECOND terminal and connect on the new port:"
        echo ""
        echo "        ssh -p 888 $ACTUAL_USER@$SERVER_IP"
        echo ""
        echo "  3. Only if that second session works, run IN THAT SESSION."
        echo "     The command depends on which mechanism owns the port -"
        echo "     the script will tell you which at the end of the run:"
        echo ""
        echo "     With socket activation (Ubuntu 22.10+, Debian 12):"
        echo "        sudo sed -i '/:22\$/d' /etc/systemd/system/ssh.socket.d/ports.conf"
        echo "        sudo systemctl daemon-reload && sudo systemctl restart ssh.socket"
        echo ""
        echo "     Without socket activation:"
        echo "        sudo sed -i '/^Port 22\$/d' /etc/ssh/sshd_config"
        echo "        sudo systemctl restart ssh"
        echo ""
        echo "     Then in both cases:"
        echo "        sudo ufw delete allow 22/tcp"
        echo "        sudo ss -tlnp | grep ':22 '     # must print nothing"
        echo ""
        echo "  4. Now open a THIRD terminal and confirm you can still get in"
        echo "     on 888. Only then close the first terminal."
        echo ""
        echo "  If step 2 fails: change nothing. You still have this session."
        echo "  Check 'sudo ss -tlnp | grep 888' and 'sudo ufw status'."
        echo ""
        echo "  On a VPS, check the provider firewall too (Hetzner Cloud"
        echo "  Firewall, AWS security groups). It sits above UFW and can block"
        echo "  888 while everything on the host looks correct."
        echo ""
        echo "  Rescue route if you do lock yourself out: the provider's web"
        echo "  console. Make sure you know where it is BEFORE you need it."
        echo "══════════════════════════════════════════════════════════════════"
    fi
    echo ""
    read -p "Do you want to proceed with SSH hardening? (y/n): " ssh_harden
    ssh_harden=${ssh_harden:-y}

    if [[ $ssh_harden == "y" ]] || [[ $ssh_harden == "Y" ]]; then
    log_info "Hardening SSH configuration..."

    # Backup original sshd_config
    sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup.$(date +%Y%m%d_%H%M%S)

    if [ "$DESKTOP_MODE" = true ]; then
        log_info "Desktop mode: password authentication stays enabled, skipping SSH key verification"
    else
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
            echo "Recommended: Cancel now (Ctrl+C) and run: ssh-copy-id ${USER:-$ACTUAL_USER}@$(hostname -I | awk '{print $1}')"
            echo "═══════════════════════════════════════════════════════════"
            read -p "Continue anyway? (y/N): " continue_without_keys
            continue_without_keys=${continue_without_keys:-n}
            if [[ ! $continue_without_keys =~ ^[Yy]$ ]]; then
                handle_error "SSH hardening cancelled - please configure SSH keys first"
            fi
            log_warning "User chose to continue without SSH keys - RISK OF LOCKOUT!"
        else
            log_info "SSH keys verified in authorized_keys"
        fi
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
    read -p "Disable IPv6? (Y/n, default: Y): " disable_ipv6
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
    read -p "Enable SSH forwarding? (Y/n, default: Y): " enable_ssh_forwarding
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
    if [ "$DESKTOP_MODE" = true ]; then
        sudo sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication yes/' /etc/ssh/sshd_config
    else
        sudo sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config
    fi
    sudo sed -i 's/^#\?PubkeyAuthentication .*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
    # ChallengeResponseAuthentication was renamed to KbdInteractiveAuthentication
    # in OpenSSH 8.7. Ubuntu 24.04 ships 9.6, where the old name is only a
    # deprecated alias: sshd accepts it but logs a deprecation warning on every
    # config parse, and it will stop working at some point. The stock 24.04
    # sshd_config does not contain the old directive at all, so the sed below
    # used to match nothing and the setting was silently never applied.
    sudo sed -i '/^#\?ChallengeResponseAuthentication /d' /etc/ssh/sshd_config
    sudo sed -i 's/^#\?KbdInteractiveAuthentication .*/KbdInteractiveAuthentication no/' /etc/ssh/sshd_config
    grep -q "^KbdInteractiveAuthentication " /etc/ssh/sshd_config || \
        echo "KbdInteractiveAuthentication no" | sudo tee -a /etc/ssh/sshd_config >/dev/null

    # Configure AddressFamily based on IPv6 choice
    if [ "$IPV6_DISABLED" = true ]; then
        sudo sed -i 's/^#\?AddressFamily .*/AddressFamily inet/' /etc/ssh/sshd_config
        log_info "SSH configured for IPv4 only"
    else
        sudo sed -i 's/^#\?AddressFamily .*/AddressFamily any/' /etc/ssh/sshd_config
        log_info "SSH configured for IPv4 and IPv6"
    fi
    if [ "$DESKTOP_MODE" = true ]; then
        sudo sed -i 's/^#\?X11Forwarding .*/X11Forwarding yes/' /etc/ssh/sshd_config
    else
        sudo sed -i 's/^#\?X11Forwarding .*/X11Forwarding no/' /etc/ssh/sshd_config
    fi
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

    # ------------------------------------------------------------------------
    # Listening ports: ONE source of truth
    #
    # Ubuntu 22.10+ and Debian 12 socket-activate sshd through ssh.socket. When
    # that is in use, sshd_config's Port directive is IGNORED entirely - the
    # kernel socket is opened by systemd and handed to sshd. Writing the port to
    # both places produces two settings that can silently disagree, and makes
    # "delete Port 22 from sshd_config" a no-op that leaves the port wide open.
    #
    # So: whichever mechanism is actually in charge is the only one configured.
    if systemctl is-enabled ssh.socket >/dev/null 2>&1 || \
       systemctl is-active ssh.socket >/dev/null 2>&1; then
        SSH_SOCKET_ACTIVATED=true
    else
        SSH_SOCKET_ACTIVATED=false
    fi

    # Socket activation comes in two flavours, and only one of them makes
    # sshd_config's Port directives dead weight. Ubuntu 24.04 ships
    # sshd-socket-generator, which reads those directives and compiles them into
    # ssh.socket at every daemon-reload - there they are the SOURCE.
    SSH_SOCKET_GENERATOR=false
    [ -f /run/systemd/generator/ssh.socket.d/addresses.conf ] && SSH_SOCKET_GENERATOR=true

    if [ "$SSH_SOCKET_ACTIVATED" = true ] && [ "$SSH_SOCKET_GENERATOR" = true ]; then
        # Keep the ports in sshd_config and let the generator compile them.
        #
        # This script used to delete them on every socket-activated host, which
        # here removes the only place the port is defined. Nothing changes at
        # the time - the socket is already listening - so it looks like it
        # worked. The next reboot regenerates the socket from an sshd_config
        # with no Port line, sshd comes back on 22, and the hardened port is
        # gone on a machine whose firewall only allows the hardened port.
        sudo sed -i '/^#\?Port /d' /etc/ssh/sshd_config
        if [ "$DESKTOP_MODE" = true ]; then
            sudo sed -i '1i Port 22' /etc/ssh/sshd_config
        else
            sudo sed -i '1i Port 22\nPort 888' /etc/ssh/sshd_config
        fi
        sudo sshd -t 2>/dev/null && log_info "sshd config validates with the Port directives in place" || \
            log_warning "sshd -t did not pass - check /etc/ssh/sshd_config before restarting"
        log_info "Socket activation with sshd-socket-generator: sshd_config carries the ports"
        log_info "  Apply changes with: systemctl daemon-reload && systemctl restart ssh.socket"
        log_info "  Restarting ssh.service alone does nothing"
    elif [ "$SSH_SOCKET_ACTIVATED" = true ]; then
        # ssh.socket owns the ports. Keep sshd_config free of Port directives so
        # there is nothing to contradict it and nothing misleading to edit.
        sudo sed -i '/^#\?Port /d' /etc/ssh/sshd_config
        if ! grep -q "^# Listening ports are managed by ssh.socket" /etc/ssh/sshd_config; then
            {
                echo ""
                echo "# Listening ports are managed by ssh.socket, not by this file."
                echo "# systemd opens the socket and hands it to sshd, so a Port directive"
                echo "# here has NO effect. Change ports in:"
                echo "#   /etc/systemd/system/ssh.socket.d/ports.conf"
                echo "# then: systemctl daemon-reload && systemctl restart ssh.socket"
            } | sudo tee -a /etc/ssh/sshd_config >/dev/null
        fi
        log_info "Socket activation detected: ssh.socket is the single source of truth for ports"
        log_info "  sshd_config Port directives removed (they would be ignored anyway)"
    else
        # No socket activation: sshd_config is authoritative. Do not leave a
        # ports.conf behind that would take over after a distribution upgrade.
        if [ -f /etc/systemd/system/ssh.socket.d/ports.conf ]; then
            sudo rm -f /etc/systemd/system/ssh.socket.d/ports.conf
            sudo systemctl daemon-reload 2>/dev/null || true
            log_info "Removed stale ssh.socket.d/ports.conf (socket activation is not in use)"
        fi
        if [ "$DESKTOP_MODE" = true ]; then
            grep -q "^Port 22$" /etc/ssh/sshd_config || echo "Port 22" | sudo tee -a /etc/ssh/sshd_config >/dev/null
        else
            grep -q "^Port 22$" /etc/ssh/sshd_config || echo "Port 22" | sudo tee -a /etc/ssh/sshd_config >/dev/null
            grep -q "^Port 888$" /etc/ssh/sshd_config || echo "Port 888" | sudo tee -a /etc/ssh/sshd_config >/dev/null
        fi
        log_info "No socket activation: sshd_config is the single source of truth for ports"
    fi

    # 'Protocol 2' was removed from OpenSSH in 7.6 (2017). SSH protocol 1 no
    # longer exists in the codebase, so the directive secures nothing - it only
    # makes sshd log "Deprecated option Protocol" on every config parse, which
    # is noise in the `sshd -t` output this script relies on for validation.
    # Remove it rather than add it, including on hosts where an earlier run
    # already wrote it.
    sudo sed -i '/^#\?Protocol [0-9]/d' /etc/ssh/sshd_config

    # MaxSessions configuration with user prompt (Lynis SSH-7408)
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "SSH MaxSessions Configuration"
    echo "═══════════════════════════════════════════════════════════"
    echo ""
    echo "MaxSessions limits concurrent multiplexed sessions per SSH connection."
    echo ""
    echo "Recommended values:"
    echo "  • 2  - High security (single user, minimal sessions)"
    echo "  • 5  - Balanced (normal usage with some tmux/screen)"
    echo "  • 10 - Permissive (heavy tmux/screen usage, multiple terminals)"
    echo ""
    echo "Current default: 10"
    echo ""
    if [ "$DESKTOP_MODE" = true ]; then
        max_sessions_default=10
    else
        max_sessions_default=2
    fi
    read -p "Enter MaxSessions value (1-10, default: $max_sessions_default): " max_sessions
    max_sessions=${max_sessions:-$max_sessions_default}

    # Validate input
    if ! [[ "$max_sessions" =~ ^[0-9]+$ ]] || [ "$max_sessions" -lt 1 ] || [ "$max_sessions" -gt 10 ]; then
        log_warning "Invalid MaxSessions value: $max_sessions, using default: $max_sessions_default"
        max_sessions=$max_sessions_default
    fi

    # Apply MaxSessions
    if grep -q "^MaxSessions" /etc/ssh/sshd_config; then
        sudo sed -i "s/^MaxSessions .*/MaxSessions $max_sessions/" /etc/ssh/sshd_config
    else
        echo "MaxSessions $max_sessions" | sudo tee -a /etc/ssh/sshd_config >/dev/null
    fi
    log_info "SSH MaxSessions set to $max_sessions"

    # Additional Lynis recommendations (SSH-7408)
    # TCPKeepAlive
    sudo sed -i 's/^#\?TCPKeepAlive .*/TCPKeepAlive no/' /etc/ssh/sshd_config
    grep -q "^TCPKeepAlive" /etc/ssh/sshd_config || echo "TCPKeepAlive no" | sudo tee -a /etc/ssh/sshd_config >/dev/null
    log_info "SSH TCPKeepAlive set to no (Lynis recommendation)"

    # Banner configuration (if legal banners were configured)
    if [ -f /etc/issue.net ]; then
        sudo sed -i 's/^#\?Banner .*/Banner \/etc\/issue.net/' /etc/ssh/sshd_config
        grep -q "^Banner" /etc/ssh/sshd_config || echo "Banner /etc/issue.net" | sudo tee -a /etc/ssh/sshd_config >/dev/null
        log_info "SSH Banner configured to display legal warning"
    fi

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

    if [ "$DESKTOP_MODE" = true ]; then
        log_info "Desktop mode: SSH stays on port 22 only, skipping rate limiting config"
    else
        SSH_PORT_NEW=888

        log_info "Configuring SSH firewall rules..."

        # No trusted-IP allowlist is created here, on purpose.
        #
        # Earlier versions prompted for a "trusted home IP" and wrote a
        # permanent `ufw allow from <ip>` rule. Home and mobile addresses are
        # not permanent: the rule outlives the address, and the address gets
        # reassigned to someone else. A stale allowlist entry is a standing
        # grant to a stranger, and nothing ever prompts you to review it.
        #
        # Rate limiting on 888 (`ufw limit`, configured earlier) protects
        # everyone equally and needs no maintenance. If you genuinely need an
        # exemption, add it yourself and put the date in the comment:
        #
        #   sudo ufw allow from <ip> to any port 888 comment "SSH exemption 2026-08-11 - review quarterly"
        log_info "SSH firewall: rate limiting active on port $SSH_PORT_NEW for all sources"
        log_info "No permanent IP allowlist is created - stale entries outlive the address"
    fi

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
    if [ "$DESKTOP_MODE" = true ]; then
        log_info "Configuring systemd SSH socket for port 22..."
    else
        log_info "Configuring systemd SSH socket for ports 22 and 888..."
    fi

    # Only configure ssh.socket when it is genuinely in charge. The unit file
    # exists on Ubuntu whether or not socket activation is enabled, so testing
    # for its presence (as this did before) would create a ports.conf on hosts
    # where sshd_config is authoritative - two sources of truth again.
    if [ "${SSH_SOCKET_ACTIVATED:-false}" = true ]; then
        log_info "Detected systemd socket activation, configuring ssh.socket..."

    # On a generator host there is nothing to write here: the Port directives
    # kept in sshd_config above are the source, and a ports.conf would become a
    # SECOND drop-in feeding the same unit - after which which one wins depends
    # on drop-in ordering and on whether the /etc file resets the list.
    if [ "${SSH_SOCKET_GENERATOR:-false}" = true ]; then
        if [ -f /etc/systemd/system/ssh.socket.d/ports.conf ]; then
            # Renamed, not deleted, and to something systemd does not read:
            # only *.conf is picked up as a drop-in.
            sudo mv /etc/systemd/system/ssh.socket.d/ports.conf \
                    "/etc/systemd/system/ssh.socket.d/ports.conf.superseded.$(date +%Y%m%d_%H%M%S)"
            log_info "Moved an older ports.conf aside - sshd_config is the source on this host"
        fi
        log_info "Ports come from sshd_config, compiled into ssh.socket by sshd-socket-generator"
    else

        # Create systemd override directory
        sudo mkdir -p /etc/systemd/system/ssh.socket.d

        # Create override configuration for SSH socket
        # Must explicitly bind to 0.0.0.0 — bare port numbers default to [::] (IPv6)
        # which fails when IPv6 is disabled at the system level
        if [ "$DESKTOP_MODE" = true ]; then
            if [ "$IPV6_DISABLED" = true ]; then
                cat <<EOF | sudo tee /etc/systemd/system/ssh.socket.d/ports.conf
[Socket]
ListenStream=
ListenStream=0.0.0.0:22
EOF
                log_info "SSH socket configured for port 22 (IPv4 only)"
            else
                cat <<EOF | sudo tee /etc/systemd/system/ssh.socket.d/ports.conf
[Socket]
ListenStream=
ListenStream=0.0.0.0:22
ListenStream=[::]:22
EOF
                log_info "SSH socket configured for port 22 (IPv4 + IPv6)"
            fi
        elif [ "$IPV6_DISABLED" = true ]; then
            cat <<EOF | sudo tee /etc/systemd/system/ssh.socket.d/ports.conf
[Socket]
ListenStream=
ListenStream=0.0.0.0:22
ListenStream=0.0.0.0:888
EOF
            log_info "SSH socket configured for ports 22 and 888 (IPv4 only)"
        else
            cat <<EOF | sudo tee /etc/systemd/system/ssh.socket.d/ports.conf
[Socket]
ListenStream=
ListenStream=0.0.0.0:22
ListenStream=0.0.0.0:888
ListenStream=[::]:22
ListenStream=[::]:888
EOF
            log_info "SSH socket configured for ports 22 and 888 (IPv4 + IPv6)"
        fi
    fi

        # Reload systemd configuration and restart SSH socket
        log_info "Reloading systemd daemon..."
        sudo systemctl daemon-reload || log_warning "Failed to reload systemd daemon"

        # Stop and start ssh.socket to ensure clean state
        log_info "Restarting SSH socket and service..."
        sudo systemctl stop ssh.socket 2>/dev/null || true
        sudo systemctl stop ssh 2>/dev/null || true
        sleep 1
        sudo systemctl start ssh.socket || log_warning "Failed to start ssh.socket"
        sudo systemctl start ssh || sudo systemctl start sshd || handle_error "Failed to start SSH service"

        # Wait for SSH to fully start
        sleep 3

        if [ "$DESKTOP_MODE" = true ]; then
            # Desktop: only verify port 22
            if ss -tlnp 2>/dev/null | grep -q ":22"; then
                log_info "Verified: SSH is listening on port 22"
            else
                log_warning "SSH not listening on port 22, attempting restart..."
                sudo systemctl daemon-reload
                sudo systemctl restart ssh.socket 2>/dev/null || true
                sudo systemctl restart ssh 2>/dev/null || sudo systemctl restart sshd 2>/dev/null || true
            fi
        else
            # Server: verify both ports with retry
            log_info "Verifying SSH is listening on ports 22 and 888..."
            RETRY_COUNT=0
            MAX_RETRIES=3
            SSH_VERIFIED=false

            while [ $RETRY_COUNT -lt $MAX_RETRIES ] && [ "$SSH_VERIFIED" = false ]; do
                if ss -tlnp 2>/dev/null | grep -q ":888" && ss -tlnp 2>/dev/null | grep -q ":22"; then
                    log_info "Verified: SSH is listening on both port 22 and 888"
                    SSH_VERIFIED=true
                else
                    RETRY_COUNT=$((RETRY_COUNT + 1))
                    if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
                        log_warning "SSH not yet listening on both ports, retrying ($RETRY_COUNT/$MAX_RETRIES)..."
                        sudo systemctl restart ssh.socket 2>/dev/null || true
                        sudo systemctl restart ssh 2>/dev/null || true
                        sleep 3
                    fi
                fi
            done

            if [ "$SSH_VERIFIED" = false ]; then
                log_warning "SSH verification failed after $MAX_RETRIES attempts"
                log_warning "Current SSH listening status:"
                ss -tlnp 2>/dev/null | grep -E "(ssh|:22|:888)" || echo "  No SSH ports found"
                log_warning "Attempting full daemon-reload and restart..."
                sudo systemctl daemon-reload
                sudo systemctl restart ssh.socket 2>/dev/null || true
                sudo systemctl restart ssh 2>/dev/null || sudo systemctl restart sshd 2>/dev/null || true
                sleep 3
                if ss -tlnp 2>/dev/null | grep -q ":888"; then
                    log_info "SSH now listening on port 888 after full restart"
                else
                    log_warning "SSH still not on port 888. Manual fix: sudo systemctl daemon-reload && sudo systemctl restart ssh.socket && sudo systemctl restart ssh"
                fi
            fi
        fi
    else
        # Fallback for systems without socket activation (older systems)
        log_info "No systemd socket activation detected, restarting SSH service..."
        sudo systemctl daemon-reload
        sudo systemctl restart ssh || sudo systemctl restart sshd || handle_error "Failed to restart SSH service"
    fi

        log_info "SSH hardened successfully"
        if [ "$DESKTOP_MODE" = true ]; then
            log_info "SSH is listening on port 22 (password auth enabled)"
        else
            log_info "SSH is now listening on BOTH port 22 and 888"
        fi
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

if skip_if_completed "FAIL2BAN"; then
    log_info "Fail2ban already configured, skipping"
else
    if [ "$DESKTOP_MODE" = true ]; then
        fail2ban_desc="Configure Fail2ban to protect against brute-force attacks on SSH."
        fail2ban_impl="Configuration (desktop mode):
• SSH protection on port 22
• Max 5 failed attempts allowed
• Ban time: 1 hour (3600s)
• Detection window: 10 minutes (600s)
• Reads the systemd journal (backend = systemd)

Benefits:
• Automatic blocking of brute-force attacks
• Protection against SSH password guessing"
        fail2ban_default="n"
    else
        fail2ban_desc="Configure Fail2ban to protect against brute-force attacks on SSH."
        fail2ban_impl="Configuration:
• SSH protection on ports 22 and 888
• Max 3 failed attempts allowed
• Ban time: 2 hours (7200s)
• Detection window: 10 minutes (600s)
• Reads the systemd journal (backend = systemd)
• Verifies after install that the jail is really active

Benefits:
• Automatic blocking of brute-force attacks
• Protection against SSH password guessing
• Reduces server load from attack attempts
• Configurable and extensible"
        fail2ban_default="y"
    fi
    if ask_component_install \
        "FAIL2BAN INTRUSION PREVENTION" \
        "fail2ban" \
        "$fail2ban_desc" \
        "$fail2ban_impl" \
        "$fail2ban_default"; then

    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Would backup existing /etc/fail2ban/jail.local if present"
        log_dry_run "Would remove /etc/fail2ban/jail.local if it is a verbatim copy of jail.conf"
        log_dry_run "  (it is read after jail.d/*.conf and silently overrides the baseline)"
        log_dry_run "Would remove superseded /etc/fail2ban/jail.d/server-baseline.conf"
        log_dry_run "Would create /etc/fail2ban/jail.d/zz-server-baseline.local with:"
        log_dry_run "  - SSH jail enabled on ports 22,888"
        log_dry_run "  - backend = systemd (Ubuntu 24.04 has no /var/log/auth.log)"
        log_dry_run "  - journalmatch = _SYSTEMD_UNIT=ssh.service"
        log_dry_run "  - Max retries: 3"
        log_dry_run "  - Ban time: 7200s (2 hours)"
        log_dry_run "  - Find time: 600s (10 minutes)"
        log_dry_run "Would enable and restart fail2ban service"
        log_dry_run "Would verify with 'fail2ban-client status sshd' that the jail is live"
    else
        log_info "Configuring Fail2ban..."

        # Backup original jail.local if it exists
        if [ -f /etc/fail2ban/jail.local ]; then
            sudo cp /etc/fail2ban/jail.local /etc/fail2ban/jail.local.backup.$(date +%Y%m%d_%H%M%S)
            log_info "Backed up existing jail.local"
        fi

        # Fail2ban reads its configuration in this order, last one wins:
        #   jail.conf  ->  jail.d/*.conf  ->  jail.local  ->  jail.d/*.local
        #
        # Earlier versions of this script copied jail.conf to jail.local. That was
        # wrong: jail.local is read AFTER jail.d/*.conf, so a verbatim copy of the
        # upstream defaults silently overrode every setting written below - including
        # the port list and the log backend. The jail looked configured and banned
        # nothing. Config now goes into jail.d/*.local, which is read last.
        if [ -f /etc/fail2ban/jail.local ] && \
           sudo cmp -s /etc/fail2ban/jail.local /etc/fail2ban/jail.conf 2>/dev/null; then
            sudo rm -f /etc/fail2ban/jail.local
            log_warning "Removed /etc/fail2ban/jail.local (verbatim copy of jail.conf)"
            log_warning "It overrode the baseline jail settings - backup kept alongside it"
        fi

        # Remove the config file written by earlier versions of this script; its
        # settings are superseded by the .local file created below.
        if [ -f /etc/fail2ban/jail.d/server-baseline.conf ]; then
            sudo rm -f /etc/fail2ban/jail.d/server-baseline.conf
            log_info "Removed superseded /etc/fail2ban/jail.d/server-baseline.conf"
        fi

        # Create jail.d directory if it doesn't exist
        sudo mkdir -p /etc/fail2ban/jail.d

        # backend = systemd requires the python3-systemd bindings. It is only a
        # Recommends of the fail2ban package, so a minimal image or an install
        # done with --no-install-recommends leaves it out - and then the jail
        # fails to initialise with "Failed to initialize any backend". That is
        # the exact silent-failure mode this section exists to eliminate, so the
        # dependency is made explicit rather than assumed.
        if ! python3 -c "import systemd.journal" >/dev/null 2>&1; then
            log_info "Installing python3-systemd (required for backend = systemd)..."
            DEBIAN_FRONTEND=noninteractive sudo apt-get install -y python3-systemd || \
                log_warning "Failed to install python3-systemd - the jail may not start"
        fi

        # Ubuntu 24.04 and Debian 12 no longer write /var/log/auth.log; sshd logs
        # to the journal only. A jail pointed at auth.log starts, reports "enabled"
        # and never bans anything. backend=systemd reads the journal directly.
        if [ "$DESKTOP_MODE" = true ]; then
            cat <<EOF | sudo tee /etc/fail2ban/jail.d/zz-server-baseline.local
# System Baseline Fail2ban Configuration (Desktop Mode)
# Created by system baseline installation script
#
# Filename note: read order is jail.conf -> jail.d/*.conf -> jail.local ->
# jail.d/*.local. This file must be read last, hence the .local extension.

[DEFAULT]
backend  = systemd
bantime  = 3600
findtime = 600
maxretry = 5

[sshd]
enabled      = true
port         = 22
filter       = sshd
backend      = systemd
journalmatch = _SYSTEMD_UNIT=ssh.service
maxretry     = 5
bantime      = 3600
findtime     = 600
EOF
        else
            cat <<EOF | sudo tee /etc/fail2ban/jail.d/zz-server-baseline.local
# Server Baseline Fail2ban Configuration
# Created by server_baseline installation script
#
# Filename note: read order is jail.conf -> jail.d/*.conf -> jail.local ->
# jail.d/*.local. This file must be read last, hence the .local extension.

[DEFAULT]
# Default ban settings for all jails
backend  = systemd
bantime  = 3600
findtime = 600
maxretry = 5

[sshd]
# SSH protection - monitors both ports 22 and 888
enabled      = true
port         = 22,888
filter       = sshd
backend      = systemd
journalmatch = _SYSTEMD_UNIT=ssh.service
maxretry     = 3
bantime      = 7200
findtime     = 600
EOF
        fi

        log_info "Fail2ban configuration created in /etc/fail2ban/jail.d/zz-server-baseline.local"
        log_info "Existing custom jails are preserved"

        sudo systemctl enable fail2ban || handle_error "Failed to enable Fail2ban"
        sudo systemctl restart fail2ban || handle_error "Failed to restart Fail2ban"

        # Verify the jail is actually live. "systemctl restart succeeded" is not
        # evidence that the jail works - that was exactly the failure mode this
        # section is being fixed for.
        log_info "Verifying that the sshd jail is actually active..."
        F2B_OK=false
        for _attempt in 1 2 3 4 5 6 7 8 9 10; do
            if sudo fail2ban-client status sshd >/dev/null 2>&1; then
                F2B_OK=true
                break
            fi
            sleep 2
        done

        if [ "$F2B_OK" = true ]; then
            log_info "✓ Fail2ban sshd jail is active and reachable"
            sudo fail2ban-client status sshd || true
            log_info "Check periodically that the ban counter is non-zero:"
            log_info "  sudo fail2ban-client status sshd"
            log_info "A jail reporting 0 bans while the journal shows failed logins is a fault, not a success."
        else
            log_warning "✗ Fail2ban restarted but the sshd jail did not come up"
            log_warning "  Diagnose with: sudo fail2ban-client -d | grep sshd"
            log_warning "  and:           sudo journalctl -u fail2ban -n 50"
        fi
    fi
        mark_completed "FAIL2BAN"
    else
        log_info "Fail2ban configuration skipped"
        mark_completed "FAIL2BAN"
    fi
fi

###############################################################################
# SYSTEMD SERVICE HARDENING
###############################################################################

if skip_if_completed "SYSTEMD_HARDENING"; then
    log_info "Systemd services already hardened, skipping"
else
    if ask_component_install \
        "SYSTEMD SERVICE HARDENING" \
        "systemd-hardening" \
        "Apply systemd security hardening to system services for improved security." \
        "Available services for hardening:
• SSH: ProtectSystem=off (VSCode/Docker compatible)
• Fail2ban: Full isolation
• Cron: Filesystem protection
• Postfix: Strict isolation + capability restrictions
• Rsyslog: Full protection suite
• Unattended-upgrades: Filesystem isolation
• Containerd: Container-compatible hardening
• Networkd-dispatcher: Full isolation
• Snapd: Limited hardening

You will be asked per service whether to apply hardening.

SSH Configuration (Maximum Compatibility):
• ProtectSystem=off: System directories (/usr, /boot, most of /etc) read-only
• ReadWritePaths: /etc/ufw, /tmp, /var/tmp, /etc/systemd/system, /etc/docker
• VSCode Remote SSH compatible
• Docker volume mounts from /home/ compatible

Benefits:
• Service isolation and reduced attack surface
• Dramatically improved security scores
• Practical server management without compatibility issues

⚠️  Services will be restarted after configuration
Lynis recommendation: BOOT-5264" \
        "y"; then

    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Would ask per service whether to apply hardening"
        log_dry_run "Available services: SSH, Docker, Fail2ban, Cron, Postfix, Rsyslog, Unattended-upgrades, Containerd, Networkd-dispatcher, Snapd"
        log_dry_run "Would reload systemd daemon and restart selected services"
    else
        log_info "Applying systemd service hardening..."
        echo ""

        # SSH service hardening
        read -p "Harden SSH service? (Y/n): " harden_ssh
        harden_ssh=${harden_ssh:-y}
        if [[ $harden_ssh =~ ^[Yy]$ ]]; then
            log_info "Hardening SSH service..."
            sudo mkdir -p /etc/systemd/system/ssh.service.d

            cat <<'EOF' | sudo tee /etc/systemd/system/ssh.service.d/hardening.conf >/dev/null
[Service]
# Systemd hardening for SSH - VSCode and Docker compatible
ProtectSystem=off
# VSCode Remote SSH needs write access to ~/.vscode-server/
# Docker containers need access to volume mounts from /home/
# Security audit tools need access to run manually via SSH
ReadWritePaths=/etc/ufw /tmp /var/tmp /etc/systemd/system /etc/docker
EOF

            log_info "✓ SSH service hardened"
        else
            log_info "⊘ SSH hardening skipped"
        fi

        # Fail2ban service hardening (if installed)
        if systemctl list-unit-files | grep -q "fail2ban.service"; then
            read -p "Harden Fail2ban service? (Y/n): " harden_fail2ban
            harden_fail2ban=${harden_fail2ban:-y}
            if [[ $harden_fail2ban =~ ^[Yy]$ ]]; then
                log_info "Hardening Fail2ban service..."
                sudo mkdir -p /etc/systemd/system/fail2ban.service.d

                cat <<'EOF' | sudo tee /etc/systemd/system/fail2ban.service.d/hardening.conf >/dev/null
[Service]
# Systemd hardening for Fail2ban
ProtectSystem=strict
ProtectHome=read-only
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
ReadWritePaths=/var/run/fail2ban /var/lib/fail2ban /var/log /var/spool/postfix/maildrop /etc/ufw
EOF

                log_info "✓ Fail2ban service hardened"
            else
                log_info "⊘ Fail2ban hardening skipped"
            fi
        fi

        # Cron service hardening
        if systemctl list-unit-files | grep -q "cron.service"; then
            read -p "Harden Cron service? (Y/n): " harden_cron
            harden_cron=${harden_cron:-y}
            if [[ $harden_cron =~ ^[Yy]$ ]]; then
                log_info "Hardening Cron service..."
                sudo mkdir -p /etc/systemd/system/cron.service.d

                cat <<'EOF' | sudo tee /etc/systemd/system/cron.service.d/hardening.conf >/dev/null
[Service]
# Systemd hardening for Cron
ProtectSystem=off
EOF

                log_info "✓ Cron service hardened"
            else
                log_info "⊘ Cron hardening skipped"
            fi
        fi

        # Postfix service hardening
        if systemctl list-unit-files | grep -q "postfix.service\|postfix@-.service"; then
            read -p "Harden Postfix service? (Y/n): " harden_postfix
            harden_postfix=${harden_postfix:-y}
            if [[ $harden_postfix =~ ^[Yy]$ ]]; then
                log_info "Hardening Postfix service..."
                sudo mkdir -p /etc/systemd/system/postfix@-.service.d

                cat <<'EOF' | sudo tee /etc/systemd/system/postfix@-.service.d/hardening.conf >/dev/null
[Service]
# Systemd hardening for Postfix mail server
PrivateDevices=yes
ProtectSystem=strict
ReadWritePaths=/var/spool/postfix /var/lib/postfix /var/mail /var/log
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
RestrictSUIDSGID=yes
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
CapabilityBoundingSet=CAP_DAC_OVERRIDE CAP_SETUID CAP_SETGID CAP_CHOWN CAP_FOWNER CAP_NET_BIND_SERVICE
SystemCallFilter=@system-service
SystemCallFilter=~@privileged @resources
SystemCallErrorNumber=EPERM
SystemCallArchitectures=native
RestrictNamespaces=yes
RestrictRealtime=yes
LockPersonality=yes
ProtectHostname=yes
ProtectClock=yes
ProtectProc=invisible
ProcSubset=pid
EOF

                log_info "✓ Postfix service hardened"
            else
                log_info "⊘ Postfix hardening skipped"
            fi
        fi

        # Rsyslog service hardening
        if systemctl list-unit-files | grep -q "rsyslog.service"; then
            read -p "Harden Rsyslog service? (Y/n): " harden_rsyslog
            harden_rsyslog=${harden_rsyslog:-y}
            if [[ $harden_rsyslog =~ ^[Yy]$ ]]; then
                log_info "Hardening Rsyslog service..."
                sudo mkdir -p /etc/systemd/system/rsyslog.service.d

                cat <<'EOF' | sudo tee /etc/systemd/system/rsyslog.service.d/hardening.conf >/dev/null
[Service]
# Systemd hardening for Rsyslog
PrivateDevices=yes
ProtectSystem=strict
ReadWritePaths=/var/log /var/spool/rsyslog /run/rsyslog
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=no
ProtectControlGroups=yes
RestrictSUIDSGID=yes
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK
CapabilityBoundingSet=CAP_DAC_READ_SEARCH CAP_SYSLOG CAP_NET_BIND_SERVICE CAP_SETUID CAP_SETGID
SystemCallFilter=@system-service
SystemCallFilter=~@privileged @resources @obsolete
SystemCallErrorNumber=EPERM
SystemCallArchitectures=native
RestrictNamespaces=no
RestrictRealtime=yes
LockPersonality=yes
ProtectHostname=yes
ProtectClock=yes
EOF

                log_info "✓ Rsyslog service hardened"
            else
                log_info "⊘ Rsyslog hardening skipped"
            fi
        fi

        # Unattended-upgrades service hardening
        if systemctl list-unit-files | grep -q "unattended-upgrades.service"; then
            read -p "Harden Unattended-upgrades service? (Y/n): " harden_unattended
            harden_unattended=${harden_unattended:-y}
            if [[ $harden_unattended =~ ^[Yy]$ ]]; then
                log_info "Hardening Unattended-upgrades service..."
                sudo mkdir -p /etc/systemd/system/unattended-upgrades.service.d

                cat <<'EOF' | sudo tee /etc/systemd/system/unattended-upgrades.service.d/hardening.conf >/dev/null
[Service]
# Systemd hardening for Unattended Upgrades
ProtectSystem=strict
ReadWritePaths=/var/lib/unattended-upgrades /var/log/unattended-upgrades /var/cache/apt /var/lib/apt /var/lib/dpkg /etc/apt
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM
SystemCallArchitectures=native
RestrictNamespaces=yes
RestrictRealtime=yes
LockPersonality=yes
ProtectHostname=yes
ProtectClock=yes
EOF

                log_info "✓ Unattended-upgrades service hardened"
            else
                log_info "⊘ Unattended-upgrades hardening skipped"
            fi
        fi

        # Containerd service hardening - DISABLED
        # NOTE: Containerd hardening causes issues with namespace/mount setup
        # Error: "Failed to set up mount namespacing: /run/containerd: No such file or directory"
        # Containerd needs extensive system access to manage containers, hardening breaks it
        if systemctl list-unit-files | grep -q "containerd.service"; then
            log_info "⊘ Containerd hardening skipped (incompatible with container runtime)"
            log_info "  Containerd requires extensive system access and cannot be hardened safely"
        fi

        # Networkd-dispatcher service hardening
        if systemctl list-unit-files | grep -q "networkd-dispatcher.service"; then
            read -p "Harden Networkd-dispatcher service? (Y/n): " harden_netdisp
            harden_netdisp=${harden_netdisp:-y}
            if [[ $harden_netdisp =~ ^[Yy]$ ]]; then
                log_info "Hardening Networkd-dispatcher service..."
                sudo mkdir -p /etc/systemd/system/networkd-dispatcher.service.d

                cat <<'EOF' | sudo tee /etc/systemd/system/networkd-dispatcher.service.d/hardening.conf >/dev/null
[Service]
# Systemd hardening for networkd-dispatcher
PrivateDevices=yes
ProtectSystem=strict
ReadWritePaths=/run/networkd-dispatcher /var/log
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
RestrictSUIDSGID=yes
RestrictAddressFamilies=AF_UNIX AF_NETLINK
CapabilityBoundingSet=CAP_NET_ADMIN
SystemCallFilter=@system-service
SystemCallFilter=~@privileged @resources @obsolete
SystemCallErrorNumber=EPERM
SystemCallArchitectures=native
RestrictNamespaces=yes
RestrictRealtime=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes
ProtectHostname=yes
ProtectClock=yes
ProtectProc=invisible
ProcSubset=pid
EOF

                log_info "✓ Networkd-dispatcher service hardened"
            else
                log_info "⊘ Networkd-dispatcher hardening skipped"
            fi
        fi

        # Snapd service hardening
        if systemctl list-unit-files | grep -q "snapd.service"; then
            read -p "Harden Snapd service? (Y/n): " harden_snapd
            harden_snapd=${harden_snapd:-y}
            if [[ $harden_snapd =~ ^[Yy]$ ]]; then
                log_info "Hardening Snapd service..."
                sudo mkdir -p /etc/systemd/system/snapd.service.d

                cat <<'EOF' | sudo tee /etc/systemd/system/snapd.service.d/hardening.conf >/dev/null
[Service]
# Systemd hardening for Snapd
ProtectSystem=strict
ReadWritePaths=/var/lib/snapd /snap /run/snapd /var/snap /var/cache/snapd /var/log /tmp
ProtectKernelTunables=yes
ProtectKernelLogs=yes
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK
SystemCallFilter=@system-service
SystemCallArchitectures=native
LockPersonality=yes
ProtectClock=yes
EOF

                log_info "✓ Snapd service hardened"
                echo "   💡 Tip: Consider disabling snapd if not needed for better security:"
                echo "      sudo systemctl stop snapd && sudo systemctl mask snapd"
            else
                log_info "⊘ Snapd hardening skipped"
            fi
        fi

        # Reload systemd daemon
        log_info "Reloading systemd daemon..."
        sudo systemctl daemon-reload

        # Ask to restart services
        echo ""
        echo "══════════════════════════════════════════════════════════"
        echo "Systemd Service Hardening Complete"
        echo "══════════════════════════════════════════════════════════"
        echo ""
        echo "Services have been hardened with security configurations."
        echo "Changes take effect after service restart."
        echo ""
        read -p "Restart hardened services now? (Y/n): " restart_services
        restart_services=${restart_services:-y}

        if [[ $restart_services =~ ^[Yy]$ ]]; then
            log_info "Restarting hardened services..."

            if [ -f /etc/systemd/system/ssh.service.d/hardening.conf ]; then
                sudo systemctl restart ssh && log_info "✓ SSH restarted" || log_warning "✗ SSH restart failed"
            fi

            if [ -f /etc/systemd/system/fail2ban.service.d/hardening.conf ]; then
                sudo systemctl restart fail2ban && log_info "✓ Fail2ban restarted" || log_warning "✗ Fail2ban restart failed"
            fi

            if [ -f /etc/systemd/system/cron.service.d/hardening.conf ]; then
                sudo systemctl restart cron && log_info "✓ Cron restarted" || log_warning "✗ Cron restart failed"
            fi

            if [ -f /etc/systemd/system/postfix@-.service.d/hardening.conf ]; then
                sudo systemctl restart postfix && log_info "✓ Postfix restarted" || log_warning "✗ Postfix restart failed"
            fi

            if [ -f /etc/systemd/system/rsyslog.service.d/hardening.conf ]; then
                sudo systemctl restart rsyslog && log_info "✓ Rsyslog restarted" || log_warning "✗ Rsyslog restart failed"
            fi

            if [ -f /etc/systemd/system/unattended-upgrades.service.d/hardening.conf ]; then
                sudo systemctl restart unattended-upgrades && log_info "✓ Unattended-upgrades restarted" || log_warning "✗ Unattended-upgrades restart failed"
            fi

            if [ -f /etc/systemd/system/containerd.service.d/hardening.conf ]; then
                sudo systemctl restart containerd && log_info "✓ Containerd restarted" || log_warning "✗ Containerd restart failed"
            fi

            if [ -f /etc/systemd/system/networkd-dispatcher.service.d/hardening.conf ]; then
                sudo systemctl restart networkd-dispatcher && log_info "✓ Networkd-dispatcher restarted" || log_warning "✗ Networkd-dispatcher restart failed"
            fi

            if [ -f /etc/systemd/system/snapd.service.d/hardening.conf ]; then
                sudo systemctl restart snapd && log_info "✓ Snapd restarted" || log_warning "✗ Snapd restart failed"
            fi

            log_info "All selected services restarted with hardened configuration"
            echo ""
            echo "✅ Service hardening complete"
            echo "💡 Verify with: sudo systemd-analyze security"
        else
            log_warning "Services NOT restarted - changes take effect on next reboot or manual restart"
        fi
    fi
        mark_completed "SYSTEMD_HARDENING"
    else
        log_info "Systemd service hardening skipped"
        mark_completed "SYSTEMD_HARDENING"
    fi
fi

###############################################################################
# AUDIT LOGGING CONFIGURATION
###############################################################################

if ask_component_install \
    "AUDIT LOGGING (auditd + acct)" \
    "audit-logging" \
    "Configure system audit logging to track security-relevant events and changes." \
    "Tools to install and configure:
• auditd - Linux audit daemon
• acct - Process accounting
• audispd-plugins - Audit dispatcher plugins

Audit rules to monitor:
• SSH configuration changes (/etc/ssh/sshd_config)
• User home directory modifications
• Privileged commands (run by root)
• PATH injection (/etc/profile, /etc/profile.d, /root/.profile)
• Scheduled execution (/etc/cron.*, /var/spool/cron/crontabs)
• Service persistence (/etc/systemd/system, systemctl execution)
• Loader hijacking (/etc/ld.so.preload, /etc/ld.so.conf.d)
• SSH keys, /etc/passwd, /etc/shadow, sudoers
• Timestomping (root running touch) and execution from /tmp, /var/tmp, /dev/shm

Benefits:
• Track unauthorized changes
• Forensic investigation capability
• Compliance (PCI-DSS, HIPAA, etc.)
• Security incident detection

View logs: sudo ausearch -k profile_tampering" \
    "$([ "$DESKTOP_MODE" = true ] && echo 'n' || echo 'y')"; then

    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Would install: auditd, acct, audispd-plugins"
        log_dry_run "Would create /etc/audit/rules.d/ssh-security.rules with:"
        log_dry_run "  - Monitor /etc/ssh/sshd_config and sshd_config.d changes"
        log_dry_run "  - Monitor /home/ directory changes"
        log_dry_run "  - Monitor privileged commands (root execve)"
        log_dry_run "Would create /etc/audit/rules.d/10-persistence.rules with:"
        log_dry_run "  - Monitor /etc/profile, /etc/profile.d, /root/.profile (PATH injection)"
        log_dry_run "  - Monitor /etc/cron.* and /var/spool/cron/crontabs"
        log_dry_run "  - Monitor /etc/systemd/system and systemctl execution"
        log_dry_run "  - Monitor /etc/ld.so.preload and /etc/ld.so.conf.d"
        log_dry_run "  - Monitor /root/.ssh, /etc/passwd, /etc/shadow, sudoers"
        log_dry_run "  - Monitor execve in /tmp, /var/tmp, /dev/shm"
        log_dry_run "  - Every rule tagged with a shared key 'persist' for one-shot ausearch"
        log_dry_run "Would enable and start auditd service"
        log_dry_run "Would run 'augenrules --load' to compile the rules into the kernel"
        log_dry_run "Would run 'systemctl enable --now acct' for process accounting"
        log_dry_run "Would verify that the rules are actually loaded (auditctl -l)"
    else
        log_info "Configuring audit logging (auditd + acct)..."

        # Install auditd and acct for system auditing
        DEBIAN_FRONTEND=noninteractive sudo apt-get install -y auditd acct audispd-plugins || \
            log_warning "Failed to install audit tools"

        # Configure auditd rules for SSH and security monitoring
        cat <<EOF | sudo tee /etc/audit/rules.d/ssh-security.rules
# Monitor SSH configuration changes
-w /etc/ssh/sshd_config -p wa -k sshd_config_changes
-w /etc/ssh/sshd_config.d/ -p wa -k sshd_config_changes

# Monitor user home directories for unauthorized changes
-w /home/ -p wa -k home_modifications

# Monitor privileged commands (run by root)
-a always,exit -F arch=b64 -S execve -F uid=0 -k privileged_commands
EOF

        # Watch the locations that persistence and PATH-hijack kits actually use.
        # The rule set above deliberately did NOT cover any of them; a userland
        # rootkit can install itself into every path below without tripping a
        # single audit rule. /var/log/auth.log is intentionally absent - it no
        # longer exists on Ubuntu 24.04 and watching it produced nothing.
        # Every rule carries two keys: a specific one for targeted searches and
        # the shared key 'persist' so a single `ausearch -k persist` returns the
        # whole persistence picture in one go.
        cat <<EOF | sudo tee /etc/audit/rules.d/10-persistence.rules
# --- Shell profile / PATH injection ---------------------------------------
# A single appended line here is enough to put an attacker-controlled directory
# in front of /usr/bin for every login shell.
-w /etc/profile -p wa -k profile_tampering -k persist
-w /etc/profile.d/ -p wa -k profile_tampering -k persist
-w /etc/bash.bashrc -p wa -k profile_tampering -k persist
-w /etc/environment -p wa -k profile_tampering -k persist
-w /root/.profile -p wa -k profile_tampering -k persist
-w /root/.bashrc -p wa -k profile_tampering -k persist

# --- Scheduled execution ---------------------------------------------------
-w /etc/crontab -p wa -k cron_tampering -k persist
-w /etc/cron.d/ -p wa -k cron_tampering -k persist
-w /etc/cron.hourly/ -p wa -k cron_tampering -k persist
-w /etc/cron.daily/ -p wa -k cron_tampering -k persist
-w /etc/cron.weekly/ -p wa -k cron_tampering -k persist
-w /etc/cron.monthly/ -p wa -k cron_tampering -k persist
-w /var/spool/cron/crontabs/ -p wa -k cron_tampering -k persist
-a always,exit -F arch=b64 -S execve -F path=/usr/bin/crontab -k cron_tampering -k persist

# --- Service persistence ---------------------------------------------------
# Self-installing, self-deleting units do not show up in list-unit-files.
-w /etc/systemd/system/ -p wa -k systemd_tampering -k persist
-w /lib/systemd/system/ -p wa -k systemd_tampering -k persist
-w /usr/lib/systemd/system/ -p wa -k systemd_tampering -k persist
-a always,exit -F arch=b64 -S execve -F path=/usr/bin/systemctl -k systemd_tampering -k persist

# --- Loader / library hijacking -------------------------------------------
-w /etc/ld.so.preload -p wa -k preload_tampering -k persist
-w /etc/ld.so.conf -p wa -k preload_tampering -k persist
-w /etc/ld.so.conf.d/ -p wa -k preload_tampering -k persist

# --- Remote access ---------------------------------------------------------
-w /root/.ssh/ -p wa -k ssh_key_tampering -k persist
-w /etc/passwd -p wa -k identity_tampering -k persist
-w /etc/shadow -p wa -k identity_tampering -k persist
-w /etc/sudoers -p wa -k identity_tampering -k persist
-w /etc/sudoers.d/ -p wa -k identity_tampering -k persist

# --- Anti-forensics --------------------------------------------------------
# Timestomping: copying mtime/ctime from a system binary onto a dropped one.
-a always,exit -F arch=b64 -S execve -F path=/usr/bin/touch -F uid=0 -k timestomp -k persist

# --- Execution from writable, world-accessible locations -------------------
# Complements the noexec mount options: noexec blocks it, this records it.
-a always,exit -F arch=b64 -S execve -F dir=/tmp -k exec_from_tmp -k persist
-a always,exit -F arch=b64 -S execve -F dir=/var/tmp -k exec_from_tmp -k persist
-a always,exit -F arch=b64 -S execve -F dir=/dev/shm -k exec_from_tmp -k persist
EOF

        # Enable and start auditd
        sudo systemctl enable auditd || log_warning "Failed to enable auditd"
        sudo systemctl restart auditd || log_warning "Failed to restart auditd"

        # Load the rules explicitly rather than relying on the service restart.
        # augenrules compiles rules.d/*.rules into the running kernel ruleset; a
        # restart alone is not a reliable signal that it succeeded, and on some
        # systems auditd refuses a manual restart altogether.
        sudo augenrules --load || log_warning "augenrules --load reported a problem"

        # Enable process accounting. 'enable --now' both enables at boot and
        # starts it immediately - process accounting being inactive after a
        # reboot means no command history for exactly the window that matters.
        sudo systemctl enable --now acct || log_warning "Failed to enable/start acct"

        # Verify the rules actually loaded. augenrules silently skips a rules
        # file it cannot parse, so "auditd restarted" says nothing about whether
        # the rules below are live.
        # wc -l, not grep -c: grep -c prints 0 and exits 1 on no match, so a
        # '|| echo 0' fallback would yield "0\n0" and break the numeric test.
        LOADED_RULES=$(sudo auditctl -l 2>/dev/null | wc -l)
        LOADED_RULES=${LOADED_RULES:-0}
        if [ "$LOADED_RULES" -gt 10 ]; then
            log_info "✓ auditd active with $LOADED_RULES rules loaded"
        else
            log_warning "✗ auditd reports only $LOADED_RULES rules loaded - expected 30+"
            log_warning "  Diagnose with: sudo augenrules --check && sudo auditctl -l"
        fi

        if systemctl is-active acct >/dev/null 2>&1; then
            log_info "✓ Process accounting (acct) is active"
        else
            log_warning "✗ Process accounting (acct) is NOT active - no command history will be kept"
        fi

        # Immutable rules (-e 2). Once loaded, the rule set cannot be changed
        # without a reboot - which is the point: an attacker with root can
        # otherwise simply flush the rules before doing anything else.
        # Opt-in, because it also blocks YOUR next change until a reboot.
        echo ""
        echo "══════════════════════════════════════════════════════════════════"
        echo "IMMUTABLE AUDIT RULES (-e 2)"
        echo "══════════════════════════════════════════════════════════════════"
        echo ""
        echo "With -e 2 the audit configuration is locked until the next reboot."
        echo "Nothing - including root - can add, remove or flush audit rules."
        echo ""
        echo "  ✅ An attacker who gains root cannot silently disable auditing"
        echo "  ⚠️  You cannot change the rules either without rebooting"
        echo ""
        echo "Recommended once the rules above are settled. Skip it on a machine"
        echo "you are still tuning."
        echo ""
        read -p "Make audit rules immutable? (y/N): " audit_immutable
        audit_immutable=${audit_immutable:-n}

        if [[ $audit_immutable =~ ^[Yy]$ ]]; then
            # 99- prefix so augenrules places it last; -e 2 must be the final rule.
            echo "-e 2" | sudo tee /etc/audit/rules.d/99-finalize.rules >/dev/null
            sudo augenrules --load 2>/dev/null || true
            log_info "✓ Audit rules will be immutable from the next reboot"
            log_info "  To undo: remove /etc/audit/rules.d/99-finalize.rules and reboot"
        else
            log_info "Audit rules remain changeable (no -e 2)"
            log_info "  Enable later: echo '-e 2' > /etc/audit/rules.d/99-finalize.rules && reboot"
        fi

        log_info "Audit logging configured successfully"
        log_info "View all persistence events: sudo ausearch -k persist"
        log_info "Or per category:             sudo ausearch -k profile_tampering"
        log_info "                             sudo ausearch -k cron_tampering"
        log_info "                             sudo ausearch -k exec_from_tmp"
    fi
else
    log_info "Audit logging configuration skipped"
fi

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
echo "   - Can run daily at 03:00 with Telegram status updates"
echo "   - Lightweight, no performance impact"
echo "   - Recommended for: Production servers"
echo ""
read -p "Do you want to install Rkhunter? (y/n): " install_rkhunter
install_rkhunter=${install_rkhunter:-n}

# Ask about Lynis
echo ""
echo "2. LYNIS (Security Auditing Tool)"
echo "   - Comprehensive security audit (200+ checks)"
echo "   - Provides hardening score and improvement suggestions"
echo "   - Can run monthly on 1st at 04:00 with Telegram reports"
echo "   - Recommended for: All servers"
echo ""
read -p "Do you want to install Lynis? (y/n): " install_lynis
install_lynis=${install_lynis:-n}

# Install selected tools
RKHUNTER_INSTALLED=false
LYNIS_INSTALLED=false
AIDE_INSTALLED=false

if [[ $install_rkhunter == "y" ]] || [[ $install_rkhunter == "Y" ]]; then
    log_info "Installing Rkhunter..."
    DEBIAN_FRONTEND=noninteractive sudo apt-get install -y rkhunter || \
        log_warning "Failed to install Rkhunter"

    # Ensure rkhunter does not warn about SSH Protocol 1 (disabled)
    log_info "Configuring rkhunter SSH protocol settings..."
    sudo sed -i 's/^#\?ALLOW_SSH_PROT_V1=.*/ALLOW_SSH_PROT_V1=0/' /etc/rkhunter.conf

    # If the setting does not exist, append it
    grep -q "^ALLOW_SSH_PROT_V1=" /etc/rkhunter.conf || \
        echo "ALLOW_SSH_PROT_V1=0" | sudo tee -a /etc/rkhunter.conf >/dev/null

    # Configure rkhunter for this server's SSH setup
    log_info "Configuring rkhunter for custom SSH port..."
    sudo sed -i 's/^#\?ALLOW_SSH_ROOT_USER=.*/ALLOW_SSH_ROOT_USER=prohibit-password/' /etc/rkhunter.conf

    # PORT_NUMBER is NOT an rkhunter configuration option. An earlier version of
    # this script set it, and rkhunter then refused the whole configuration with
    # "Unknown configuration file option: PORT_NUMBER=888" and aborted every
    # scan from that point on - while the daily report kept saying "All Clear",
    # because it only looked for warning lines and an aborted scan produces none.
    #
    # This script broke rootkit scanning on the servers it hardened. Remove the
    # line wherever a previous run left it.
    if grep -q '^PORT_NUMBER=' /etc/rkhunter.conf 2>/dev/null; then
        sudo sed -i '/^PORT_NUMBER=/d' /etc/rkhunter.conf
        log_warning "Removed invalid PORT_NUMBER option from /etc/rkhunter.conf"
        log_warning "  It was written by an earlier version of this script and aborted every scan."
    fi

    # Fix WEB_CMD to use absolute path (fixes "Invalid WEB_CMD" error)
    sudo sed -i 's|^WEB_CMD=.*|WEB_CMD=/bin/false|' /etc/rkhunter.conf

    # Whitelist known hidden files that are standard on Ubuntu servers
    log_info "Whitelisting known hidden files in rkhunter..."
    grep -q "^ALLOWHIDDENFILE=/etc/.resolv.conf.systemd-resolved.bak" /etc/rkhunter.conf || \
        echo "ALLOWHIDDENFILE=/etc/.resolv.conf.systemd-resolved.bak" | sudo tee -a /etc/rkhunter.conf >/dev/null
    grep -q "^ALLOWHIDDENFILE=/etc/.updated" /etc/rkhunter.conf || \
        echo "ALLOWHIDDENFILE=/etc/.updated" | sudo tee -a /etc/rkhunter.conf >/dev/null

    # Add settings if they don't exist
    grep -q "^ALLOW_SSH_ROOT_USER=" /etc/rkhunter.conf || echo "ALLOW_SSH_ROOT_USER=prohibit-password" | sudo tee -a /etc/rkhunter.conf >/dev/null
    # NO PORT_NUMBER LINE HERE. There used to be one, fourteen lines below the
    # block above that removes it and explains that it aborts every scan - so
    # every fresh install wrote back the exact option the code above had just
    # deleted, and shipped a host whose rootkit scanner never ran.
    grep -q "^WEB_CMD=" /etc/rkhunter.conf || echo "WEB_CMD=/bin/false" | sudo tee -a /etc/rkhunter.conf >/dev/null

    # Verify instead of assuming. One option this build rejects aborts every
    # scan from here on - silently, because an aborted scan produces no warning
    # lines at all. WEB_CMD is the one that varies between distributions:
    # /bin/false is refused as a "relative pathname" by some builds on usrmerge
    # systems, where /bin is a symlink into /usr/bin.
    if sudo rkhunter --config-check >/dev/null 2>&1; then
        log_info "rkhunter configuration is valid"
    else
        log_warning "rkhunter rejected its configuration - trying the merged path for WEB_CMD"
        sudo sed -i 's|^WEB_CMD=.*|WEB_CMD=/usr/bin/false|' /etc/rkhunter.conf
        if ! sudo rkhunter --config-check >/dev/null 2>&1; then
            sudo sed -i 's|^WEB_CMD=|# DISABLED - rejected by this rkhunter build: WEB_CMD=|' /etc/rkhunter.conf
        fi
        if sudo rkhunter --config-check >/dev/null 2>&1; then
            log_info "rkhunter configuration is valid"
        else
            log_warning "rkhunter still rejects its configuration - scans will abort:"
            sudo rkhunter --config-check 2>&1 | head -5 | sed 's/^/  /'
            log_warning "Fix these before trusting any rkhunter report from this host."
        fi
    fi

    # Update rkhunter database
    log_info "Updating rkhunter file properties database..."

    # Note: We intentionally disable internet updates (WEB_CMD=/bin/false)
    # Ubuntu's rkhunter package is kept up-to-date via apt, which is more secure
    # The --update command will show "Update failed" warnings - this is expected and safe

    # Update file properties (hashes) - this is what we actually need
    if sudo rkhunter --propupd --skip-keypress 2>/dev/null; then
        log_info "Rkhunter file properties updated successfully"
    else
        log_warning "Failed to update rkhunter properties - you may need to run: sudo rkhunter --propupd"
    fi

    log_info "Rkhunter installed and configured successfully"
    log_info "Note: Rkhunter uses local database (updated via apt-get upgrade)"
    log_info "Note: Internet updates are disabled for security (WEB_CMD=/bin/false)"
    RKHUNTER_INSTALLED=true
else
    log_warning "Rkhunter installation skipped"
fi

if [[ $install_lynis == "y" ]] || [[ $install_lynis == "Y" ]]; then
    log_info "Installing Lynis from GitHub source..."

    # Remove old apt version if present
    sudo apt-get remove --purge -y lynis 2>/dev/null || true

    # Install dependencies
    sudo apt-get install -y curl wget tar 2>/dev/null || true

    # Determine latest version number automatically
    log_info "Fetching latest Lynis version from GitHub..."
    LYNIS_VERSION=$(curl -s https://api.github.com/repos/CISOfy/lynis/releases/latest | grep -Po '"tag_name": "\K[^"]+')

    if [[ -z "$LYNIS_VERSION" ]]; then
        log_warning "Could not fetch latest Lynis version. Installing fixed version 3.1.6."
        LYNIS_VERSION="3.1.6"
    else
        log_info "Latest Lynis version: $LYNIS_VERSION"
    fi

    # Download and install.
    #
    # The previous version ran `wget -q ...` and then tested $? for a retry.
    # With `set -e` active the script exits on the failing wget before ever
    # reaching that test, so the fallback was unreachable code and a transient
    # network problem aborted the entire installation. -q also hid the reason.
    #
    # Lynis is optional tooling. A download failure warns and moves on.
    LYNIS_DOWNLOADED=false
    for try_version in "$LYNIS_VERSION" "3.1.6"; do
        log_info "Downloading Lynis ${try_version}..."
        if sudo wget --tries=2 --timeout=20 \
                "https://github.com/CISOfy/lynis/archive/refs/tags/${try_version}.tar.gz" \
                -O /tmp/lynis.tar.gz 2>/tmp/lynis-download.err; then
            LYNIS_VERSION="$try_version"
            LYNIS_DOWNLOADED=true
            break
        fi
        log_warning "Download of Lynis ${try_version} failed"
        sed 's/^/    /' /tmp/lynis-download.err 2>/dev/null | tail -3
        [ "$try_version" = "3.1.6" ] || log_warning "Retrying with the pinned version..."
    done

    if [ "$LYNIS_DOWNLOADED" != true ]; then
        log_warning "Could not download Lynis - skipping it and continuing"
        log_warning "  Everything else on this host is unaffected."
        log_warning "  Install it later with: bash $SCRIPT_DIR/install-script.sh --section  (choose 16)"
        LYNIS_INSTALLED=false
        sudo rm -f /tmp/lynis.tar.gz /tmp/lynis-download.err 2>/dev/null || true
    else

    # Remove old installation if exists
    sudo rm -rf /usr/local/lynis 2>/dev/null || true
    sudo rm -f /usr/local/bin/lynis 2>/dev/null || true
    sudo rm -f /usr/sbin/lynis 2>/dev/null || true

    # Extract to /usr/local, in a subshell so the directory change cannot leak
    # into the rest of the script.
    (
        cd /usr/local || exit 1
        sudo tar xzf /tmp/lynis.tar.gz
        sudo rm /tmp/lynis.tar.gz
        sudo mv "lynis-${LYNIS_VERSION}" lynis || sudo mv lynis-* lynis
    )

    # Create symlinks for compatibility
    sudo ln -sf /usr/local/lynis/lynis /usr/local/bin/lynis
    sudo ln -sf /usr/local/lynis/lynis /usr/sbin/lynis

    # Set permissions
    sudo chmod +x /usr/local/lynis/lynis
    sudo chown -R root:root /usr/local/lynis

    # Verify installation
    if /usr/local/lynis/lynis show version &>/dev/null; then
        INSTALLED_VERSION=$(/usr/local/lynis/lynis show version 2>/dev/null | head -1)
        log_info "Lynis ${INSTALLED_VERSION} installed successfully (GitHub version)"
        LYNIS_INSTALLED=true
    else
        log_warning "Lynis installation verification failed"
        LYNIS_INSTALLED=false
    fi
    fi   # end of: download succeeded
else
    log_warning "Lynis installation skipped"
fi

###############################################################################
# DEBSUMS - Package Integrity Verification
###############################################################################

if ! check_component_status "DEBSUMS"; then
    if prompt_user \
    "Install and configure debsums?

debsums verifies the integrity of installed packages by checking MD5 checksums.

Features:
• Detects modified or corrupted system files
• Daily automated verification via cron
• Helps identify compromised packages or corruption
• Lightweight and non-intrusive

Configuration:
• Installs debsums package
• Configures daily cron job (/etc/default/debsums)
• Runs automatically every day

Benefits:
• Early detection of system file tampering
• Identifies package corruption from disk errors
• Security monitoring of critical system files
• Compliance with security best practices

Lynis recommendation: DEB-0810" \
    "y"; then

    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Would install debsums package"
        log_dry_run "Would configure /etc/default/debsums with CRON_CHECK=yes (daily)"
    else
        log_info "Installing debsums..."

        if ! dpkg -l | grep -q "^ii  debsums"; then
            DEBIAN_FRONTEND=noninteractive sudo apt-get install -y debsums || \
                log_warning "Failed to install debsums"
        else
            log_info "debsums is already installed"
        fi

        # Configure debsums for daily checks (Lynis PKGS-7370)
        log_info "Configuring debsums for daily verification..."

        # Backup existing config if it exists
        if [ -f /etc/default/debsums ]; then
            sudo cp /etc/default/debsums /etc/default/debsums.backup.$(date +%Y%m%d_%H%M%S)
        fi

        # Create debsums configuration
        cat <<'EOF' | sudo tee /etc/default/debsums >/dev/null
# Defaults for debsums cron jobs
# sourced by /etc/cron.d/debsums

#
# This is a POSIX shell fragment
#

# Set this to 'yes' to enable daily checksum verification
# Lynis recommendation: PKGS-7370 - enable regular integrity checking
CRON_CHECK=yes
EOF

        log_info "debsums configured for daily verification"

        # Verify debsums is working
        if command -v debsums &>/dev/null; then
            log_info "debsums installed and configured successfully"
            echo ""
            echo "══════════════════════════════════════════════════════════"
            echo "debsums will run daily to verify package integrity"
            echo "Manual check: sudo debsums -s (shows only errors)"
            echo "══════════════════════════════════════════════════════════"
            echo ""
        else
            log_warning "debsums installation verification failed"
        fi
    fi
        mark_completed "DEBSUMS"
    else
        log_info "debsums installation skipped"
        mark_completed "DEBSUMS"
    fi
fi

# Show manual installation info if both were skipped
if [ "$RKHUNTER_INSTALLED" = false ] && [ "$LYNIS_INSTALLED" = false ]; then
    log_info "You can install them later with:"
    log_info "  Rkhunter: sudo apt-get install -y rkhunter"
    log_info "  Lynis: Download from https://github.com/CISOfy/lynis/releases"
fi

# Only configure Telegram integration if at least one tool was installed (server only)
if [ "$DESKTOP_MODE" = true ]; then
    if [ "$RKHUNTER_INSTALLED" = true ] || [ "$LYNIS_INSTALLED" = true ]; then
        log_info "Desktop mode: Telegram integration skipped"
        log_info "Run scans manually: sudo rkhunter --check / sudo lynis audit system"
    fi
elif [ "$RKHUNTER_INSTALLED" = true ] || [ "$LYNIS_INSTALLED" = true ]; then

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
    echo "  - Rkhunter: Daily scan at 03:00 (sends status update every day)"
    echo "  - Lynis: Monthly audit on 1st of month at 04:00"
    echo ""
    read -p "Do you want to configure Telegram alerts for security scans? (y/n): " setup_sec_telegram
    setup_sec_telegram=${setup_sec_telegram:-n}

    if [[ $setup_sec_telegram == "y" ]] || [[ $setup_sec_telegram == "Y" ]]; then
        echo ""
        echo "To get Telegram bot token and chat ID:"
        echo "  1. Open Telegram and search for @BotFather"
        echo "  2. Send /newbot and follow instructions"
        echo "  3. Copy the bot token"
        echo "  4. Start chat with your bot (send /start)"
        echo "  5. Get your chat ID from @userinfobot"
        echo ""
        read -p "Enter Telegram Bot Token: " SECURITY_TELEGRAM_BOT_TOKEN
        read -p "Enter Telegram Chat ID: " SECURITY_TELEGRAM_CHAT_ID
    fi
fi

# Only configure Telegram integration if credentials are available
if [[ ! -z "$SECURITY_TELEGRAM_BOT_TOKEN" ]] && [[ ! -z "$SECURITY_TELEGRAM_CHAT_ID" ]]; then
    log_info "Configuring Telegram integration for security scans..."

    # Write the credentials ONCE, here, before anything that needs them.
    # Every alerting component reads this one file: the three reporters, the
    # watchdog, the daily self-check and aide-refresh. Nothing carries its own
    # copy - a token in five places is five places to rotate and five chances
    # for one of them to be silently wrong.
    #
    # It lives with the project checkout, not in /etc. '.env' is already
    # gitignored, so it cannot be committed by accident.
    PROJECT_ENV="$PROJECT_ROOT/.env"
    {
        printf 'TELEGRAM_BOT_TOKEN=%s\n' "$SECURITY_TELEGRAM_BOT_TOKEN"
        printf 'TELEGRAM_CHAT_ID=%s\n'   "$SECURITY_TELEGRAM_CHAT_ID"
        # Written out commented, because a knob nobody knows exists is a knob
        # nobody turns - and each of these is the difference between a daily
        # report that gets read and one that gets skimmed.
        cat <<'ENVDOC'

# --- security-selfcheck tuning ------------------------------------------------
# All optional. Uncomment and fill in what applies to this host.

# Containers that are SUPPOSED to hold host-level access, so the same lines
# about Portainer and Netdata do not arrive every single morning until you stop
# reading them. Format: name=risk,risk
#SELFCHECK_ACK_HOST_ACCESS="portainer=docker.sock netdata=docker.sock"

# Ports a cloud firewall in front of this machine lets through (Hetzner, AWS
# security groups, ...). That layer leaves no trace on the host, so without
# this every port behind it is reported as reachable from the internet.
# DECLARED, never measured - re-verify from outside when you change it.
#SELFCHECK_EXTERNAL_ALLOW="888"

# This host's own intended services, on top of SSH and HTTP/HTTPS. Whatever is
# reachable and NOT listed here is what the report is actually for.
#SELFCHECK_EXPECTED_PUBLIC=""
ENVDOC
    } | sudo tee "$PROJECT_ENV" >/dev/null
    sudo chmod 600 "$PROJECT_ENV"
    log_info "Alert credentials written to $PROJECT_ENV (mode 600)"
    log_warning "If you move or re-clone this checkout, copy .env across."
    log_warning "Otherwise every alert goes silent - the daily self-check fails when it is gone."

    # Create rkhunter Telegram wrapper script (only if installed)
    if [ "$RKHUNTER_INSTALLED" = true ]; then
    # Installed from server-baseline/reporters/ so update-baseline.sh can
    # deploy the identical script. Credentials are NOT written into it;
    # it reads /etc/server-baseline/selfcheck.env at runtime.
    RKH_SRC="$SCRIPT_DIR/reporters/rkhunter-telegram.sh"
    if [ -f "$RKH_SRC" ]; then
        sudo install -m 700 -o root -g root "$RKH_SRC" /usr/local/bin/rkhunter-telegram.sh
        sudo sed -i "s|^ENV_FILE_DEFAULT=.*|ENV_FILE_DEFAULT=\\"${PROJECT_ENV:-}\\"|" /usr/local/bin/rkhunter-telegram.sh 2>/dev/null || true
    else
        log_warning "reporters/rkhunter-telegram.sh not found - skipping rkhunter reporter"
    fi

    # Replace placeholders with actual credentials for rkhunter
    log_info "Rkhunter Telegram integration configured (chmod 700 for security)"

    # Create symlink in scripts directory if it exists
    if [ -d "$USER_HOME/scripts" ]; then
        sudo ln -sf /usr/local/bin/rkhunter-telegram.sh "$USER_HOME/scripts/rkhunter-telegram" 2>/dev/null || true
        log_info "Created symlink: ~/scripts/rkhunter-telegram"
    fi
    fi

    # Create lynis Telegram wrapper script (only if installed)
    if [ "$LYNIS_INSTALLED" = true ]; then
    LYN_SRC="$SCRIPT_DIR/reporters/lynis-telegram.sh"
    if [ -f "$LYN_SRC" ]; then
        sudo install -m 700 -o root -g root "$LYN_SRC" /usr/local/bin/lynis-telegram.sh
        sudo sed -i "s|^ENV_FILE_DEFAULT=.*|ENV_FILE_DEFAULT=\\"${PROJECT_ENV:-}\\"|" /usr/local/bin/lynis-telegram.sh 2>/dev/null || true
    else
        log_warning "reporters/lynis-telegram.sh not found - skipping Lynis reporter"
    fi

    # Replace placeholders with actual credentials for lynis
    sudo chmod 700 /usr/local/bin/lynis-telegram.sh
    log_info "Lynis Telegram integration configured (chmod 700 for security)"

    # Create symlink in scripts directory if it exists
    if [ -d "$USER_HOME/scripts" ]; then
        sudo ln -sf /usr/local/bin/lynis-telegram.sh "$USER_HOME/scripts/lynis-telegram" 2>/dev/null || true
        log_info "Created symlink: ~/scripts/lynis-telegram"
    fi
    fi

    # NOTE: AIDE Telegram integration is configured in the AIDE FILE INTEGRITY MONITORING section
    # after AIDE is actually installed (search for "AIDE Telegram wrapper script")

    # Create cron jobs for automated scans (only for installed tools)
    CRON_CONTENT=""

    if [ "$RKHUNTER_INSTALLED" = true ]; then
        CRON_CONTENT+="# Rkhunter daily scan at 03:00 (sends status update every day)"$'\n'
        CRON_CONTENT+="0 3 * * * root /usr/local/bin/rkhunter-telegram.sh"$'\n'
    fi

    if [ "$LYNIS_INSTALLED" = true ]; then
        if [ ! -z "$CRON_CONTENT" ]; then
            CRON_CONTENT+=$'\n'
        fi
        CRON_CONTENT+="# Lynis monthly audit on 1st of month at 04:00"$'\n'
        CRON_CONTENT+="0 4 1 * * root /usr/local/bin/lynis-telegram.sh"$'\n'
    fi

    # NOTE: AIDE cron job is added in the AIDE FILE INTEGRITY MONITORING section

    if [ ! -z "$CRON_CONTENT" ]; then
        echo "$CRON_CONTENT" | sudo tee /etc/cron.d/security-scans >/dev/null
        sudo chmod 644 /etc/cron.d/security-scans
    fi

    log_info "Telegram integration configured successfully"
    if [ "$RKHUNTER_INSTALLED" = true ]; then
        log_info "Rkhunter: Daily scans at 03:00 (sends status update every day)"
    fi
    if [ "$LYNIS_INSTALLED" = true ]; then
        log_info "Lynis: Monthly audits on 1st of month at 04:00"
    fi
    # NOTE: AIDE log info is shown in the AIDE FILE INTEGRITY MONITORING section
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

fi  # End of desktop mode / tool installed check

###############################################################################
# SECURITY SELF-CHECK
###############################################################################
#
# Installs security-selfcheck.sh and schedules it daily. This is the control
# that verifies the other controls: it asserts that fail2ban actually bans, that
# auditd is running with rules loaded, that AIDE's check completes, that PATH is
# not hijacked, and that no second Docker daemon or proxyware container exists.
#
# Every check it performs corresponds to a control that was installed, reported
# healthy, and did nothing. "systemctl is-active" is not evidence.

if skip_if_completed "SECURITY_SELFCHECK"; then
    log_info "Security self-check already installed, skipping"
else
    if ask_component_install \
        "SECURITY SELF-CHECK" \
        "audit-logging" \
        "Install a daily self-check that verifies the security controls actually work." \
        "What it does:
• Verifies fail2ban is banning (not just running)
• Verifies auditd is active with rules loaded, and warns if it was ever stopped
• Verifies 'aide --check' completes instead of failing silently
• Detects PATH hijacking and replaced diagnostic tools
• Detects a second Docker daemon, proxyware containers, and host-level container access
• Detects executables in /tmp, /dev/shm, /var/tmp and known persistence markers
• Detects secrets exposed on process command lines

Installed to: /usr/local/bin/security-selfcheck.sh
Schedule:     daily at 06:00 via /etc/cron.d/security-selfcheck
Alerts:       only when something fails (Telegram, if configured)

Run it any time with: sudo security-selfcheck" \
        "$([ "$DESKTOP_MODE" = true ] && echo 'n' || echo 'y')"; then

        if [ "$DRY_RUN" = true ]; then
            log_dry_run "Would install /usr/local/bin/security-selfcheck.sh"
            log_dry_run "Would create /etc/cron.d/security-selfcheck (daily at 06:00)"
            log_dry_run "Would store Telegram credentials in /etc/server-baseline/selfcheck.env (chmod 600)"
        else
            # Baseline refresh helper. Deliberately NOT put on a timer: a
            # scheduled `aide --update` absorbs tampering into the baseline
            # within one cycle, which is worse than a stale database. It is
            # meant to be run after a deliberate change, and it reports what it
            # absorbed every time.
            AIDE_REFRESH_SRC="$SCRIPT_DIR/aide-refresh.sh"
            if [ -f "$AIDE_REFRESH_SRC" ]; then
                sudo install -m 700 -o root -g root "$AIDE_REFRESH_SRC" /usr/local/bin/aide-refresh.sh
        sudo sed -i "s|^ENV_FILE_DEFAULT=.*|ENV_FILE_DEFAULT=\\"${PROJECT_ENV:-}\\"|" /usr/local/bin/aide-refresh.sh 2>/dev/null || true
                sudo ln -sf /usr/local/bin/aide-refresh.sh /usr/local/bin/aide-refresh
                log_info "Installed /usr/local/bin/aide-refresh.sh"
                log_info "  Run it after a deliberate change: sudo aide-refresh --reason 'post upgrade'"
                log_info "  It reports which files it absorbs, and refuses to refresh on an AIDE error."
            fi

            SELFCHECK_SRC="$SCRIPT_DIR/security-selfcheck.sh"

            if [ -f "$SELFCHECK_SRC" ]; then
                sudo install -m 700 -o root -g root "$SELFCHECK_SRC" /usr/local/bin/security-selfcheck.sh
        sudo sed -i "s|^ENV_FILE_DEFAULT=.*|ENV_FILE_DEFAULT=\\"${PROJECT_ENV:-}\\"|" /usr/local/bin/security-selfcheck.sh 2>/dev/null || true
                sudo ln -sf /usr/local/bin/security-selfcheck.sh /usr/local/bin/security-selfcheck
                log_info "Installed /usr/local/bin/security-selfcheck.sh"

                # Store Telegram credentials outside the script so the script
                # itself stays a plain, reviewable file with no secrets in it.
                if [[ ! -z "${SECURITY_TELEGRAM_BOT_TOKEN:-}" ]] && [[ ! -z "${SECURITY_TELEGRAM_CHAT_ID:-}" ]]; then
                    sudo mkdir -p /etc/server-baseline
                    sudo chmod 700 /etc/server-baseline
                    printf 'TELEGRAM_BOT_TOKEN=%s\nTELEGRAM_CHAT_ID=%s\n' \
                        "$SECURITY_TELEGRAM_BOT_TOKEN" "$SECURITY_TELEGRAM_CHAT_ID" | \
                        sudo tee /etc/server-baseline/selfcheck.env >/dev/null
                    sudo chmod 600 /etc/server-baseline/selfcheck.env
                    SELFCHECK_ARGS="--quiet --telegram"
                    log_info "Self-check will alert via Telegram on failures"
                else
                    SELFCHECK_ARGS="--quiet"
                    log_info "No Telegram credentials - self-check output goes to cron mail"
                fi

                {
                    echo "# Daily security self-check - verifies that the security controls work"
                    echo "# Only produces output when a check fails."
                    echo "0 6 * * * root /usr/local/bin/security-selfcheck.sh $SELFCHECK_ARGS"
                } | sudo tee /etc/cron.d/security-selfcheck >/dev/null
                sudo chmod 644 /etc/cron.d/security-selfcheck
                log_info "Scheduled daily security self-check at 06:00"

                echo ""
                log_info "Running the self-check once now to establish a baseline..."
                sudo /usr/local/bin/security-selfcheck.sh || true
            else
                log_warning "security-selfcheck.sh not found next to the install script - skipping"
                log_warning "Expected at: $SELFCHECK_SRC"
            fi
        fi
        mark_completed "SECURITY_SELFCHECK"
    else
        log_info "Security self-check skipped"
        mark_completed "SECURITY_SELFCHECK"
    fi
fi

###############################################################################
# SECURITY WATCHDOG
###############################################################################
#
# The self-check above is level-triggered: it reports what is true at 06:00.
# This is edge-triggered: it fires the moment a security control changes state.
#
# That difference matters. auditd being stopped is the first move in this class
# of compromise, and it happens in under a second. A daily check reports it
# hours later; a state-change watchdog reports it within the minute.

if skip_if_completed "SECURITY_WATCHDOG"; then
    log_info "security watchdog already installed, skipping"
else
    if ask_component_install \
        "SECURITY WATCHDOG" \
        "audit-logging" \
        "Alert immediately when a security control stops or something changes." \
        "Services (alerts on stop AND on unexplained return):
• auditd         - systemd unit state
• fail2ban       - systemd unit state
• fail2ban-jail  - whether the sshd jail is actually reachable

That last one exists because 'fail2ban is active' was true throughout the
incident this was written for, while the jail banned nothing. A unit being up
is not the same as the control working, so the jail is tracked separately.

State changes (alerts with a diff of what changed):
• listeners        - a new port bound to 0.0.0.0 or ::
• root-keys        - authorized_keys for root and admin users
• path-hijack      - .local/bin under a system path, or replaced diagnostic tools
• ld-preload       - /etc/ld.so.preload became non-empty
• ufw              - firewall disabled or default policy changed
• docker-daemons   - a second dockerd/containerd appeared
• container-images - a container image never seen on this host before
• boot-id          - the machine rebooted (context for the alerts around it)

Behaviour:
• Alerts on change only - silent while nothing changes
• Every alert says WHAT changed, not just that something did
• States the impact, the logged-in session count and the last log line
• Logs to syslog as well, so there is a trace even if Telegram fails
• Any monitor can be dropped via WATCH_MONITORS if it proves noisy

Installed to: /usr/local/bin/security-watchdog.sh
Schedule:     systemd timer, every minute
Test alert:   sudo security-watchdog --test  (also runs monthly on its own)
Re-baseline:  sudo security-watchdog --reset (after intentional changes)

Why separate from the daily self-check: a control can be stopped and the payload
deployed inside a single minute. A once-a-day check reports that far too late." \
        "$([ "$DESKTOP_MODE" = true ] && echo 'n' || echo 'y')"; then

        if [ "$DRY_RUN" = true ]; then
            log_dry_run "Would install /usr/local/bin/security-watchdog.sh"
            log_dry_run "Would create security-watchdog.service and .timer (every minute)"
            log_dry_run "Would schedule a monthly test alert to verify the alert path"
        else
            WATCHDOG_SRC="$SCRIPT_DIR/watchdogs/security-watchdog.sh"

            if [ -f "$WATCHDOG_SRC" ]; then
                sudo install -m 700 -o root -g root "$WATCHDOG_SRC" /usr/local/bin/security-watchdog.sh
        sudo sed -i "s|^ENV_FILE_DEFAULT=.*|ENV_FILE_DEFAULT=\\"${PROJECT_ENV:-}\\"|" /usr/local/bin/security-watchdog.sh 2>/dev/null || true
                sudo ln -sf /usr/local/bin/security-watchdog.sh /usr/local/bin/security-watchdog
                log_info "Installed /usr/local/bin/security-watchdog.sh"

                # Credentials live in the same file as the self-check
                if [[ ! -z "${SECURITY_TELEGRAM_BOT_TOKEN:-}" ]] && [[ ! -z "${SECURITY_TELEGRAM_CHAT_ID:-}" ]]; then
                    sudo mkdir -p /etc/server-baseline
                    sudo chmod 700 /etc/server-baseline
                    if [ ! -f /etc/server-baseline/selfcheck.env ]; then
                        printf 'TELEGRAM_BOT_TOKEN=%s\nTELEGRAM_CHAT_ID=%s\n' \
                            "$SECURITY_TELEGRAM_BOT_TOKEN" "$SECURITY_TELEGRAM_CHAT_ID" | \
                            sudo tee /etc/server-baseline/selfcheck.env >/dev/null
                        sudo chmod 600 /etc/server-baseline/selfcheck.env
                    fi
                else
                    log_warning "No Telegram credentials - the watchdog will only log to syslog"
                    log_warning "Add them later to /etc/server-baseline/selfcheck.env"
                fi

                cat <<'EOF' | sudo tee /etc/systemd/system/security-watchdog.service >/dev/null
[Unit]
Description=Alert on auditd state changes
Documentation=https://github.com/Made-By-Adem/linux-server-management-scripts

[Service]
Type=oneshot
ExecStart=/usr/local/bin/security-watchdog.sh
# A non-zero exit means "auditd is down", which is the alert itself, not a
# failure of this unit. Without this, the timer would be marked failed every
# run while auditd stays stopped.
SuccessExitStatus=0 1
EOF

                cat <<'EOF' | sudo tee /etc/systemd/system/security-watchdog.timer >/dev/null
[Unit]
Description=Check auditd state every minute

[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
AccuracySec=10s
Unit=security-watchdog.service

[Install]
WantedBy=timers.target
EOF

                sudo systemctl daemon-reload
                sudo systemctl enable --now security-watchdog.timer || \
                    log_warning "Failed to enable security-watchdog.timer"

                # Establish the baseline state now, so the first real run
                # compares against reality instead of firing a false alert.
                sudo /usr/local/bin/security-watchdog.sh >/dev/null 2>&1 || true

                # Monthly deliberate test. An alerting chain that has gone quiet
                # is indistinguishable from "nothing happened" until you make it
                # speak on purpose.
                {
                    echo "# Monthly watchdog test - proves the alert path still works"
                    echo "0 9 1 * * root /usr/local/bin/security-watchdog.sh --test"
                } | sudo tee /etc/cron.d/security-watchdog-test >/dev/null
                sudo chmod 644 /etc/cron.d/security-watchdog-test

                if systemctl is-active security-watchdog.timer >/dev/null 2>&1; then
                    log_info "✓ security watchdog timer is active (checks every minute)"
                    log_info "  Verify the alert path now with: sudo security-watchdog --test"
                    log_info "  Current state:                  sudo security-watchdog --status"
                else
                    log_warning "✗ security-watchdog.timer did not start"
                fi
            else
                log_warning "watchdogs/security-watchdog.sh not found next to the install script - skipping"
                log_warning "Expected at: $WATCHDOG_SRC"
            fi
        fi
        mark_completed "SECURITY_WATCHDOG"
    else
        log_info "security watchdog skipped"
        mark_completed "SECURITY_WATCHDOG"
    fi
fi

###############################################################################
# SYSSTAT PERFORMANCE MONITORING
###############################################################################

if skip_if_completed "SYSSTAT"; then
    log_info "Sysstat already configured, skipping"
else
    if ask_component_install \
        "SYSSTAT PERFORMANCE MONITORING" \
        "sysstat" \
        "Enable sysstat for system performance monitoring and statistics collection." \
        "Features:
• CPU usage statistics
• Memory utilization tracking
• Disk I/O monitoring
• Network statistics
• Historical performance data (28 days)

Tools included:
• sar - System Activity Reporter
• iostat - I/O statistics
• mpstat - CPU statistics per core
• pidstat - Process statistics

Benefits:
• Performance troubleshooting
• Capacity planning
• Identify resource bottlenecks
• Security incident investigation
• Minimal overhead (~0.1% CPU)

Lynis recommendation: ACCT-9626" \
        "$([ "$DESKTOP_MODE" = true ] && echo 'n' || echo 'y')"; then

    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Would install sysstat package"
        log_dry_run "Would enable sysstat in /etc/default/sysstat"
        log_dry_run "Would enable and restart sysstat service"
    else
        log_info "Installing and enabling sysstat..."

        # Install sysstat if not already installed
        if ! dpkg -l | grep -q "^ii  sysstat "; then
            DEBIAN_FRONTEND=noninteractive sudo apt-get install -y sysstat || \
                log_warning "Failed to install sysstat"
        else
            log_info "sysstat already installed"
        fi

        # Enable sysstat
        if [ -f /etc/default/sysstat ]; then
            sudo sed -i 's/^ENABLED="false"/ENABLED="true"/' /etc/default/sysstat
            log_info "Enabled sysstat data collection"
        fi

        # Enable and restart sysstat service
        sudo systemctl enable sysstat || log_warning "Failed to enable sysstat"
        sudo systemctl restart sysstat || log_warning "Failed to restart sysstat"

        log_info "Sysstat enabled and running"
        echo ""
        echo "══════════════════════════════════════════════════════════"
        echo "Sysstat Performance Monitoring Enabled"
        echo "══════════════════════════════════════════════════════════"
        echo "Usage examples:"
        echo "  sar               # Today's activity report"
        echo "  sar -u 1 5        # CPU usage, 5 samples at 1 second"
        echo "  iostat -x 1 5     # Detailed I/O statistics"
        echo "  mpstat -P ALL 1 5 # All CPU cores statistics"
        echo ""
        echo "Historical data: /var/log/sysstat/ (28 days retention)"
        echo "══════════════════════════════════════════════════════════"
        echo ""
    fi
        mark_completed "SYSSTAT"
    else
        log_info "Sysstat installation skipped"
        mark_completed "SYSSTAT"
    fi
fi

###############################################################################
# AIDE FILE INTEGRITY MONITORING
###############################################################################

if skip_if_completed "AIDE"; then
    log_info "AIDE already configured, skipping"
elif [ "$DESKTOP_MODE" = true ]; then
    log_info "AIDE file integrity monitoring skipped (desktop mode — server intrusion detection)"
    mark_completed "AIDE"
else
    # Detect Raspberry Pi
    IS_RASPBERRY_PI=false
    if grep -qi "raspberry\|bcm27\|bcm28" /proc/cpuinfo 2>/dev/null || \
       [ -f /sys/firmware/devicetree/base/model ] && grep -qi "raspberry" /sys/firmware/devicetree/base/model 2>/dev/null; then
        IS_RASPBERRY_PI=true
    fi

    # Show strong warning for Raspberry Pi
    if [ "$IS_RASPBERRY_PI" = true ]; then
        echo ""
        echo -e "${RED}╔═══════════════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${RED}║                                                                           ║${NC}"
        echo -e "${RED}║   ██████╗  █████╗ ███╗   ██╗ ██████╗ ███████╗██████╗                     ║${NC}"
        echo -e "${RED}║   ██╔══██╗██╔══██╗████╗  ██║██╔════╝ ██╔════╝██╔══██╗                    ║${NC}"
        echo -e "${RED}║   ██║  ██║███████║██╔██╗ ██║██║  ███╗█████╗  ██████╔╝                    ║${NC}"
        echo -e "${RED}║   ██║  ██║██╔══██║██║╚██╗██║██║   ██║██╔══╝  ██╔══██╗                    ║${NC}"
        echo -e "${RED}║   ██████╔╝██║  ██║██║ ╚████║╚██████╔╝███████╗██║  ██║                    ║${NC}"
        echo -e "${RED}║   ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═══╝ ╚═════╝ ╚══════╝╚═╝  ╚═╝                    ║${NC}"
        echo -e "${RED}║                                                                           ║${NC}"
        echo -e "${RED}║              AIDE IS NOT RECOMMENDED FOR RASPBERRY PI                     ║${NC}"
        echo -e "${RED}║                                                                           ║${NC}"
        echo -e "${RED}╚═══════════════════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "${RED}${BOLD}RISKS OF RUNNING AIDE ON RASPBERRY PI:${NC}"
        echo ""
        echo -e "${RED}  ✗ SD CARD WEAR:${NC} AIDE performs intensive disk I/O that significantly"
        echo -e "    reduces SD card lifespan. Database init alone writes gigabytes of data."
        echo ""
        echo -e "${RED}  ✗ FILESYSTEM CORRUPTION:${NC} Heavy I/O on flash storage can cause EXT4"
        echo -e "    errors like 'failed to convert unwritten extents' leading to data loss."
        echo ""
        echo -e "${RED}  ✗ SYSTEM INSTABILITY:${NC} AIDE initialization (10-20 min) can cause"
        echo -e "    system hangs, bus errors, and kernel panics on Pi hardware."
        echo ""
        echo -e "${RED}  ✗ RESOURCE EXHAUSTION:${NC} Pi's limited RAM and I/O bandwidth are"
        echo -e "    overwhelmed by AIDE's full filesystem scans."
        echo ""
        echo -e "${YELLOW}ALTERNATIVES FOR RASPBERRY PI:${NC}"
        echo "  • Use rkhunter (already in this script) - lightweight rootkit detection"
        echo "  • Use Lynis (already in this script) - security auditing without heavy I/O"
        echo "  • Monitor critical files with inotifywait (event-based, no scanning)"
        echo "  • Use remote/cloud-based integrity monitoring"
        echo ""
        echo -e "${BOLD}Raspberry Pi detected. AIDE installation will be skipped.${NC}"
        echo ""
        read -p "Press Enter to continue..."
        log_warning "AIDE skipped - not recommended for Raspberry Pi hardware"
        mark_completed "AIDE"
    else
    if ask_component_install \
        "AIDE FILE INTEGRITY MONITORING" \
        "aide" \
        "Install and configure AIDE for file integrity monitoring and intrusion detection." \
        "Security features:
• Detects unauthorized file changes
• Monitors system binaries and configs
• Creates cryptographic checksums (SHA-256, SHA-512)
• Regular integrity checks via daily cron

Monitored paths:
• /bin, /sbin, /usr/bin, /usr/sbin (system binaries)
• /etc (configuration files)
• /boot (kernel files)
• /lib, /lib64 (system libraries)

⚠️  IMPORTANT:
• Initial database creation: 10-20 minutes
• Daily checks: 5-10 minutes (4:00 AM)
• High disk I/O during scans
• Recommended for PRODUCTION servers only

Benefits:
• Intrusion detection
• Compliance requirements (PCI-DSS, HIPAA)
• Change tracking and auditing
• Alert on unauthorized modifications

Lynis recommendation: FINT-4350" \
        "n"; then

    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "AIDE Production Server Confirmation"
    echo "═══════════════════════════════════════════════════════════"
    echo ""
    echo "AIDE is resource-intensive and recommended for production servers only."
    echo ""
    echo "Install AIDE if:"
    echo "  ✓ This is a production server"
    echo "  ✓ You need intrusion detection"
    echo "  ✓ Compliance requires file integrity monitoring"
    echo ""
    echo "Skip AIDE if:"
    echo "  ✗ This is a development/test server"
    echo "  ✗ Limited disk I/O budget"
    echo ""
    read -p "Is this a PRODUCTION server? Install AIDE? (y/N): " is_production
    is_production=${is_production:-n}

    if [[ $is_production =~ ^[Yy]$ ]]; then
        if [ "$DRY_RUN" = true ]; then
            log_dry_run "Would install aide and aide-common"
            log_dry_run "Would configure /etc/aide/aide.conf with SHA-512 checksums (stronger than SHA-256)"
            log_dry_run "Would configure critical file monitoring with SHA-512 hashes"
            log_dry_run "Would initialize AIDE database (15+ minutes)"
            log_dry_run "Would create daily cron job /etc/cron.daily/aide-check"
        else
            log_info "Installing AIDE file integrity monitoring..."

            # Install AIDE
            DEBIAN_FRONTEND=noninteractive sudo apt-get install -y aide aide-common || \
                handle_error "Failed to install AIDE"

            # Backup default config
            if [ -f /etc/aide/aide.conf ]; then
                sudo cp /etc/aide/aide.conf /etc/aide/aide.conf.backup.$(date +%Y%m%d_%H%M%S)
            fi

            # Configure AIDE with stronger checksums (Lynis FINT-4402)
            log_info "Configuring AIDE with SHA-512 checksums..."

            # Set SHA-512 as default checksum algorithm
            if grep -q "^Checksums =" /etc/aide/aide.conf; then
                sudo sed -i 's/^Checksums =.*/Checksums = sha512/' /etc/aide/aide.conf
            else
                echo "Checksums = sha512" | sudo tee -a /etc/aide/aide.conf >/dev/null
            fi

            # Add custom exclusions
            cat <<'EOF' | sudo tee -a /etc/aide/aide.conf >/dev/null

# Custom exclusions added by server baseline script (Lynis FINT-4350)
# Exclude frequently changing directories to reduce false positives
!/var/log
!/var/cache
!/var/tmp
!/tmp
!/proc
!/sys
!/dev
!/run
!/var/lib/docker
!/var/lib/containerd

# Paths that change by design, and would otherwise make every single run
# report differences. An integrity monitor that always fires is one that gets
# ignored, which is the same outcome as not having one.
#
# Note what is given up: an attacker could alter the watchdog's state files
# without AIDE noticing. That is an acceptable trade only because those files
# change every minute legitimately - AIDE could never have distinguished
# tampering from normal operation there anyway.
!/var/lib/aide
!/var/lib/server-baseline
!/var/lib/systemd
!/root/\.vscode-server
!/root/\.cache
!/root/\.copilot
!/root/\.bash_history

# backup.sh opens an SSH ControlMaster socket here, so the directory mtime
# changes on every backup run. Only this subdirectory: the keys and
# authorized_keys beside it are among the most important things AIDE watches,
# and the sockets inside are ephemeral and root-only anyway.
!/root/\.ssh/cm

# Package metadata, refreshed by apt's own timers. Tampering here is not a
# useful attack: the indexes are signature-verified, so a modified one fails
# apt rather than installing anything.
!/var/lib/apt/lists
!/var/lib/apt/periodic

# rkhunter copies /etc/passwd and /etc/group here on every scan to diff them
# against the previous run. The copies change whenever a user is added and on
# every scan regardless. The diff rkhunter draws from them is the control;
# these are its scratch space, and /var/lib/rkhunter/db beside them is not
# excluded.
!/var/lib/rkhunter/tmp
!/var/lib/ubuntu-advantage
!/var/lib/landscape
!/var/lib/update-notifier
!/var/lib/PackageKit

# Monitor Docker binaries if installed
/usr/bin/docker$ R
/usr/bin/docker-compose$ R

# Monitor critical config files with detailed attributes (SHA-512)
/etc/ssh/sshd_config$ p+i+n+u+g+s+b+acl+selinux+xattrs+sha512
/etc/sudoers$ p+i+n+u+g+s+b+acl+selinux+xattrs+sha512
/etc/passwd$ p+i+n+u+g+s+b+acl+selinux+xattrs+sha512
/etc/shadow$ p+i+n+u+g+s+b+acl+selinux+xattrs+sha512
EOF

            # This repository is a git checkout on the host it manages, and git
            # rewrites objects, refs and logs on every pull - a few thousand
            # differences from one 'git pull'.
            #
            # Written here rather than in the heredoc above because an AIDE
            # rule must be a literal path prefix: it has to start with '/', so
            # there is no way to say "any .git anywhere". A first attempt used
            # !.*/\.git/objects, which AIDE refuses to parse - the whole config
            # became invalid and every check exited 17. The real checkout path
            # is known here, so it is used.
            #
            # Deliberately NOT the whole .git directory: hooks and config stay
            # monitored, because a hook is executable code that runs as whoever
            # runs git.
            AIDE_GIT_ROOT="${PROJECT_ROOT//./\\.}"
            for gp in objects logs refs index FETCH_HEAD ORIG_HEAD \
                      COMMIT_EDITMSG packed-refs modules; do
                echo "!${AIDE_GIT_ROOT}/\\.git/${gp}"
            done | sudo tee -a /etc/aide/aide.conf >/dev/null

            # Never leave a config behind that AIDE cannot read: that is exit 17
            # on every scheduled run, which reads as "AIDE is broken" long
            # before anyone works out which line did it.
            if ! sudo aide --config=/etc/aide/aide.conf --config-check >/dev/null 2>&1; then
                log_warning "AIDE rejected the generated config - restoring the backup"
                sudo cp /etc/aide/aide.conf "/etc/aide/aide.conf.rejected.$(date +%Y%m%d_%H%M%S)"
                LATEST_BAK=$(ls -1t /etc/aide/aide.conf.backup.* 2>/dev/null | head -1)
                [ -n "$LATEST_BAK" ] && sudo cp "$LATEST_BAK" /etc/aide/aide.conf
            fi

            log_info "AIDE configured with SHA-512 checksums and exclusions"

            # Initialize AIDE database
            echo ""
            echo "══════════════════════════════════════════════════════════"
            echo "INITIALIZING AIDE DATABASE"
            echo "══════════════════════════════════════════════════════════"
            echo ""
            echo "⏳ This will take 10-20 minutes depending on system size"
            echo "   Please be patient while AIDE scans all monitored files..."
            echo ""

            # Run aideinit
            sudo aideinit || log_warning "AIDE initialization had warnings (may be normal)"

            # Move database to correct location
            if [ -f /var/lib/aide/aide.db.new ]; then
                sudo mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db
                log_info "AIDE database initialized successfully"
                AIDE_INSTALLED=true

                # Create AIDE Telegram wrapper script if Telegram credentials are available
                if [[ ! -z "$SECURITY_TELEGRAM_BOT_TOKEN" ]] && [[ ! -z "$SECURITY_TELEGRAM_CHAT_ID" ]]; then
                    # Installed from server-baseline/reporters/ so
                    # update-baseline.sh can deploy the identical script.
                    AIDE_SRC="$SCRIPT_DIR/reporters/aide-telegram.sh"
                    if [ -f "$AIDE_SRC" ]; then
                        sudo install -m 700 -o root -g root "$AIDE_SRC" /usr/local/bin/aide-telegram.sh
        sudo sed -i "s|^ENV_FILE_DEFAULT=.*|ENV_FILE_DEFAULT=\\"${PROJECT_ENV:-}\\"|" /usr/local/bin/aide-telegram.sh 2>/dev/null || true
                    else
                        log_warning "reporters/aide-telegram.sh not found - skipping AIDE reporter"
                    fi

                    # Replace placeholders with actual credentials for AIDE
                    log_info "AIDE Telegram integration configured"

                    # Create symlink in scripts directory if it exists
                    if [ -d "$USER_HOME/scripts" ]; then
                        sudo ln -sf /usr/local/bin/aide-telegram.sh "$USER_HOME/scripts/aide-telegram" 2>/dev/null || true
                        log_info "Created symlink: ~/scripts/aide-telegram"
                    fi

                    # Remove the old email-based cron job and use Telegram version
                    sudo rm -f /etc/cron.daily/aide-check 2>/dev/null || true

                    # Add AIDE to the security-scans cron job
                    if [ -f /etc/cron.d/security-scans ]; then
                        # Append AIDE cron job if not already present
                        if ! grep -q "aide-telegram.sh" /etc/cron.d/security-scans; then
                            echo "" | sudo tee -a /etc/cron.d/security-scans >/dev/null
                            echo "# AIDE daily integrity check at 05:00" | sudo tee -a /etc/cron.d/security-scans >/dev/null
                            echo "0 5 * * * root /usr/local/bin/aide-telegram.sh" | sudo tee -a /etc/cron.d/security-scans >/dev/null
                        fi
                    else
                        # Create new cron file for AIDE
                        echo "# AIDE daily integrity check at 05:00" | sudo tee /etc/cron.d/security-scans >/dev/null
                        echo "0 5 * * * root /usr/local/bin/aide-telegram.sh" | sudo tee -a /etc/cron.d/security-scans >/dev/null
                        sudo chmod 644 /etc/cron.d/security-scans
                    fi
                    log_info "AIDE: Daily integrity checks at 05:00 with Telegram notifications"
                else
                    # No Telegram credentials - create email-based cron job
                    cat <<'EOF' | sudo tee /etc/cron.daily/aide-check >/dev/null
#!/bin/bash
# AIDE daily integrity check (Lynis FINT-4350)
#
# AIDE exit codes: 0 = clean, 1..7 = differences, >= 14 = AIDE itself failed.
# The database is only refreshed on a genuinely clean run.

LOG_FILE="/var/log/aide-check-$(date +%Y%m%d).log"

# On Debian and Ubuntu, `aide` does NOT read /etc/aide/aide.conf by itself:
# aide-common generates /var/lib/aide/aide.conf.autogenerated and ships
# aide.wrapper to invoke it. A bare `aide --check` fails with "missing
# configuration" (exit 17) on every run - which an earlier version of this
# script did, so AIDE never actually ran here at all.
if command -v aide.wrapper >/dev/null 2>&1; then
    AIDE="aide.wrapper"
elif [ -x /usr/sbin/aide.wrapper ]; then
    AIDE="/usr/sbin/aide.wrapper"
elif [ -f /var/lib/aide/aide.conf.autogenerated ]; then
    AIDE="aide --config=/var/lib/aide/aide.conf.autogenerated"
elif [ -f /etc/aide/aide.conf ]; then
    AIDE="aide --config=/etc/aide/aide.conf"
elif [ -f /etc/aide.conf ]; then
    AIDE="aide --config=/etc/aide.conf"
else
    echo "No usable AIDE configuration - is aide-common installed?" >&2
    exit 1
fi

# Run check
$AIDE --check > "$LOG_FILE" 2>&1
CHECK_RESULT=$?

if [ $CHECK_RESULT -ge 14 ]; then
    # AIDE could not complete - integrity is UNVERIFIED, not "unchanged"
    cat "$LOG_FILE" | mail -s "AIDE: CHECK FAILED (exit $CHECK_RESULT) on $(hostname)" root 2>/dev/null || true
elif [ $CHECK_RESULT -ne 0 ]; then
    cat "$LOG_FILE" | mail -s "AIDE: File Changes Detected on $(hostname)" root 2>/dev/null || true
else
    # No changes, update database
    $AIDE --update >/dev/null 2>&1
    mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db 2>/dev/null || true
fi

# Keep logs for 30 days
find /var/log -name "aide-check-*.log" -mtime +30 -delete 2>/dev/null || true
EOF

                    sudo chmod 755 /etc/cron.daily/aide-check
                    log_info "AIDE daily check cron job created (email-based)"
                fi
            else
                log_warning "AIDE database not found at expected location"
            fi

            echo ""
            echo "══════════════════════════════════════════════════════════"
            echo "AIDE File Integrity Monitoring Configured"
            echo "══════════════════════════════════════════════════════════"
            echo "✓ Database initialized"
            echo "✓ Daily checks enabled (4:00 AM via cron)"
            echo "✓ Alerts sent to root user"
            echo ""
            echo "Manual commands:"
            echo "  sudo aide --check          # Check integrity now"
            echo "  sudo aide --update         # Update database"
            echo ""
            echo "Logs: /var/log/aide-check-*.log"
            echo "══════════════════════════════════════════════════════════"
            echo ""
        fi
    else
        log_info "AIDE installation skipped (not a production server)"
    fi
        mark_completed "AIDE"
    else
        log_info "AIDE installation skipped"
        mark_completed "AIDE"
    fi
    fi  # End of Raspberry Pi else branch
fi

###############################################################################
# COMPILER RESTRICTIONS
###############################################################################

if skip_if_completed "COMPILER_RESTRICTIONS"; then
    log_info "Compiler restrictions already configured, skipping"
elif [ "$DESKTOP_MODE" = true ]; then
    log_info "Compiler restrictions skipped (desktop mode — needed for development)"
    mark_completed "COMPILER_RESTRICTIONS"
else
    if ask_component_install \
        "COMPILER ACCESS RESTRICTIONS" \
        "compiler-restrictions" \
        "Restrict access to compilers to prevent on-server malware compilation." \
        "Security features:
• Restrict access to gcc, g++, cc, make, as
• Only root can compile (chmod 700)
• Prevents attackers from compiling exploits
• Reduces privilege escalation opportunities

Restricted compilers:
• /usr/bin/gcc
• /usr/bin/g++
• /usr/bin/cc
• /usr/bin/as (assembler)
• /usr/bin/make

⚠️  WARNING: This may break development workflows!

Recommended FOR:
  ✓ Production servers (web, database, apps)
  ✓ Servers that only RUN software

NOT recommended for:
  ✗ Development servers
  ✗ Build/CI servers
  ✗ Raspberry Pi with dev projects

Note: Only root can compile with these restrictions
To restore access: sudo chmod 755 /usr/bin/gcc /usr/bin/g++ /usr/bin/make

Lynis recommendation: HRDN-7222" \
        "n"; then

    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "Compiler Restrictions - Production Server Check"
    echo "═══════════════════════════════════════════════════════════"
    echo ""
    echo "This will restrict compiler access to root ONLY (chmod 700)."
    echo ""
    echo "Restrict compilers if:"
    echo "  ✓ Pure production server (no development)"
    echo "  ✓ Only running pre-built software"
    echo "  ✓ Security is priority"
    echo ""
    echo "Skip if:"
    echo "  ✗ Development server"
    echo "  ✗ Need to compile software"
    echo "  ✗ Run npm install with native modules"
    echo "  ✗ Build Docker images with compilation"
    echo ""
    read -p "Restrict compilers? (PRODUCTION servers only) (y/N): " restrict_compilers
    restrict_compilers=${restrict_compilers:-n}

    if [[ $restrict_compilers =~ ^[Yy]$ ]]; then
        if [ "$DRY_RUN" = true ]; then
            log_dry_run "Would restrict compiler permissions:"
            log_dry_run "  - gcc, g++, cc, as, make → 700 (root only)"
        else
            log_info "Restricting compiler access to root only..."

            # List of compilers to restrict
            COMPILERS="/usr/bin/gcc /usr/bin/g++ /usr/bin/cc /usr/bin/as /usr/bin/make"
            RESTRICTED=0

            for compiler in $COMPILERS; do
                if [ -f "$compiler" ]; then
                    # Restrict to root only (700)
                    sudo chown root:root "$compiler"
                    sudo chmod 700 "$compiler"
                    log_info "✓ Restricted: $compiler"
                    ((RESTRICTED++))
                fi
            done

            if [ $RESTRICTED -gt 0 ]; then
                echo ""
                echo "══════════════════════════════════════════════════════════"
                echo "Compiler Access Restricted"
                echo "══════════════════════════════════════════════════════════"
                echo "Restricted $RESTRICTED compiler(s)"
                echo ""
                echo "Access limited to:"
                echo "  ✓ root user ONLY"
                echo ""
                echo "To restore access to all users:"
                echo "  for file in $COMPILERS; do"
                echo "    sudo chmod 755 \$file"
                echo "    sudo chown root:root \$file"
                echo "  done"
                echo "══════════════════════════════════════════════════════════"
                echo ""
            else
                log_warning "No compilers found to restrict"
            fi
        fi
    else
        log_info "Compiler restrictions skipped (not a production-only server)"
    fi
        mark_completed "COMPILER_RESTRICTIONS"
    else
        log_info "Compiler restrictions skipped"
        mark_completed "COMPILER_RESTRICTIONS"
    fi
fi

###############################################################################
# DEPRECATED PACKAGE CLEANUP
###############################################################################

if skip_if_completed "PACKAGE_CLEANUP"; then
    log_info "Package cleanup already performed, skipping"
else
    if ask_component_install \
        "DEPRECATED PACKAGE CLEANUP" \
        "package-cleanup" \
        "Remove deprecated and insecure packages to reduce attack surface." \
        "Packages to remove:
• nis - Insecure legacy authentication
• rsh-client - Unencrypted remote shell
• telnet - Unencrypted terminal protocol
• tftp - Trivial FTP (insecure)
• xinetd - Super-server (rarely needed)

Additional cleanup:
• apt-get autoremove - Remove unused dependencies
• apt-get clean - Clear package cache

Benefits:
• Reduced attack surface
• Less maintenance overhead
• Remove known security vulnerabilities
• Free disk space

⚠️  Only removes if packages are installed
Safe for most server configurations

Lynis recommendation: PKGS-7346" \
        "y"; then

    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Would check and remove deprecated packages:"
        log_dry_run "  - nis, rsh-client, telnet, tftp, xinetd"
        log_dry_run "Would purge residual configuration files from removed packages (dpkg --purge)"
        log_dry_run "Would run apt-get autoremove"
        log_dry_run "Would run apt-get clean"
    else
        log_info "Checking for deprecated/insecure packages..."

        # List of packages to remove
        DEPRECATED_PKGS="nis rsh-client telnet tftp xinetd"
        REMOVED_COUNT=0

        for pkg in $DEPRECATED_PKGS; do
            if dpkg -l | grep -q "^ii  $pkg "; then
                log_info "Removing deprecated package: $pkg"
                sudo apt-get remove -y "$pkg" >/dev/null 2>&1 && ((REMOVED_COUNT++)) || \
                    log_warning "Failed to remove $pkg"
            fi
        done

        # Autoremove unused dependencies
        log_info "Removing unused dependencies..."
        sudo apt-get autoremove -y >/dev/null 2>&1

        # Clean package cache
        log_info "Cleaning package cache..."
        sudo apt-get clean >/dev/null 2>&1

        # Purge removed/config-only packages (Lynis PKGS-7346)
        #
        # NEVER purge boot-critical packages. On a stock cloud image grub-pc is
        # routinely left in 'rc' state, and purging it asks whether to delete
        # /boot/grub - a question that makes the machine unbootable if answered
        # wrongly, asked in the middle of an unattended cleanup step. Tidying up
        # residual config files is not worth any risk to the bootloader.
        log_info "Purging old configuration files from removed packages..."
        RC_PACKAGES=$(dpkg -l | awk '/^rc/{print $2}' | \
                      grep -vE '^(grub|shim|linux-image|linux-headers|linux-modules|efibootmgr|initramfs)' || true)
        RC_SKIPPED=$(dpkg -l | awk '/^rc/{print $2}' | \
                     grep -E '^(grub|shim|linux-image|linux-headers|linux-modules|efibootmgr|initramfs)' || true)

        if [ -n "$RC_SKIPPED" ]; then
            log_warning "Leaving boot-critical packages alone: $(echo "$RC_SKIPPED" | tr '\n' ' ')"
            log_warning "  Purging these can remove /boot/grub and make the system unbootable."
        fi

        if [ -n "$RC_PACKAGES" ]; then
            RC_COUNT=$(echo "$RC_PACKAGES" | wc -l)
            log_info "Found $RC_COUNT package(s) with residual config files:"
            echo "$RC_PACKAGES" | sed 's/^/    /'
            # noninteractive so a stray debconf prompt cannot block or, worse,
            # be answered by whatever keystroke arrives next.
            echo "$RC_PACKAGES" | DEBIAN_FRONTEND=noninteractive xargs -r sudo dpkg --purge 2>/dev/null || \
                log_warning "Some packages could not be purged - not fatal"
            log_info "✓ Purged configuration files from removed packages"
        else
            log_info "✓ No residual configuration files to purge"
        fi

        if [ $REMOVED_COUNT -gt 0 ]; then
            log_info "✓ Removed $REMOVED_COUNT deprecated package(s)"
        else
            log_info "✓ No deprecated packages found (good!)"
        fi

        log_info "✓ Unused dependencies removed"
        log_info "✓ Package cache cleaned"
    fi
        mark_completed "PACKAGE_CLEANUP"
    else
        log_info "Package cleanup skipped"
        mark_completed "PACKAGE_CLEANUP"
    fi
fi

###############################################################################
# SHELL IMPROVEMENTS
###############################################################################

if ask_component_install \
    "SHELL IMPROVEMENTS (Bash Aliases)" \
    "shell-improvements" \
    "Add useful bash aliases to .bashrc for improved productivity." \
    "Aliases to add:
• ll - List files in detailed format (ls -lah)
• update - Quick system update command
• dps - Docker ps with better formatting

Target: $USER_HOME/.bashrc" \
    "y"; then

    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Would add bash aliases to $USER_HOME/.bashrc:"
        log_dry_run "  - alias ll='ls -lah'"
        log_dry_run "  - alias update='sudo apt-get update && sudo apt-get upgrade -y'"
        log_dry_run "  - alias dps='docker ps --format \"table {{.Names}}\t{{.Status}}\t{{.Ports}}\"'"
    else
        log_info "Adding shell improvements..."

        # System-wide, not in one account's .bashrc.
        #
        # USER_HOME is where the service directories live (/home on a root-only
        # host), which is not necessarily a home directory with an rc file in
        # it. Appending aliases to "$USER_HOME/.bashrc" wrote them to
        # /home/.bashrc there - a file no shell ever reads.
        cat > /etc/profile.d/99-server-baseline.sh <<'PROFILE_EOF'
# Installed by server-baseline. Safe to edit; re-running the installer
# overwrites this file.

alias ll='ls -lah'
alias update='apt-get update && apt-get upgrade -y'
alias dps='docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"'
alias dlog='docker logs -f --tail 100'
PROFILE_EOF
        sudo chmod 644 /etc/profile.d/99-server-baseline.sh

        # Ubuntu sources /etc/profile.d only for login shells. Interactive
        # non-login shells read /etc/bash.bashrc, so point that at the same file
        # rather than maintaining two copies.
        if [ -f /etc/bash.bashrc ] && ! grep -q '99-server-baseline' /etc/bash.bashrc; then
            {
                echo ""
                echo "# server-baseline aliases (also loaded for login shells via profile.d)"
                echo "[ -r /etc/profile.d/99-server-baseline.sh ] && . /etc/profile.d/99-server-baseline.sh"
            } | sudo tee -a /etc/bash.bashrc >/dev/null
        fi

        # Make this repo's tools available as commands.
        #
        # Symlinks, never copies: install-script.sh installs files from its own
        # directory (reporters/, watchdogs/), and it resolves that directory by
        # following the symlink back to the checkout. A copy in /usr/local/bin
        # would look for those files in /usr/local/bin and find nothing.
        link_repo_tool() {
            local target="$1" name="$2"
            if [ -f "$target" ]; then
                sudo ln -sf "$target" "/usr/local/bin/$name"
                log_info "  $name -> $target"
            fi
        }

        log_info "Linking repository tools into /usr/local/bin..."
        link_repo_tool "$SCRIPT_DIR/install-script.sh"                 server-setup
        link_repo_tool "$SCRIPT_DIR/update-baseline.sh"                update-baseline
        link_repo_tool "$PROJECT_ROOT/update-containers/update-containers.sh" update-containers
        link_repo_tool "$PROJECT_ROOT/backup-script/backup.sh"         backup-folders

        log_info "Shell improvements added"
        log_info "  Aliases apply to new shells; run 'source /etc/profile.d/99-server-baseline.sh' for this one."
    fi
else
    log_info "Shell improvements skipped"
fi

###############################################################################
# DIRECTORY STRUCTURE
###############################################################################

if ask_component_install \
    "PROJECT DIRECTORY STRUCTURE" \
    "directories" \
    "Create standard directory structure in user home directory for organizing projects." \
    "Directories to create in $USER_HOME:
• docker/ - Docker compose files and configs
• scripts/ - Shell scripts and automation
• projects/ - Development projects

Owner: $ACTUAL_USER" \
    "y"; then

    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Would verify and correct USER_HOME if needed"
        log_dry_run "Would create directories in $USER_HOME:"
        log_dry_run "  - docker/"
        log_dry_run "  - scripts/"
        log_dry_run "  - projects/"
        log_dry_run "Would set ownership to $ACTUAL_USER:$ACTUAL_USER"
    else
        log_info "Creating project directory structure..."

        # Verify we're creating directories in the correct user's home
        # SUDO_USER is unset when the script is run from a root shell rather
        # than through sudo, and `set -u` turns a bare reference into a fatal
        # error - two thirds of the way through an installation.
        SUDO_INVOKER="${SUDO_USER:-}"
        if [ "$USER_HOME" = "/root" ] && [ -n "$SUDO_INVOKER" ] && [ "$SUDO_INVOKER" != "root" ]; then
            log_warning "Detected USER_HOME points to /root but script was run with sudo by $SUDO_INVOKER"
            log_warning "Correcting to use actual user's home directory..."
            # Use getent to get the correct home directory
            CORRECTED_HOME=$(getent passwd "$SUDO_INVOKER" | cut -d: -f6)
            if [ -n "$CORRECTED_HOME" ] && [ "$CORRECTED_HOME" != "/" ]; then
                USER_HOME="$CORRECTED_HOME"
                log_info "Using corrected home directory: $USER_HOME"
            else
                log_warning "Could not determine correct home directory, using /home/$SUDO_INVOKER"
                USER_HOME="/home/$SUDO_INVOKER"
            fi
        fi

        # Cross-check USER_HOME against /etc/passwd for ACTUAL_USER and verify the directory exists.
        # On Ubuntu Desktop with multiple users, the early autodetection may have picked the wrong one.
        # Guard `getent` (not present on minimal systems) the same way the early detection does.
        if command -v getent &>/dev/null; then
            PASSWD_HOME=$(getent passwd "$ACTUAL_USER" 2>/dev/null | cut -d: -f6)
        else
            PASSWD_HOME=$(grep "^$ACTUAL_USER:" /etc/passwd 2>/dev/null | cut -d: -f6)
        fi
        if [ -n "$PASSWD_HOME" ] && [ "$PASSWD_HOME" != "/" ] && [ "$PASSWD_HOME" != "$USER_HOME" ]; then
            log_warning "USER_HOME ($USER_HOME) does not match /etc/passwd entry for $ACTUAL_USER ($PASSWD_HOME)"
            log_info "Using home directory from /etc/passwd: $PASSWD_HOME"
            USER_HOME="$PASSWD_HOME"
        fi

        if [ ! -d "$USER_HOME" ]; then
            handle_error "Home directory does not exist: $USER_HOME (user: $ACTUAL_USER). Re-run the script with sudo from the intended account."
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
    fi
else
    log_info "Directory structure creation skipped"
fi

###############################################################################
# CLOUDFLARE TUNNEL SETUP
###############################################################################

if ask_component_install \
    "CLOUDFLARE TUNNEL" \
    "cloudflare-tunnel" \
    "Set up Cloudflare Tunnel (cloudflared) for secure remote access without opening ports." \
    "What is Cloudflare Tunnel:
• Secure tunnel to your server without port forwarding
• No need to expose SSH/HTTP ports publicly
• Free Cloudflare Zero Trust protection
• Access via custom domain

Setup requires:
• Cloudflare account (free)
• Tunnel token from https://one.dash.cloudflare.com/
• Navigate to: Networks > Tunnels > Create/Select Tunnel

Directory: $USER_HOME/docker/cloudflare/" \
    "n"; then

    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Would create $USER_HOME/docker/cloudflare/"
        log_dry_run "Would prompt for Cloudflare Tunnel token"
        log_dry_run "Would create .env file with CF_TOKEN"
        log_dry_run "Would create docker-compose.yaml for cloudflared"
        log_dry_run "Would set ownership to $ACTUAL_USER"
        CF_CONFIGURED=true  # Assume configured for dry-run summary
    else
        log_info "Setting up Cloudflare Tunnel..."

        # Ensure parent docker directory exists with correct ownership
        if [ ! -d "$USER_HOME/docker" ]; then
            sudo mkdir -p "$USER_HOME/docker" || handle_error "Failed to create docker directory"
        fi
        # Always ensure correct ownership, even if directory existed
        sudo chown "$ACTUAL_USER:$ACTUAL_USER" "$USER_HOME/docker" || handle_error "Failed to set ownership on docker directory"

        # Create cloudflare directory (now parent exists with correct ownership)
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
        echo "  4. Copy the tunnel token (starts with 'ey...')"
        echo ""
        echo "Note: Token will be visible when you paste it"
        echo ""
        read -p "Enter your Cloudflare Tunnel token (or 'n' to skip): " cf_token

        if [[ $cf_token != "n" ]] && [[ $cf_token != "N" ]] && [[ ! -z "$cf_token" ]]; then
            # Validate token format (should start with 'ey' - JWT format)
            if [[ ! "$cf_token" =~ ^ey ]]; then
                log_warning "Token doesn't appear to be in expected format (should start with 'ey')"
                read -p "Continue anyway? (y/N): " continue_anyway
                if [[ ! $continue_anyway =~ ^[Yy]$ ]]; then
                    log_warning "Cloudflare Tunnel setup cancelled"
                    CF_CONFIGURED=false
                else
                    log_info "Continuing with provided token..."
                fi
            fi

            if [[ $cf_token =~ ^ey ]] || [[ $continue_anyway =~ ^[Yy]$ ]]; then
                # Show token preview for verification
                TOKEN_PREVIEW="${cf_token:0:20}...${cf_token: -10}"
                echo ""
                echo "Token preview: $TOKEN_PREVIEW"
                read -p "Is this correct? (Y/n): " confirm_token
                confirm_token=${confirm_token:-y}

                if [[ ! $confirm_token =~ ^[Yy]$ ]]; then
                    log_warning "Token not confirmed, skipping Cloudflare Tunnel setup"
                    CF_CONFIGURED=false
                else
                    # Create .env file with token (as the actual user)
                    sudo -u "$ACTUAL_USER" bash -c "echo 'CF_TOKEN=$cf_token' > '$USER_HOME/docker/cloudflare/.env'"
                    sudo -u "$ACTUAL_USER" chmod 600 "$USER_HOME/docker/cloudflare/.env"
                fi
            fi
        else
            log_warning "Cloudflare Tunnel setup skipped"
            CF_CONFIGURED=false
        fi

        # Only create docker-compose if token was confirmed
        if [[ -f "$USER_HOME/docker/cloudflare/.env" ]]; then

            # Create docker-compose.yaml for Cloudflare (as the actual user)
            sudo -u "$ACTUAL_USER" cat <<'EOF' > "$USER_HOME/docker/cloudflare/docker-compose.yaml"
services:
  cloudflared:
    # NOTE: Using :latest tag. For production, consider pinning to a specific version (e.g., cloudflare/cloudflared:2024.1.5)
    image: cloudflare/cloudflared:latest
    # The token is passed via the environment, NOT on the command line. Compose
    # interpolates ${CF_TOKEN} into `command:`, which would put the tunnel token
    # in the process argv - readable through `ps`, /proc, and `docker inspect` by
    # anything on the host, including any container running with pid: host.
    # cloudflared reads TUNNEL_TOKEN from the environment.
    # CF_TOKEN is interpolated from the .env file in this directory, which
    # `docker compose` reads automatically.
    command: tunnel --no-autoupdate run
    environment:
      - TUNNEL_TOKEN=${CF_TOKEN}
    network_mode: host
    restart: unless-stopped
EOF

            # Ensure ownership is correct
            sudo chown -R "$ACTUAL_USER:$ACTUAL_USER" "$USER_HOME/docker/cloudflare"
            log_info "Cloudflare Tunnel configuration created (token stored securely in .env)"
            CF_CONFIGURED=true

            # Ask about Cloudflare-only mode
            echo ""
            echo "=========================================================================="
            echo "CLOUDFLARE-ONLY MODE"
            echo "=========================================================================="
            echo ""
            echo "With Cloudflare-only mode, ALL Docker services (Portainer, Netdata, etc.)"
            echo "will only be accessible through Cloudflare Tunnel."
            echo ""
            echo "What this means:"
            echo "  • Docker containers bind to 127.0.0.1 (localhost only)"
            echo "  • No service ports are opened in UFW (9443, 19999, etc.)"
            echo "  • HTTP/HTTPS ports (80/443) are also removed from UFW"
            echo "  • Services are ONLY reachable via your Cloudflare domain"
            echo "  • SSH remains open as emergency fallback"
            echo ""
            echo "  ✅ Maximum security: zero exposed service ports"
            echo "  ⚠️  Requires Cloudflare Tunnel to be running for access"
            echo ""
            read -p "Enable Cloudflare-only mode? (Y/n): " cf_only_choice
            cf_only_choice=${cf_only_choice:-y}

            if [[ $cf_only_choice =~ ^[Yy]$ ]]; then
                CLOUDFLARE_ONLY=true
                log_info "Cloudflare-only mode ENABLED - services will only be accessible via Cloudflare Tunnel"

                # Remove HTTP/HTTPS UFW rules if they were already added in the UFW section
                if sudo ufw status | grep -q "80/tcp"; then
                    sudo ufw delete allow 80/tcp 2>/dev/null || true
                    log_info "Removed UFW rule for port 80/tcp (HTTP) - not needed in Cloudflare-only mode"
                fi
                if sudo ufw status | grep -q "443/tcp"; then
                    sudo ufw delete allow 443/tcp 2>/dev/null || true
                    log_info "Removed UFW rule for port 443/tcp (HTTPS) - not needed in Cloudflare-only mode"
                fi
                sudo ufw reload 2>/dev/null || true
            else
                CLOUDFLARE_ONLY=false
                log_info "Cloudflare-only mode disabled - services will be accessible directly via IP"
            fi
        fi
    fi
else
    log_info "Cloudflare Tunnel setup skipped"
    CF_CONFIGURED=false
fi

###############################################################################
# PORTAINER SETUP
###############################################################################

if ask_component_install \
    "PORTAINER (Docker Management UI)" \
    "portainer" \
    "Set up Portainer for Docker container management through a web interface." \
    "What is Portainer:
• Web-based Docker management interface
• Manage containers, images, volumes, networks
• Access via HTTPS on port 9443
• Optional Agent port 8000 for remote management

Directory: $USER_HOME/docker/portainer/
Access: https://$SERVER_IP:9443 (after deployment)" \
    "$([ "$DESKTOP_MODE" = true ] && echo 'n' || echo 'y')"; then

    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Would create $USER_HOME/docker/portainer/"
        log_dry_run "Would create docker-compose.yaml for Portainer CE"
        log_dry_run "Would expose ports 8000 and 9443"
        log_dry_run "Would mount Docker socket"
        log_dry_run "Would set ownership to $ACTUAL_USER"
        log_dry_run "Would ask about Portainer Agent port (8000)"
        log_dry_run "Would add UFW rules for Portainer (9443)"
        PORTAINER_AGENT_ENABLED=false  # Set for dry-run
    else
        log_info "Setting up Portainer..."

        # Ensure parent docker directory exists with correct ownership
        if [ ! -d "$USER_HOME/docker" ]; then
            sudo mkdir -p "$USER_HOME/docker" || handle_error "Failed to create docker directory"
        fi
        # Always ensure correct ownership, even if directory existed
        sudo chown "$ACTUAL_USER:$ACTUAL_USER" "$USER_HOME/docker" || handle_error "Failed to set ownership on docker directory"

        # Create portainer directory (now parent exists with correct ownership)
        if [ ! -d "$USER_HOME/docker/portainer" ]; then
            sudo -u "$ACTUAL_USER" mkdir -p "$USER_HOME/docker/portainer" || handle_error "Failed to create portainer directory"
        fi

        # Create docker-compose.yaml for Portainer (as the actual user)
        if [ "$CLOUDFLARE_ONLY" = true ]; then
            # Cloudflare-only mode: bind to localhost only
            sudo -u "$ACTUAL_USER" cat <<'EOF' > "$USER_HOME/docker/portainer/docker-compose.yaml"
services:
  portainer:
    # NOTE: Using :lts tag. For production, consider pinning to a specific version (e.g., portainer/portainer-ce:2.19.4)
    image: portainer/portainer-ce:lts
    container_name: portainer
    ports:
      - "127.0.0.1:9443:9443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - portainer_data:/data
    restart: always

volumes:
  portainer_data:
    driver: local
EOF
            log_info "Portainer bound to 127.0.0.1 (Cloudflare-only mode)"
        else
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
        fi

        # Ensure ownership is correct
        sudo chown -R "$ACTUAL_USER:$ACTUAL_USER" "$USER_HOME/docker/portainer"
        log_info "Portainer configuration created"

        ###############################################################################
        # PORTAINER FIREWALL RULES
        ###############################################################################

        PORTAINER_AGENT_ENABLED=false

        if [ "$CLOUDFLARE_ONLY" = true ]; then
            log_info "Cloudflare-only mode: skipping Portainer UFW rules (services bound to localhost)"
        else
            log_info "Adding Portainer ports to firewall..."

            # Ask about Portainer Agent port (optional)
            echo ""
            read -p "Do you want to enable Portainer Agent port 8000? (only needed for remote management) (y/n): " enable_agent

            if [[ $enable_agent == "y" ]] || [[ $enable_agent == "Y" ]]; then
                sudo ufw allow 8000/tcp comment 'Portainer Agent' || log_warning "Failed to add Portainer port 8000"
                PORTAINER_AGENT_ENABLED=true
                log_info "Portainer Agent port 8000 enabled"
            fi

            # Always add Portainer HTTPS port
            sudo ufw allow 9443/tcp comment 'Portainer HTTPS' || log_warning "Failed to add Portainer port 9443"
            sudo ufw reload || handle_error "Failed to reload UFW"

            log_info "Portainer HTTPS port 9443 added to firewall"
        fi
    fi
else
    log_info "Portainer setup skipped"
    PORTAINER_AGENT_ENABLED=false
fi

###############################################################################
# NETDATA MONITORING SETUP
###############################################################################

if ask_component_install \
    "NETDATA REAL-TIME MONITORING" \
    "netdata" \
    "Set up Netdata for real-time server monitoring with optional Telegram alerts." \
    "What is Netdata:
• Real-time performance monitoring dashboard
• CPU, RAM, Disk, Network metrics
• Docker container monitoring
• Systemd journal log monitoring
• Optional Telegram alerts for critical issues
• Access via web dashboard on port 19999

Directory: $USER_HOME/docker/netdata/
Access: http://$SERVER_IP:19999 (after deployment)" \
    "n"; then

    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Would create $USER_HOME/docker/netdata/"
        log_dry_run "Would ask for Netdata hostname (default: $(hostname))"
        log_dry_run "Would ask about Telegram alerts configuration"
        log_dry_run "Would create .env file with NETDATA_HOSTNAME"
        log_dry_run "Would create docker-compose.yaml for Netdata"
        log_dry_run "Would configure systemd-journal plugin"
        log_dry_run "Would add UFW rule for port 19999"
        log_dry_run "Would set ownership to $ACTUAL_USER"
        NETDATA_CONFIGURED=true  # Set for dry-run
        TELEGRAM_CONFIGURED=false  # Set for dry-run
    else
    log_info "Setting up Netdata as Docker container..."

    # Ensure parent docker directory exists with correct ownership
    if [ ! -d "$USER_HOME/docker" ]; then
        sudo mkdir -p "$USER_HOME/docker" || handle_error "Failed to create docker directory"
    fi
    # Always ensure correct ownership, even if directory existed
    sudo chown "$ACTUAL_USER:$ACTUAL_USER" "$USER_HOME/docker" || handle_error "Failed to set ownership on docker directory"

    # Create netdata directory (now parent exists with correct ownership)
    if [ ! -d "$USER_HOME/docker/netdata" ]; then
        sudo -u "$ACTUAL_USER" mkdir -p "$USER_HOME/docker/netdata" || handle_error "Failed to create netdata directory"
    fi

    # Create config directory for persistent configuration
    if [ ! -d "$USER_HOME/docker/netdata/config" ]; then
        sudo -u "$ACTUAL_USER" mkdir -p "$USER_HOME/docker/netdata/config" || handle_error "Failed to create netdata config directory"
    fi

    # Ask for Netdata hostname
    echo ""
    echo "=========================================================================="
    echo "NETDATA HOSTNAME CONFIGURATION"
    echo "=========================================================================="
    echo ""
    CURRENT_HOSTNAME=$(hostname)
    echo "Current server hostname: $CURRENT_HOSTNAME"
    echo ""
    echo "Enter a hostname for Netdata (will appear in dashboard and alerts)"
    echo "Examples: production-web, vps-01, ${CURRENT_HOSTNAME}-monitor"
    echo ""
    read -p "Netdata hostname (default: $CURRENT_HOSTNAME): " NETDATA_HOSTNAME
    NETDATA_HOSTNAME=${NETDATA_HOSTNAME:-$CURRENT_HOSTNAME}
    log_info "Netdata hostname will be set to: $NETDATA_HOSTNAME"

    # Configure Telegram alerts (optional — server only)
    if [ "$DESKTOP_MODE" = true ]; then
        log_info "Desktop mode: Netdata Telegram alerts skipped"
        TELEGRAM_CONFIGURED=false
        TELEGRAM_BOT_TOKEN=""
        TELEGRAM_CHAT_ID=""
    else
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
    read -p "Do you want to configure Telegram alerts now? (y/n): " setup_telegram

    TELEGRAM_BOT_TOKEN=""
    TELEGRAM_CHAT_ID=""

    if [[ $setup_telegram == "y" ]] || [[ $setup_telegram == "Y" ]]; then
        echo ""
        echo "Note: Tokens will be visible when you type/paste them"
        echo ""
        read -p "Enter your Telegram Bot Token: " TELEGRAM_BOT_TOKEN

        # Validate bot token format (should be like: 123456789:ABCdef...)
        if [[ ! "$TELEGRAM_BOT_TOKEN" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]]; then
            log_warning "Bot token doesn't appear to be in expected format (e.g., 123456789:ABCdefGHI...)"
            read -p "Continue anyway? (y/N): " continue_token
            if [[ ! $continue_token =~ ^[Yy]$ ]]; then
                log_warning "Telegram configuration cancelled"
                TELEGRAM_CONFIGURED=false
                TELEGRAM_BOT_TOKEN=""
                TELEGRAM_CHAT_ID=""
            fi
        fi

        if [[ ! -z "$TELEGRAM_BOT_TOKEN" ]]; then
            read -p "Enter your Telegram Chat ID: " TELEGRAM_CHAT_ID

            # Validate chat ID format (should be numeric, can be negative for groups)
            if [[ ! "$TELEGRAM_CHAT_ID" =~ ^-?[0-9]+$ ]]; then
                log_warning "Chat ID doesn't appear to be numeric"
                read -p "Continue anyway? (y/N): " continue_chatid
                if [[ ! $continue_chatid =~ ^[Yy]$ ]]; then
                    log_warning "Telegram configuration cancelled"
                    TELEGRAM_CONFIGURED=false
                    TELEGRAM_BOT_TOKEN=""
                    TELEGRAM_CHAT_ID=""
                fi
            fi
        fi

        if [[ ! -z "$TELEGRAM_BOT_TOKEN" ]] && [[ ! -z "$TELEGRAM_CHAT_ID" ]]; then
            # Show preview for confirmation
            TOKEN_PREVIEW="${TELEGRAM_BOT_TOKEN:0:15}...${TELEGRAM_BOT_TOKEN: -5}"
            echo ""
            echo "Configuration preview:"
            echo "  Bot Token: $TOKEN_PREVIEW"
            echo "  Chat ID:   $TELEGRAM_CHAT_ID"
            echo ""
            read -p "Is this correct? (Y/n): " confirm_telegram
            confirm_telegram=${confirm_telegram:-y}

            if [[ $confirm_telegram =~ ^[Yy]$ ]]; then
                log_info "Telegram alerts will be configured"
                TELEGRAM_CONFIGURED=true
            else
                log_warning "Telegram configuration not confirmed"
                TELEGRAM_CONFIGURED=false
                TELEGRAM_BOT_TOKEN=""
                TELEGRAM_CHAT_ID=""
            fi
        else
            log_warning "Telegram configuration skipped - missing token or chat ID"
            TELEGRAM_CONFIGURED=false
        fi
    else
        log_info "Telegram alerts not configured"
        TELEGRAM_CONFIGURED=false
    fi
    fi  # End of desktop mode Telegram skip

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

    # Create .env file with hostname and Telegram config (secrets stored here, not in docker-compose.yaml)
    if [ "$TELEGRAM_CONFIGURED" = true ]; then
        sudo -u "$ACTUAL_USER" cat <<EOF > "$USER_HOME/docker/netdata/.env"
NETDATA_HOSTNAME=$NETDATA_HOSTNAME
TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN
TELEGRAM_CHAT_ID=$TELEGRAM_CHAT_ID
EOF
        sudo -u "$ACTUAL_USER" chmod 600 "$USER_HOME/docker/netdata/.env"
        log_info "Telegram credentials stored securely in .env file (chmod 600)"
    else
        sudo -u "$ACTUAL_USER" cat <<EOF > "$USER_HOME/docker/netdata/.env"
NETDATA_HOSTNAME=$NETDATA_HOSTNAME
EOF
    fi

    # Create docker-compose.yaml for Netdata
    if [ "$TELEGRAM_CONFIGURED" = true ]; then
        # With Telegram configuration - credentials loaded from .env file
        sudo -u "$ACTUAL_USER" cat <<'EOF' > "$USER_HOME/docker/netdata/docker-compose.yaml"
services:
  netdata:
    # NOTE: Using :latest tag. For production, consider pinning to a specific version (e.g., netdata/netdata:v1.44.1)
    image: netdata/netdata:latest
    container_name: netdata
    hostname: ${NETDATA_HOSTNAME:-netdata}
    ports:
      - "19999:19999"
    restart: always
    init: true
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
    env_file:
      - .env
    environment:
      - NETDATA_CLAIM_TOKEN=
      - NETDATA_CLAIM_ROOMS=
      - SEND_TELEGRAM=YES

volumes:
  netdatalib:
  netdatacache:
EOF
    else
        # Without Telegram - create empty config directory for future use
        log_info "Creating empty config directory for future configuration..."
        sudo -u "$ACTUAL_USER" touch "$USER_HOME/docker/netdata/config/.gitkeep"

        # Without Telegram (as the actual user)
        sudo -u "$ACTUAL_USER" cat <<EOF > "$USER_HOME/docker/netdata/docker-compose.yaml"
services:
  netdata:
    # NOTE: Using :latest tag. For production, consider pinning to a specific version (e.g., netdata/netdata:v1.44.1)
    image: netdata/netdata:latest
    container_name: netdata
    hostname: \${NETDATA_HOSTNAME:-netdata}
    ports:
      - "19999:19999"
    restart: always
    init: true
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

    # Cloudflare-only mode: bind Netdata to localhost only
    if [ "$CLOUDFLARE_ONLY" = true ]; then
        sed -i 's/"19999:19999"/"127.0.0.1:19999:19999"/' "$USER_HOME/docker/netdata/docker-compose.yaml"
        log_info "Netdata bound to 127.0.0.1 (Cloudflare-only mode)"
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

    # Add Netdata port to firewall (skip in Cloudflare-only mode)
    if [ "$CLOUDFLARE_ONLY" = true ]; then
        log_info "Cloudflare-only mode: skipping Netdata UFW rules (services bound to localhost)"
    else
        sudo ufw allow 19999/tcp comment 'Netdata Monitoring' || log_warning "Failed to add Netdata port"
        sudo ufw reload || handle_error "Failed to reload UFW"
    fi

    log_info "Netdata configuration created"
    NETDATA_CONFIGURED=true

    # Show Netdata access information
    echo ""
    echo "=========================================================================="
    echo "NETDATA CONFIGURATION COMPLETE"
    echo "=========================================================================="
    echo ""
    if [ "$CLOUDFLARE_ONLY" = true ]; then
        echo "Netdata is configured in Cloudflare-only mode (bound to localhost)."
        echo ""
        echo "To access Netdata, configure a public hostname in Cloudflare Tunnel:"
        echo ""
        echo "  1. Go to your Cloudflare Zero Trust Dashboard"
        echo "  2. Navigate to: Networks > Tunnels > [Your Tunnel] > Public Hostname"
        echo "  3. Add a new public hostname with these settings:"
        echo ""
        echo "     Subdomain:    netdata (or monitoring, stats, etc.)"
        echo "     Domain:       [your-domain.com]"
        echo "     Service Type: HTTP"
        echo "     URL:          http://localhost:19999"
        echo ""
        echo "  4. After saving, access Netdata via: https://netdata.your-domain.com"
        echo ""
        echo "  ⚠️  Netdata is NOT accessible via http://$SERVER_IP:19999 (Cloudflare-only mode)"
    else
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
    fi
    echo ""
    echo "=========================================================================="
    echo ""
    fi
else
    log_info "Netdata setup skipped"
    NETDATA_CONFIGURED=false
    TELEGRAM_CONFIGURED=false
fi

###############################################################################
# START DOCKER CONTAINERS
###############################################################################

# Skip container startup in dry-run and desktop mode
if [ "$DRY_RUN" = true ]; then
    log_dry_run "Skipping Docker container startup (dry-run mode)"
    PORTAINER_STARTED=false
    NETDATA_STARTED=false
elif [ "$DESKTOP_MODE" = true ]; then
    log_info "Desktop mode: Docker containers will not be started automatically"
    log_info "Start containers manually when needed: cd ~/docker/<service> && docker compose up -d"
    PORTAINER_STARTED=false
    NETDATA_STARTED=false
else
    echo ""
    echo "=========================================================================="
    echo "DOCKER CONTAINERS STARTUP"
    echo "=========================================================================="
    echo ""

    # Ask to start Cloudflare Tunnel
    if [ "$CF_CONFIGURED" = true ]; then
    read -p "Do you want to start Cloudflare Tunnel now? (y/n): " start_cf
    start_cf=${start_cf:-y}

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
read -p "Do you want to start Portainer now? (y/n): " start_portainer
start_portainer=${start_portainer:-y}

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
    read -p "Do you want to start Netdata now? (y/n): " start_netdata
    start_netdata=${start_netdata:-y}

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
fi  # End of dry-run check for Docker container startup

###############################################################################
# PORTAINER ACCESS INFORMATION
###############################################################################

if [ "$PORTAINER_STARTED" = true ]; then
    echo ""
    echo "=========================================================================="
    echo "PORTAINER ACCESS INFORMATION"
    echo "=========================================================================="
    echo ""
    if [ "$CLOUDFLARE_ONLY" = true ]; then
        echo "Portainer is running in Cloudflare-only mode (bound to localhost)."
        echo ""
        echo "To access Portainer, configure a public hostname in Cloudflare Tunnel:"
        echo ""
        echo "  1. Go to your Cloudflare Zero Trust Dashboard"
        echo "  2. Navigate to: Networks > Tunnels > [Your Tunnel] > Public Hostname"
        echo "  3. Add a new public hostname with these settings:"
        echo ""
        echo "     Subdomain:    portainer (or your choice)"
        echo "     Domain:       [your-domain.com]"
        echo "     Service Type: HTTPS"
        echo "     URL:          https://localhost:9443"
        echo ""
        echo "     ⚠️  Important: Enable these settings:"
        echo "         - No TLS Verify: ON (since Portainer uses self-signed cert)"
        echo ""
        echo "  4. After saving, access Portainer via: https://portainer.your-domain.com"
        echo ""
        echo "  ⚠️  Portainer is NOT accessible via https://$SERVER_IP:9443 (Cloudflare-only mode)"
    else
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
    fi
    echo ""
    echo "=========================================================================="
    echo ""
fi

###############################################################################
# DOCKER NETWORK FILTERING (DOCKER-USER) + EGRESS POLICY
###############################################################################
#
# Runs late on purpose: by this point we know whether Cloudflare-only mode is on
# and which service ports are actually in use, so the allowlist can be accurate.
#
# Why this section exists at all: Docker inserts its own DNAT and FORWARD rules
# and does NOT traverse UFW's INPUT chain. Every port published with `-p` is
# therefore reachable from the internet regardless of what `ufw status` shows.
# A container published on 0.0.0.0 is exposed even when UFW has no rule for it -
# and "I never opened that port in UFW" is not a defence. DOCKER-USER is the
# chain Docker guarantees it will consult first, so that is where the filter has
# to live.

if [ "$DRY_RUN" = true ]; then
    log_dry_run "Would offer DOCKER-USER filtering in /etc/ufw/after.rules:"
    log_dry_run "  - RETURN for established/related and private ranges"
    log_dry_run "  - RETURN for 80/tcp and 443/tcp (unless Cloudflare-only mode)"
    log_dry_run "  - DROP everything else arriving on the external interface"
    log_dry_run "Would offer an outbound (egress) allowlist:"
    log_dry_run "  - allow out 53, 123/udp, 80/tcp, 443/tcp, 22/tcp, 888/tcp, private ranges"
    log_dry_run "  - then 'ufw default deny outgoing'"
fi

if [ "$DRY_RUN" != true ] && command -v docker &>/dev/null && command -v ufw &>/dev/null; then

if skip_if_completed "DOCKER_FIREWALL"; then
    log_info "Docker firewall filtering already configured, skipping"
else
    echo ""
    echo "=========================================================================="
    echo "DOCKER NETWORK FILTERING"
    echo "=========================================================================="
    echo ""
    echo "Docker bypasses UFW. Ports published by containers are reachable from"
    echo "the internet even when UFW shows no rule for them."
    echo ""
    echo "This hands container traffic to UFW instead, so 'ufw route allow' is"
    echo "the one place a container port gets opened and 'ufw status' lists"
    echo "every open port on this machine - host and container alike."
    echo ""
    echo "Traffic that stays allowed:"
    echo "  • Established and related connections"
    echo "  • Traffic from private ranges (10/8, 172.16/12, 192.168/16)"
    echo "  • Container-to-container and host-to-container traffic"
    if [ "$CLOUDFLARE_ONLY" != true ]; then
        echo "  • External inbound on 80/tcp and 443/tcp"
    else
        echo "  • Nothing external inbound (Cloudflare-only mode)"
    fi
    echo ""
    echo "Everything else from the internet to a container port is DROPPED."
    echo ""
    echo "Open one later with:"
    echo "  sudo ufw route allow proto tcp from any to any port <port>"
    echo ""
    read -p "Apply DOCKER-USER filtering? (Y/n): " apply_docker_fw
    apply_docker_fw=${apply_docker_fw:-y}

    if [[ $apply_docker_fw =~ ^[Yy]$ ]]; then
        # Detect the interface holding the default route
        EXT_IF=$(ip -4 route show default | awk '{print $5; exit}')
        if [ -z "$EXT_IF" ]; then
            log_warning "Could not detect the external interface - skipping DOCKER-USER filtering"
        else
            log_info "External interface detected: $EXT_IF"

            # Route rules first, so ufw-user-forward is populated before the
            # chain starts consulting it.
            # || true throughout: set -e is on, and a firewall rule that fails
            # to apply should warn and carry on, not abandon the install
            # half-way through.
            if [ "$CLOUDFLARE_ONLY" != true ]; then
                if sudo ufw route allow proto tcp from any to any port 80  >/dev/null &&
                   sudo ufw route allow proto tcp from any to any port 443 >/dev/null; then
                    log_info "Added ufw route rules for 80/tcp and 443/tcp"
                else
                    log_warning "Could not add the ufw route rules for 80/443 - ports may end up closed"
                fi
            fi

            sudo cp /etc/ufw/after.rules /etc/ufw/after.rules.backup.$(date +%Y%m%d_%H%M%S)

            # Drop any block a previous run added, so this is re-runnable
            sudo sed -i '/# BEGIN SERVER-BASELINE DOCKER-USER/,/# END SERVER-BASELINE DOCKER-USER/d' /etc/ufw/after.rules

            {
                echo ""
                echo "# BEGIN SERVER-BASELINE DOCKER-USER"
                echo "# Managed by server-baseline install-script.sh - edit between the markers only."
                echo "# Docker does not traverse UFW's INPUT chain; DOCKER-USER is consulted first"
                echo "# for all container traffic. This hands that traffic to ufw-user-forward,"
                echo "# so 'ufw route allow' is the one place a container port is opened and"
                echo "# 'ufw status' shows every open port on the machine."
                echo "*filter"
                # after.rules is restored as its own pass, so a chain it jumps to
                # has to be declared here or iptables-restore rejects the whole
                # file. Declaring it does not empty it - ufw restores with
                # --noflush, which leaves an existing chain's rules alone.
                echo ":ufw-user-forward - [0:0]"
                echo ":DOCKER-USER - [0:0]"
                echo "-A DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN"
                echo "-A DOCKER-USER -s 10.0.0.0/8 -j RETURN"
                echo "-A DOCKER-USER -s 172.16.0.0/12 -j RETURN"
                echo "-A DOCKER-USER -s 192.168.0.0/16 -j RETURN"
                echo "-A DOCKER-USER -j ufw-user-forward"
                echo "-A DOCKER-USER -i $EXT_IF -j DROP"
                echo "-A DOCKER-USER -j RETURN"
                echo "COMMIT"
                echo "# END SERVER-BASELINE DOCKER-USER"
            } | sudo tee -a /etc/ufw/after.rules >/dev/null

            # `ufw reload` prints "Firewall not enabled (skipping reload)" and
            # exits 0 when ufw is disabled, and a reload that succeeds without
            # the jump appearing is not a success either. Check the result, not
            # the exit code.
            RELOAD_RC=0
            RELOAD_OUT=$(sudo ufw reload 2>&1) || RELOAD_RC=$?
            if [ "$RELOAD_RC" -ne 0 ] || printf '%s' "$RELOAD_OUT" | grep -q 'not enabled'; then
                log_warning "✗ UFW reload did not apply the rules: ${RELOAD_OUT:-no output}"
                log_warning "  A timestamped backup is in /etc/ufw/"
            elif ! sudo iptables -S DOCKER-USER 2>/dev/null | grep -q -- '-j ufw-user-forward'; then
                log_warning "✗ DOCKER-USER does not jump to ufw-user-forward"
                log_warning "  Container traffic is NOT being filtered. Check /etc/ufw/after.rules"
                log_warning "  A timestamped backup is in /etc/ufw/"
            else
                log_info "✓ Container ports now go through UFW"
                log_info "  Open one with:  sudo ufw route allow proto tcp from any to any port <port>"
                log_info "  Close one with: sudo ufw route delete allow proto tcp from any to any port <port>"
                log_info "  See them all:   sudo ufw status"
            fi
        fi
    else
        log_warning "DOCKER-USER filtering skipped - container ports remain reachable from the internet"
        log_warning "regardless of UFW rules. See the Security model section of README.md."
    fi

    ###########################################################################
    # EGRESS POLICY
    ###########################################################################
    #
    # Proxyjacking, cryptomining and data exfiltration all need outbound
    # connectivity, usually on arbitrary ports. `ufw default allow outgoing`
    # means a payload that lands on the host can dial out to anything. An
    # allowlist does not prevent the initial compromise; it removes most of the
    # value the attacker gets from it.
    echo ""
    echo "=========================================================================="
    echo "OUTBOUND (EGRESS) POLICY"
    echo "=========================================================================="
    echo ""
    echo "Default is 'allow outgoing': the server may connect anywhere, on any port."
    echo ""
    echo "Restricting egress to an allowlist keeps normal operation working while"
    echo "cutting off payloads that need arbitrary outbound ports."
    echo ""
    echo "Would be allowed outbound:"
    echo "  • DNS (53), NTP (123)"
    echo "  • HTTP (80) and HTTPS (443)  - apt, Docker registries, Cloudflare"
    echo "  • SSH (22, 888)              - git, backups, remote administration"
    echo "  • Traffic to private ranges"
    echo ""
    echo "⚠️  Anything else outbound is denied, including mail (25/587), and any"
    echo "    service you run that dials a non-standard port. Add rules for those."
    echo ""
    echo "    Undo at any time with:  sudo ufw default allow outgoing"
    echo ""
    read -p "Restrict outbound traffic to the allowlist? (y/N): " apply_egress
    apply_egress=${apply_egress:-n}

    if [[ $apply_egress =~ ^[Yy]$ ]]; then
        log_info "Applying egress allowlist..."

        sudo ufw allow out 53 comment 'DNS' || log_warning "Failed to allow outbound DNS"
        sudo ufw allow out 123/udp comment 'NTP' || log_warning "Failed to allow outbound NTP"
        sudo ufw allow out 80/tcp comment 'HTTP (apt, registries)' || log_warning "Failed to allow outbound HTTP"
        sudo ufw allow out 443/tcp comment 'HTTPS (apt, registries, Cloudflare)' || log_warning "Failed to allow outbound HTTPS"
        sudo ufw allow out 22/tcp comment 'SSH out (git, backups)' || log_warning "Failed to allow outbound SSH 22"
        sudo ufw allow out 888/tcp comment 'SSH out (backups)' || log_warning "Failed to allow outbound SSH 888"
        sudo ufw allow out to 10.0.0.0/8 comment 'Private range' || true
        sudo ufw allow out to 172.16.0.0/12 comment 'Private range' || true
        sudo ufw allow out to 192.168.0.0/16 comment 'Private range' || true

        sudo ufw default deny outgoing || handle_error "Failed to set default deny outgoing"
        sudo ufw reload || log_warning "Failed to reload UFW"

        log_info "✓ Egress restricted to the allowlist"
        log_warning "Note: this governs traffic originating on the HOST. Container traffic"
        log_warning "is forwarded, not output, so it is not covered by this policy."
        log_warning "Restrict container egress with per-network rules or an egress proxy."
    else
        log_info "Egress policy left at 'allow outgoing'"
    fi

    mark_completed "DOCKER_FIREWALL"
fi

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
    desktop_flag=""
    if [ "$DESKTOP_MODE" = true ]; then
        desktop_flag=" --desktop"
    fi
    if [ "$MODE" = "interactive" ]; then
        echo "  sudo bash $0 --interactive$desktop_flag"
    else
        echo "  sudo bash $0 --fresh-install$desktop_flag"
    fi
    echo ""
    echo "Or run without dry-run:"
    if [ "$DESKTOP_MODE" = true ]; then
        echo "  sudo bash $0 --interactive --desktop   # For existing desktops (recommended)"
        echo "  sudo bash $0 --fresh-install --desktop  # For fresh desktop installations"
    else
        echo "  sudo bash $0 --interactive   # For existing servers (recommended)"
        echo "  sudo bash $0 --fresh-install # For fresh installations"
    fi
    echo ""
    echo "=========================================================================="
    exit 0
fi

###############################################################################
# FINAL CHECKS AND SUMMARY
###############################################################################

echo ""
echo "=========================================================================="
if [ "$DESKTOP_MODE" = true ]; then
    log_info "Desktop setup completed successfully!"
else
    log_info "Server setup completed successfully!"
fi
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
if [ "$DESKTOP_MODE" = true ]; then
echo "  - Swap: ${SWAP_SIZE}MB (swappiness=60)"
else
echo "  - Swap: ${SWAP_SIZE}MB (swappiness=10)"
fi
echo ""
echo "Security features:"
if [ "$DESKTOP_MODE" = true ]; then
    if [ "$SSH_HARDENED" = true ]; then
        echo "  - SSH: Port 22 (password + key authentication)"
    else
        echo "  - SSH: Not hardened (skipped)"
    fi
    echo "  - Firewall: UFW enabled (port 22/SSH only)"
else
    if [ "$SSH_HARDENED" = true ]; then
        echo "  - SSH: Ports 22 AND 888 (key-only authentication)"
        echo "    ⚠️  REMEMBER: Test port 888 and manually disable port 22!"
    else
        echo "  - SSH: Not hardened (skipped)"
    fi
    if [ "$CLOUDFLARE_ONLY" = true ]; then
        UFW_PORTS="22, 888 (SSH only)"
        echo "  - Firewall: UFW enabled (ports $UFW_PORTS) - Cloudflare-only mode"
        echo "  - Cloudflare-only: All services bound to 127.0.0.1 (localhost)"
    else
        UFW_PORTS="22, 80, 443, 888, 9443"
        if [ "${PORTAINER_AGENT_ENABLED:-false}" = true ]; then
            UFW_PORTS="$UFW_PORTS, 8000"
        fi
        if [ "${NETDATA_CONFIGURED:-false}" = true ]; then
            UFW_PORTS="$UFW_PORTS, 19999"
        fi
        echo "  - Firewall: UFW enabled (ports $UFW_PORTS)"
    fi
    echo "  - Fail2ban: Enabled for SSH (monitoring ports 22 and 888)"
fi
echo "  - Automatic updates: Enabled"
echo "  - Kernel hardening: Applied"
echo ""
echo "Monitoring tools installed:"
echo "  - htop, atop, iotop, nethogs"
echo "  - smartmontools, nvme-cli (disk health)"
if [ "$NETDATA_CONFIGURED" = true ]; then
if [ "$CLOUDFLARE_ONLY" = true ]; then
echo "  - Netdata Docker container (via Cloudflare Tunnel - localhost:19999)"
else
echo "  - Netdata Docker container (http://$SERVER_IP:19999)"
fi
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
if [ "$DESKTOP_MODE" = true ]; then
    echo "  ✅ Docker installed (no containers started in desktop mode)"
    echo "  Start containers manually: cd ~/docker/<service> && docker compose up -d"
else
    if [ "${CF_CONFIGURED:-false}" = true ]; then
        echo "  ✅ Cloudflare Tunnel (~/docker/cloudflare)"
        if [ "$CLOUDFLARE_ONLY" = true ]; then
            echo "     🔒 Cloudflare-only mode: all services routed through tunnel"
        fi
    else
        echo "  ⏭️  Cloudflare Tunnel (skipped)"
    fi
    if [ "$CLOUDFLARE_ONLY" = true ]; then
        echo "  ✅ Portainer (~/docker/portainer) - localhost:9443 via Cloudflare"
    else
        echo "  ✅ Portainer (~/docker/portainer)"
    fi
    if [ "${NETDATA_CONFIGURED:-false}" = true ]; then
        if [ "$CLOUDFLARE_ONLY" = true ]; then
            echo "  ✅ Netdata (~/docker/netdata) - localhost:19999 via Cloudflare"
        else
            echo "  ✅ Netdata (~/docker/netdata)"
        fi
    fi
fi
echo ""
if [ "$DESKTOP_MODE" != true ]; then
    echo "Container status:"
    if [ "${CF_CONFIGURED:-false}" = true ] && docker ps --format '{{.Names}}' 2>/dev/null | grep -q cloudflared; then
        echo "  🟢 Cloudflare Tunnel: Running"
    elif [ "${CF_CONFIGURED:-false}" = true ]; then
        echo "  ⚪ Cloudflare Tunnel: Not started"
    fi
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q portainer; then
        echo "  🟢 Portainer: Running"
    else
        echo "  ⚪ Portainer: Not started"
    fi
    if [ "${NETDATA_CONFIGURED:-false}" = true ]; then
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q netdata; then
            echo "  🟢 Netdata: Running"
        else
            echo "  ⚪ Netdata: Not started"
        fi
    fi
    echo ""
fi
echo "IMPORTANT NOTES:"
if [ "$DESKTOP_MODE" = true ]; then
    if [ "$SSH_HARDENED" = true ]; then
        echo "  1. SSH: Port 22 with password authentication enabled"
        echo "  2. Consider setting up SSH keys for additional security"
    else
        echo "  1. SSH hardening was skipped"
        echo "  2. Consider running SSH hardening for additional security"
    fi
    echo "  3. Docker installed but no containers started (start manually when needed)"
    echo "  4. User '$ACTUAL_USER' has been added to docker group"
    echo "  5. Log out and back in for docker group to take effect"
else
    if [ "$SSH_HARDENED" = true ]; then
        echo "  1. ⚠️  SSH: Currently on BOTH port 22 AND 888"
        echo ""
        echo "     ┌──────────────────────────────────────────────────────────┐"
        echo "     │ DO NOT CLOSE THIS TERMINAL until 888 is proven to work.  │"
        echo "     │ It is your only way back in if something is wrong.       │"
        echo "     └──────────────────────────────────────────────────────────┘"
        echo ""
        echo "     a) Open a SECOND terminal (leave this one open):"
        echo "          ssh -p 888 $ACTUAL_USER@$SERVER_IP"
        echo ""
        echo "     b) Only if that works, run IN THAT SECOND SESSION:"
        if [ "${SSH_SOCKET_ACTIVATED:-false}" = true ]; then
            echo "          # This host uses socket activation - the port lives in"
            echo "          # ssh.socket, NOT in sshd_config. Editing sshd_config does nothing."
            echo "          sudo sed -i '/:22\$/d' /etc/systemd/system/ssh.socket.d/ports.conf"
            echo "          sudo systemctl daemon-reload && sudo systemctl restart ssh.socket"
        else
            echo "          sudo sed -i '/^Port 22\$/d' /etc/ssh/sshd_config"
            echo "          sudo systemctl restart ssh"
        fi
        echo "          sudo ufw delete allow 22/tcp"
        echo ""
        echo "     Confirm it is really gone:  sudo ss -tlnp | grep ':22 '"
        echo ""
        echo "     c) Open a THIRD terminal, confirm 888 still works,"
        echo "        and only then close this one."
        echo ""
        echo "     If (a) fails, change nothing - you still have this session."
        echo "     Check: sudo ss -tlnp | grep 888   and   sudo ufw status"
        echo "     On a VPS, also check the provider firewall (it sits above UFW)."
        echo ""
        echo "  2. Password authentication is DISABLED"
        echo "  3. Make sure your SSH key is authorized before disconnecting!"
    else
        echo "  1. SSH hardening was skipped"
        echo "  2. ⚠️  Consider running SSH hardening manually for security!"
    fi
    echo "  4. User '$ACTUAL_USER' has been added to docker group"
    echo "  5. Log out and back in for docker group to take effect"
fi
echo ""
if [ "$DESKTOP_MODE" != true ]; then
    echo "Quick access URLs:"
    if [ "$CLOUDFLARE_ONLY" = true ]; then
        echo "  ⚠️  Cloudflare-only mode: configure public hostnames in Cloudflare Dashboard"
        echo "  - Portainer: https://portainer.your-domain.com (configure in Cloudflare → localhost:9443)"
        if [ "${NETDATA_CONFIGURED:-false}" = true ]; then
            echo "  - Netdata:   https://netdata.your-domain.com (configure in Cloudflare → localhost:19999)"
        fi
    else
        if [ "${PORTAINER_STARTED:-false}" = true ]; then
            echo "  - Portainer: https://$SERVER_IP:9443"
        fi
        if [ "${NETDATA_STARTED:-false}" = true ]; then
            echo "  - Netdata: http://$SERVER_IP:19999"
        fi
    fi
fi
echo ""
echo "Error log saved to: $ERROR_LOG"
echo ""

# Run Lynis security audit if installed (show final hardening score)
if command -v lynis >/dev/null 2>&1; then
    echo ""
    echo "=========================================================================="
    echo "LYNIS SECURITY AUDIT (Optional)"
    echo "=========================================================================="
    echo ""
    echo "Lynis can run a security scan to verify hardening improvements."
    echo -e "${YELLOW}Note: This scan can take 5-15 minutes on limited CPU systems.${NC}"
    echo ""
    read -p "Run Lynis security audit now? (y/N): " run_lynis
    run_lynis=${run_lynis:-n}

    if [[ $run_lynis =~ ^[Yy]$ ]]; then
        echo ""
        echo "Running Lynis security scan (this may take a while)..."
        echo ""

        # Run quick Lynis audit
        sudo lynis audit system --quick --no-colors 2>/dev/null | tail -50 || true

        echo ""

        # Extract and display hardening index if available
        if [ -f /var/log/lynis-report.dat ]; then
            HARDENING_INDEX=$(grep "hardening_index=" /var/log/lynis-report.dat 2>/dev/null | cut -d'=' -f2)
            SUGGESTION_COUNT=$(grep -c "suggestion\[\]=" /var/log/lynis-report.dat 2>/dev/null || echo "0")
            WARNING_COUNT=$(grep -c "warning\[\]=" /var/log/lynis-report.dat 2>/dev/null || echo "0")

            if [ ! -z "$HARDENING_INDEX" ]; then
                echo "══════════════════════════════════════════════════════════"
                echo "Lynis Security Hardening Results:"
                echo "══════════════════════════════════════════════════════════"
                echo "  Hardening Index: $HARDENING_INDEX/100"
                echo "  Warnings: $WARNING_COUNT"
                echo "  Suggestions: $SUGGESTION_COUNT"
                echo ""

                # Display top 10 suggestions if any exist
                if [ "$SUGGESTION_COUNT" -gt 0 ]; then
                    echo "Top 10 Hardening Suggestions:"
                    echo "──────────────────────────────────────────────────────────"
                    grep "suggestion\[\]=" /var/log/lynis-report.dat 2>/dev/null | \
                        cut -d'=' -f2- | \
                        head -10 | \
                        nl -w2 -s'. ' || echo "  (No suggestions available)"
                    echo ""

                    if [ "$SUGGESTION_COUNT" -gt 10 ]; then
                        echo "  ... and $((SUGGESTION_COUNT - 10)) more suggestions"
                        echo ""
                    fi
                fi

                echo "Full report: /var/log/lynis-report.dat"
                echo "View all suggestions:"
                echo "  grep 'suggestion\\[\\]=' /var/log/lynis-report.dat | cut -d'=' -f2-"
                echo ""
                echo "View report: sudo lynis show details <TEST-ID>"
                echo "══════════════════════════════════════════════════════════"
            fi
        fi

        echo ""
    else
        echo ""
        echo "Lynis audit skipped. You can run it manually later with:"
        echo "  sudo lynis audit system --quick"
        echo ""
    fi
fi

# Run Rkhunter rootkit scan if installed (optional)
if command -v rkhunter >/dev/null 2>&1; then
    echo ""
    echo "=========================================================================="
    echo "RKHUNTER ROOTKIT SCAN (Optional)"
    echo "=========================================================================="
    echo ""
    echo "Rkhunter can scan for rootkits, backdoors, and local exploits."
    echo -e "${YELLOW}Note: This scan can take 5-10 minutes on limited CPU systems.${NC}"
    echo ""
    read -p "Run Rkhunter rootkit scan now? (y/N): " run_rkhunter
    run_rkhunter=${run_rkhunter:-n}

    if [[ $run_rkhunter =~ ^[Yy]$ ]]; then
        echo ""
        echo "Running Rkhunter scan (this may take a while)..."
        echo ""

        # Update rkhunter database first
        sudo rkhunter --update --nocolors 2>/dev/null || true

        # Run rkhunter scan
        sudo rkhunter --check --skip-keypress --nocolors 2>/dev/null || true

        echo ""
        echo "══════════════════════════════════════════════════════════"
        echo "Rkhunter Scan Complete"
        echo "══════════════════════════════════════════════════════════"
        echo "Full log: /var/log/rkhunter.log"
        echo ""
        echo "View warnings only:"
        echo "  sudo grep -i warning /var/log/rkhunter.log"
        echo "══════════════════════════════════════════════════════════"
        echo ""
    else
        echo ""
        echo "Rkhunter scan skipped. You can run it manually later with:"
        echo "  sudo rkhunter --check --skip-keypress"
        echo ""
    fi
fi

echo "=========================================================================="

# Ask for reboot
echo ""
read -p "System setup complete. Reboot now? (y/n): " reboot_choice
reboot_choice=${reboot_choice:-n}

if [[ $reboot_choice == "y" ]] || [[ $reboot_choice == "Y" ]]; then
    log_info "Rebooting system in 5 seconds... (Ctrl+C to cancel)"
    sleep 5
    sudo shutdown -r now
else
    log_info "Remember to reboot the system later to apply all changes!"
fi
