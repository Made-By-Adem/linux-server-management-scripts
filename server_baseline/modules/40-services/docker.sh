#!/bin/bash

###############################################################################
# Module: Docker Installation
# Description: Install Docker Engine and Docker Compose
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${SCRIPT_DIR}/modules/00-core/common.sh"

MODULE_NAME="docker"
MODULE_DESCRIPTION="Docker installation"

should_run() {
    skip_if_completed "$MODULE_NAME" "$MODULE_DESCRIPTION" && return 1
    answer_is_yes "INSTALL_DOCKER" || return 1
    return 0
}

run() {
    log_section "Installing Docker"

    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Would install Docker Engine"
        log_dry_run "Would install Docker Compose plugin"
        log_dry_run "Would add $ACTUAL_USER to docker group"
        log_dry_run "Would configure daemon.json"
        return 0
    fi

    # Add Docker's official GPG key
    log_info "Adding Docker repository..."
    install_packages "Docker prerequisites" ca-certificates curl gnupg
    
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    # Add Docker repository
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      tee /etc/apt/sources.list.d/docker.list > /dev/null

    apt-get update >> "$ERROR_LOG" 2>&1

    # Install Docker
    install_packages "Docker Engine" docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    # Add user to docker group
    usermod -aG docker "$ACTUAL_USER"
    log_info "✓ User $ACTUAL_USER added to docker group"

    # Configure Docker daemon
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json <<EOF
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "${DOCKER_LOG_MAX_SIZE:-10m}",
    "max-file": "${DOCKER_LOG_MAX_FILE:-3}"
  }
}
EOF

    # Create Docker directory for user
    create_directory "$USER_HOME/docker" "755"
    chown "$ACTUAL_USER:$ACTUAL_USER" "$USER_HOME/docker"

    # Enable and start Docker
    enable_service "docker"
    restart_service "docker"

    log_info "✓ Docker installed and configured"
    log_info "Docker version: $(docker --version)"

    mark_completed "$MODULE_NAME"
    echo ""
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    should_run && run
fi
