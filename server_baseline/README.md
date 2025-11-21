# Server Baseline

Automated server hardening for Ubuntu/Debian and Raspberry Pi.

> Made By Adem

## Table of Contents

1. [Quick Start](#quick-start)
- [Options](#options)
- [Profile Comparison](#profile-comparison)
- [What Gets Installed](#what-gets-installed)
- [After Installation](#after-installation)
2. [Detailed Features](#detailed-features)
- [Configuration Questions](#configuration-questions)
- [Telegram Alerts](#telegram-alerts)
- [Directory Structure](#directory-structure)
- [Requirements](#requirements)
- [FAQ](#faq)
- [Troubleshooting](#troubleshooting)
- [License](#license)

---

# 1. Quick Start

```bash
# Interactive mode (recommended for first-time setup)
sudo bash set-serverbaseline.sh --interactive

# Ubuntu VPS with production defaults
sudo bash set-serverbaseline.sh --ubuntu-vps

# Raspberry Pi optimized settings
sudo bash set-serverbaseline.sh --raspberry-pi

# Preview changes without applying
sudo bash set-serverbaseline.sh --dry-run --ubuntu-vps
```

## Options

| Option | Description |
|--------|-------------|
| `--interactive` | Ask all questions upfront with explanations |
| `--ubuntu-vps` | Production Ubuntu settings (strict security) |
| `--raspberry-pi` | Lightweight ARM settings (SD card-friendly) |
| `--dry-run` | Show what would happen without making changes |

## Profile Comparison

| Setting | Ubuntu VPS | Raspberry Pi |
|---------|------------|--------------|
| Password expiry | 90 days | 365 days |
| SSH max sessions | 2 | 3 |
| Fail2ban ban time | 2 hours | 1 hour |
| AIDE | Enabled | Disabled |
| Journald max size | 500MB | 100MB |

## What Gets Installed

**Security:**

- SSH hardening (custom port, key-only auth)
- UFW firewall
- Fail2ban intrusion prevention
- Rkhunter rootkit scanner
- Lynis security auditing
- Legal warning banners
- Kernel hardening (sysctl)
- Process hiding (hidepid=2)

**Services:**

- Docker
- Portainer (Docker web UI)
- Netdata monitoring
- Cloudflare Tunnel (optional)

**System:**

- Unattended security upgrades
- Journald log rotation
- Systemd service hardening

## After Installation

1. **Test SSH on new port before disconnecting:**

   ```bash
   ssh -p 888 user@server-ip
   ```

2. **If SSH works, remove old port 22:**

   ```bash
   sudo sed -i '/^Port 22$/d' /etc/ssh/sshd_config
   sudo systemctl restart ssh
   ```

3. **Log out and back in** to activate docker group

---

# 2. Detailed Features

### SSH Hardening

The script applies comprehensive SSH hardening:

- **Custom port**: Moves SSH from port 22 to 888 (configurable)
- **Key-only authentication**: Disables password login for improved security
- **Rate limiting**: Limits authentication attempts
- **Configurable MaxSessions**: Control concurrent SSH sessions (default: 2 for Ubuntu, 3 for Pi)
- **Disabled root login**: Root cannot login directly via SSH
- **Secure algorithms**: Only strong ciphers and MACs enabled

### Firewall (UFW)

Automatic firewall configuration:

- Default deny incoming, allow outgoing
- Opens only required ports (SSH, HTTP, HTTPS, Portainer, Netdata)
- Rate limiting on SSH port
- IPv6 support (optional)

### Fail2ban

Intrusion prevention system:

- Monitors SSH login attempts
- Bans IPs after failed attempts (configurable retries)
- Ban duration: 2 hours (Ubuntu) or 1 hour (Raspberry Pi)
- Automatically unbans after timeout

### Kernel Hardening

Applies sysctl security settings:

- IP spoofing protection
- SYN flood protection
- ICMP redirect blocking
- Source routing disabled
- Martian packet logging
- Memory protections (ASLR, etc.)

### Security Scanning

**Rkhunter (Rootkit Hunter):**

- Daily scans for rootkits, backdoors, and exploits
- Telegram alerts on suspicious findings
- Automatic database updates

**Lynis:**

- Comprehensive security auditing
- 200+ security checks
- Monthly reports via Telegram
- Hardening recommendations

### AIDE (File Integrity Monitoring)

- Monitors critical system files for changes
- SHA-512 checksums
- Daily integrity checks
- Only enabled on Ubuntu VPS (too I/O intensive for SD cards)

### Docker & Containers

- Docker Engine with Compose plugin
- Production-optimized logging (10MB max, 3 rotations)
- Automatic container restart on failure
- User added to docker group

### Monitoring (Netdata)

- Real-time system monitoring dashboard
- CPU, memory, disk, network metrics
- Docker container monitoring
- Telegram alerting integration
- Access via `http://server-ip:19999`

### Portainer

- Web-based Docker management
- No command line needed
- Container management, logs, shell access
- Access via `https://server-ip:9443`

### Cloudflare Tunnel

- Secure external access without port forwarding
- Free DDoS protection
- Custom domain support
- Zero-trust access

---

## Configuration Questions

During installation, the script asks questions in categories A-I:

### A. System Basics

- **Hostname**: Server name on the network
- **Domain**: Domain suffix (default: .local)
- **Timezone**: Your timezone (default: Europe/Amsterdam)

### B. Telegram Alerts (Optional)

- **Bot Token**: From @BotFather
- **Chat ID**: From @userinfobot
- Can be skipped and configured later

### C. SSH & Firewall

- **SSH Port**: Custom port (default: 888)
- **Key-only login**: Disable password authentication
- **MaxSessions**: Concurrent SSH sessions (1-10)
- **UFW**: Enable firewall
- **Systemd hardening**: Harden system services

### D. Cloudflare Tunnel (Optional)

- **Tunnel token**: From Cloudflare dashboard
- Can be skipped

### E. Fail2ban

- **Ban time**: How long to ban IPs (hours)
- **Max retries**: Failed attempts before ban

### F. Docker

- **Install Docker**: Yes/No
- Warning if Docker already exists

### G. Monitoring

- **Netdata**: Real-time monitoring via Docker
- **Journald**: Configure system logging

### H. Security Tooling

- **Rkhunter**: Rootkit scanner
- **AIDE**: File integrity monitoring
- **Unattended upgrades**: Automatic security updates

### I. Other Tools

- **Python3**: Programming language
- **Node.js**: JavaScript runtime
- **Git**: Version control
- **Portainer**: Docker web UI

---

## Telegram Alerts

Configure Telegram to receive security scan notifications:

1. Create a bot via [@BotFather](https://t.me/BotFather)
2. Get your chat ID from [@userinfobot](https://t.me/userinfobot)
3. Enter credentials during installation

**You'll receive alerts for:**

- Rkhunter: Daily at 03:00 (only on warnings)
- Lynis: Monthly security audit reports
- Netdata: Real-time system alerts

---

## Directory Structure

```
server_baseline/
├── set-serverbaseline.sh    # Main script
├── config/
│   ├── default.conf         # Default settings
│   ├── ubuntu.conf          # Ubuntu VPS profile
│   └── pi.conf              # Raspberry Pi profile
└── modules/
    ├── 00-core/             # Core utilities
    ├── 01-preflight/        # Questions system
    ├── 10-system/           # System configuration
    ├── 20-security/         # Security hardening
    ├── 30-network/          # Network & SSH
    ├── 40-services/         # Docker, Portainer, etc.
    ├── 50-monitoring/       # Rkhunter, Lynis, AIDE
    ├── 60-hardening/        # Systemd, journald
    └── 99-finalize/         # Cleanup & summary
```

---

## Requirements

### System Requirements

- **OS**: Ubuntu 20.04+ or Debian 11+
- **RAM**: Minimum 1GB (2GB recommended)
- **Disk**: Minimum 10GB free space
- **Network**: Internet connection required

### Access Requirements

- Root access (sudo)
- SSH key authentication configured
- Terminal access

### How to Set Up SSH Keys

**On Windows (PowerShell):**

```powershell
ssh-keygen -t ed25519 -C "your@email.com"
type $env:USERPROFILE\.ssh\id_ed25519.pub | ssh user@server "cat >> ~/.ssh/authorized_keys"
```

**On Mac/Linux:**

```bash
ssh-keygen -t ed25519 -C "your@email.com"
ssh-copy-id user@server
```

---

## FAQ

### General

**Q: How long does the installation take?**
A: Approximately 15-30 minutes, depending on internet speed and server specs.

**Q: Can I run the script multiple times?**
A: Yes. The script tracks completed modules and skips them on subsequent runs.

**Q: Does this cost money?**
A: No. Everything installed is free and open source.

### SSH

**Q: I locked myself out, what now?**
A: Use your VPS provider's console/VNC access, or physical access for local servers. Re-enable password authentication temporarily.

**Q: Can I keep port 22 open?**
A: Yes, but not recommended. Add `sudo ufw allow 22/tcp` if needed.

**Q: How do I change the SSH port later?**
A:

```bash
sudo nano /etc/ssh/sshd_config  # Change Port
sudo ufw allow NEW_PORT/tcp
sudo ufw delete allow 888/tcp
sudo systemctl restart ssh
```

### Docker

**Q: Docker commands require sudo?**
A: Log out and back in after installation. The script adds you to the docker group.

**Q: How do I update containers?**
A:

```bash
cd ~/docker/container-name
docker compose pull && docker compose up -d
```

### Security

**Q: How do I see banned IPs?**
A: `sudo fail2ban-client status sshd`

**Q: How do I unban an IP?**
A: `sudo fail2ban-client set sshd unbanip 1.2.3.4`

**Q: When do security scans run?**
A: Rkhunter daily at 03:00, Lynis monthly on the 1st at 04:00.

---

## Troubleshooting

### Connection refused on new SSH port

```bash
# Via console/VNC:
sudo systemctl status ssh
sudo ss -tlnp | grep ssh
sudo ufw status
sudo systemctl restart ssh
```

### Permission denied (publickey)

```bash
# Check key permissions:
chmod 700 ~/.ssh
chmod 600 ~/.ssh/authorized_keys

# Verify key is in authorized_keys:
cat ~/.ssh/authorized_keys
```

### Docker daemon not running

```bash
sudo systemctl status docker
sudo systemctl start docker
sudo systemctl enable docker
```

### Portainer not accessible

```bash
docker ps | grep portainer
docker logs portainer
sudo ufw status | grep 9443
```

### Check installation logs

```bash
sudo cat /var/log/server_baseline_*.log
sudo journalctl -xe
```

---

## License

MIT License - see [LICENSE.md](LICENSE.md)

---

**Need help?** Open an issue on GitHub or check the FAQ section above.
