# Linux Server Management Scripts

A collection of professional bash scripts for Ubuntu/Debian server management, automation, and Docker container maintenance.

> Made By Adem

## What's Inside

This repository contains two main toolsets:

### 1. [Server Baseline Setup](server_baseline/)

Automated server hardening for Ubuntu/Debian and Raspberry Pi.

**Key Features:**

- 4 simple options: `--interactive`, `--ubuntu-vps`, `--raspberry-pi`, `--dry-run`
- All questions asked upfront - then runs without interruption
- Profile-based configuration (Ubuntu VPS vs Raspberry Pi)
- Telegram alerts for security notifications

**Security:**

- SSH hardening (custom port, key-only auth)
- UFW firewall & Fail2ban intrusion prevention
- Rkhunter rootkit scanner & Lynis security auditing
- AIDE file integrity monitoring (Ubuntu VPS only)
- Kernel hardening (sysctl) & process hiding

**Services:**

- Docker & Portainer (Docker web UI)
- Netdata monitoring
- Cloudflare Tunnel (optional)
- Unattended security upgrades

**Quick Start:**

```bash
cd server_baseline
sudo bash set-serverbaseline.sh --interactive
```

[→ Full Documentation](server_baseline/README.md)

---

### 2. [Docker Container Updates](update-containers/)

Safe and automated Docker container updates with Docker Compose support.

**Key Features:**

- Interactive container selection
- Automatic updates for all containers
- System package updates (apt)
- Dry-run mode for testing
- Comprehensive logging
- Error handling with rollback

**Quick Start:**

```bash
cd update-containers
sudo bash update-containers.sh --interactive
```

[→ Full Documentation](update-containers/README.md)

---

## Quick Start

### Server Baseline Setup

```bash
# Interactive mode (recommended)
cd server_baseline
sudo bash set-serverbaseline.sh --interactive

# Ubuntu VPS with production defaults
sudo bash set-serverbaseline.sh --ubuntu-vps

# Raspberry Pi optimized
sudo bash set-serverbaseline.sh --raspberry-pi

# Preview changes
sudo bash set-serverbaseline.sh --dry-run --ubuntu-vps
```

### Docker Container Updates

```bash
# Interactive mode
cd update-containers
sudo bash update-containers.sh --interactive

# Unattended mode (update all)
sudo bash update-containers.sh --unattended

# With system updates
sudo bash update-containers.sh --unattended --update-system
```

---

## Requirements

- **OS:** Ubuntu 20.04+ or Debian 11+ (including Raspberry Pi OS)
- **Privileges:** Root/sudo access required
- **Shell:** Bash 4.0+

### For Container Updates

- Docker Engine installed
- Docker Compose V2 (plugin)
- Containers managed via `docker-compose.yml` files

---

## Features Comparison

| Feature | Server Baseline | Container Updates |
|---------|----------------|-------------------|
| Fresh installation | Yes | No |
| Interactive mode | Yes | Yes |
| Unattended mode | Yes | Yes |
| Dry-run mode | Yes | Yes |
| Resume capability | Yes | No |
| System updates | Yes | Yes |
| Docker installation | Yes | No (requires existing) |
| Container management | No | Yes |
| Security hardening | Yes | No |

---

## Directory Structure

```text
linux-server-management-scripts/
├── README.md                    # This file
├── server_baseline/             # Server setup & hardening
│   ├── set-serverbaseline.sh    # Main script
│   ├── config/                  # Configuration profiles
│   └── modules/                 # Modular components
└── update-containers/           # Docker container updates
    └── update-containers.sh     # Update script
```

---

## Security

Both scripts follow security best practices:

- Minimal privileges: Only request sudo when needed
- Input validation: All user inputs are sanitized
- Safe defaults: Secure configurations out of the box
- Backup creation: Critical files backed up before changes
- Audit logging: All actions logged for review
- Error handling: Graceful failure with rollback support

---

## Logging

### Server Baseline

- **Log:** `/var/log/server_baseline_[timestamp].log`
- **State:** `/var/lib/server-setup/installation.state`
- **Backups:** `/var/backups/server-setup-backup-[timestamp]/`

### Container Updates

- **Log:** `/var/log/docker-updates/update_[timestamp].log`
- **Dry-run:** `/tmp/docker-update-dryrun-[timestamp].txt`

---

## Troubleshooting

**Script requires sudo:**

```bash
sudo bash script.sh --mode
```

**Docker not found:**

```bash
# Install Docker using server baseline first
cd server_baseline
sudo bash set-serverbaseline.sh --interactive
```

**Permission denied:**

```bash
chmod +x server_baseline/set-serverbaseline.sh
chmod +x update-containers/update-containers.sh
```

For detailed troubleshooting:

- [Server Baseline Troubleshooting](server_baseline/README.md#troubleshooting)
- [Container Updates Troubleshooting](update-containers/README.md#troubleshooting)

---

## Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/AmazingFeature`)
3. Make your changes
4. Test with `--dry-run` mode
5. Commit (`git commit -m 'Add AmazingFeature'`)
6. Push (`git push origin feature/AmazingFeature`)
7. Open a Pull Request

---

## License

MIT License - see [LICENSE](LICENSE) for details.

---

## Disclaimer

**USE AT YOUR OWN RISK**

These scripts modify system configurations. Always:

- Test with `--dry-run` first
- Maintain your own backups
- Understand what you're running

For enterprise systems, consult a professional.

---

Made with care by Adem
