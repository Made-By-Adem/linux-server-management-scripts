#!/bin/bash
# =============================================================================
# Configuration Loader Module
# =============================================================================
# This module provides functions to load configuration files and process
# templates with variable substitution.
#
# Features:
# - Load default configuration
# - Load profile-based configurations
# - Process templates with variable substitution
# - Validate configuration values
# - Show configuration diff
#
# =============================================================================

# Get the script directory
MODULES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_BASE_DIR="${MODULES_DIR}/../config"
TEMPLATE_DIR="${CONFIG_BASE_DIR}/templates"

# =============================================================================
# Configuration Loading Functions
# =============================================================================

# -----------------------------------------------------------------------------
# load_default_config
# Load the default configuration file
# -----------------------------------------------------------------------------
load_default_config() {
    local default_config="${CONFIG_BASE_DIR}/default.conf"

    if [[ ! -f "$default_config" ]]; then
        echo "ERROR: Default configuration not found: $default_config" >&2
        return 1
    fi

    # Source the default configuration
    source "$default_config"

    # Set generation metadata
    export GENERATION_DATE="$(date '+%Y-%m-%d %H:%M:%S %Z')"

    return 0
}

# -----------------------------------------------------------------------------
# load_profile_config
# Load a profile configuration (sources default.conf first)
#
# Arguments:
#   $1 - Profile name (e.g., "production", "development", "raspberry-pi")
# -----------------------------------------------------------------------------
load_profile_config() {
    local profile_name="$1"
    local profile_config="${CONFIG_BASE_DIR}/profiles/${profile_name}.conf"

    if [[ -z "$profile_name" ]]; then
        echo "ERROR: Profile name not specified" >&2
        return 1
    fi

    if [[ ! -f "$profile_config" ]]; then
        echo "ERROR: Profile configuration not found: $profile_config" >&2
        echo "Available profiles:" >&2
        ls -1 "${CONFIG_BASE_DIR}/profiles/" 2>/dev/null | sed 's/\.conf$//' | sed 's/^/  - /' >&2
        return 1
    fi

    # Source the profile configuration (which will source default.conf internally)
    source "$profile_config"

    # Set generation metadata
    export GENERATION_DATE="$(date '+%Y-%m-%d %H:%M:%S %Z')"

    return 0
}

# -----------------------------------------------------------------------------
# load_custom_config
# Load a custom configuration file from a specified path
#
# Arguments:
#   $1 - Path to custom configuration file
# -----------------------------------------------------------------------------
load_custom_config() {
    local config_file="$1"

    if [[ -z "$config_file" ]]; then
        echo "ERROR: Configuration file path not specified" >&2
        return 1
    fi

    if [[ ! -f "$config_file" ]]; then
        echo "ERROR: Configuration file not found: $config_file" >&2
        return 1
    fi

    # Load default first, then override with custom
    load_default_config || return 1
    source "$config_file"

    # Set generation metadata
    export GENERATION_DATE="$(date '+%Y-%m-%d %H:%M:%S %Z')"

    return 0
}

# =============================================================================
# Template Processing Functions
# =============================================================================

# -----------------------------------------------------------------------------
# process_template
# Process a template file and substitute variables
#
# Arguments:
#   $1 - Template file path (absolute or relative to TEMPLATE_DIR)
#   $2 - Output file path (optional, defaults to stdout)
#
# Returns:
#   0 on success, 1 on error
#
# Template variable format:
#   {{VARIABLE_NAME}} - Will be replaced with the value of $VARIABLE_NAME
#
# Example:
#   process_template "pam/pwquality.conf.template" "/tmp/pwquality.conf"
# -----------------------------------------------------------------------------
process_template() {
    local template_file="$1"
    local output_file="${2:-}"

    # Resolve template path
    if [[ ! -f "$template_file" ]]; then
        # Try relative to template directory
        template_file="${TEMPLATE_DIR}/${template_file}"
    fi

    if [[ ! -f "$template_file" ]]; then
        echo "ERROR: Template file not found: $template_file" >&2
        return 1
    fi

    # Read template content
    local template_content
    template_content=$(<"$template_file")

    # Process template variables
    # This uses eval to substitute {{VAR}} with the value of $VAR
    # It's safe because we control the template files
    local processed_content="$template_content"

    # Find all {{VARIABLE}} patterns and replace them
    while [[ "$processed_content" =~ \{\{([A-Z_][A-Z0-9_]*)\}\} ]]; do
        local var_name="${BASH_REMATCH[1]}"
        local var_value="${!var_name:-}"

        # Replace the first occurrence
        processed_content="${processed_content/\{\{${var_name}\}\}/${var_value}}"
    done

    # Output to file or stdout
    if [[ -n "$output_file" ]]; then
        echo "$processed_content" > "$output_file"
    else
        echo "$processed_content"
    fi

    return 0
}

