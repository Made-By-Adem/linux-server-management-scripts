#!/bin/bash

###############################################################################
# Docker Container Update Script
# Version: 2.0
# Purpose: Safely update Docker containers with user-friendly interface
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
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

# Unicode characters for visual feedback
CHECK_MARK="✓"
CROSS_MARK="✗"
ARROW="→"
BULLET="•"

# Script modes
MODE=""  # Will be set to: interactive or unattended
UPDATE_SYSTEM=false
DRY_RUN=false

# Log files
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_DIR="/var/log/docker-updates"
LOG_FILE="$LOG_DIR/update_$TIMESTAMP.log"
DRY_RUN_REPORT="/tmp/docker-update-dryrun-$TIMESTAMP.txt"

# Results tracking
declare -A UPDATE_SUCCESS
declare -A UPDATE_FAILED
declare -A UPDATE_SKIPPED

# System update flag
SYSTEM_UPDATED=false

###############################################################################
# Helper Functions
###############################################################################

# Function to show usage
show_usage() {
    cat <<EOF
Usage: sudo bash $0 [MODE] [OPTIONS]

Modes:
  --interactive      Interactive mode - select containers manually
  --unattended       Unattended mode - update all containers automatically
  --dry-run          Show what would be done without making changes

Options:
  --update-system    Update system packages before container updates
  --help, -h         Show this help message

Examples:
  sudo bash $0 --interactive                # Interactive mode
  sudo bash $0 --unattended                 # Update all containers automatically
  sudo bash $0 --dry-run                    # Show what would be updated
  sudo bash $0 --interactive --dry-run      # Interactive dry-run
  sudo bash $0 --unattended --update-system # Update system + all containers
  sudo bash $0 --interactive --update-system # Update system + choose containers

Notes:
  - If no mode is specified, help will be shown
  - Use --dry-run to preview changes without executing them
  - Use --unattended mode for cron jobs and automation
  - Always run with sudo for proper permissions
EOF
    exit 0
}

# Function to parse command-line arguments
parse_arguments() {
    # Show help if no arguments
    if [ $# -eq 0 ]; then
        echo -e "${YELLOW}No mode specified.${NC}"
        echo ""
        show_usage
    fi

    while [[ $# -gt 0 ]]; do
        case $1 in
            --interactive)
                MODE="interactive"
                shift
                ;;
            --unattended)
                MODE="unattended"
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --update-system)
                UPDATE_SYSTEM=true
                shift
                ;;
            --help|-h)
                show_usage
                ;;
            *)
                echo -e "${RED}Unknown option: $1${NC}" >&2
                echo "" >&2
                echo "Run '$0 --help' for usage information" >&2
                exit 1
                ;;
        esac
    done

    # Show help if no mode specified (only --update-system was given)
    if [ -z "$MODE" ] && [ "$DRY_RUN" = false ]; then
        echo -e "${YELLOW}No mode specified.${NC}"
        echo ""
        show_usage
    fi

    # Default to interactive if only --dry-run is specified
    if [ -z "$MODE" ] && [ "$DRY_RUN" = true ]; then
        MODE="interactive"
    fi
}

# Function to log info
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE" 2>/dev/null || true
}

# Function to log warning
log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
    echo "[WARNING] $(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE" 2>/dev/null || true
}

# Function to log dry-run actions
log_dry_run() {
    echo -e "${CYAN}[DRY-RUN]${NC} $1"
    echo "[DRY-RUN] $1" >> "$DRY_RUN_REPORT" 2>/dev/null || true
}

# Function to log error
log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
    echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE" 2>/dev/null || true
}

# Function to log success
log_success() {
    echo -e "${GREEN}${CHECK_MARK}${NC} $1"
    echo "[SUCCESS] $(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE" 2>/dev/null || true
}

# Function for section headers
print_header() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
}

# Function for sub-headers
print_subheader() {
    echo ""
    echo -e "${BLUE}───────────────────────────────────────────────────────────────${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}───────────────────────────────────────────────────────────────${NC}"
    echo ""
}

