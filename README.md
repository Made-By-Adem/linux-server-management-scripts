# Server Management Scripts

A collection of professional bash scripts for Ubuntu/Debian server management, automation, and Docker container maintenance.

## 📦 What's Inside

This repository contains two main toolsets:

### 1. [Server Baseline Setup](server_baseline/)
**Purpose:** Fresh server installation and hardening automation

A comprehensive script for setting up and securing new Ubuntu/Debian servers (including Raspberry Pi). Features interactive mode for existing servers and fresh-install mode for new deployments.

**Key Features:**
- System hardening and security configuration
- Automated user setup with SSH keys
- Firewall configuration (UFW)
- Fail2ban installation and configuration
- Docker and Docker Compose installation
- Optional services: Portainer, Netdata, Cloudflare Tunnel
- Resume capability for interrupted installations
- Dry-run mode for testing

**Use Cases:**
- Setting up new servers from scratch
- Hardening existing servers
- Standardizing server configurations
- Automated deployments

[→ Full Documentation](server_baseline/README.md)

---

### 2. [Docker Container Updates](update_docker_containers/)
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

[→ Full Documentation](update_docker_containers/README.md)

---

## 🚀 Quick Start

### Server Baseline Setup

```bash
# Fresh server installation
cd server_baseline
sudo bash install_script.sh --fresh-install

# Interactive mode (existing server)
sudo bash install_script.sh --interactive

# Dry-run (preview changes)
sudo bash install_script.sh --dry-run
```

### Docker Container Updates

```bash
# Interactive mode (select containers manually)
cd update_docker_containers
sudo bash update_containers.sh --interactive

# Unattended mode (update all containers)
sudo bash update_containers.sh --unattended

# With system updates
sudo bash update_containers.sh --unattended --update-system
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
git clone https://github.com/MadeByAdem/Scripts.git
cd Scripts
```

### Make Scripts Executable

```bash
# Server baseline
chmod +x server_baseline/install_script.sh

# Container updates
chmod +x update_docker_containers/update_containers.sh
```

### Optional: Install System-Wide

```bash
# Server baseline
sudo cp server_baseline/install_script.sh /usr/local/bin/server-setup
sudo chmod +x /usr/local/bin/server-setup

# Container updates
sudo cp update_docker_containers/update_containers.sh /usr/local/bin/docker-update
sudo chmod +x /usr/local/bin/docker-update

# Now you can run from anywhere:
sudo server-setup --help
sudo docker-update --help
```

---

## 📖 Common Workflows

### Scenario 1: New Server Setup

```bash
# 1. Clone repository
git clone https://github.com/MadeByAdem/Scripts.git
cd Scripts/server_baseline

# 2. Run fresh installation
sudo bash install_script.sh --fresh-install

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
0 3 * * 0 /path/to/Scripts/update_docker_containers/update_containers.sh --unattended --update-system >> /var/log/docker-updates/cron.log 2>&1
```

### Scenario 3: Manual Container Maintenance

```bash
# Update specific containers interactively
cd Scripts/update_docker_containers
sudo bash update_containers.sh --interactive

# Preview changes first
sudo bash update_containers.sh --dry-run

# Then run the actual update
sudo bash update_containers.sh --interactive
```

---

## 🔍 Features Comparison

| Feature | Server Baseline | Container Updates |
|---------|----------------|-------------------|
| Fresh installation | ✅ | ❌ |
| Interactive mode | ✅ | ✅ |
| Unattended mode | ❌ | ✅ |
| Dry-run mode | ✅ | ✅ |
| Resume capability | ✅ | ❌ |
| System updates | ✅ | ✅ |
| Docker installation | ✅ | ❌ (requires existing) |
| Container management | ❌ | ✅ |
| Security hardening | ✅ | ❌ |
| Logging | ✅ | ✅ |

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

**Script requires sudo**
```bash
# Always run with sudo
sudo bash script.sh --mode
```

**Docker not found (Container Updates)**
```bash
# Install Docker first using server baseline
cd server_baseline
sudo bash install_script.sh --interactive
# Select Docker installation when prompted
```

**Permission denied errors**
```bash
# Ensure scripts are executable
chmod +x server_baseline/install_script.sh
chmod +x update_docker_containers/update_containers.sh
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
- [Server Baseline Troubleshooting](server_baseline/README.md#troubleshooting)
- [Container Updates Troubleshooting](update_docker_containers/README.md#troubleshooting)

---

## 🤝 Contributing

Contributions are welcome! Here's how:

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/AmazingFeature`)
3. Make your changes
4. Test thoroughly (use `--dry-run` mode)
5. Commit with clear messages (`git commit -m 'Add AmazingFeature'`)
6. Push to your branch (`git push origin feature/AmazingFeature`)
7. Open a Pull Request

### Contribution Guidelines
- Follow existing code style and patterns
- Add comments for complex logic
- Update documentation for new features
- Test on Ubuntu/Debian before submitting
- Include error handling
- Use `set -e`, `set -u`, `set -o pipefail` for safety

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
- [Server Baseline Setup - Full Guide](server_baseline/README.md)
- [Docker Container Updates - Full Guide](update_docker_containers/README.md)

### Useful Links
- [Docker Documentation](https://docs.docker.com/)
- [Docker Compose Documentation](https://docs.docker.com/compose/)
- [Ubuntu Server Guide](https://ubuntu.com/server/docs)
- [Debian Administrator's Handbook](https://www.debian.org/doc/manuals/debian-handbook/)

---

## 💡 Support

- **Issues:** [GitHub Issues](https://github.com/MadeByAdem/Scripts/issues)
- **Discussions:** [GitHub Discussions](https://github.com/MadeByAdem/Scripts/discussions)
- **Documentation:** Individual README files in each directory

---

## 🎯 Roadmap

### Planned Features
- [ ] Support for other init systems (systemd, OpenRC)
- [ ] RPM-based distro support (CentOS, RHEL, Fedora)
- [ ] Container backup before updates
- [ ] Email notifications for automated updates
- [ ] Web dashboard for management
- [ ] Multi-server orchestration

### Under Consideration
- Docker Swarm/Kubernetes support
- Automated SSL certificate management
- Database backup integration
- Monitoring and alerting
- Configuration management (Ansible integration)

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