# -----------------------------------------------------------------------------
# show_template_diff
# Show the diff between a processed template and an existing file
#
# Arguments:
#   $1 - Template file path
#   $2 - Existing file path to compare against
#
# Returns:
#   0 if files differ, 1 if identical or error
# -----------------------------------------------------------------------------
show_template_diff() {
    local template_file="$1"
    local existing_file="$2"

    if [[ ! -f "$existing_file" ]]; then
        echo "INFO: File does not exist yet: $existing_file"
        echo "New file will be created."
        return 0
    fi

    # Process template to temporary file
    local temp_file
    temp_file=$(mktemp)

    if ! process_template "$template_file" "$temp_file"; then
        rm -f "$temp_file"
        return 1
    fi

    # Show diff (unified format, colored if available)
    echo "========================================"
    echo "Changes to be applied to: $existing_file"
    echo "========================================"

    if command -v colordiff &>/dev/null; then
        diff -u "$existing_file" "$temp_file" | colordiff || true
    else
        diff -u "$existing_file" "$temp_file" || true
    fi

    echo "========================================"

    # Cleanup
    rm -f "$temp_file"

    # Return 0 if there are differences (diff returns 1)
    diff -q "$existing_file" "$temp_file" &>/dev/null
    local diff_result=$?

    return $((! diff_result))
}

# -----------------------------------------------------------------------------
# deploy_template
# Deploy a processed template to a target file with backup
#
# Arguments:
#   $1 - Template file path
#   $2 - Target file path
#   $3 - Backup directory (optional, default: /var/backups/server-setup-backup)
#   $4 - Permissions (optional, default: preserve existing or 644)
#   $5 - Owner (optional, default: preserve existing or root:root)
#
# Returns:
#   0 on success, 1 on error
# -----------------------------------------------------------------------------
deploy_template() {
    local template_file="$1"
    local target_file="$2"
    local backup_dir="${3:-/var/backups/server-setup-backup}"
    local permissions="${4:-}"
    local owner="${5:-}"

    # Create backup directory if it doesn't exist
    if [[ ! -d "$backup_dir" ]]; then
        mkdir -p "$backup_dir" || {
            echo "ERROR: Failed to create backup directory: $backup_dir" >&2
            return 1
        }
    fi

    # Backup existing file if it exists
    if [[ -f "$target_file" ]]; then
        local backup_file="${backup_dir}/$(basename "$target_file").$(date +%Y%m%d_%H%M%S).bak"
        cp -a "$target_file" "$backup_file" || {
            echo "ERROR: Failed to create backup: $backup_file" >&2
            return 1
        }
        echo "Backup created: $backup_file"

        # Preserve existing permissions if not specified
        if [[ -z "$permissions" ]]; then
            permissions=$(stat -c '%a' "$target_file" 2>/dev/null || echo "644")
        fi
        if [[ -z "$owner" ]]; then
            owner=$(stat -c '%U:%G' "$target_file" 2>/dev/null || echo "root:root")
        fi
    else
        # Default permissions for new files
        permissions="${permissions:-644}"
        owner="${owner:-root:root}"
    fi

    # Create target directory if it doesn't exist
    local target_dir
    target_dir=$(dirname "$target_file")
    if [[ ! -d "$target_dir" ]]; then
        mkdir -p "$target_dir" || {
            echo "ERROR: Failed to create directory: $target_dir" >&2
            return 1
        }
    fi

    # Process template and write to target file
    if ! process_template "$template_file" "$target_file"; then
        echo "ERROR: Failed to process template: $template_file" >&2
        return 1
    fi

    # Set permissions
    chmod "$permissions" "$target_file" || {
        echo "ERROR: Failed to set permissions: $permissions" >&2
        return 1
    }

    # Set owner
    chown "$owner" "$target_file" || {
        echo "ERROR: Failed to set owner: $owner" >&2
        return 1
    }

    echo "Successfully deployed: $target_file"
    return 0
}