# Function to check if script is run as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        echo ""
        echo "Run: sudo $0 $*"
        echo "Or:  sudo $0 --help for usage information"
        exit 1
    fi
}

# Function to check Docker
check_docker() {
    if ! command -v docker &> /dev/null; then
        log_error "Docker is not installed!"
        exit 1
    fi

    if ! docker info &> /dev/null; then
        log_error "Docker daemon is not running!"
        exit 1
    fi
}

# Function to create log directory
setup_logging() {
    mkdir -p "$LOG_DIR"
    touch "$LOG_FILE"
    log_info "Logging started: $LOG_FILE"
}

# Function to create symlink in scripts directory
create_symlink() {
    local script_path="$(realpath "$0")"
    local script_dir="$(dirname "$script_path")"
    local symlink_name="update-containers"

    # Only create symlink if script is in /home/scripts or ~/scripts
    if [[ "$script_dir" =~ ^/home/[^/]+/scripts$ ]] || [[ "$script_dir" == "/home/scripts" ]]; then
        # Check if symlink already exists and points to this script
        if [ -L "$script_dir/$symlink_name" ]; then
            local current_target="$(readlink -f "$script_dir/$symlink_name")"
            if [ "$current_target" = "$script_path" ]; then
                # Symlink already exists and is correct
                return 0
            fi
        fi

        # Create or update symlink
        ln -sf "$script_path" "$script_dir/$symlink_name" 2>/dev/null || true

        # Verify symlink was created successfully
        if [ -L "$script_dir/$symlink_name" ]; then
            log_info "Created symlink: $script_dir/$symlink_name -> $script_path"
        fi
    fi
}

###############################################################################
# System Update Functions
###############################################################################

# Function to perform system update
perform_system_update() {
    print_header "System Package Update"

    # DRY-RUN MODE: Show what would be done and which packages would be upgraded
    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Would update package lists: apt-get update"
        log_dry_run "Checking for upgradeable packages (based on current cache)..."
        log_dry_run "Note: Package list may be stale if apt-get update hasn't been run recently"

        local upgradable=$(apt list --upgradable 2>/dev/null | grep -v "Listing" | wc -l)
        if [ "$upgradable" -gt 0 ]; then
            log_dry_run "Found $upgradable packages that would be upgraded:"
            apt list --upgradable 2>/dev/null | grep -v "Listing" | while read line; do
                log_dry_run "  - $line"
            done
        else
            log_dry_run "No packages need upgrading (based on current cache)"
        fi

        log_dry_run "Would upgrade packages: apt-get upgrade -y"
        log_dry_run "Would clean up: apt-get autoremove -y"
        SYSTEM_UPDATED=true
        return 0
    fi

    # ACTUAL SYSTEM UPDATE (not dry-run)
    log_info "Running system package update..."
    log_info "${ARROW} Updating package lists..."

    if ! DEBIAN_FRONTEND=noninteractive apt-get update 2>&1 | tee -a "$LOG_FILE"; then
        log_error "Failed to update package lists"
        return 1
    fi
    log_success "Package lists updated"

    log_info "${ARROW} Upgrading packages..."
    if ! DEBIAN_FRONTEND=noninteractive apt-get upgrade -y 2>&1 | tee -a "$LOG_FILE"; then
        log_error "Failed to upgrade packages"
        return 1
    fi
    log_success "Packages upgraded"

    log_info "${ARROW} Cleaning up..."
    DEBIAN_FRONTEND=noninteractive apt-get autoremove -y >> "$LOG_FILE" 2>&1 || true
    log_success "System update complete"

    SYSTEM_UPDATED=true
    return 0
}

