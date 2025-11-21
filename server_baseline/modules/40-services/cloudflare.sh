#!/bin/bash

###############################################################################
# Module: Cloudflare Tunnel
# Description: Install Cloudflare Tunnel for secure external access
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${SCRIPT_DIR}/modules/00-core/common.sh"

MODULE_NAME="cloudflare"
MODULE_DESCRIPTION="Cloudflare Tunnel"

should_run() {
    skip_if_completed "$MODULE_NAME" "$MODULE_DESCRIPTION" && return 1
    answer_is_yes "INSTALL_CLOUDFLARE" || return 1
    answer_is_yes "INSTALL_DOCKER" || return 1
    return 0
}

run() {
    log_section "Installing Cloudflare Tunnel"

    local cf_token="$(get_answer 'CLOUDFLARE_TOKEN' 'skip')"

    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Would create Cloudflare tunnel docker-compose"
        [ "$cf_token" != "skip" ] && log_dry_run "Would configure with provided token"
        return 0
    fi

    # Create Cloudflare directory
    local cf_dir="$USER_HOME/docker/cloudflare"
    create_directory "$cf_dir" "755"

    # Create docker-compose.yml
    cat > "$cf_dir/docker-compose.yml" << 'COMPOSE'
version: '3'
services:
  cloudflared:
    image: cloudflare/cloudflared:latest
    container_name: cloudflared
    restart: unless-stopped
    command: tunnel --no-autoupdate run
    environment:
      - TUNNEL_TOKEN=${CF_TOKEN}
COMPOSE

    # Create .env file
    if [ "$cf_token" != "skip" ] && [ -n "$cf_token" ]; then
        echo "CF_TOKEN=$cf_token" > "$cf_dir/.env"
        chmod 600 "$cf_dir/.env"
        log_info "✓ Token configured"

        # Start container
        cd "$cf_dir"
        docker compose up -d >> "$ERROR_LOG" 2>&1
        log_info "✓ Cloudflare Tunnel started"
    else
        echo "CF_TOKEN=your-token-here" > "$cf_dir/.env"
        chmod 600 "$cf_dir/.env"
        log_info "✓ Cloudflare prepared (configure token in $cf_dir/.env)"
    fi

    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$cf_dir"

    mark_completed "$MODULE_NAME"
    echo ""
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    should_run && run
fi
