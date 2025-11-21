#!/bin/bash

###############################################################################
# Common Utilities for All Modules
# Shared functions, logging, state management
###############################################################################

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# =============================================================================
# LOGGING FUNCTIONS
# =============================================================================

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
    [ -n "${ERROR_LOG:-}" ] && echo "[ERROR] $1" >> "$ERROR_LOG"
}

log_dry_run() {
    echo -e "${CYAN}[DRY-RUN]${NC} $1"
    [ -n "${DRY_RUN_REPORT:-}" ] && echo "[DRY-RUN] $1" >> "$DRY_RUN_REPORT" 2>/dev/null || true
}

log_section() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
}

# =============================================================================
# STATE MANAGEMENT (Resume Capability)
# =============================================================================

is_completed() {
    local module_name="$1"
    [ -f "$STATE_FILE" ] && grep -q "^${module_name}$" "$STATE_FILE" 2>/dev/null
}

mark_completed() {
    local module_name="$1"
    [ -n "${STATE_FILE:-}" ] && echo "$module_name" >> "$STATE_FILE"
}

skip_if_completed() {
    local module_name="$1"
    local description="$2"

    if is_completed "$module_name"; then
        log_info "✓ $description (already completed, skipping)"
        return 0  # Return success = skip
    fi
    return 1  # Return failure = don't skip
}

# =============================================================================
# USER ANSWERS (From Pre-flight Questions)
# =============================================================================

# Associative array to store user answers (declared in main script)
# declare -A USER_ANSWERS

get_answer() {
    local key="$1"
    local default="${2:-}"

    if [ -n "${USER_ANSWERS[$key]:-}" ]; then
        echo "${USER_ANSWERS[$key]}"
    else
        echo "$default"
    fi
}

has_answer() {
    local key="$1"
    [ -n "${USER_ANSWERS[$key]:-}" ]
}

answer_is_yes() {
    local key="$1"
    local value="$(get_answer "$key")"
    [[ "$value" =~ ^[Yy]$ ]] || [[ "$value" =~ ^[Yy][Ee][Ss]$ ]]
}

# =============================================================================
# PACKAGE MANAGEMENT
# =============================================================================

install_package() {
    local package="$1"
    local description="${2:-$package}"

    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Would install: $description ($package)"
        return 0
    fi

    if dpkg -l | grep -q "^ii  $package "; then
        log_info "✓ $description already installed"
        return 0
    fi

    log_info "Installing $description..."
    if ! apt-get install -y "$package" >> "$ERROR_LOG" 2>&1; then
        log_error "Failed to install $package"
        return 1
    fi
    log_info "✓ $description installed"
}

install_packages() {
    local description="$1"
    shift
    local packages=("$@")

    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Would install: $description (${packages[*]})"
        return 0
    fi

    log_info "Installing $description..."
    if ! apt-get install -y "${packages[@]}" >> "$ERROR_LOG" 2>&1; then
        log_error "Failed to install some packages: ${packages[*]}"
        return 1
    fi
    log_info "✓ $description installed"
}

# =============================================================================
# FILE OPERATIONS
# =============================================================================

backup_file() {
    local file="$1"

    if [ ! -f "$file" ]; then
        return 0
    fi

    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Would backup: $file"
        return 0
    fi

    local backup="${file}.backup.$(date +%Y%m%d_%H%M%S)"
    cp "$file" "$backup"
    log_info "Backed up: $file → $backup"
}

create_directory() {
    local dir="$1"
    local mode="${2:-755}"

    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Would create directory: $dir (mode: $mode)"
        return 0
    fi

    if [ ! -d "$dir" ]; then
        mkdir -p "$dir"
        chmod "$mode" "$dir"
        log_info "Created directory: $dir"
    fi
}

# =============================================================================
# SERVICE MANAGEMENT
# =============================================================================

restart_service() {
    local service="$1"

    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Would restart service: $service"
        return 0
    fi

    log_info "Restarting $service..."
    if systemctl restart "$service" >> "$ERROR_LOG" 2>&1; then
        log_info "✓ $service restarted"
    else
        log_warning "Failed to restart $service (check logs)"
    fi
}

enable_service() {
    local service="$1"

    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Would enable service: $service"
        return 0
    fi

    systemctl enable "$service" >> "$ERROR_LOG" 2>&1
}

# =============================================================================
# DOCKER OPERATIONS
# =============================================================================

docker_compose_up() {
    local compose_dir="$1"
    local service_name="${2:-container}"

    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Would start Docker container in: $compose_dir"
        return 0
    fi

    if [ ! -d "$compose_dir" ]; then
        log_error "Docker compose directory not found: $compose_dir"
        return 1
    fi

    log_info "Starting $service_name container..."
    cd "$compose_dir"
    if docker compose up -d >> "$ERROR_LOG" 2>&1; then
        log_info "✓ $service_name started"
    else
        log_warning "Failed to start $service_name (check logs)"
    fi
}

# =============================================================================
# VALIDATION
# =============================================================================

is_valid_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

is_valid_ip() {
    local ip="$1"
    [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]
}

# =============================================================================
# ERROR HANDLING
# =============================================================================

handle_error() {
    local message="$1"
    log_error "$message"
    exit 1
}

# =============================================================================
# COMPATIBILITY
# =============================================================================

# Ensure associative array exists (if not already declared in main script)
if [ -z "${USER_ANSWERS[*]:-}" ]; then
    declare -gA USER_ANSWERS
fi
