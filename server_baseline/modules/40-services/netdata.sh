#!/bin/bash

###############################################################################
# Module: Netdata Installation
# Description: Install Netdata real-time monitoring
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${SCRIPT_DIR}/modules/00-core/common.sh"

MODULE_NAME="netdata"
MODULE_DESCRIPTION="Netdata monitoring"

should_run() {
    skip_if_completed "$MODULE_NAME" "$MODULE_DESCRIPTION" && return 1
    answer_is_yes "INSTALL_NETDATA" || return 1
    answer_is_yes "INSTALL_DOCKER" || return 1
    return 0
}

run() {
    log_section "Installing Netdata"

    local telegram_token="$(get_answer 'TELEGRAM_BOT_TOKEN' '')"
    local telegram_chat="$(get_answer 'TELEGRAM_CHAT_ID' '')"

    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Would create Netdata docker-compose"
        log_dry_run "Would configure with host monitoring"
        [ -n "$telegram_token" ] && log_dry_run "Would configure Telegram alerts"
        return 0
    fi

    # Create Netdata directory
    local netdata_dir="$USER_HOME/docker/netdata"
    create_directory "$netdata_dir" "755"

    # Create docker-compose.yml with full monitoring
    cat > "$netdata_dir/docker-compose.yml" << 'COMPOSE'
version: '3'
services:
  netdata:
    image: netdata/netdata:stable
    container_name: netdata
    hostname: ${HOSTNAME}
    restart: unless-stopped
    ports:
      - "19999:19999"
    cap_add:
      - SYS_PTRACE
      - SYS_ADMIN
    security_opt:
      - apparmor:unconfined
    volumes:
      - netdataconfig:/etc/netdata
      - netdatalib:/var/lib/netdata
      - netdatacache:/var/cache/netdata
      - /etc/passwd:/host/etc/passwd:ro
      - /etc/group:/host/etc/group:ro
      - /etc/localtime:/etc/localtime:ro
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /etc/os-release:/host/etc/os-release:ro
      - /var/log:/host/var/log:ro
      - /var/run/docker.sock:/var/run/docker.sock:ro
    environment:
      - NETDATA_CLAIM_TOKEN=
      - NETDATA_CLAIM_ROOMS=
      - DOCKER_HOST=unix:///var/run/docker.sock
COMPOSE

    # Add Telegram config if provided
    if [ -n "$telegram_token" ] && [ -n "$telegram_chat" ]; then
        cat >> "$netdata_dir/docker-compose.yml" << TELEGRAM
      - TELEGRAM_BOT_TOKEN=$telegram_token
      - DEFAULT_RECIPIENT_TELEGRAM=$telegram_chat

volumes:
  netdataconfig:
  netdatalib:
  netdatacache:
TELEGRAM
        log_info "✓ Telegram alerts configured"
    else
        cat >> "$netdata_dir/docker-compose.yml" << VOLUMES

volumes:
  netdataconfig:
  netdatalib:
  netdatacache:
VOLUMES
    fi

    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$netdata_dir"

    # Start Netdata
    cd "$netdata_dir"
    HOSTNAME=$(hostname) docker compose up -d >> "$ERROR_LOG" 2>&1

    log_info "✓ Netdata installed"
    log_info "Access at: http://$SERVER_IP:19999"

    mark_completed "$MODULE_NAME"
    echo ""
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    should_run && run
fi
