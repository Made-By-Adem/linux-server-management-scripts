# Server Management Scripts

A collection of professional bash scripts for Ubuntu/Debian server management, automation, and Docker container maintenance.

## 📦 What's Inside?

This repository contains two main toolsets:

### 1. [Server Baseline Setup](server-baseline/)

**Purpose:** Fresh server installation and hardening automation

A comprehensive script for setting up and securing new Ubuntu/Debian servers (including Raspberry Pi). Features interactive mode for existing servers and fresh-install mode for new deployments.

**Key Features:**

- **17 Advanced Security Hardening Layers** (NEW in v4.0, Enhanced in v4.1 - Based on Lynis recommendations)
  - Security repository verification
  - Password policies & PAM hardening (SHA-512 with 65536 rounds + password aging)
  - Extended kernel hardening (15+ sysctl parameters)
  - USB storage control, core dump protection
  - File permissions, legal banners, /proc hardening
  - SSH MaxSessions configuration, Fail2ban best practices
  - Systemd service hardening (PrivateTmp=no for Lynis/Rkhunter manual execution)
  - Sysstat monitoring, AIDE file integrity with SHA-512 checksums (production)
  - Compiler restrictions, residual config cleanup
- System hardening and security configuration
- Automated user setup with SSH keys
- Firewall configuration (UFW)
- Fail2ban installation and configuration
- Docker and Docker Compose installation
- Optional services: Portainer, Netdata, Cloudflare Tunnel
- Resume capability for interrupted installations
- Backwards compatibility (safe re-run on existing installations)
- Dry-run mode for testing

**Use Cases:**

- Setting up new servers from scratch
- Hardening existing servers
- Standardizing server configurations
- Automated deployments

[→ Full Documentation](server-baseline/README.md)

---

### 2. [Docker Container Updates](update-containers/)

**Purpose:** Safe and automated Docker container updates

A smart script for updating Docker containers managed by Docker Compose. Supports both manual (interactive) and automated (unattended) workflows.

**Key Features:**

- Interactive container selection
- Automatic updates for all containers
- System package updates (apt)
- Dry-run mode for testing
- Comprehensive logging
- Error handling with rollback
- Preserves container state (stopped containers stay stopped)
- Visual progress indicators

**Use Cases:**

- Regular container maintenance
- Security updates automation
- Selective container updates
- Scheduled cron jobs

[→ Full Documentation](update-containers/README.md)

---

### 3. [Remote Folder Backup](backup-script/)

**Purpose:** Pull folders from a remote server via rsync

A backup script that syncs specified folders from a remote server to the local machine over a single SSH connection. Configurable via a simple `.env` file.

**Key Features:**

- Configurable folder list via `.env`
- Single SSH connection (multiplexing)
- Rsync with `--delete` for exact mirrors
- Automatic backup directory naming (`backup-<hostname>`)

**Use Cases:**

- Scheduled remote server backups
- Pulling Docker volumes and configs from production
- Disaster recovery preparation

[→ Full Documentation](backup-script/README.md)

---

## 🚀 Quick Start

### Server Baseline Setup

```bash
# Fresh server installation
cd server-baseline
sudo bash install-script.sh --fresh-install

# Interactive mode (existing server)
sudo bash install-script.sh --interactive

# Dry-run (preview changes)
sudo bash install-script.sh --dry-run
```

### Docker Container Updates

```bash
# Interactive mode (select containers manually)
cd update-containers
sudo bash update-containers.sh --interactive

# Unattended mode (update all containers)
sudo bash update-containers.sh --unattended

# With system updates
sudo bash update-containers.sh --unattended --update-system
```

### Remote Folder Backup

```bash
# Configure .env first, then run:
cd backup-script
bash backup.sh

# Or if installed system-wide:
backup-folders
```

---

## 📋 Requirements

### System Requirements

- **OS:** Ubuntu 20.04+ or Debian 11+ (including Raspberry Pi OS)
- **Privileges:** Root/sudo access required
- **Shell:** Bash 4.0+

### For Container Updates

- Docker Engine installed
- Docker Compose V2 (plugin)
- Containers managed via `docker-compose.yml` files

---

## 🔧 Installation

### Clone the Repository

```bash
# Clone to your server
git clone https://github.com/MadeByAdem/linux-server-management-scripts.git
cd linux-server-management-scripts
```

### Make Scripts Executable

```bash
# Server baseline
chmod +x server-baseline/install-script.sh

# Container updates
chmod +x update-containers/update-containers.sh

# Folder backup
chmod +x backup-script/backup.sh
```

### Optional: Install System-Wide

```bash
# Server baseline
sudo cp server-baseline/install-script.sh /usr/local/bin/server-setup
sudo chmod +x /usr/local/bin/server-setup

# Container updates
sudo cp update-containers/update-containers.sh /usr/local/bin/update-containers
sudo chmod +x /usr/local/bin/update-containers

# Folder backup (symlink so it finds .env)
sudo ln -sf $(pwd)/backup-script/backup.sh /usr/local/bin/backup-folders

# Now you can run from anywhere:
sudo server-setup --help
sudo update-containers --help
backup-folders
```

---

## 📖 Common Workflows

### Scenario 1: New Server Setup

