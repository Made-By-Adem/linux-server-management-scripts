#!/bin/bash

###############################################################################
# Module: Portainer Installation
# Description: Install Portainer Docker management UI
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${SCRIPT_DIR}/modules/00-core/common.sh"

MODULE_NAME="portainer"
MODULE_DESCRIPTION="Portainer container management"

should_run() {
    skip_if_completed "$MODULE_NAME" "$MODULE_DESCRIPTION" && return 1
    answer_is_yes "INSTALL_PORTAINER" || return 1
    answer_is_yes "INSTALL_DOCKER" || return 1
    return 0
}

run() {
    log_section "Installing Portainer"

    local enable_agent="$(get_answer 'ENABLE_PORTAINER_AGENT' 'n')"

    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Would create Portainer docker-compose.yml"
        log_dry_run "Would start Portainer container"
        [ "$enable_agent" = "y" ] && log_dry_run "Would expose agent port 9001"
        return 0
    fi

    # Create Portainer directory
    local portainer_dir="$USER_HOME/docker/portainer"
    create_directory "$portainer_dir" "755"

    # Create docker-compose.yml
    if [ "$enable_agent" = "y" ]; then
        cat > "$portainer_dir/docker-compose.yml" <<COMPOSE
version: '3'
services:
  portainer:
    image: portainer/portainer-ce:lts
    container_name: portainer
    restart: unless-stopped
    ports:
      - "9443:9443"
      - "9001:9001"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - portainer_data:/data

volumes:
  portainer_data:
COMPOSE
    else
        cat > "$portainer_dir/docker-compose.yml" <<COMPOSE
version: '3'
services:
  portainer:
    image: portainer/portainer-ce:lts
    container_name: portainer
    restart: unless-stopped
    ports:
      - "9443:9443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - portainer_data:/data

volumes:
  portainer_data:
COMPOSE
    fi

    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$portainer_dir"

    # Start Portainer
    cd "$portainer_dir"
    docker compose up -d >> "$ERROR_LOG" 2>&1

    log_info "✓ Portainer installed"
    log_info "Access at: https://$SERVER_IP:9443"

    mark_completed "$MODULE_NAME"
    echo ""
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    should_run && run
fi