# Function to ask if user wants to update system (interactive mode only)
ask_system_update() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  System Package Update${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "Do you want to update system packages before updating containers?"
    echo ""
    echo -e "${YELLOW}This will run:${NC}"
    echo "  • sudo apt-get update"
    echo "  • sudo apt-get upgrade -y"
    echo "  • sudo apt-get autoremove -y"
    echo ""
    echo -e "${BLUE}Recommended:${NC} Yes - ensures latest security patches"
    echo -e "${YELLOW}Note:${NC} This may take several minutes"
    echo ""

    read -p "Update system packages? (y/n): " update_system

    if [[ "$update_system" =~ ^[Yy]$ ]]; then
        if perform_system_update; then
            echo ""
            log_success "System update completed successfully"
            echo ""
            read -p "Press Enter to continue with container updates..."
        else
            echo ""
            log_warning "System update failed, but continuing with container updates"
            echo ""
            read -p "Press Enter to continue..."
        fi
    else
        log_info "System update skipped"
    fi
}

###############################################################################
# Container Discovery
###############################################################################

# Function to get all Docker containers
get_containers() {
    docker ps --format "{{.Names}}" | sort
}

# Function to get container info
get_container_info() {
    local container=$1
    local image=$(docker inspect --format='{{.Config.Image}}' "$container" 2>/dev/null || echo "Unknown")
    local status=$(docker inspect --format='{{.State.Status}}' "$container" 2>/dev/null || echo "Unknown")
    local created=$(docker inspect --format='{{.Created}}' "$container" 2>/dev/null | cut -d'T' -f1 || echo "Unknown")

    echo "$image|$status|$created"
}