> [!IMPORTANT]
> If you already cloned the repository in the [Installation](#-installation) section above, **skip step 1** and just run `cd server-baseline` from inside the `linux-server-management-scripts` directory. Running `git clone` again will either fail or create a nested duplicate of the repo.

```bash
# 1. Clone repository (skip if already cloned)
git clone https://github.com/MadeByAdem/linux-server-management-scripts.git
cd linux-server-management-scripts/server-baseline

# If you already cloned it earlier, just run this instead:
# cd server-baseline

# 2. Run fresh installation
sudo bash install-script.sh --fresh-install

# 3. Follow the interactive prompts
# - Creates user with sudo access
# - Sets up SSH keys
# - Configures firewall
# - Installs Docker
# - Optional: Portainer, Netdata, etc.
```

### Scenario 2: Weekly Container Updates

```bash
# Set up automated weekly updates
sudo crontab -e

# Add this line for Sunday 3 AM updates:
0 3 * * 0 /path/to/linux-server-management-scripts/update-containers/update-containers.sh --unattended --update-system >> /var/log/docker-updates/cron.log 2>&1
```

### Scenario 3: Manual Container Maintenance

```bash
# Update specific containers interactively
cd linux-server-management-scripts/update-containers
sudo bash update-containers.sh --interactive

# Preview changes first
sudo bash update-containers.sh --dry-run

# Then run the actual update
sudo bash update-containers.sh --interactive
```

---

## 🔍 Features Comparison

| Feature              | Server Baseline | Container Updates      |
| -------------------- | --------------- | ---------------------- |
| Fresh installation   | ✅              | ❌                     |
| Interactive mode     | ✅              | ✅                     |
| Unattended mode      | ❌              | ✅                     |
| Dry-run mode         | ✅              | ✅                     |
| Resume capability    | ✅              | ❌                     |
| System updates       | ✅              | ✅                     |
| Docker installation  | ✅              | ❌ (requires existing) |
| Container management | ❌              | ✅                     |
| Security hardening   | ✅              | ❌                     |
| Logging              | ✅              | ✅                     |

---

## 🛡️ Security

Both scripts follow security best practices:

- **Minimal privileges:** Only request sudo when needed
- **Input validation:** All user inputs are sanitized
- **Safe defaults:** Secure configurations out of the box
- **Backup creation:** Critical files backed up before changes
- **Audit logging:** All actions logged for review
- **Error handling:** Graceful failure with rollback support

### Security Features (Server Baseline)

- SSH hardening (disable root login, password auth)
- UFW firewall configuration
- Fail2ban intrusion prevention
- Automatic security updates
- HTTPS-only package downloads

### Security Features (Container Updates)

- Only updates running containers
- Preserves stopped container state
- Rollback on failure
- Comprehensive logging
- No destructive operations without confirmation

---

## 📊 Logging

Both scripts provide detailed logging:

### Server Baseline

- **Location:** `/var/log/server_install_[timestamp].log`
- **State file:** `/var/lib/server-setup/installation.state`
- **Backups:** `/var/backups/server-setup-backup-[timestamp]/`

### Container Updates

- **Location:** `/var/log/docker-updates/update_[timestamp].log`
- **Dry-run reports:** `/tmp/docker-update-dryrun-[timestamp].txt`

---

## 🐛 Troubleshooting

### Common Issues

**"unable to execute ./script.sh: No such file or directory"**

```bash
# This error occurs when scripts have Windows line endings (CRLF)
# Fix with sed:
sed -i 's/\r$//' ./script.sh

# Or use dos2unix:
sudo apt install dos2unix
dos2unix ./script.sh
```

**Script requires sudo**

```bash
# Always run with sudo
sudo bash script.sh --mode
```

**Docker not found (Container Updates)**

```bash
# Install Docker first using server baseline
cd server-baseline
sudo bash install-script.sh --interactive
# Select Docker installation when prompted
```

**Permission denied errors**

```bash
# Ensure scripts are executable
chmod +x server-baseline/install-script.sh
chmod +x update-containers/update-containers.sh
```

**Container not found error**

```bash
# Container must be managed by docker-compose
# Ensure docker-compose.yml exists in standard locations:
# - ~/docker/[service]/
# - /opt/docker/[service]/
# - /srv/docker/[service]/
```

For more specific troubleshooting, see individual README files:

- [Server Baseline Troubleshooting](server-baseline/README.md#troubleshooting)
- [Container Updates Troubleshooting](update-containers/README.md#troubleshooting)

---


## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

**In short:**

- ✅ Free to use, modify, and distribute
- ✅ Use in commercial projects
- ✅ Modify however you want
- 📋 Must include license and copyright notice
- ❌ No warranty or liability

---

## ⚠️ Disclaimer

**USE AT YOUR OWN RISK**

These scripts modify system configurations and perform administrative tasks. While designed with safety in mind:

- **Test in development first:** Always use `--dry-run` mode before production
- **Understand what you're running:** Read the documentation
- **Backups are your friend:** Scripts create backups, but maintain your own too
- **No guarantees:** We're not responsible for data loss or downtime

For enterprise or critical systems, consult a professional DevOps engineer.

---

## 📚 Additional Resources

### Documentation

- [Server Baseline Setup](server-baseline/README.md)
- [Backup script](backup-script/README.md)
- [Docker Container Updates - Full Guide](update-containers/README.md)

### Useful Links

- [Docker Documentation](https://docs.docker.com/)
- [Docker Compose Documentation](https://docs.docker.com/compose/)
- [Ubuntu Server Guide](https://ubuntu.com/server/docs)
- [Debian Administrator&#39;s Handbook](https://www.debian.org/doc/manuals/debian-handbook/)

---

## 🌟 Acknowledgments

Built with focus on:

- **Safety:** Extensive error handling and validation
- **Usability:** Clear output with colors and symbols
- **Reliability:** Tested on Ubuntu 20.04+, Debian 11+, Raspberry Pi OS
- **Maintainability:** Well-documented, modular code

---

**Made with ❤️ by MadeByAdem**

If you find these scripts useful, consider giving this repository a ⭐ on GitHub!
