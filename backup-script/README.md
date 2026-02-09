# Remote Backup Script

Pulls folders from a remote (source) server to the local (backup) server via `rsync` over a single SSH connection.

## Overview

```
┌─────────────────────┐         rsync over SSH         ┌─────────────────────┐
│   SOURCE SERVER     │  ◄──────────────────────────   │   BACKUP SERVER     │
│  (remote/origin)    │                                │  (runs this script) │
│                     │                                │                     │
│  Has the data you   │                                │  Stores the backup  │
│  want to backup     │                                │  in backup-<host>/  │
└─────────────────────┘                                └─────────────────────┘
```

## Files

| File | Description |
|------|-------------|
| `backup.sh` | The backup script |
| `.env` | Configuration (server, user, folders) |

## Quick Start

### 1. Generate an SSH key on the source server

On the **source server** (the server that has the data), logged in as the user you want to connect with (e.g. `admin`):

```bash
ssh-keygen -t ed25519 -N ""
```

This creates a key pair at `~/.ssh/id_ed25519` (private) and `~/.ssh/id_ed25519.pub` (public).

### 2. Authorize the key on the source server

Still on the **source server**, add the public key to its own `authorized_keys`:

```bash
cat ~/.ssh/id_ed25519.pub >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

### 3. Copy the private key to the backup server

Display the private key on the **source server**:

```bash
cat ~/.ssh/id_ed25519
```

Then on the **backup server** (where this script runs), save it:

```bash
mkdir -p ~/.ssh && chmod 700 ~/.ssh
nano ~/.ssh/id_ed25519
```

Paste the private key contents, save, and set the correct permissions:

```bash
chmod 600 ~/.ssh/id_ed25519
```

### 4. Test the SSH connection

On the **backup server**, verify the connection works:

```bash
ssh -i ~/.ssh/id_ed25519 -p 22 admin@192.168.1.100 "echo 'Connection OK'"
```

> **Important:** The username must match the user that owns the `authorized_keys` on the source server. If you generated the key as `admin`, use `admin` here — not `root`.

Replace `admin`, `192.168.1.100` and port `22` with your actual values.

### 5. Create a config file per server

Copy the example and name it `.env.<server>`:

```bash
cp .env.example .env.oc2
cp .env.example .env.ac1
cp .env.example .env.ac2
```

Edit each file with the server-specific settings:

```env
REMOTE_HOST="10.10.10.20"
REMOTE_NAME="oc2"
REMOTE_USER="admin"
SSH_PORT="22"
SSH_KEY="/home/adem/.ssh/id_ed25519_oc2"
BACKUP_DEST="/home/adem/backups"

TELEGRAM_BOT_TOKEN="123456789:ABCdefGHIjklMNOpqrSTUvwxYZ"
TELEGRAM_CHAT_ID="123456789"

BACKUP_FOLDERS=(
    "/etc"
    "/home"
    "/opt/docker"
    "/var/lib/docker/volumes"
)
```

You can also use a single `.env` (without server name) as default config.

| Variable | Description |
|----------|-------------|
| `REMOTE_HOST` | IP or hostname of the source server |
| `REMOTE_NAME` | Friendly name for the backup folder, e.g. `oc2` → `backup-oc2/` (default: `REMOTE_HOST`) |
| `REMOTE_USER` | SSH username on the source server (must match the user that has the key in `authorized_keys`) |
| `SSH_PORT` | SSH port (default: `22`) |
| `SSH_KEY` | Absolute path to the private SSH key on this (backup) server. Use a full path, not `$HOME` or `~` |
| `BACKUP_DEST` | Local directory to store backups (default: next to script) |
| `TELEGRAM_BOT_TOKEN` | Telegram bot token (optional — leave empty to disable notifications) |
| `TELEGRAM_CHAT_ID` | Telegram chat ID to send notifications to |
| `BACKUP_FOLDERS` | List of absolute paths to backup (one per line) |

### 6. Run the script

```bash
chmod +x backup.sh

# Backup a specific server
./backup.sh oc2        # uses .env.oc2
./backup.sh ac1        # uses .env.ac1
./backup.sh ac2        # uses .env.ac2

# Or use default .env
./backup.sh
```

The backup is stored in `backup-<REMOTE_NAME>/` in the configured `BACKUP_DEST` directory (or next to the script if not set).

### 7. Optional: Install system-wide as `backup-folders` command

From the repository root:

```bash
sudo ln -sf $(pwd)/backup-script/backup.sh /usr/local/bin/backup-folders
```

Then run it from anywhere (no sudo needed):

```bash
backup-folders oc2
backup-folders ac1
backup-folders ac2
```

## Crontab Setup

Open the crontab:

```bash
crontab -e
```

Add a schedule for each server, for example daily at 03:00:

```cron
0 3 * * * /path/to/backup-script/backup.sh oc2 >> /var/log/backup.log 2>&1
10 3 * * * /path/to/backup-script/backup.sh ac1 >> /var/log/backup.log 2>&1
20 3 * * * /path/to/backup-script/backup.sh ac2 >> /var/log/backup.log 2>&1
```

Other schedule examples:

```cron
# Every hour
0 * * * * /path/to/backup-script/backup.sh oc2 >> /var/log/backup.log 2>&1

# Every Sunday at 02:00
0 2 * * 0 /path/to/backup-script/backup.sh oc2 >> /var/log/backup.log 2>&1

# Every 6 hours
0 */6 * * * /path/to/backup-script/backup.sh oc2 >> /var/log/backup.log 2>&1
```

> Replace `/path/to/` with the actual path to the `backup-script` directory.

## How It Works

1. Reads configuration from `.env`
2. Validates SSH key and server settings
3. Opens one persistent SSH connection (multiplexing)
4. Syncs each folder via `rsync` over that connection (`--delete` removes files no longer present on the source)
5. Closes the SSH connection when done
6. Result is stored in `backup-<REMOTE_HOST>/` mirroring the source server's directory structure