# =============================================================================
# Configuration Validation Functions
# =============================================================================

# -----------------------------------------------------------------------------
# validate_config
# Validate that required configuration variables are set
#
# Returns:
#   0 if all required variables are set, 1 otherwise
# -----------------------------------------------------------------------------
validate_config() {
    local required_vars=(
        "PASSWORD_MAX_DAYS"
        "PASSWORD_MIN_LENGTH"
        "SSH_NEW_PORT"
        "SYSTEM_TIMEZONE"
    )

    local missing_vars=()

    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            missing_vars+=("$var")
        fi
    done

    if [[ ${#missing_vars[@]} -gt 0 ]]; then
        echo "ERROR: Required configuration variables are not set:" >&2
        printf '  - %s\n' "${missing_vars[@]}" >&2
        return 1
    fi

    return 0
}

# -----------------------------------------------------------------------------
# show_config_summary
# Display a summary of the loaded configuration
# -----------------------------------------------------------------------------
show_config_summary() {
    echo "========================================"
    echo "Configuration Summary"
    echo "========================================"
    echo "Profile:          ${CONFIG_PROFILE_NAME:-default}"
    echo "Description:      ${CONFIG_PROFILE_DESCRIPTION:-N/A}"
    echo "Generated:        ${GENERATION_DATE:-N/A}"
    echo ""
    echo "Key Settings:"
    echo "  Password Max Age:     ${PASSWORD_MAX_DAYS} days"
    echo "  Password Min Length:  ${PASSWORD_MIN_LENGTH} characters"
    echo "  SSH Port:             ${SSH_NEW_PORT}"
    echo "  Timezone:             ${SYSTEM_TIMEZONE}"
    echo "  Fail2ban SSH Ban:     ${FAIL2BAN_SSH_BANTIME} seconds"
    echo "  Journal Max Size:     ${JOURNAL_MAX_USE}"
    echo "  Swap Enabled:         ${SWAP_ENABLED}"
    echo "  AIDE Enabled:         ${AIDE_ENABLED}"
    echo "  Compiler Restrict:    ${COMPILER_RESTRICT_ENABLED}"
    echo "========================================"
}

# =============================================================================
# Helper Functions
# =============================================================================

# -----------------------------------------------------------------------------
# list_available_profiles
# List all available configuration profiles
# -----------------------------------------------------------------------------
list_available_profiles() {
    echo "Available configuration profiles:"
    echo ""

    if [[ -d "${CONFIG_BASE_DIR}/profiles" ]]; then
        for profile_file in "${CONFIG_BASE_DIR}/profiles"/*.conf; do
            if [[ -f "$profile_file" ]]; then
                local profile_name
                profile_name=$(basename "$profile_file" .conf)

                # Try to extract description from the profile
                local description
                description=$(grep '^CONFIG_PROFILE_DESCRIPTION=' "$profile_file" 2>/dev/null | cut -d'"' -f2)

                printf "  %-20s %s\n" "$profile_name" "$description"
            fi
        done
    else
        echo "  No profiles found."
    fi
}

# -----------------------------------------------------------------------------
# export_current_config
# Export the current configuration to a file
#
# Arguments:
#   $1 - Output file path
# -----------------------------------------------------------------------------
export_current_config() {
    local output_file="$1"

    if [[ -z "$output_file" ]]; then
        echo "ERROR: Output file path not specified" >&2
        return 1
    fi

    # Export all configuration variables
    {
        echo "# Exported configuration"
        echo "# Generated: $(date '+%Y-%m-%d %H:%M:%S %Z')"
        echo "# Profile: ${CONFIG_PROFILE_NAME:-default}"
        echo ""

        # Get all uppercase variables (configuration variables)
        for var in $(compgen -v | grep '^[A-Z_]' | sort); do
            # Skip some special variables
            if [[ "$var" =~ ^(BASH_|FUNCNAME|GROUPS|DIRSTACK|PIPESTATUS) ]]; then
                continue
            fi

            local value="${!var}"
            printf '%s="%s"\n' "$var" "$value"
        done
    } > "$output_file"

    echo "Configuration exported to: $output_file"
    return 0
}

# =============================================================================
# Module Initialization
# =============================================================================

# Auto-load default configuration if no configuration is loaded yet
if [[ -z "${CONFIG_PROFILE_NAME:-}" ]]; then
    # Only load if we're being sourced (not executed directly)
    if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
        load_default_config
    fi
fi