# Function to find compose directory for a container
find_compose_dir() {
    local container=$1

    # Search in standard docker directories
    local common_dirs=(
        "$HOME/docker"
        "/home/*/docker"
        "/opt/docker"
        "/srv/docker"
    )

    for base_dir in "${common_dirs[@]}"; do
        for dir in $base_dir/*/; do
            if [ -f "$dir/docker-compose.yml" ] || [ -f "$dir/docker-compose.yaml" ]; then
                # Check if this compose file contains this container
                if grep -q "$container" "$dir/docker-compose.yml" 2>/dev/null || \
                   grep -q "$container" "$dir/docker-compose.yaml" 2>/dev/null; then
                    echo "$dir"
                    return 0
                fi
            fi
        done
    done

    # Try via container labels
    local project_dir=$(docker inspect --format='{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$container" 2>/dev/null)
    if [ -n "$project_dir" ] && [ "$project_dir" != "<no value>" ]; then
        echo "$project_dir"
        return 0
    fi

    return 1
}

###############################################################################
# Container Selection
###############################################################################

# Function to let user select containers (interactive mode)
select_containers() {
    local containers=()
    mapfile -t containers < <(get_containers)

    if [ ${#containers[@]} -eq 0 ]; then
        log_error "No running containers found!"
        exit 1
    fi

    # All UI output goes to stderr so it doesn't get captured
    print_header "Available Docker Containers" >&2

    echo -e "${CYAN}No.  Container Name${NC}                    ${CYAN}Image${NC}                              ${CYAN}Status${NC}    ${CYAN}Created${NC}" >&2
    echo "─────────────────────────────────────────────────────────────────────────────────────────────" >&2

    local index=1
    for container in "${containers[@]}"; do
        IFS='|' read -r image status created <<< "$(get_container_info "$container")"
        printf "${YELLOW}%-4s${NC} %-30s %-35s %-10s %s\n" "[$index]" "$container" "$image" "$status" "$created" >&2
        ((index++))
    done

    echo "" >&2
    echo -e "${MAGENTA}${BULLET}${NC} Enter numbers separated by spaces (e.g., 1 3 5)" >&2
    echo -e "${MAGENTA}${BULLET}${NC} Enter 'all' to select all containers" >&2
    echo -e "${MAGENTA}${BULLET}${NC} Enter 'q' to quit" >&2
    echo "" >&2

    read -p "Selection: " selection </dev/tty

    if [[ "$selection" == "q" ]]; then
        log_info "Update cancelled by user" >&2
        exit 0
    fi

    local selected_containers=()

    if [[ "$selection" == "all" ]]; then
        selected_containers=("${containers[@]}")
    else
        for num in $selection; do
            if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le ${#containers[@]} ]; then
                selected_containers+=("${containers[$((num-1))]}")
            else
                log_warning "Invalid selection: $num (skipped)" >&2
            fi
        done
    fi

    if [ ${#selected_containers[@]} -eq 0 ]; then
        log_error "No valid containers selected!" >&2
        exit 1
    fi

    # Only the selected containers go to stdout
    echo "${selected_containers[@]}"
}

# Function to get all containers (unattended mode)
get_all_containers() {
    local containers=()
    mapfile -t containers < <(get_containers)

    if [ ${#containers[@]} -eq 0 ]; then
        log_error "No running containers found!" >&2
        exit 1
    fi

    log_info "Found ${#containers[@]} running containers" >&2
    # Only the container names go to stdout
    echo "${containers[@]}"
}

###############################################################################
# Container Update Functions
###############################################################################

# Function to update a single container
update_container() {
    local container=$1
    local compose_dir=$2

    print_subheader "Container: $container"

    log_info "Searching for compose directory..."

    if [ -z "$compose_dir" ]; then
        log_error "No docker-compose directory found for $container"
        UPDATE_FAILED["$container"]="No compose directory found"
        return 1
    fi

    log_info "Compose directory: $compose_dir"

    # Determine compose file name
    local compose_file=""
    if [ -f "$compose_dir/docker-compose.yml" ]; then
        compose_file="docker-compose.yml"
    elif [ -f "$compose_dir/docker-compose.yaml" ]; then
        compose_file="docker-compose.yaml"
    else
        log_error "No docker-compose.yml found in $compose_dir"
        UPDATE_FAILED["$container"]="No compose file found"
        return 1
    fi

    log_info "Compose file: $compose_file"

    # Step 1: Get current image
    log_info "${ARROW} Getting current image info..."
    local old_image=$(docker inspect --format='{{.Config.Image}}' "$container" 2>/dev/null || echo "Unknown")
    local old_image_id=$(docker inspect --format='{{.Image}}' "$container" 2>/dev/null || echo "Unknown")

    # DRY-RUN MODE: Just show what would be done
    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Would stop container: docker compose down"
        log_dry_run "Would remove old image: $old_image_id"
        log_dry_run "Would pull new image: docker compose pull"
        log_dry_run "Would start container: docker compose up -d"
        log_dry_run "Would verify container is running"
        UPDATE_SUCCESS["$container"]="[DRY-RUN] Would update from $old_image"
        return 0
    fi

    # ACTUAL UPDATE PROCESS (not dry-run)
    # Step 2: Docker Compose Down
    log_info "${ARROW} Stopping container..."
    if ! (cd "$compose_dir" && docker compose -f "$compose_file" down 2>&1 | tee -a "$LOG_FILE"); then
        log_error "Failed to stop container"
        UPDATE_FAILED["$container"]="Stop failed"
        return 1
    fi
    log_success "Container stopped"

    # Step 3: Remove old image
    log_info "${ARROW} Removing old image..."
    if [ "$old_image_id" != "Unknown" ]; then
        if docker rmi "$old_image_id" 2>&1 | tee -a "$LOG_FILE"; then
            log_success "Old image removed"
        else
            log_warning "Could not remove old image (possibly used by other containers)"
        fi
    fi

    # Step 4: Pull new image
    log_info "${ARROW} Downloading new image..."
    if ! (cd "$compose_dir" && docker compose -f "$compose_file" pull 2>&1 | tee -a "$LOG_FILE"); then
        log_error "Failed to download new image"
        UPDATE_FAILED["$container"]="Download failed"

        # Try to restart container with old image
        log_warning "Attempting to restart container..."
        (cd "$compose_dir" && docker compose -f "$compose_file" up -d 2>&1 | tee -a "$LOG_FILE") || true
        return 1
    fi
    log_success "New image downloaded"

    # Step 5: Start container (docker compose up -d will only start previously running containers)
    log_info "${ARROW} Starting container..."
    if ! (cd "$compose_dir" && docker compose -f "$compose_file" up -d 2>&1 | tee -a "$LOG_FILE"); then
        log_error "Failed to start container"
        UPDATE_FAILED["$container"]="Start failed"
        return 1
    fi
    log_success "Container started"

    # Step 6: Verify
    log_info "${ARROW} Verifying container status..."
    sleep 3  # Give container time to start

    if docker ps --filter "name=$container" --format '{{.Names}}' | grep -q "^${container}$"; then
        local new_image=$(docker inspect --format='{{.Config.Image}}' "$container" 2>/dev/null || echo "Unknown")
        log_success "Container running successfully"
        log_info "Old image: $old_image"
        log_info "New image: $new_image"
        UPDATE_SUCCESS["$container"]="$old_image → $new_image"
        return 0
    else
        log_error "Container not active after update!"
        UPDATE_FAILED["$container"]="Not active after update"
        return 1
    fi
}

###############################################################################
# Main Update Process
###############################################################################

# Function to update selected containers
update_selected_containers() {
    local containers=("$@")

    print_header "Starting Updates"

    log_info "Number of containers to update: ${#containers[@]}"

    # Find compose directories for all containers
    declare -A compose_dirs

    for container in "${containers[@]}"; do
        log_info "Finding compose directory for: $container"
        compose_dir=$(find_compose_dir "$container") || compose_dir=""
        compose_dirs["$container"]=$compose_dir
    done

    # Show summary and ask for confirmation (interactive mode only)
    if [ "$MODE" = "interactive" ]; then
        echo ""
        echo -e "${YELLOW}The following containers will be updated:${NC}"
        for container in "${containers[@]}"; do
            echo -e "  ${BULLET} $container ${CYAN}(${compose_dirs[$container]:-Not found})${NC}"
        done
        echo ""

        read -p "Proceed with update? (yes/no): " confirm

        if [[ ! "$confirm" =~ ^(yes|y)$ ]]; then
            log_info "Update cancelled by user"
            exit 0
        fi
    else
        # Unattended mode - just show what will be updated
        log_info "Updating containers:"
        for container in "${containers[@]}"; do
            log_info "  - $container (${compose_dirs[$container]:-Not found})"
        done
    fi

    # Update each container
    for container in "${containers[@]}"; do
        update_container "$container" "${compose_dirs[$container]}"
        echo ""
    done
}

###############################################################################
# Report Generation
###############################################################################

# Function to show final report
show_summary() {
    print_header "Update Summary"

    # Count arrays safely (handle unset arrays with set -u)
    local success_count=0
    local failed_count=0
    local skipped_count=0

    # Check if arrays have elements
    if [ -n "${UPDATE_SUCCESS[*]+x}" ]; then
        success_count=${#UPDATE_SUCCESS[@]}
    fi
    if [ -n "${UPDATE_FAILED[*]+x}" ]; then
        failed_count=${#UPDATE_FAILED[@]}
    fi
    if [ -n "${UPDATE_SKIPPED[*]+x}" ]; then
        skipped_count=${#UPDATE_SKIPPED[@]}
    fi

    local total=$((success_count + failed_count + skipped_count))

    echo -e "${CYAN}Total containers:${NC} $total"
    echo ""

    # System update status
    if [ "$SYSTEM_UPDATED" = true ]; then
        echo -e "${GREEN}${CHECK_MARK} System packages updated${NC}"
        echo ""
    fi

    # Successful updates
    if [ $success_count -gt 0 ]; then
        echo -e "${GREEN}${CHECK_MARK} Successfully updated: $success_count${NC}"
        for container in "${!UPDATE_SUCCESS[@]}"; do
            echo -e "  ${GREEN}${BULLET}${NC} $container"
            echo -e "    ${UPDATE_SUCCESS[$container]}"
        done
        echo ""
    fi

    # Failed updates
    if [ $failed_count -gt 0 ]; then
        echo -e "${RED}${CROSS_MARK} Failed: $failed_count${NC}"
        for container in "${!UPDATE_FAILED[@]}"; do
            echo -e "  ${RED}${BULLET}${NC} $container"
            echo -e "    Reason: ${UPDATE_FAILED[$container]}"
        done
        echo ""
    fi

    # Skipped containers
    if [ $skipped_count -gt 0 ]; then
        echo -e "${YELLOW}${ARROW} Skipped: $skipped_count${NC}"
        for container in "${!UPDATE_SKIPPED[@]}"; do
            echo -e "  ${YELLOW}${BULLET}${NC} $container"
            echo -e "    Reason: ${UPDATE_SKIPPED[$container]}"
        done
        echo ""
    fi

    # Current status of all containers
    print_subheader "Current Container Status"

    docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Image}}" | head -20

    echo ""
    if [ "$DRY_RUN" = true ]; then
        echo -e "${CYAN}Dry-run report available at:${NC} $DRY_RUN_REPORT"
        echo -e "${YELLOW}No changes were made (dry-run mode)${NC}"
    else
        echo -e "${CYAN}Full logs available at:${NC} $LOG_FILE"
    fi
    echo ""
}

###############################################################################
# Main Function
###############################################################################

main() {
    # Parse arguments first
    parse_arguments "$@"

    # Banner
    clear
    echo -e "${CYAN}"
    cat << "EOF"
╔═══════════════════════════════════════════════════════════════╗
║                                                               ║
║        Docker Container Update Tool v2.0                      ║
║        Safely and easily update your containers               ║
║                                                               ║
╚═══════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"

    # Show mode
    case "$MODE" in
        "interactive")
            log_info "Mode: INTERACTIVE (manual container selection)"
            ;;
        "unattended")
            log_info "Mode: UNATTENDED (updating all containers automatically)"
            ;;
    esac

    # Show dry-run status
    if [ "$DRY_RUN" = true ]; then
        log_warning "DRY-RUN MODE: No actual changes will be made"
    fi

    # Checks
    check_root "$@"
    check_docker
    setup_logging
    create_symlink

    log_info "Script started by: ${SUDO_USER:-root}"

    # Initialize dry-run report if needed
    if [ "$DRY_RUN" = true ]; then
        echo "Dry-Run Report - $(date)" > "$DRY_RUN_REPORT"
        echo "=========================================================================" >> "$DRY_RUN_REPORT"
        echo "" >> "$DRY_RUN_REPORT"
        log_info "Dry-run mode enabled - no changes will be made"
        log_info "Report will be saved to: $DRY_RUN_REPORT"
    fi

    # System update handling
    if [ "$UPDATE_SYSTEM" = true ]; then
        # --update-system flag provided
        perform_system_update || log_warning "System update failed, continuing with containers"
    elif [ "$MODE" = "interactive" ]; then
        # Interactive mode - ask user
        ask_system_update
    fi
    # In unattended mode without --update-system flag, skip system updates

    # Container selection based on mode
    if [ "$MODE" = "interactive" ]; then
        selected_containers=($(select_containers))
    else
        # Unattended mode - get all containers
        selected_containers=($(get_all_containers))
    fi

    # Update process
    update_selected_containers "${selected_containers[@]}"

    # Summary
    show_summary

    # Determine exit code - check if UPDATE_FAILED has any elements
    local has_failures=0
    if [ -n "${UPDATE_FAILED[*]+x}" ] && [ ${#UPDATE_FAILED[@]} -gt 0 ]; then
        has_failures=1
    fi

    if [ $has_failures -eq 1 ]; then
        log_warning "Script completed with errors"
        exit 1
    else
        log_success "Script completed successfully!"
        exit 0
    fi
}

# Run main function
main "$@"
