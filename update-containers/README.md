# Docker Container Update Tool

> **Part of:** [Linux Server Management Scripts](https://github.com/MadeByAdem/linux-server-management-scripts)

A user-friendly bash script for safely updating Docker containers with visual feedback and comprehensive logging.

## 🚀 Quickstart

```bash
# 1. Download the repository
git clone https://github.com/MadeByAdem/linux-server-management-scripts.git
cd linux-server-management-scripts/update-containers

# 2. Make it executable
chmod +x update-containers.sh

# 3. Run with sudo
sudo ./update-containers.sh
```

---

## 📋 Table of Contents

- [What Does This Script Do?](#what-does-this-script-do)
- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [Usage](#usage)
- [Dry-Run Mode](#dry-run-mode)
- [System Updates](#system-updates)
- [Automation with Cron](#automation-with-cron)
- [Logs and Monitoring](#logs-and-monitoring)
- [Troubleshooting](#troubleshooting)
- [Security](#security)

---

## What Does This Script Do?

This script automates updating Docker containers in a safe and user-friendly manner:

**Interactive Mode:**
1. **Optional System Package Update** - Updates system packages before container updates
2. **Shows all running containers** - Clear list with details
3. **Lets user select containers** - Interactive choice, one or multiple
4. **Stops selected containers** - Via `docker compose down`
5. **Removes old images** - Frees up disk space
6. **Downloads new images** - Via `docker compose pull`
7. **Restarts containers** - Via `docker compose up -d`
8. **Verifies the result** - Checks if everything succeeded
9. **Shows clear report** - Visual overview of successes and failures

**Unattended Mode:**
- Automatically updates ALL running containers without user interaction
- Perfect for automation via cron jobs
- Can include system updates with `--update-system` flag

**Dry-Run Mode:**
- Preview all changes without executing them
- Can be combined with interactive or unattended modes
- Perfect for testing before actual updates
- Generates a report showing what would be updated

---

## Features

### ✨ Key Features

- **System Package Updates**
  - Optional `apt-get update && apt-get upgrade -y` before container updates
  - Ensures latest security patches
  - Interactive prompt with clear explanation
  - Tracks update status in final summary

- **Three Operation Modes**
  - Interactive mode - manual container selection
  - Unattended mode - automatic updates for all containers
  - Dry-run mode - preview changes without executing them
  - Perfect for both manual and automated use cases

- **Interactive Container Selection** (Interactive Mode)
  - Clear list of all containers
  - Select one, multiple, or all containers
  - Shows image, status, and creation date

- **Visual Feedback**
  - Color-coded output (green=success, red=error, yellow=warning)
  - Unicode symbols (✓, ✗, →, •) for clear status
  - Progress indicators per step

- **Safety Checks**
  - Verification of Docker installation
  - Check if Docker daemon is running
  - Rollback on errors (attempts to restart container)
  - Confirmation required before updates

- **Comprehensive Logging**
  - All actions logged to `/var/log/docker-updates/`
  - Timestamps for every action
  - Success and error messages with details

- **Intelligent Compose Directory Detection**
  - Searches standard locations (`~/docker`, `/opt/docker`, etc.)
  - Uses Docker labels for project folders
  - Supports both `.yml` and `.yaml` extensions

- **Detailed Report**
  - Summary of all updates
  - List of successful updates with image changes
  - List of failed updates with reason
  - Current status of all containers

---

## Requirements

### System Requirements

- **Operating System**: Linux (Ubuntu, Debian, CentOS, etc.)
- **Docker**: Docker Engine installed and running
- **Docker Compose**: V2 (plugin) or standalone
- **Bash**: Version 4.0 or higher
- **Permissions**: Root/sudo access

### Docker Setup Requirements

For each container:
- A `docker-compose.yml` or `docker-compose.yaml` file must exist
- The compose file must be located in one of these locations:
  - `~/docker/[container-name]/`
  - `/home/*/docker/[container-name]/`
  - `/opt/docker/[container-name]/`
  - `/srv/docker/[container-name]/`

**Recommended Directory Structure:**
```
~/docker/
├── portainer/
│   └── docker-compose.yml
├── netdata/
│   └── docker-compose.yml
├── traefik/
│   └── docker-compose.yml
└── app/
    └── docker-compose.yml
```

---

## Installation

### Option 1: Git Clone (Recommended)

```bash
# Clone the repository
git clone https://github.com/MadeByAdem/linux-server-management-scripts.git
cd linux-server-management-scripts/update-containers

# Make executable
chmod +x update-containers.sh

# Test the script
sudo ./update-containers.sh
```

### Option 2: Direct Download

```bash
# Download the script
wget https://raw.githubusercontent.com/MadeByAdem/linux-server-management-scripts/main/update-containers/update-containers.sh

# Make executable
chmod +x update-containers.sh

# Run
sudo ./update-containers.sh
```

### Option 3: System-wide Installation

```bash
# Copy to /usr/local/bin for system-wide use
sudo cp update-containers.sh /usr/local/bin/update-containers

# Make executable
sudo chmod +x /usr/local/bin/update-containers

# Now you can run it from anywhere:
sudo update-containers
```

---

## Usage

### Basic Usage

The script supports three modes of operation:

```bash
# Interactive mode - manually select containers
sudo ./update-containers.sh --interactive

# Unattended mode - automatically update all containers
sudo ./update-containers.sh --unattended

# Dry-run mode - preview what would be updated
sudo ./update-containers.sh --dry-run
sudo ./update-containers.sh --interactive --dry-run

# With system package updates
sudo ./update-containers.sh --unattended --update-system
sudo ./update-containers.sh --interactive --update-system

# Show help (also shown when no mode is specified)
sudo ./update-containers.sh --help
sudo ./update-containers.sh
```

### Modes Explained

**Interactive Mode**
- Shows list of all running containers
- You manually select which containers to update
- Asks for confirmation before updating
- Best for: Manual updates, selective updates, learning

**Unattended Mode**
- Automatically updates ALL running containers
- No user interaction required
- Perfect for automation (cron jobs)
- Best for: Scheduled maintenance, automation

**Dry-Run Mode**
- Shows what would be updated WITHOUT making changes
- Can be combined with --interactive or --unattended
- Perfect for testing and verification
- Best for: Previewing updates, checking compatibility

### Step-by-Step Example (Interactive Mode)

**Step 1: System Package Update (Optional - only in interactive mode)**
```
═══════════════════════════════════════════════════════════════
  System Package Update
═══════════════════════════════════════════════════════════════

Do you want to update system packages before updating containers?

This will run:
  • sudo apt-get update
  • sudo apt-get upgrade -y
  • sudo apt-get autoremove -y

Recommended: Yes - ensures latest security patches
Note: This may take several minutes

Update system packages? (y/n):
```

*Note: In unattended mode, use `--update-system` flag to include system updates*

**Step 2: Container List**
```
╔═══════════════════════════════════════════════════════════════╗
║        Docker Container Update Tool v2.0                     ║
╚═══════════════════════════════════════════════════════════════╝

═══════════════════════════════════════════════════════════════
  Available Docker Containers
═══════════════════════════════════════════════════════════════

No.  Container Name                Image                              Status     Created
────────────────────────────────────────────────────────────────────────────────────────
[1]  portainer                     portainer/portainer-ce:latest      running    2024-01-15
[2]  netdata                       netdata/netdata:latest             running    2024-01-10
[3]  traefik                       traefik:v2.10                      running    2024-01-20
[4]  webapp                        myapp:latest                       running    2024-02-01

• Enter numbers separated by spaces (e.g., 1 3 5)
• Enter 'all' to select all containers
• Enter 'q' to quit

Selection:
```

**Step 3: Make Selection**
```bash
Selection: 1 3
# Or for all:
Selection: all
```

**Step 4: Confirmation**
```
The following containers will be updated:
  • portainer (/home/user/docker/portainer)
  • traefik (/home/user/docker/traefik)

Proceed with update? (yes/no):
```

**Step 5: Update Process**
```
───────────────────────────────────────────────────────────────
  Container: portainer
───────────────────────────────────────────────────────────────

[INFO] Compose directory: /home/user/docker/portainer
[INFO] → Getting current image info...
[INFO] → Stopping container...
✓ Container stopped
[INFO] → Removing old image...
✓ Old image removed
[INFO] → Downloading new image...
✓ New image downloaded
[INFO] → Starting container...
✓ Container started
[INFO] → Verifying container status...
✓ Container running successfully
```

**Step 6: Summary**
```
═══════════════════════════════════════════════════════════════
  Update Summary
═══════════════════════════════════════════════════════════════

Total containers: 2

✓ System packages updated

✓ Successfully updated: 2
  • portainer
    portainer/portainer-ce:2.19.0 → portainer/portainer-ce:2.19.1
  • traefik
    traefik:v2.10.0 → traefik:v2.10.1

───────────────────────────────────────────────────────────────
  Current Container Status
───────────────────────────────────────────────────────────────

NAMES        STATUS                  IMAGE
portainer    Up 5 seconds           portainer/portainer-ce:latest
traefik      Up 3 seconds           traefik:v2.10

Full logs available at: /var/log/docker-updates/update_20240201_143022.log
```

---

## Dry-Run Mode

### What is Dry-Run?

Dry-run mode allows you to **preview all changes** that would be made, without actually executing them. This is perfect for:
- Testing the script before running it on production
- Verifying which containers would be updated
- Checking if system updates would be applied
- Understanding the impact before making changes

### How to Use Dry-Run

```bash
# Dry-run with interactive mode (default)
sudo ./update-containers.sh --dry-run

# Dry-run with interactive selection
sudo ./update-containers.sh --interactive --dry-run

# Dry-run with unattended mode (all containers)
sudo ./update-containers.sh --unattended --dry-run

# Dry-run with system updates
sudo ./update-containers.sh --dry-run --update-system
```

### What Dry-Run Shows

During a dry-run, the script will:
- ✅ List all running containers
- ✅ Show which containers would be selected
- ✅ Display what commands would be executed
- ✅ Show system update commands (if `--update-system` is used)
- ✅ Generate a detailed report file
- ❌ **NOT** actually stop any containers
- ❌ **NOT** actually pull new images
- ❌ **NOT** actually make any changes

### Example Dry-Run Output

```
[DRY-RUN] Would stop container: docker compose down
[DRY-RUN] Would remove old image: sha256:abc123...
[DRY-RUN] Would pull new image: docker compose pull
[DRY-RUN] Would start container: docker compose up -d
[DRY-RUN] Would verify container is running

═══════════════════════════════════════════════════════════════
  Update Summary
═══════════════════════════════════════════════════════════════

✓ Successfully updated: 2
  • portainer
    [DRY-RUN] Would update from portainer/portainer-ce:latest
  • traefik
    [DRY-RUN] Would update from traefik:v2.10

Dry-run report available at: /tmp/docker-update-dryrun-20240201_143022.txt
No changes were made (dry-run mode)
```

### Dry-Run Report File

The dry-run generates a detailed report at `/tmp/docker-update-dryrun-[timestamp].txt` containing:
- All containers that would be updated
- All commands that would be executed
- System update commands (if applicable)
- Timestamp and mode information

---

## System Updates

### How It Works

The script includes an optional system package update feature that runs before container updates:

1. **Interactive Prompt**: Script asks if you want to update system packages
2. **Clear Information**: Shows exactly which commands will run
3. **Safe Execution**: Uses `DEBIAN_FRONTEND=noninteractive` for automation
4. **Progress Tracking**: Visual feedback for each step
5. **Summary Inclusion**: System update status shown in final report

### What Gets Updated

When you choose to update system packages, the script runs:

```bash
# Update package lists
sudo apt-get update

# Upgrade all packages
sudo apt-get upgrade -y

# Remove unused packages
sudo apt-get autoremove -y
```

### Benefits

- **Security**: Ensures latest security patches before updating containers
- **Compatibility**: System packages may affect container operations
- **Convenience**: Single command for complete system and container updates
- **Visibility**: Clear logging of what was updated

### Best Practices

**When to update system packages:**
- ✅ Before major container updates
- ✅ During scheduled maintenance windows
- ✅ When security updates are available
- ✅ Weekly/monthly as part of routine maintenance

**When to skip:**
- ⚠️ During critical operations
- ⚠️ If you just updated packages recently
- ⚠️ When you want faster container-only updates

---

## Automation with Cron

### Weekly Updates (Recommended)

For automatic weekly updates, you can set up a cron job using **unattended mode**. This is useful for:
- Automatic security updates
- Less manual intervention
- Consistent update schedules

**⚠️ Note:** Automatic updates will restart your services!

#### Method 1: Using Unattended Mode (Recommended)

```bash
# Open crontab editor
sudo crontab -e

# Choose your editor (nano is easiest for beginners)

# Add one of these lines at the end:
```

**Examples:**

```bash
# Every Sunday at 03:00 - update all containers
0 3 * * 0 /path/to/update-containers.sh --unattended >> /var/log/docker-updates/cron.log 2>&1

# Every Sunday at 03:00 - update system AND all containers
0 3 * * 0 /path/to/update-containers.sh --unattended --update-system >> /var/log/docker-updates/cron.log 2>&1

# Every Monday at 02:00
0 2 * * 1 /path/to/update-containers.sh --unattended >> /var/log/docker-updates/cron.log 2>&1

# First day of the month at 04:00
0 4 1 * * /path/to/update-containers.sh --unattended >> /var/log/docker-updates/cron.log 2>&1

# Every Saturday at 02:30 with system updates
30 2 * * 6 /path/to/update-containers.sh --unattended --update-system >> /var/log/docker-updates/cron.log 2>&1
```

#### Method 2: Alternative - Direct Path in Crontab

If you installed the script system-wide:

```bash
# Install system-wide first (if not done already)
sudo cp update-containers.sh /usr/local/bin/update-containers
sudo chmod +x /usr/local/bin/update-containers

# Add to crontab
sudo crontab -e

# Add one of these lines:
0 3 * * 0 /usr/local/bin/update-containers --unattended >> /var/log/docker-updates/cron.log 2>&1
0 3 * * 0 /usr/local/bin/update-containers --unattended --update-system >> /var/log/docker-updates/cron.log 2>&1
```

#### Method 3: With Email Notifications

If you want email notifications:

```bash
# Install mail utilities (if not already installed)
sudo apt-get install mailutils

# Add to crontab
sudo crontab -e

# Add:
MAILTO="your@email.com"
0 3 * * 0 /path/to/update-containers.sh --unattended --update-system
```

#### Cron Time Schedule Explained

```
* * * * * command
│ │ │ │ │
│ │ │ │ └─── Day of week (0-7, 0 and 7 are Sunday)
│ │ │ └───── Month (1-12)
│ │ └─────── Day of month (1-31)
│ └───────── Hour (0-23)
└─────────── Minute (0-59)
```

**Examples:**
```bash
# Every day at 02:00
0 2 * * *

# Every Sunday at 03:00
0 3 * * 0

# First day of month at 04:00
0 4 1 * *

# Twice per week (Monday and Thursday at 02:00)
0 2 * * 1,4

# Every weekday at 03:00
0 3 * * 1-5
```

### Tips for Automatic Updates

**✅ Best Practices:**
- Schedule updates at night (fewer active users)
- Use consistent timing
- Keep logs for troubleshooting
- Test manually before automating
- Make backups of important data before updates

**⚠️ Warnings:**
- Updates can take services temporarily offline
- New versions may have breaking changes
- Test updates on development/staging first
- Consider using specific version tags instead of `latest`

**🔔 Monitoring:**
```bash
# Check if cron job executed
sudo grep docker-update /var/log/syslog

# View automatic update logs
tail -f /var/log/docker-updates/auto-update-*.log

# List all cron jobs
sudo crontab -l
```

---

## Logs and Monitoring

### Log Locations

**Main logs:**
```
/var/log/docker-updates/
├── update_20240201_143022.log   # Detailed logs per run
├── update_20240208_030015.log
├── cron.log                      # Cron job output
└── auto-update-20240215.log      # Automatic update logs
```

### Viewing Logs

```bash
# Most recent log
sudo tail -100 /var/log/docker-updates/update_*.log | tail -100

# Live log following (during update)
sudo tail -f /var/log/docker-updates/update_*.log

# All logs from today
sudo grep "$(date +%Y-%m-%d)" /var/log/docker-updates/*.log

# Search for errors
sudo grep ERROR /var/log/docker-updates/*.log

# Search for successful updates
sudo grep SUCCESS /var/log/docker-updates/*.log
```

### Log Rotation

To prevent logs from becoming too large:

```bash
# Create logrotate configuration
sudo nano /etc/logrotate.d/docker-updates
```

Add:
```
/var/log/docker-updates/*.log {
    weekly
    rotate 12
    compress
    delaycompress
    notifempty
    create 0640 root root
    sharedscripts
}
```

This ensures:
- Logs rotated weekly
- 12 weeks of logs retained
- Old logs compressed
- Empty logs removed

---

## Troubleshooting

### Common Problems

#### 1. "unable to execute ./update-containers.sh: No such file or directory"

**Problem:** The script exists but gives "No such file or directory" error.

**Cause:** The script has Windows-style line endings (CRLF) instead of Unix line endings (LF). This happens when the file was edited or transferred from a Windows system.

**Solution:**
```bash
# Fix line endings with sed
sed -i 's/\r$//' ./update-containers.sh

# Or install and use dos2unix
sudo apt install dos2unix
dos2unix ./update-containers.sh
```

**Prevention:** The repository includes a `.gitattributes` file that ensures correct line endings when cloning. If you manually copy files, always convert line endings.

---

#### 2. "This script must be run as root"

**Problem:** Script executed without sudo.

**Solution:**
```bash
# Always use sudo
sudo ./update-containers.sh
```

---

#### 3. "Docker is not installed" or "Docker daemon is not running"

**Problem:** Docker not installed or not started.

**Solution:**
```bash
# Check Docker status
sudo systemctl status docker

# Start Docker
sudo systemctl start docker

# Enable Docker to start automatically
sudo systemctl enable docker

# Install Docker (if not installed)
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh
```

---

#### 4. "No docker-compose directory found"

**Problem:** Script cannot find the compose directory.

**Possible causes:**
- Container not started via docker-compose
- Compose file in unexpected location
- Container name doesn't match directory name

**Solution:**
```bash
# Check how container was started
docker inspect <container-name> | grep -i compose

# Find where compose file is
find ~ /opt /srv -name "docker-compose.yml" -o -name "docker-compose.yaml" 2>/dev/null

# Move compose files to standard location
mkdir -p ~/docker/<container-name>
mv /path/to/docker-compose.yml ~/docker/<container-name>/

# Or edit the script to add your location
# Edit line 208 in update-containers.sh
```

---

#### 5. "Container not active after update"

**Problem:** Container doesn't start after update.

**Possible causes:**
- New image has breaking changes
- Port conflict
- Volume/bind mount issues
- Network configuration problems

**Solution:**
```bash
# Check container logs
docker logs <container-name>

# Check if port is already in use
sudo netstat -tulpn | grep <port-number>

# Try manual start
cd ~/docker/<container-name>
docker compose up

# If that doesn't work, rollback to old image
docker compose down
docker pull <old-image-version>
# Update compose file with old version
docker compose up -d
```

---

#### 6. Container starts but doesn't work correctly

**Problem:** Container is running but not functioning.

**Diagnostics:**
```bash
# Check logs
docker logs <container-name> --tail 100

# Check resource usage
docker stats <container-name>

# Check network
docker network inspect <network-name>

# Enter container for debugging
docker exec -it <container-name> /bin/bash
# or
docker exec -it <container-name> /bin/sh
```

---

#### 7. "Permission denied" errors

**Problem:** No access to files/directories.

**Solution:**
```bash
# Ensure log directory exists and is accessible
sudo mkdir -p /var/log/docker-updates
sudo chmod 755 /var/log/docker-updates

# Ensure script is executable
chmod +x update-containers.sh

# Check file permissions of compose directories
ls -la ~/docker/
```

---

#### 8. Script hangs/freezes

**Problem:** Script seems to freeze.

**Possible causes:**
- Docker pull takes long (large image)
- Network issues
- Container shutdown takes long

**Solution:**
```bash
# Check if process is active
ps aux | grep update_containers

# Check Docker operations
docker ps -a
docker images

# Check network
ping 8.8.8.8
ping registry.hub.docker.com

# If really stuck, kill the process
sudo pkill -f update-containers.sh

# Check and cleanup any leftover containers
docker ps -a
docker compose down  # in relevant directories
```

---

#### 8. Cron job doesn't work

**Problem:** Automatic updates not executing.

**Diagnostics:**
```bash
# Check if cron service is active
sudo systemctl status cron

# Check crontab entries
sudo crontab -l

# Check syslog for cron execution
sudo grep CRON /var/log/syslog | tail -20

# Check cron logs
sudo tail -f /var/log/docker-updates/cron.log
```

**Solution:**
```bash
# Start cron service
sudo systemctl start cron
sudo systemctl enable cron

# Ensure script uses full paths
# Instead of: ./update-containers.sh
# Use: /full/path/to/update-containers.sh

# Ensure PATH variable is correct in crontab
sudo crontab -e
# Add at top:
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Test cron entry manually
sudo /usr/local/bin/docker-update-auto
```

---

### Debug Mode

For extra debug information, add `-x` to shebang:

```bash
# Edit update-containers.sh
# Change first line from:
#!/bin/bash

# To:
#!/bin/bash -x

# Now it shows every executed command
```

---

## Security

### Important Considerations

**✅ What the script DOES:**
- Verifies Docker installation and status
- Detailed logging of all actions
- Rollback attempt on errors (tries to restart container)
- Verification after update if container is active

**⚠️ What the script DOES NOT do:**
- **No automatic backups** of volumes/data
  - Make your own backups for production!
- **No health checks** of applications
  - Container may run but app could be broken
- **No rollback** to old image on application errors
  - Only on start failures
- **No notifications** on errors
  - Consider integration with monitoring tools

### Recommendations for Production

**Before using this script in production:**

1. **Make Backups**
   ```bash
   # Backup Docker volumes
   docker run --rm -v <volume-name>:/data -v $(pwd):/backup \
     ubuntu tar czf /backup/volume-backup.tar.gz /data
   ```

2. **Test First**
   - Test updates on development/staging environment
   - Use specific version tags instead of `latest`
   - Read release notes of new versions

3. **Monitoring**
   ```bash
   # Use health checks in compose files
   healthcheck:
     test: ["CMD", "curl", "-f", "http://localhost"]
     interval: 30s
     timeout: 10s
     retries: 3
   ```

4. **Notifications**
   - Integrate with Telegram/Slack for alerts
   - Setup email notifications via cron
   - Use monitoring tools (Netdata, Prometheus, etc.)

### Data Safety

**Volumes are NOT removed:**
- Docker volumes remain intact during updates
- Only container and image are replaced
- Data in volumes is safe

**But be aware:**
- Bind mounts depend on compose configuration
- Breaking changes in new versions may alter data structure
- Always make backups for critical data!

---

## Advanced Usage

### Custom Compose Locations

If you have compose files in other locations:

```bash
# Edit update-containers.sh
# Find function: find_compose_dir (around line 204)

# Add your custom directories to common_dirs array:
local common_dirs=(
    "$HOME/docker"
    "/home/*/docker"
    "/opt/docker"
    "/srv/docker"
    "/your/custom/path/docker"    # Add here
    "/another/path/containers"    # Or here
)
```

### Selective Updates per Type

You can create different cron jobs for different container types:

```bash
# Database updates - monthly, extra careful
0 4 1 * * /usr/local/bin/update-databases.sh

# Webserver updates - weekly
0 3 * * 0 /usr/local/bin/update-webservers.sh

# Monitoring tools - daily
0 2 * * * /usr/local/bin/update-monitoring.sh
```

---

## Support and Contributing

### Need Help?

- **Issues:** [GitHub Issues](https://github.com/MadeByAdem/linux-server-management-scripts/issues)
- **Questions:** Check this README and Troubleshooting section first

### Contributing

Contributions are welcome!

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/AmazingFeature`)
3. Commit your changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

---

## Changelog

### Version 2.0 (2024-02-15)
- **Mode-based operation**
  - `--interactive` mode - manually select containers
  - `--unattended` mode - automatically update all containers
  - `--dry-run` mode - preview changes without executing
  - `--update-system` flag for system package updates
  - Modes can be combined (e.g., `--interactive --dry-run`)
- **Improved argument parsing**
  - Clear help messages shown when no mode specified
  - Better error handling
  - Helpful suggestions when arguments are missing or invalid
- **Enhanced automation support**
  - Perfect for cron jobs with unattended mode
  - System updates can be included via flag
  - Dry-run for testing automation scripts
- **Dry-run reporting**
  - Shows all planned actions without making changes
  - Generates detailed report file
  - Perfect for testing and verification
- Updated documentation with all mode examples

### Version 1.0 (2024-01-15)
- Initial release
- Interactive container selection
- Automatic compose directory detection
- Visual feedback with colors and symbols
- Comprehensive logging
- Update summary
- Error handling and rollback
- System package update feature
- Optional `apt-get update && upgrade` before container updates
- System update tracking in summary

---

## License

MIT License - see [LICENSE.md](LICENSE.md)

**What this means:**
- ✅ Free to use
- ✅ Can be modified
- ✅ Can be shared
- ✅ Commercial use allowed
- ⚠️ Use at your own risk (no warranties)

---

## Credits

**Developed by:** MadeByAdem

**Built with:**
- Bash scripting
- Docker & Docker Compose
- Linux utilities

**Related:**

- [Server Baseline Script](../server-baseline/) - Comprehensive server setup and hardening

---

## Disclaimer

**USE AT YOUR OWN RISK**

This script is a tool for Docker container management. The authors are not responsible for:
- Data loss
- Service downtime
- Update issues
- Any other damage

**Recommendations:**
- ✅ Always make backups before production use
- ✅ Test first in development environment
- ✅ Read full documentation
- ✅ Understand what each section does

For enterprise/critical systems, consult a professional DevOps engineer.

---

**Good luck updating your containers!** 🐳🚀

If you find this script useful, give it a ⭐ on GitHub!
