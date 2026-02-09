#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Remote Backup Script - Pull folders from a remote server via rsync
# Usage: backup-folders [server]    e.g. backup-folders oc2
#        backup-folders             (uses default .env)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# --- Determine config file ---
if [[ -n "${1:-}" ]]; then
    ENV_FILE="${SCRIPT_DIR}/.env.${1}"
else
    ENV_FILE="${SCRIPT_DIR}/.env"
fi

# --- Load .env ---
if [[ ! -f "$ENV_FILE" ]]; then
    echo "[ERROR] Config file not found: $ENV_FILE"
    if [[ -n "${1:-}" ]]; then
        echo "        Create it with: cp .env .env.${1}"
    fi
    # List available configs
    CONFIGS=$(ls "${SCRIPT_DIR}"/.env* 2>/dev/null | xargs -I{} basename {})
    if [[ -n "$CONFIGS" ]]; then
        echo ""
        echo "Available configs:"
        echo "$CONFIGS"
    fi
    exit 1
fi
source "$ENV_FILE"

# --- Validate required variables ---
if [[ -z "${REMOTE_HOST:-}" ]]; then
    echo "[ERROR] REMOTE_HOST is not set in .env"
    exit 1
fi
if [[ -z "${REMOTE_USER:-}" ]]; then
    echo "[ERROR] REMOTE_USER is not set in .env"
    exit 1
fi
if [[ ${#BACKUP_FOLDERS[@]} -eq 0 ]]; then
    echo "[ERROR] BACKUP_FOLDERS is empty in .env"
    exit 1
fi

SSH_PORT="${SSH_PORT:-22}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"

# --- Telegram notification function ---
send_telegram() {
    local message="$1"
    if [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]]; then
        curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            -d chat_id="${TELEGRAM_CHAT_ID}" \
            -d parse_mode="HTML" \
            -d text="${message}" > /dev/null 2>&1 || true
    fi
}

# --- Validate SSH key ---
if [[ ! -f "$SSH_KEY" ]]; then
    echo "[ERROR] SSH key not found at: $SSH_KEY"
    echo "        Generate one with: ssh-keygen -t ed25519 -f $SSH_KEY -N ''"
    exit 1
fi

# --- Setup backup directory ---
BACKUP_DIR="${BACKUP_DEST:-${SCRIPT_DIR}}/backup-${REMOTE_NAME:-${REMOTE_HOST}}"
mkdir -p "$BACKUP_DIR"

echo "======================================"
echo " Remote Backup"
echo "======================================"
echo " Server:  ${REMOTE_NAME:-${REMOTE_HOST}} (${REMOTE_USER}@${REMOTE_HOST}:${SSH_PORT})"
echo " Folders: ${BACKUP_FOLDERS[*]}"
echo " Dest:    ${BACKUP_DIR}"
echo "======================================"
echo ""

# --- Run rsync (single SSH connection via multiplexing) ---
SOCKET="/tmp/backup-ssh-${REMOTE_HOST}"

# Open persistent SSH connection
echo "[*] Opening SSH connection to ${REMOTE_HOST}..."
if ! ssh -o StrictHostKeyChecking=accept-new \
    -i "$SSH_KEY" \
    -p "$SSH_PORT" \
    -M -S "$SOCKET" \
    -f -N \
    "${REMOTE_USER}@${REMOTE_HOST}"; then
    echo "[ERROR] Failed to connect to ${REMOTE_HOST}"
    send_telegram "❌ <b>Backup failed</b>
<b>From:</b> ${REMOTE_NAME:-${REMOTE_HOST}}
<b>To:</b> $(hostname)
<b>Error:</b> SSH connection failed
<b>Time:</b> $(date '+%Y-%m-%d %H:%M:%S')"
    exit 1
fi

# Ensure we clean up the SSH connection on exit
cleanup() {
    ssh -S "$SOCKET" -O exit "${REMOTE_USER}@${REMOTE_HOST}" 2>/dev/null || true
}
trap cleanup EXIT

# Rsync each folder using the shared SSH connection
FAILED=0
for folder in "${BACKUP_FOLDERS[@]}"; do
    folder="${folder%/}/"
    LOCAL_PATH="${BACKUP_DIR}${folder}"
    mkdir -p "$LOCAL_PATH"

    echo "[*] Syncing ${folder} ..."
    if rsync -az --delete \
        -e "ssh -i '$SSH_KEY' -p $SSH_PORT -S '$SOCKET'" \
        "${REMOTE_USER}@${REMOTE_HOST}:${folder}" \
        "$LOCAL_PATH"; then
        echo "    [OK] ${folder}"
    else
        echo "    [FAIL] ${folder}"
        FAILED=$((FAILED + 1))
    fi
done

echo ""
HOSTNAME=$(hostname)
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

if [[ $FAILED -eq 0 ]]; then
    echo "[SUCCESS] Backup completed to: ${BACKUP_DIR}"
    send_telegram "✅ <b>Backup successful</b>
<b>From:</b> ${REMOTE_NAME:-${REMOTE_HOST}}
<b>To:</b> ${HOSTNAME}:${BACKUP_DIR}
<b>Folders:</b> ${#BACKUP_FOLDERS[@]}
<b>Time:</b> ${TIMESTAMP}"
else
    echo "[WARNING] Backup completed with ${FAILED} failed folder(s)"
    send_telegram "❌ <b>Backup failed</b>
<b>From:</b> ${REMOTE_NAME:-${REMOTE_HOST}}
<b>To:</b> ${HOSTNAME}:${BACKUP_DIR}
<b>Failed:</b> ${FAILED}/${#BACKUP_FOLDERS[@]} folders
<b>Time:</b> ${TIMESTAMP}"
    exit 1
fi
