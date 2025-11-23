# Server Baseline - Automated Server Installation & Hardening Script

> **Part of:** [Linux Server Management Scripts](https://github.com/MadeByAdem/linux-server-management-scripts)

A comprehensive, user-friendly installation script for Ubuntu/Debian servers that fully configures, secures, and optimizes your server with a single command.

## Table of Contents

- [Quickstart - Choose Your Scenario](#-quickstart---choose-your-scenario)
- [What Does This Script Do?](#what-does-this-script-do)
- [Section Safety Guide](#section-safety-guide)
- [Who Is This For?](#who-is-this-for)
- [What Does It Install?](#what-does-it-install)
- [Why These Installations?](#why-these-installations)
- [Security Measures](#security-measures)
- [Requirements](#requirements)
- [Installation](#installation)
- [Supported Platforms](#supported-platforms)
- [Important Warnings](#important-warnings)
- [Usage](#usage)
- [After Installation](#after-installation)
- [FAQ](#faq)
- [Troubleshooting](#troubleshooting)
- [License](#license)

---

## 🚀 Quickstart - Choose Your Scenario

| Scenario | Best Mode | Estimated Time |
|----------|-----------|----------------|
| [New Ubuntu Server](#scenario-1-new-ubuntu-server) | `--fresh-install` | 15-30 min |
| [Existing Ubuntu Server](#scenario-2-existing-ubuntu-server-in-use) | `--interactive` | 20-40 min |
| [New Raspberry Pi](#scenario-3-new-raspberry-pi) | `--fresh-install` | 20-45 min |
| [Existing Raspberry Pi](#scenario-4-existing-raspberry-pi-in-use) | `--section` | 15-30 min |

---

### Scenario 1: New Ubuntu Server

**Situation:** Fresh Ubuntu VPS or dedicated server, no services installed yet.

#### Prerequisites
```bash
# On your LOCAL machine - set up SSH key access first
ssh-keygen -t ed25519 -C "your@email.com"  # Skip if you already have a key
ssh-copy-id user@your-server-ip
```

#### Step-by-Step
```bash
# 1. Connect to your server
ssh user@your-server-ip

# 2. Download the script
git clone https://github.com/MadeByAdem/linux-server-management-scripts.git
cd linux-server-management-scripts/server-baseline

# 3. Run in fresh-install mode (minimal prompts)
sudo bash install-script.sh --fresh-install

# 4. IMPORTANT: Test new SSH port BEFORE closing this terminal!
#    Open a NEW terminal and test:
ssh -p 888 user@your-server-ip

# 5. If step 4 works, you can close port 22:
sudo sed -i '/^Port 22$/d' /etc/ssh/sshd_config
sudo systemctl restart ssh
```

#### Warnings for This Scenario
| Warning | Details |
|---------|---------|
| ⚠️ SSH Keys Required | Script disables password login - ensure your key works first |
| ⚠️ Keep Terminal Open | Don't close your SSH session until you've tested port 888 |
| ⚠️ Reboot Needed | Some kernel changes require a reboot to take effect |

---

### Scenario 2: Existing Ubuntu Server (In Use)

**Situation:** Ubuntu server already running services (web server, databases, applications), but NO Docker containers.

#### Prerequisites
```bash
# Ensure you have SSH key access (password will be disabled)
ssh-copy-id user@your-server-ip  # Skip if already done
```

#### Step-by-Step
```bash
# 1. Connect to your server
ssh user@your-server-ip

# 2. Download the script
git clone https://github.com/MadeByAdem/linux-server-management-scripts.git
cd linux-server-management-scripts/server-baseline

# 3. Preview what will happen (recommended!)
sudo bash install-script.sh --dry-run

# 4. Run in interactive mode - confirms each component
sudo bash install-script.sh --interactive

# 5. For each component, you'll see:
#    - Current status
#    - What will change
#    - Option to skip or proceed

# 6. Test new SSH port in a NEW terminal before closing this one
ssh -p 888 user@your-server-ip
```

#### Warnings for This Scenario
| Warning | Details |
|---------|---------|
| ⚠️ UFW Firewall | When asked, add any custom ports your services use (e.g., 3000, 8080) |
| ⚠️ Service Restarts | System updates may restart some services automatically |
| ⚠️ SSH Keys Required | Ensure your key works before SSH hardening section |
| ⚠️ Backup Created | Automatic backup at `/var/backups/server-setup-backup-*/` |

#### Services to Check After Installation
```bash
# Verify your services are still running
systemctl status nginx        # or apache2
systemctl status postgresql   # or mysql
systemctl status your-app
```

---

### Scenario 3: New Raspberry Pi

**Situation:** Fresh Raspberry Pi OS installation, no services configured yet.

#### Prerequisites
```bash
# On your LOCAL machine - set up SSH key access
ssh-keygen -t ed25519 -C "your@email.com"  # Skip if you already have a key
ssh-copy-id pi@raspberrypi.local           # or use IP address
```

#### Step-by-Step
```bash
# 1. Connect to your Pi
ssh pi@raspberrypi.local

# 2. Download the script
git clone https://github.com/MadeByAdem/linux-server-management-scripts.git
cd linux-server-management-scripts/server-baseline

# 3. Run in fresh-install mode
sudo bash install-script.sh --fresh-install

# 4. During installation, note these Pi-specific prompts:
#    - USB storage: Answer 'n' (Pi often boots from USB/SD)
#    - AIDE file integrity: Answer 'n' (causes SD card wear)
#    - Swap: Script auto-detects Pi and adjusts swap size

# 5. Test new SSH port in a NEW terminal
ssh -p 888 pi@raspberrypi.local

# 6. Reboot to apply all changes
sudo reboot
```

#### Warnings for This Scenario
| Warning | Details |
|---------|---------|
| ⚠️ SSH Keys Required | Script disables password login |
| ⚠️ USB Storage | Answer 'n' to USB blacklist - Pi may use USB storage |
| 🚫 **AIDE Monitoring** | **NEVER install on Raspberry Pi** - see warning below |
| ⚠️ Swap Size | Auto-configured for Pi's limited RAM |
| ⚠️ Slower Installation | Pi is slower than VPS - be patient |

> ### 🚫 CRITICAL: AIDE on Raspberry Pi
>
> **NEVER install AIDE on a Raspberry Pi!** The script will automatically skip AIDE on Pi hardware, but if you're asked:
>
> **ALWAYS answer 'n' (NO) to AIDE installation.**
>
> **Why AIDE is dangerous on Raspberry Pi:**
>
> - **SD Card Destruction**: AIDE performs massive disk I/O during initialization (10-20 min of continuous writes) and daily scans, drastically reducing SD card lifespan
> - **Filesystem Corruption**: Heavy I/O on flash storage causes EXT4 errors like `failed to convert unwritten extents to written extents` leading to potential data loss
> - **System Crashes**: AIDE initialization can cause bus errors, kernel panics, and system hangs on Pi hardware
> - **Resource Exhaustion**: Pi's limited RAM and I/O bandwidth cannot handle AIDE's full filesystem scans
>
> **Safe alternatives already included in this script:**
>
> - ✅ **rkhunter** - Lightweight rootkit detection
> - ✅ **Lynis** - Security auditing without heavy I/O
> - ✅ **debsums** - Package integrity verification (monthly, minimal I/O)

---

### Scenario 4: Existing Raspberry Pi (In Use)

**Situation:** Raspberry Pi already running Docker containers, Home Assistant, Pi-hole, media servers, or other services that MUST NOT be interrupted.

#### Prerequisites
```bash
# Ensure SSH key access
ssh-copy-id pi@raspberrypi.local  # Skip if already done

# Check what's currently running
ssh pi@raspberrypi.local
docker ps                          # List running containers
systemctl list-units --type=service --state=running
```

#### Step-by-Step
```bash
# 1. Connect to your Pi
ssh pi@raspberrypi.local

# 2. Download the script
git clone https://github.com/MadeByAdem/linux-server-management-scripts.git
cd linux-server-management-scripts/server-baseline

# 3. Preview ALL changes first
sudo bash install-script.sh --section --dry-run

# 4. Run with section selection (SAFEST approach)
sudo bash install-script.sh --section

# 5. When the menu appears, select ONLY safe sections:
#    Enter: 1 3 7 8 9 10 11 12 15 16 17 19
#
#    This includes:
#    1  - System updates
#    3  - Timezone
#    7  - Security repository
#    8  - Password hardening
#    9  - Deprecated cleanup
#    10 - Kernel hardening
#    11 - Core dump disable
#    12 - Umask hardening
#    15 - Fail2ban
#    16 - Lynis scanner
#    17 - Rkhunter scanner
#    19 - Audit logging

# 6. Reboot when convenient (not urgent)
sudo reboot
```

#### Sections to AVOID
| Section | Why Skip It |
|---------|-------------|
| **6 (docker)** | **WILL DESTROY ALL CONTAINERS AND DATA** |
| **13 (ssh-hardening)** | Only if you're sure about SSH keys |
| **14 (ufw-firewall)** | May block container ports - see below if needed |
| **18 (systemd-hardening)** | Restarts Docker = brief container downtime |
| **20-22 (containers)** | Only if you want these specific tools |

#### If You Want Firewall (Section 14)
```bash
# If you choose to run UFW, do this AFTER:

# 1. Check what ports your containers use
docker ps --format "table {{.Names}}\t{{.Ports}}"

# 2. Add rules for each container port
sudo ufw allow 8123/tcp comment 'Home Assistant'
sudo ufw allow 53/tcp comment 'Pi-hole DNS'
sudo ufw allow 53/udp comment 'Pi-hole DNS'
sudo ufw allow 80/tcp comment 'Pi-hole Web'
sudo ufw allow 32400/tcp comment 'Plex'
# Add more as needed...

# 3. Verify your containers still work
docker ps
```

#### If You Want SSH Hardening (Section 13)
```bash
# BEFORE running section 13:

# 1. Verify your SSH key works
ssh -i ~/.ssh/id_ed25519 pi@raspberrypi.local

# 2. Run section 13
sudo bash install-script.sh --section
# Enter: 13

# 3. KEEP THIS TERMINAL OPEN and test in new terminal:
ssh -p 888 pi@raspberrypi.local

# 4. Only close old terminal if step 3 works!
```

#### Warnings for This Scenario
| Warning | Details |
|---------|---------|
| 🚫 **NEVER Section 6** | Docker reinstall destroys ALL containers and volumes |
| ⚠️ Container Ports | If using UFW, manually add all container ports |
| ⚠️ Brief Restarts | Section 18 causes ~10 second container restart |
| ⚠️ Test SSH First | Before section 13, verify your key works |
| ✅ Backup Auto-Created | Rollback available at `/var/backups/server-setup-backup-*/` |

#### Verify After Installation
```bash
# Check all containers are still running
docker ps

# Check container logs for errors
docker logs <container-name>

# Check services
systemctl status docker
```

---

⚠️ **Need more details?** See the [Section Safety Guide](#section-safety-guide) for a complete breakdown of all 23 sections.

**⚠️ IMPORTANT:** This script contains **no hardcoded credentials or private endpoints**. All tokens and sensitive configuration are provided interactively by you during setup.

**🆕 NEW:** The script now supports three modes:
- `--fresh-install`: Minimal prompts for fresh servers (original behavior)
- `--interactive`: Safe mode for existing servers - asks permission for each component
- `--dry-run`: Preview mode - shows what would be done without making changes

---

## Table of Contents

- [What Does This Script Do?](#what-does-this-script-do)
- [Section Safety Guide](#section-safety-guide)
- [Who Is This For?](#who-is-this-for)
- [What Does It Install?](#what-does-it-install)
- [Why These Installations?](#why-these-installations)
- [Security Measures](#security-measures)
- [Requirements](#requirements)
- [Installation](#installation)
- [Supported Platforms](#supported-platforms)
- [Important Warnings](#important-warnings)
- [Usage](#usage)
- [After Installation](#after-installation)
- [FAQ](#faq)
- [Troubleshooting](#troubleshooting)
- [License](#license)

---

## What Does This Script Do?

This script transforms a fresh Ubuntu/Debian server into a **production-ready, hardened, and optimized server** in approximately 15-30 minutes. It automates over 100 manual steps that would normally take hours.

### Main Features

1. **Complete System Update** - Updates all packages to the latest versions with security repository verification
2. **System Configuration** - Timezone (Europe/Amsterdam) and FQDN hostname setup
3. **Development Environment** - Installs Python, Node.js, Git, and essential tools
4. **Docker & Containerization** - Complete Docker installation with Docker Compose
5. **Advanced Security Hardening** - 18 comprehensive security layers based on Lynis recommendations
   - Security repository configuration
   - FQDN hostname configuration (improves system identification)
   - Password policies & PAM hardening (SHA-512 with 65536 rounds + password aging policies)
   - Extended kernel hardening (15+ sysctl parameters)
   - USB storage control (with Raspberry Pi support)
   - Core dump protection
   - File permissions hardening
   - Legal warning banners
   - /proc filesystem hardening (hidepid=2)
   - SSH hardening with configurable MaxSessions
   - Fail2ban with jail.local best practices
   - Systemd service hardening (PrivateTmp=no for Lynis/Rkhunter manual execution)
   - Sysstat performance monitoring
   - AIDE file integrity monitoring with SHA-512 checksums (production servers)
   - Compiler access restrictions with chmod 700 (production servers)
   - Package integrity verification with debsums (monthly automated checks)
   - Deprecated package cleanup with residual config purging
6. **Monitoring** - Optional Netdata monitoring with Telegram alerts
7. **Container Management** - Portainer for easy Docker management
8. **Cloudflare Tunnel** - Secure external access without port forwarding
9. **System Optimization** - Swap configuration, kernel hardening, logging
10. **Security Scanning** - Optional Rkhunter and Lynis with automated scans
11. **Backwards Compatibility** - Safe re-run on existing installations (skips completed sections)

---

## Section Safety Guide

When running this script on a server with existing services (Docker containers, databases, web servers, etc.), use `--section` mode to select only the sections you need. This table helps you understand the risk level of each section.

### Section Reference

| # | Section | Risk Level | Safe for Running Services? | Notes |
|---|---------|------------|---------------------------|-------|
| 1 | system-update | Low | Yes | May restart some services automatically after updates |
| 2 | hostname | Low | Yes | Only changes hostname, no service impact |
| 3 | timezone | Low | Yes | Only affects log timestamps |
| 4 | swap | Low | Yes | Only if no swap exists; won't modify existing swap |
| 5 | dev-environment | Low | Yes | Installs Python, Node.js, Git - additive only |
| 6 | docker | **HIGH** | **NO** | **Will STOP and REMOVE all containers!** Skip if you have running containers |
| 7 | security-repository | Low | Yes | Only adds apt repositories |
| 8 | password-hardening | Low | Yes | Only affects new password changes |
| 9 | deprecated-cleanup | Low | Yes | Only removes unused legacy packages |
| 10 | kernel-hardening | Medium | Yes | Requires reboot for full effect |
| 11 | core-dump-disable | Low | Yes | No service impact |
| 12 | umask-hardening | Low | Yes | Only affects new files |
| 13 | ssh-hardening | **MEDIUM** | Yes* | *Ensure you have SSH keys configured first! Changes port to 888 |
| 14 | ufw-firewall | **HIGH** | **Caution** | Choose "MERGE" mode to preserve existing rules. Add container ports! |
| 15 | fail2ban | Low | Yes | Additive security, won't block existing connections |
| 16 | lynis | Low | Yes | Security scanner only, no changes |
| 17 | rkhunter | Low | Yes | Rootkit scanner only, no changes |
| 18 | systemd-hardening | Medium | Yes* | *May restart Docker, SSH, Fail2ban services |
| 19 | audit-logging | Low | Yes | Additive logging only |
| 20 | netdata | Low | Yes | New container, won't affect existing ones |
| 21 | portainer | Low | Yes | New container, won't affect existing ones |
| 22 | cloudflare-tunnel | Low | Yes | New container, won't affect existing ones |
| 23 | telegram | Low | Yes | Configuration only |

### Recommended Sections for Existing Servers

For a Raspberry Pi or server with running Docker containers, these sections are safe to run:

```bash
# Safe sections for hardening an existing server:
sudo bash install-script.sh --section
# Select: 1 3 7 8 9 10 11 12 15 16 17 19

# This includes:
# 1  - System updates
# 3  - Timezone
# 7  - Security repository
# 8  - Password hardening
# 9  - Deprecated cleanup
# 10 - Kernel hardening (reboot needed)
# 11 - Core dump disable
# 12 - Umask hardening
# 15 - Fail2ban
# 16 - Lynis scanner
# 17 - Rkhunter scanner
# 19 - Audit logging
```

### Sections to SKIP or Handle Carefully

| Section | Action | Reason |
|---------|--------|--------|
| **6 (docker)** | **SKIP** | Will destroy all existing containers and data |
| **13 (ssh-hardening)** | Careful | Only run if you have SSH keys. Keep old terminal open! |
| **14 (ufw-firewall)** | Careful | Choose MERGE mode. Manually add ports your containers need |
| **18 (systemd-hardening)** | Careful | Will restart Docker service (brief container restart) |

### UFW Firewall - Adding Container Ports

If you run section 14 (ufw-firewall), you need to add ports for your existing services:

```bash
# After running UFW section, add your container ports:
sudo ufw allow 8080/tcp comment 'My web app'
sudo ufw allow 3000/tcp comment 'Node.js app'
sudo ufw allow 5432/tcp comment 'PostgreSQL'
# etc.

# View current rules:
sudo ufw status numbered
```

---

## Who Is This For?

### Perfect for:

- **Beginners** who want to set up a server without extensive Linux knowledge
- **Developers** who want to quickly set up a development environment
- **System Administrators** who want to save time on server setup
- **DevOps Engineers** who want reproducible server configurations
- **Hobbyists** with a Raspberry Pi or VPS

### Use Cases:

- Web hosting server
- Docker container host
- Development/test environment
- Home server / NAS
- VPS for personal projects
- CI/CD pipeline server

---

## What Does It Install?

### Essential Packages

**Basic Tools:**
- `curl` & `wget` - Download tools for files and scripts
- `git` - Version control system for code
- `net-tools` - Network configuration tools (ifconfig, netstat, etc.)

**Monitoring Tools:**
- `htop` - Interactive process viewer (better than top)
- `atop` - Advanced system monitor with historical logging
- `iotop` - Disk I/O monitoring per process
- `nethogs` - Network traffic monitoring per process

### Development Environments

**Python 3 (system repository version)**
- Installation: Python 3.x with pip and venv (version depends on your Ubuntu/Debian release)
- Why: Most popular programming language for automation, web development, data science
- Usage: Run scripts, build web apps with Django/Flask

**Node.js LTS (Long Term Support)**
- Installation: Node.js with npm package manager
- Why: JavaScript runtime for server-side applications
- Usage: Build web apps with Express, React, Next.js, APIs

### Docker Platform

**Docker Engine & Docker Compose**
- Installation: Docker CE, Docker CLI, Containerd, BuildX, Compose plugin
- Why: Containers make it possible to isolate and easily deploy applications
- Usage: Run apps in isolated environments, easy scaling
- Configuration: Production-optimized with log rotation (10MB max, 3 files)
- **Note:** Container images use `:latest` or `:lts` tags by default. For production, consider pinning specific versions in docker-compose files

**Benefits of Docker:**
- Each application runs in its own container (no conflicts)
- Easy app installation with one command
- Simple backups
- Automatic restart on crashes

### System Configuration

**Timezone Configuration**

- Sets timezone to Europe/Amsterdam
- Enables NTP time synchronization
- Ensures consistent log timestamps
- Important for scheduled tasks and cron jobs

**FQDN Hostname Configuration**

- Configures hostname with Fully Qualified Domain Name (.local)
- Updates /etc/hosts with proper FQDN mapping
- Example: `server` becomes `server.local`
- Benefits:
  - Better system identification in logs and monitoring
  - Required for some services (mail servers, SSL certificates)
  - Prevents hostname resolution warnings
  - Improves Lynis security score (NAME-4404)
- Verification: `hostname --fqdn` shows full domain name
- Required for proper DNS resolution and network identification

### Security

**Firewall (UFW - Uncomplicated Firewall)**
- Default: All incoming connections blocked except:
  - Port 22 (SSH - temporary, for migration)
  - Port 888 (SSH - new secure port)
  - Port 80 (HTTP)
  - Port 443 (HTTPS)
  - Port 9443 (Portainer HTTPS)
  - Port 19999 (Netdata - if installed)
- Why: Prevents unwanted access to your server

**Fail2ban**
- Blocks IP addresses after too many failed login attempts
- Default: 3 failed SSH attempts = 2 hour ban
- Why: Protects against brute-force attacks

**SSH Hardening**
- Moves SSH from port 22 to 888 (fewer automated scans)
- Disables password login (SSH keys only)
- Disables root login with password
- Rate limiting on SSH connections
- Optional IP whitelist for trusted locations
- **LogLevel VERBOSE** for enhanced security auditing
- **Configurable MaxSessions** - Interactive prompt (default: 2, recommended for security)
- **Configurable SSH forwarding** (AllowTcpForwarding, AllowAgentForwarding) - default enabled for flexibility
- TCPKeepAlive disabled for improved security
- Banner support for legal warnings
- Why: SSH is the gateway to your server, must be optimally secured

**Kernel Hardening (Enhanced in current with Docker/Container Compatibility)**
- **IP source routing disabled** on all interfaces (prevents spoofing attacks)
- **Martian packet logging enabled** (logs suspicious network packets)
- **Kernel debug keys disabled** (kernel.sysrq=0 for security)
- **Core dumps disabled** for setuid programs and completely system-wide
- **Uncommon protocols blacklisted** (DCCP, SCTP, RDS, TIPC) - reduces attack surface
- **Extended sysctl hardening** (15+ additional parameters from Lynis recommendations):
  - kernel.kptr_restrict = 2 (hide kernel pointers)
  - kernel.unprivileged_bpf_disabled = 1 (prevent unprivileged BPF)
  - **net.core.bpf_jit_harden = 1** (allows QUIC protocol, set to 1 not 2 for compatibility)
  - **net.ipv4.conf.all.forwarding = 1** (Docker compatibility, especially network_mode: host)
  - **net.ipv6.conf.all.forwarding = 1** (required for containerized services)
  - **net.netfilter.nf_conntrack_max = 524288** (increased for QUIC protocol support)
  - kernel.perf_event_paranoid = 3 (restrict performance events)
  - fs.protected_hardlinks = 1 (protect hardlinks)
  - fs.protected_symlinks = 1 (protect symlinks)
  - fs.protected_fifos = 2 (protect FIFOs)
  - fs.protected_regular = 2 (protect regular files)
  - kernel.yama.ptrace_scope = 1 (restrict ptrace)
  - vm.swappiness = 10 (reduce swap usage)
  - vm.vfs_cache_pressure = 50 (optimize cache)
- SYN flood protection and TCP hardening
- **Docker/Container Compatibility**: IP forwarding enabled for Docker containers using `network_mode: host` (Cloudflare Tunnel, Netdata, VPN clients, reverse proxies)
- **QUIC Protocol Support**: BPF JIT and connection tracking optimized for modern protocols
- Why: Prevents kernel-level attacks while maintaining compatibility with containerized services

**Password & Authentication Hardening (NEW, Enhanced)**

- SHA-512 password hashing with 65536 rounds (slow brute-force attacks)
- Strong password quality requirements (12+ chars, complexity)
- **Password aging policies** (NEW):
  - PASS_MIN_DAYS=7 (minimum days between password changes)
  - PASS_MAX_DAYS=365 (maximum password age - annual renewal)
  - PASS_WARN_AGE=30 (warning 30 days before expiration)
  - Applied to existing user accounts automatically (chage command)
- Per-user temporary directories (libpam-tmpdir)
- Only affects password-based logins (SSH keys unaffected)
- Why: Defense in depth, compliance requirements (Lynis AUTH-9286) - even though SSH keys are primary auth method

**Advanced Package Security**
- **apt-listchanges**: Review security changes before package upgrades
- **debsums**: Verify integrity of installed packages with MD5 checksums
  - Monthly automated verification via cron job
  - Detects modified or corrupted system files
  - Helps identify compromised packages or disk corruption
  - Lightweight and runs automatically on 1st of each month
  - Manual check: `sudo debsums -s` (shows only errors)
- **apt-show-versions**: Better package version tracking
- **needrestart**: Know when to restart services after updates
- **Residual config cleanup** (NEW): Purges configuration files from removed packages
- Why: Prevent compromised packages, maintain system integrity, reduce attack surface (Lynis DEB-0810)

**Automatic Updates**
- Initial full system upgrade during installation (`apt-get upgrade`)
- Daily automatic security updates via `unattended-upgrades` after installation
- Automatic download and installation of security patches
- Why: Always stays up-to-date with latest security fixes

**Audit Logging (auditd + acct)**
- Monitors all changes to SSH configuration
- Logs all root commands
- Tracks who does what on the server
- Why: Detects unwanted changes and helps with incident response

### Additional Security Hardening (NEW)

**USB Storage Control:**

- Optionally disable USB mass storage devices
- Prevents data exfiltration and malware via USB drives
- USB keyboards/mice still work normally
- Raspberry Pi-aware (warns about USB storage usage)
- Default: Disabled for safety (can be enabled on VPS/cloud servers)

**File Permissions Hardening:**

- Secure permissions on critical files
- /etc/crontab → 600 (root only)
- /etc/cron.* directories → 700 (root only)
- /etc/ssh/sshd_config → 600 (root only)
- /etc/at.deny → 600 (if exists)

**Legal Warning Banners:**

- Optional login warning banners
- Displays legal notice before SSH login
- Establishes no expectation of privacy
- Recommended for business/production servers

**/proc Filesystem Hardening:**

- Configured with hidepid=2
- Users can only see their own processes
- Prevents information leakage about running processes
- Safe for single-user VPS and multi-user systems
- Root can still see all processes

**Fail2ban Best Practices:**

- Uses jail.local instead of jail.conf (Lynis DEB-0880)
- Prevents configuration overwrites during updates
- Configuration preserved in /etc/fail2ban/jail.d/

**Systemd Service Hardening (Maximum Compatibility):**

- **SSH Service (VSCode/Lynis/Rkhunter Compatible):**
  - ❌ PrivateTmp: DISABLED to allow manual Lynis/Rkhunter execution via SSH
  - ❌ ProtectSystem=off: DISABLED because `apt install` requires write access to system directories (ProtectSystem=full is too restrictive)
  - ❌ ProtectHome: DISABLED for VSCode Remote SSH and Docker volume mount compatibility
  - ❌ NoNewPrivileges: DISABLED for VSCode server processes
  - ReadWritePaths: `/etc/ufw /tmp /var/tmp /etc/systemd/system /etc/docker`

- **Docker Service:**
  - NoNewPrivileges only (minimal hardening to maintain functionality)

- **Fail2ban Service (Full Hardening):**
  - PrivateTmp + ProtectSystem + ProtectHome + NoNewPrivileges
  - ReadWritePaths: `/var/run/fail2ban /var/lib/fail2ban /var/log /var/spool/postfix/maildrop /etc/ufw`

- **Cron Service:**
  - PrivateTmp + ProtectSystem + NoNewPrivileges

**Why PrivateTmp/ProtectHome/ProtectSystem are disabled for SSH:**
- PrivateTmp blocks manual Lynis/Rkhunter scans (need access to system `/tmp`)
- ProtectSystem=full is too restrictive for `apt install` operations via SSH
- VSCode Remote SSH needs write access to `~/.vscode-server/`
- Docker containers need access to volume mounts from `/home/`
- This configuration works out-of-the-box for development/staging servers

**Security Note:** Even without PrivateTmp/ProtectHome/ProtectSystem/NoNewPrivileges on SSH, you still have:
- ✅ SSH key authentication only (no passwords)
- ✅ Port 888 instead of 22 (reduced bot attacks)
- ✅ UFW firewall + Fail2ban protection
- ✅ All 16 other current hardening layers active
- ✅ Practical server management without compatibility issues

**Sysstat Performance Monitoring:**

- System performance statistics collection
- CPU, memory, disk I/O, network monitoring
- Historical data retention (28 days)
- Tools: sar, iostat, mpstat, pidstat
- Minimal overhead (~0.1% CPU)

**AIDE File Integrity Monitoring (Production Servers):**

- **SHA-512 cryptographic checksums** (NEW in current - stronger than SHA-256)
- Configured with SHA-512 as default checksum algorithm
- Critical files monitored with SHA-512: /etc/ssh/sshd_config, /etc/sudoers, /etc/passwd, /etc/shadow
- Daily integrity checks via cron (4:00 AM)
- Monitors: /bin, /sbin, /usr/bin, /usr/sbin, /etc, /boot, /lib
- Email alerts on unauthorized changes
- Only recommended for production servers (high I/O)
- Not recommended for Raspberry Pi (SD card wear)
- Database initialization: 10-20 minutes
- Why: SHA-512 provides better protection against collision attacks (Lynis FINT-4402)

**Compiler Access Restrictions (Production Servers):**

- Restricts access to gcc, g++, cc, make, as with chmod 700
- Only root can compile code (no group access)
- Prevents attackers from compiling exploits on-server
- Only recommended for pure production servers
- Not for development/build/CI servers
- To restore: `sudo chmod 755 /usr/bin/gcc /usr/bin/g++ /usr/bin/make`

**Deprecated Package Cleanup (Enhanced):**

- Removes insecure legacy packages (nis, rsh-client, telnet, tftp, xinetd)
- **Purges residual configuration files** (NEW): Removes config files from previously removed packages
- Runs apt-get autoremove for unused dependencies
- Clears apt cache to free disk space
- Reduces attack surface and eliminates configuration remnants
- Why: Configuration files can contain sensitive data or outdated settings (Lynis PKGS-7346)

**Optional Security Scans:**

**Rkhunter (Rootkit Hunter)**
- Scans daily at 03:00 for rootkits, backdoors, and exploits
- Sends Telegram alert on suspicious findings
- Why: Detects malicious software trying to hide

**Lynis (Security Auditing)**
- Monthly comprehensive security audit (200+ checks)
- Provides hardening score and improvement points
- Sends monthly report via Telegram
- Why: Identifies weak spots in your configuration

### Monitoring

**Netdata (Optional)**
- Real-time monitoring dashboard
- Metrics: CPU, RAM, disk, network, containers
- **Systemd journal log monitoring** - Full access to host system logs
- **Docker container monitoring** - Track all container metrics
- Telegram alerts preconfigured at container level (may require additional tuning in Netdata's alarm configuration depending on your environment)
- Why: Always have visibility into server status, quick problem detection
- Access: Via web browser on port 19999

### Container Management

**Portainer**
- Graphical interface for Docker management
- No Docker commands needed - everything via web interface
- Start/stop containers, view logs, open shell
- Why: Makes Docker accessible for beginners
- Access: Via HTTPS on port 9443

### Cloudflare Tunnel (Optional)

**Cloudflared**
- Secure tunnel to your server without opening ports on your router
- Access your server remotely via your own domain name
- Free Cloudflare DNS + DDoS protection
- Why: Safest way to make services publicly accessible
- Usage: Host websites, remote access to Portainer/Netdata

---

## Why These Installations?

### Security First

Servers on the internet are **attacked within minutes** by automated bots. This script secures your server **before** it becomes vulnerable.

**Without this script:**
- Default SSH on port 22 = hundreds of brute-force attempts per day
- No firewall = all ports open to everyone
- Manual updates = missed security patches
- No monitoring = only notice problems when it's too late

**With this script:**
- SSH on custom port with rate limiting
- Firewall blocks everything except what's needed
- Automatic security updates
- Real-time monitoring and alerts

### Developer Friendly

Everything you need to start developing immediately:
- **Python**: Scripts, automation, AI/ML, web apps
- **Node.js**: JavaScript backends, APIs, real-time apps
- **Docker**: Databases, services, everything in containers
- **Git**: Code versioning and collaboration

### Production Ready

Configurations are optimized for production use:
- **Swap**: Smartly calculated based on available RAM
- **Logging**: Automatic rotation, limited disk usage
- **Docker**: Resource limits, automatic restart
- **Kernel**: Hardening parameters against attacks

---

## Security Measures

### Multi-layer Security Approach

**1. Network Layer (Firewall)**
- UFW with deny-by-default policy
- Only essential ports open
- Rate limiting on SSH
- **IPv6 disabled by default** to reduce attack surface (can be re-enabled if needed)

**2. Access Layer (SSH)**
- Key-based authentication (no passwords)
- Custom port (888 instead of 22)
- Fail2ban against brute-force
- Optional IP whitelist
- **IPv6 disabled for SSH** (AddressFamily inet) - can be adjusted if IPv6 is required

**3. System Layer (Kernel)**
- IP spoofing protection
- SYN flood protection
- TCP hardening
- ICMP redirect blocking

**4. Application Layer (Docker)**
- Containers run isolated
- Log rotation prevents disk full
- Auto-restart on crashes

**5. Monitoring Layer**
- Real-time monitoring (Netdata)
- Security scans (Rkhunter, Lynis)
- Audit logging (auditd)
- Telegram alerts on problems

### What Does This Protect Against?

- **Brute-force attacks** - Fail2ban and rate limiting
- **Port scanning** - Custom SSH port, firewall
- **DDoS attacks** - SYN flood protection, Cloudflare (optional)
- **Rootkits/Malware** - Rkhunter scans (optional)
- **Unauthorized access** - SSH keys only, audit logging
- **Zero-day exploits** - Automatic security updates

---

## Requirements

### Server Requirements

**Operating System:**
- Ubuntu 20.04 LTS or newer
- Debian 11 (Bullseye) or newer
- Raspbian (Raspberry Pi OS)

**Minimum Hardware:**
- 1 GB RAM (2 GB recommended)
- 10 GB free disk space (20 GB recommended)
- Internet connection

**Recommended Hardware:**
- 2+ GB RAM for Docker workloads
- 20+ GB disk space for containers and logs
- SSD for better performance

### Network Requirements

- Working internet connection
- Access to Ubuntu/Debian package repositories
- Access to Docker Hub (docker.com)
- Access to NodeSource (nodejs.org)

### Access Requirements

**SSH Access:**
- SSH key pair (VERY IMPORTANT - see warnings)
- Root or sudo privileges
- Terminal access (PuTTY on Windows, Terminal on Mac/Linux)

**How to Create an SSH Key:**

**On Windows (PowerShell):**
```powershell
ssh-keygen -t ed25519 -C "your@email.com"
# Copy your key to the server:
type $env:USERPROFILE\.ssh\id_ed25519.pub | ssh user@server "cat >> ~/.ssh/authorized_keys"
```

**On Mac/Linux:**
```bash
ssh-keygen -t ed25519 -C "your@email.com"
# Copy your key to the server:
ssh-copy-id user@server
```

---

## Supported Platforms

| Platform | Version | Status | Notes |
|----------|---------|--------|-------|
| Ubuntu | 20.04 LTS | ✅ Fully supported | Recommended |
| Ubuntu | 22.04 LTS | ✅ Fully supported | Recommended |
| Ubuntu | 24.04 LTS | ✅ Fully supported | Latest |
| Debian | 11 (Bullseye) | ✅ Fully supported | |
| Debian | 12 (Bookworm) | ✅ Fully supported | |
| Raspbian | 11+ | ✅ Fully supported | Raspberry Pi |
| Ubuntu | < 20.04 | ⚠️ May not work | Not tested |
| CentOS/RHEL | All | ❌ Not supported | Uses yum instead of apt |

---

## Important Warnings

### ⚠️ CRITICAL: SSH Access

**READ THIS BEFORE RUNNING THE SCRIPT:**

This script modifies your SSH configuration. **If you do this wrong, you can lock yourself out of your server!**

**Required BEFORE running the script:**
1. Make sure you have an SSH key
2. Test your SSH key: `ssh -i ~/.ssh/id_ed25519 user@server`
3. Make sure your key is in `~/.ssh/authorized_keys` on the server

**The script does the following:**
1. Disables password login
2. Moves SSH from port 22 to 888
3. Temporarily keeps both ports active for safe migration

**Safe workflow:**
1. Script runs, SSH now listens on BOTH port 22 and 888
2. Test new port: `ssh -p 888 user@server`
3. If it works, manually close port 22:
   ```bash
   sudo sed -i '/^Port 22$/d' /etc/ssh/sshd_config
   sudo systemctl restart ssh
   ```

**If you lock yourself out:**
- For VPS providers: Use rescue console / VNC
- For physical server: Physical access needed
- For cloud providers: Restore server snapshot

### ⚠️ Firewall Changes

The script configures UFW firewall. This can overwrite existing firewall rules.

**If you already have a firewall:**
- First make a backup of your rules
- Note which ports you want to keep open
- Add them during the script (interactive prompt) or manually afterwards

**Open ports after installation:**
```bash
sudo ufw allow 3000/tcp comment 'Custom app'
sudo ufw reload
```

### ⚠️ Docker Configuration

The script installs Docker and adds your user to the docker group.

**Important implications:**
- You must log out and log back in for docker without sudo
- Docker containers run with root privileges
- Containers can have access to your entire system if you give them wrong permissions

**Security best practices:**
- Only run trusted containers
- Always use specific version tags (not `latest`)
- Limit resources (CPU/memory) for containers

### ⚠️ Production vs Development

**This script is suitable for:**
- Development servers
- Personal projects
- Small production environments (< 100 users)
- Home servers

**For large production environments you need extra:**
- Load balancing
- High availability setup
- Dedicated database servers
- Professional backup solution
- Monitoring with alerting (Prometheus, Grafana)
- Log aggregation (ELK stack)

### ⚠️ Automatic Updates

Automatic security updates are convenient but can rarely cause problems.

**Risks:**
- Updates can restart services
- Kernel updates require reboot
- Breaking changes (very rare for security updates)

**Mitigation:**
- Script only installs security updates (not all updates)
- Make regular backups
- Monitor your server after updates

---

## Installation

### Step 1: Download the Script

**Option A: With Git (recommended)**
```bash
git clone https://github.com/MadeByAdem/linux-server-management-scripts.git
cd linux-server-management-scripts/server-baseline
```

**Option B: Direct Download**
```bash
wget https://github.com/MadeByAdem/server_baseline/archive/main.zip
unzip main.zip
cd server_baseline-main
```

**Option C: Copy and Paste**
```bash
# Create a file
nano install-script.sh

# Paste the script content
# Press Ctrl+X, then Y, then Enter to save

# Make executable
chmod +x install-script.sh
```

### Step 2: Check Your SSH Key

**Test if your key works:**
```bash
ssh user@your-server-ip
# If you can login WITHOUT a password, your key works!
```

**If you need to enter a password, set up your key first:**
```bash
# On your local computer:
ssh-copy-id user@your-server-ip
```

### Step 3: Run the Script

```bash
sudo bash install-script.sh
```

### Step 4: Answer the Questions

The script asks interactive questions. Here's an overview:

**Previous installation found? (if applicable)**
- Choice: Resume / Start fresh / Exit
- Recommended: Resume (skips completed steps)

**Extra firewall ports?**
- Enter port number or 'n' to skip
- Example: If your app runs on port 3000, enter '3000'

**SSH hardening?**
- Recommended: `y` (yes)
- Only `n` if you know what you're doing

**Disable IPv6?**
- Recommended: `y` (yes) - Reduces attack surface
- Choose `n` if your environment requires IPv6
- This affects both SSH and firewall configuration

**Trusted IP for SSH whitelist?**
- Optional: Your home/office IP address
- Benefit: No rate limiting for this IP
- Find your IP: https://icanhazip.com

**Install security scanning tools?**
- Rkhunter: Recommended `y` for production servers
- Lynis: Recommended `y` for all servers

**Configure Telegram alerts?**
- Optional but useful for monitoring
- You need: Bot Token + Chat ID
- Steps are explained in the script

**Cloudflare Tunnel?**
- Only `y` if you have a Cloudflare account and want a tunnel
- You need: Tunnel Token
- Otherwise: `n` to skip

**Netdata monitoring?**
- Recommended: `y` (very useful for monitoring)
- Uses ~200MB RAM

**Portainer Agent port?**
- Only `y` if you want remote Portainer management
- Most users: `n`

**Start Docker containers?**
- Cloudflare: `y` if you entered a token
- Portainer: Recommended `y`
- Netdata: Recommended `y`

**Reboot after completion?**
- Recommended: `y` to apply all changes

### Step 5: Test SSH on New Port

**IMPORTANT: Do this BEFORE disconnecting!**

**Open a NEW terminal (keep old one open!):**
```bash
ssh -p 888 user@your-server-ip
```

**If it works:**
```bash
# In the new SSH session on port 888:
sudo sed -i '/^Port 22$/d' /etc/ssh/sshd_config
sudo systemctl restart ssh
```

**Test again:**
```bash
ssh -p 888 user@your-server-ip
# Should still work
```

**From now on always use -p 888:**
```bash
ssh -p 888 user@server
```

**Tip: Create an SSH config for easy access:**
```bash
# On your local computer:
nano ~/.ssh/config

# Add:
Host myserver
    HostName your-server-ip
    Port 888
    User your-username
    IdentityFile ~/.ssh/id_ed25519

# Now you can login with:
ssh myserver
```

---

## Usage

### Resume Script

The script has resume functionality for major installation sections. If it's interrupted (crash, internet down, etc.):

```bash
# Just run again:
sudo bash install-script.sh

# You'll get options:
# 1. Resume (skips completed parts)
# 2. Start fresh (starts over)
# 3. Exit
```

**State is saved in:** `/var/lib/server-setup/installation.state`

**Resume capability covers:**
- System updates and package installation
- Docker installation
- SSH hardening configuration
- Custom UFW firewall ports

**Note:** Other sections (Fail2ban, security scans, containers) may re-execute if the script is interrupted during those phases. This is safe as they are idempotent where possible.

**To start from scratch:**
```bash
sudo rm -f /var/lib/server-setup/installation.state
sudo bash install-script.sh
```

### Manual Installations After Script

**Extra firewall ports:**
```bash
# Add port
sudo ufw allow 3000/tcp comment 'My App'
sudo ufw reload

# View status
sudo ufw status verbose
```

**Install security scanning tools later:**
```bash
# Rkhunter
sudo apt-get install -y rkhunter
sudo rkhunter --update
sudo rkhunter --propupd

# Lynis
sudo apt-get install -y lynis

# Run manual scans
sudo rkhunter --check --skip-keypress
sudo lynis audit system
```

**Configure Cloudflare Tunnel later:**
```bash
cd ~/docker/cloudflare
nano .env
# Add: CF_TOKEN=your-token
docker compose up -d
```

---

## After Installation

### First Steps

**1. Restart the server (if not already done)**
```bash
sudo reboot
```

**2. Log back in with new SSH port**
```bash
ssh -p 888 user@server
```

**3. Check Docker**
```bash
# Should work without sudo:
docker ps

# If this doesn't work, log out and back in
```

**4. Access Portainer**
```
Open browser: https://your-server-ip:9443
```

**First time:**
- Create admin account
- Choose password (min. 12 characters)
- Select "Local" environment
- Click "Connect"

**5. Access Netdata (if installed)**
```
Open browser: http://your-server-ip:19999
```

### Check Server Status

**Running containers:**
```bash
docker ps

# Or prettier formatted:
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
```

**Firewall status:**
```bash
sudo ufw status verbose
```

**Fail2ban status:**
```bash
# SSH jail status
sudo fail2ban-client status sshd

# See banned IPs
sudo fail2ban-client status sshd | grep "Banned IP"
```

**System resources:**
```bash
# Interactive monitoring
htop

# Historical system monitoring (logs CPU, memory, disk, network over time)
atop

# Disk I/O
sudo iotop

# Network per process
sudo nethogs

# Or use Netdata dashboard!
```

**View audit logs:**
```bash
# SSH config changes
sudo ausearch -k sshd_config_changes

# All root commands today
sudo ausearch -k privileged_commands -ts today

# Authentication events
sudo ausearch -k auth_log_changes
```

### Configure Cloudflare Tunnel

**If you installed Cloudflare Tunnel:**

**1. Go to Cloudflare Dashboard**
```
https://one.dash.cloudflare.com/
```

**2. Navigate to Networks > Tunnels**

**3. Select your tunnel**

**4. Add Public Hostname**

**For Portainer:**
- Subdomain: `portainer`
- Domain: `your-domain.com`
- Service Type: `HTTPS`
- URL: `https://your-server-ip:9443`
- No TLS Verify: `ON` (important!)

**For Netdata:**
- Subdomain: `netdata`
- Domain: `your-domain.com`
- Service Type: `HTTP`
- URL: `http://your-server-ip:19999`

**Now accessible via:**
- Portainer: `https://portainer.your-domain.com`
- Netdata: `https://netdata.your-domain.com`

### Security Best Practices

**1. Re-enable IPv6 if needed**
If your environment requires IPv6:
```bash
# Re-enable IPv6 in UFW
sudo nano /etc/default/ufw
# Change: IPV6=yes

# Re-enable IPv6 in SSH
sudo nano /etc/ssh/sshd_config
# Change: AddressFamily any (or remove the line)

# Restart services
sudo systemctl restart ssh
sudo ufw reload
```

**2. Change default port numbers (optional extra security)**
```bash
# Change SSH from 888 to a random port
sudo nano /etc/ssh/sshd_config
# Change: Port 888 to Port 12345 (choose your own number)
sudo systemctl restart ssh

# Update firewall
sudo ufw delete allow 888/tcp
sudo ufw allow 12345/tcp comment 'SSH'
sudo ufw reload

# Update Fail2ban
sudo nano /etc/fail2ban/jail.d/server-baseline.conf
# Change: port = 22,888 to port = 12345
sudo systemctl restart fail2ban
```

**3. Configure automatic backups**
```bash
# Create backup script
nano ~/scripts/backup.sh
```

```bash
#!/bin/bash
# Backup script example

BACKUP_DIR="/backup"
DATE=$(date +%Y%m%d_%H%M%S)

# Backup Docker volumes
docker run --rm -v portainer_data:/data -v $BACKUP_DIR:/backup \
  ubuntu tar czf /backup/portainer_$DATE.tar.gz /data

# Backup Docker compose files
tar czf $BACKUP_DIR/docker_configs_$DATE.tar.gz ~/docker

# Keep only last 7 backups
find $BACKUP_DIR -name "*.tar.gz" -mtime +7 -delete

echo "Backup completed: $DATE"
```

```bash
# Make executable
chmod +x ~/scripts/backup.sh

# Test it
~/scripts/backup.sh

# Add to cron (daily at 02:00)
crontab -e
# Add:
0 2 * * * /home/your-user/scripts/backup.sh >> /var/log/backup.log 2>&1
```

**4. Monitoring and alerts**

If you configured Telegram, you'll automatically receive:
- Rkhunter: Daily at 03:00 (only on warnings)
- Lynis: Monthly on the 1st at 04:00
- Netdata: Real-time on problems (high CPU, disk full, etc.)

**Run manually:**
```bash
# Rkhunter scan now
sudo rkhunter --check --skip-keypress

# Lynis audit now
sudo lynis audit system
```

**5. Regular update checks**

Script installs automatic *security* updates. For all updates:
```bash
# Manual update cycle
sudo apt-get update
sudo apt-get upgrade -y
sudo apt-get autoremove -y

# Or use the alias the script creates:
update
```

**6. Update Docker containers**

```bash
# Update all containers in a directory
cd ~/docker/portainer
docker compose pull
docker compose up -d

# Or via Portainer web interface (easier!)
```

---

## FAQ

### General

**Q: How long does the script take?**
A: Approximately 15-30 minutes, depending on your internet speed and server speed. Most time goes to downloading packages.

**Q: Can I run the script multiple times?**
A: Yes! The script is idempotent where possible. It detects what's already installed and skips that. Use the "Resume" option if you have previous installations.

**Q: Does this cost money?**
A: No! Everything the script installs is free and open source. Cloudflare Tunnel is also free (for personal use).

**Q: How much disk space does it use?**
A: (Approximate estimates - actual usage may vary based on your system)
- Script itself: ~5 GB (Docker, packages, etc.)
- Containers: ~500 MB (Portainer + Netdata + Cloudflare)
- Logs: ~500 MB (with automatic rotation)
- Total: ~6 GB + your own applications

**Q: How much RAM does it use?**
A: (Approximate estimates - actual usage may vary)
- Base system: ~300 MB
- Docker: ~100 MB
- Portainer: ~50 MB
- Netdata: ~200 MB
- Total: ~650 MB (on 2 GB server, 1.3 GB remains for your apps)

### SSH & Access

**Q: I locked myself out, what now?**
A:
1. For VPS: Use VNC/Console in your provider dashboard
2. For physical server: Connect monitor and keyboard
3. For cloud: Restore last snapshot
4. Login locally and reset SSH:
```bash
sudo nano /etc/ssh/sshd_config
# Add: PasswordAuthentication yes
# Add: Port 22
sudo systemctl restart ssh
```

**Q: Can I keep port 22 open?**
A: Yes, but not recommended. If you still want to:
```bash
# Add port 22 to firewall
sudo ufw allow 22/tcp comment 'SSH legacy'

# Keep both ports in SSH config
# The script already keeps both open, just don't close port 22
```

**Q: How do I change the SSH port later?**
A:
```bash
# 1. Change config
sudo nano /etc/ssh/sshd_config
# Change: Port 888 to Port NEW_NUMBER

# 2. Update firewall (BEFORE restarting SSH!)
sudo ufw allow NEW_NUMBER/tcp comment 'SSH new'
sudo ufw reload

# 3. Test config
sudo sshd -t

# 4. Restart SSH
sudo systemctl restart ssh

# 5. Test new port in NEW terminal
ssh -p NEW_NUMBER user@server

# 6. If it works, remove old rule
sudo ufw delete allow 888/tcp
```

### Docker & Containers

**Q: Why can't I run docker commands without sudo?**
A: You must log out and log back in after installation. The script adds you to the docker group, but that only becomes active after logging in again.
```bash
# Force new session:
newgrp docker
# Or better: log out and back in
```

**Q: How do I stop containers?**
A:
```bash
# Via command line:
cd ~/docker/portainer
docker compose down

# Or use Portainer web interface!
```

**Q: How do I update containers?**
A:
```bash
cd ~/docker/container-name
docker compose pull
docker compose down
docker compose up -d

# Or in one go:
docker compose pull && docker compose up -d
```

**Q: How do I remove unused containers/images?**
A:
```bash
# Remove stopped containers
docker container prune

# Remove unused images
docker image prune -a

# Remove unused volumes
docker volume prune

# Everything at once (careful!)
docker system prune -a --volumes
```

**Q: Containers don't start after reboot**
A: Check the restart policy:
```bash
docker ps -a
# Look at the RESTART column

# If it's 'no', change the docker-compose.yaml:
nano ~/docker/container/docker-compose.yaml
# Add or change:
# restart: unless-stopped

docker compose up -d
```

### Security

**Q: How do I see which IPs are blocked by Fail2ban?**
A:
```bash
# SSH jail status
sudo fail2ban-client status sshd

# Unblock specific IP
sudo fail2ban-client set sshd unbanip 1.2.3.4
```

**Q: How do I add extra IPs to the SSH whitelist?**
A:
```bash
# Add IP with SSH whitelist bypass
sudo ufw insert 1 allow from 1.2.3.4 to any port 888 comment 'SSH whitelist - extra IP'
sudo ufw reload
```

**Q: Are my passwords stored securely?**
A: The script doesn't store passwords. Only tokens are stored:
- **Cloudflare token**: `~/docker/cloudflare/.env` (chmod 600, user-owned) ✅ Secure
- **Telegram credentials for security scans**: `/usr/local/bin/*-telegram.sh` (chmod 700, root-owned) ✅ Secure (root-only access)
- **Telegram credentials for Netdata**: Stored in Docker environment variables (container-level isolation) ✅ Secure

**Token Security:**
All Telegram tokens are properly secured with restricted permissions. The security scan wrapper scripts (`rkhunter-telegram.sh`, `lynis-telegram.sh`, `aide-telegram.sh`) are automatically set to chmod 700 (read/execute only by root), preventing other users from accessing the tokens.

**Q: How often do security scans run?**

- Rkhunter: Daily at 03:00 (sends daily status update)
- Lynis: Monthly on the 1st at 04:00
- AIDE: Daily at 05:00 (sends alert on file changes, status if no changes)

Check cron:
```bash
sudo cat /etc/cron.d/security-scans
```

### Monitoring

**Q: Netdata uses too much RAM**
A: Netdata can be optimized:
```bash
# Edit config
docker exec -it netdata nano /etc/netdata/netdata.conf

# Add in [global] section:
# memory mode = ram
# page cache size = 32
# history = 3600

# Restart container
docker restart netdata
```

**Q: How do I get Telegram alerts working?**
A:
1. Create bot via @BotFather on Telegram
2. Copy bot token (e.g.: `123456:ABCdef...`)
3. Start chat with your bot (send /start)
4. Get your chat ID via @userinfobot (e.g.: `987654321`)
5. Test configuration:
```bash
# If Netdata is running:
docker exec netdata /usr/libexec/netdata/plugins.d/alarm-notify.sh test

# For security scans:
sudo /usr/local/bin/rkhunter-telegram.sh
```

**Q: Portainer web interface not accessible**
A:
```bash
# Check if container is running
docker ps | grep portainer

# Check logs
docker logs portainer

# Check firewall
sudo ufw status | grep 9443

# Common problem: browser doesn't trust self-signed cert
# Solution: Click through security warning, or use Cloudflare Tunnel
```

### Cloudflare

**Q: How do I get a Cloudflare Tunnel token?**
A:
1. Go to https://one.dash.cloudflare.com/
2. Click "Networks" > "Tunnels"
3. Click "Create a tunnel"
4. Choose "Cloudflared"
5. Give tunnel a name
6. Copy the token (long string starting with `eyJ...`)
7. Skip public hostname step (do later)

**Q: My tunnel doesn't work**
A:
```bash
# Check container logs
docker logs cloudflared

# Common errors:
# - Wrong token: Check .env file
# - No internet: Check connectivity
# - Token expired: Create new tunnel

# Test manually:
docker compose -f ~/docker/cloudflare/docker-compose.yaml logs -f
```

**Q: Can I use Cloudflare Tunnel without a domain name?**
A: No, you need a domain name that runs through Cloudflare. Free alternatives:
- Freenom (.tk, .ml, .ga domains - free)
- DuckDNS (free subdomain)
- Cloudflare Pages (free subdomain)

### Updates & Maintenance

**Q: How do I update the system?**
A: Security updates go automatically. For all updates:
```bash
sudo apt-get update
sudo apt-get upgrade -y
sudo apt-get autoremove -y

# Or use alias:
update
```

**Q: How often should I reboot?**
A:
- After kernel updates (you'll get notification on login)
- Monthly for general maintenance
- On strange problems (RAM leaks, etc.)

```bash
# Check if reboot needed
ls /var/run/reboot-required

# Scheduled reboot (in 10 min, users get warning)
sudo shutdown -r +10 "Server reboot for maintenance"

# Cancel reboot
sudo shutdown -c
```

**Q: How do I see what was updated?**
A:
```bash
# Recently installed packages
grep " install " /var/log/dpkg.log | tail -20

# Automatic update log
sudo cat /var/log/unattended-upgrades/unattended-upgrades.log
```

---

## Troubleshooting

### "unable to execute ./install-script.sh: No such file or directory"

**Problem:** The script exists but gives "No such file or directory" error.

**Cause:** The script has Windows-style line endings (CRLF) instead of Unix line endings (LF). This happens when the file was edited or transferred from a Windows system.

**Solution:**
```bash
# Fix line endings with sed
sed -i 's/\r$//' ./install-script.sh

# Or install and use dos2unix
sudo apt install dos2unix
dos2unix ./install-script.sh
```

**Prevention:** The repository includes a `.gitattributes` file that ensures correct line endings when cloning. If you manually copy files, always convert line endings.

---

### V4.0 Security Hardening Issues

**"UFW reload fails with 'No usable temporary directory found'"**

**Cause:** SSH systemd hardening with `PrivateTmp=yes` isolates `/tmp` without proper ReadWritePaths.

**Solution:**
```bash
# Edit SSH hardening config
sudo nano /etc/systemd/system/ssh.service.d/hardening.conf

# Ensure this line exists:
ReadWritePaths=/etc/ufw /tmp /var/tmp /etc/systemd/system /etc/docker

# Reload and restart
sudo systemctl daemon-reload
sudo systemctl restart ssh

# Log out and back in for changes to take effect
exit
# Then reconnect via SSH
```

**"Cloudflare Tunnel fails with 'timeout: no recent network activity'"**

**Cause:** IP forwarding disabled by kernel hardening, blocking QUIC protocol.

**Solution:**
```bash
# Check current IP forwarding status
sysctl net.ipv4.conf.all.forwarding
sysctl net.ipv6.conf.all.forwarding

# If set to 0, enable it:
sudo nano /etc/sysctl.d/99-server-hardening.conf

# Change these lines:
net.ipv4.conf.all.forwarding = 1
net.ipv6.conf.all.forwarding = 1
net.core.bpf_jit_harden = 1  # Must be 1, not 2
net.netfilter.nf_conntrack_max = 524288

# Apply changes
sudo sysctl -p /etc/sysctl.d/99-server-hardening.conf

# Restart Cloudflare Tunnel
sudo docker compose restart
```

**"Docker containers using network_mode: host can't connect"**

**Cause:** Same as Cloudflare Tunnel - IP forwarding disabled.

**Solution:** Follow Cloudflare Tunnel solution above. Containers using `network_mode: host` (like Netdata, VPN clients, reverse proxies) require IP forwarding to be enabled.

**"VSCode Remote SSH or Docker volume mounts not working"**

**Note:** The script is **pre-configured** to work with VSCode Remote SSH and Docker volume mounts from `/home`. These should work out-of-the-box.

**If you upgraded from an older version** or modified the hardening configuration:

```bash
# Check your current SSH hardening config
cat /etc/systemd/system/ssh.service.d/hardening.conf

# Should look like this:
[Service]
# Systemd hardening for SSH (Lynis BOOT-5264) - VSCode compatible
PrivateTmp=yes
ProtectSystem=full
# ProtectHome and NoNewPrivileges disabled for VSCode/Docker compatibility
ReadWritePaths=/etc/ufw /tmp /var/tmp /etc/systemd/system /etc/docker
```

**If ProtectHome or NoNewPrivileges are present**, update to the current configuration:

```bash
sudo nano /etc/systemd/system/ssh.service.d/hardening.conf

# Remove or comment out these lines:
# ProtectHome=read-only  (or any ProtectHome setting)
# NoNewPrivileges=yes

# Also remove /home from ReadWritePaths (not needed without ProtectHome)

# Reload and restart
sudo systemctl daemon-reload
sudo systemctl restart ssh
```

**Why this works:**
- VSCode needs to write to `~/.vscode-server/` - works without ProtectHome
- Docker needs access to volume mounts from `/home/` - works without ProtectHome
- You still have strong security from other hardening layers

**"Cannot write to /etc from SSH session"**

**Cause:** SSH systemd hardening with `ProtectSystem=full` makes `/etc` read-only.

**V4.0 Already Includes Common /etc Paths:**

The current script includes these essential `/etc` directories in ReadWritePaths:
- ✅ `/etc/ufw` - UFW firewall configuration
- ✅ `/etc/systemd/system` - Service configuration files
- ✅ `/etc/docker` - Docker daemon configuration

**If you need to write to OTHER /etc files:**

**Option A: Temporary Remount (Most Secure - Recommended)**
```bash
# Temporarily remount /etc as read-write
sudo mount -o remount,rw /etc

# Make your changes
sudo nano /etc/your-file

# /etc automatically returns to read-only after SSH restart
# This is by design for security
```

**Benefits:**
- ✅ Maximum security - /etc remains protected
- ✅ Conscious decision required for /etc modifications
- ✅ No permanent security reduction

**Option B: Add Specific Path (Balanced Security)**
```bash
# Edit SSH hardening config
sudo nano /etc/systemd/system/ssh.service.d/hardening.conf

# Add ONLY the specific directory you need (example: /etc/nginx):
ReadWritePaths=/etc/ufw /tmp /var/tmp /home /etc/systemd/system /etc/docker /etc/nginx

# Reload and restart
sudo systemctl daemon-reload
sudo systemctl restart ssh
exit  # Log out and back in
```

**Benefits:**
- ✅ Convenient for frequently modified directories
- ✅ Most of /etc remains protected
- ⚠️  Slightly reduced security for that specific path

**Option C: Full /etc Access (NOT Recommended)**
```bash
# Add entire /etc to ReadWritePaths
ReadWritePaths=/etc/ufw /tmp /var/tmp /home /etc/systemd/system /etc/docker /etc

# Reload and restart
sudo systemctl daemon-reload
sudo systemctl restart ssh
exit
```

**Drawbacks:**
- ❌ Significantly reduced security
- ❌ Compromised SSH session can modify any /etc file
- ❌ Lower Lynis score
- ❌ Not recommended for production servers

**Recommendation:** Use Option A (temporary remount) for occasional changes, or Option B for specific directories you modify frequently. Avoid Option C unless absolutely necessary.

**"Cannot edit scripts in /usr/local/bin from SSH session"**

**Cause:** SSH systemd hardening with `ProtectSystem=full` makes `/usr` (including `/usr/local/bin`) read-only.

**Affected Files:**
- `/usr/local/bin/lynis-telegram.sh` - Lynis monitoring script
- `/usr/local/bin/rkhunter-telegram.sh` - Rootkit scanner script
- `/usr/local/bin/aide-telegram.sh` - AIDE integrity monitoring script
- Any other custom scripts you've added to `/usr/local/bin`

**Option A: Temporary Remount (Most Secure - Recommended)**
```bash
# Temporarily remount /usr as read-write
sudo mount -o remount,rw /usr

# Make your changes
sudo nano /usr/local/bin/lynis-telegram.sh
sudo nano /usr/local/bin/rkhunter-telegram.sh
sudo nano /usr/local/bin/aide-telegram.sh

# /usr automatically returns to read-only after SSH restart
# This is by design for security
```

**Benefits:**
- ✅ Maximum security - /usr remains protected
- ✅ Conscious decision required for system modifications
- ✅ No permanent security reduction
- ✅ Best practice for production servers

**Option B: Add /usr/local/bin to ReadWritePaths (Balanced Security)**
```bash
# Edit SSH hardening config
sudo nano /etc/systemd/system/ssh.service.d/hardening.conf

# Add /usr/local/bin to ReadWritePaths:
ReadWritePaths=/etc/ufw /tmp /var/tmp /etc/systemd/system /etc/docker /usr/local/bin

# Reload and restart
sudo systemctl daemon-reload
sudo systemctl restart ssh
exit  # Log out and back in
```

**Benefits:**
- ✅ Convenient for frequently modified scripts
- ✅ /usr system directories remain protected
- ⚠️  Slightly reduced security for /usr/local/bin

**Option C: Full /usr Access (NOT Recommended)**
```bash
# Add entire /usr to ReadWritePaths
ReadWritePaths=/etc/ufw /tmp /var/tmp /etc/systemd/system /etc/docker /usr

# Reload and restart
sudo systemctl daemon-reload
sudo systemctl restart ssh
exit
```

**Drawbacks:**
- ❌ Significantly reduced security
- ❌ Compromised SSH session can modify system binaries
- ❌ Lower Lynis score
- ❌ Not recommended for any server environment

**Recommendation:** Use Option A (temporary remount) for occasional script updates, or Option B if you need to update monitoring scripts frequently. Never use Option C - it exposes critical system directories.

**"Cannot run Lynis/Rkhunter manually via SSH"**

**Cause:** SSH systemd hardening with `PrivateTmp=yes` isolates `/tmp` per SSH session. Lynis and Rkhunter need access to the system-wide `/tmp` directory to create temporary files.

**Error you might see:**
```
mktemp: failed to create file via template '/tmp/lynis.XXXXXXXXXX': No such file or directory
```

**Solution: Run scripts outside SSH session context**

```bash
# For manual Lynis audit with Telegram notification:
sudo bash -c 'cd / && /usr/local/bin/lynis-telegram.sh'

# For manual Rkhunter scan with Telegram notification:
sudo bash -c 'cd / && /usr/local/bin/rkhunter-telegram.sh'

# For manual AIDE check with Telegram notification:
sudo bash -c 'cd / && /usr/local/bin/aide-telegram.sh'

# For manual Lynis audit without Telegram (interactive):
sudo bash -c 'cd / && lynis audit system'

# For manual Rkhunter scan without Telegram (interactive):
sudo bash -c 'cd / && rkhunter --check --skip-keypress'

# For manual AIDE check without Telegram:
sudo aide --check
```

**Why this works:**
- `sudo bash -c` creates a new shell process outside your SSH session context
- This shell has access to the system-wide `/tmp` directory
- `cd /` ensures the script runs from root directory (simulates cron environment)
- This is exactly how cron executes these scripts automatically

**Automated scans still work normally:**
- Cron jobs are not affected by SSH hardening
- Daily/monthly scans via cron work perfectly
- Only manual execution via SSH requires the `bash -c` wrapper

**Alternative: Clean up stale PID files**

If you see "PID file exists" warnings:
```bash
# Remove stale Lynis PID file
sudo rm -f /var/run/lynis.pid

# Remove stale Rkhunter lock file (if exists)
sudo rm -f /var/lib/rkhunter/rkhunter.lock
```

### Installation Problems

**"No internet connectivity detected"**
```bash
# Test DNS
ping -c 4 8.8.8.8
ping -c 4 google.com

# If first works but second doesn't = DNS problem
# Fix DNS:
sudo nano /etc/resolv.conf
# Add:
# nameserver 8.8.8.8
# nameserver 1.1.1.1
```

**"Failed to update package lists after multiple attempts"**
```bash
# Check repository status
sudo apt-get update

# If there are errors with repositories:
# 1. Backup sources
sudo cp /etc/apt/sources.list /etc/apt/sources.list.backup

# 2. Reset to defaults (Ubuntu example)
sudo nano /etc/apt/sources.list
# Replace content with official mirrors:
# deb http://archive.ubuntu.com/ubuntu focal main restricted universe multiverse
# deb http://archive.ubuntu.com/ubuntu focal-updates main restricted universe multiverse
# deb http://security.ubuntu.com/ubuntu focal-security main restricted universe multiverse

# 3. Try again
sudo apt-get update
```

**"Failed to download Docker GPG key"**
```bash
# Test connection with Docker
curl -I https://download.docker.com

# If this fails, possible firewall issue
# Try manual Docker installation:
# https://docs.docker.com/engine/install/ubuntu/
```

**"Script exited with error code"**
```bash
# Check error log
sudo cat /var/log/server_install_*.log

# Common fixes:
# 1. Disk full
df -h
# Free space if needed

# 2. Not enough RAM
free -h
# Add swap or upgrade RAM

# 3. Missing dependencies
sudo apt-get install -f

# Resume script
sudo bash install-script.sh
# Choose option 1 (Resume)
```

### SSH Problems

**"Connection refused on port 888"**
```bash
# Via rescue console / VNC:

# 1. Check if SSH is running
sudo systemctl status ssh

# 2. Check which ports are active
sudo ss -tlnp | grep ssh
# Should show: :888 and possibly :22

# 3. Check firewall
sudo ufw status

# 4. Check SSH config
sudo grep "^Port" /etc/ssh/sshd_config
# Should show: Port 22 and Port 888

# 5. Restart SSH
sudo systemctl restart ssh
```

**"Permission denied (publickey)"**
```bash
# On the server (via rescue console):

# 1. Check permissions authorized_keys
ls -la ~/.ssh/authorized_keys
# Must be: -rw------- (600)

# Fix permissions:
chmod 700 ~/.ssh
chmod 600 ~/.ssh/authorized_keys

# 2. Check if your key is in there
cat ~/.ssh/authorized_keys
# Must show your public key

# 3. Check SSH config allows keys
sudo grep PubkeyAuthentication /etc/ssh/sshd_config
# Must be: PubkeyAuthentication yes

# 4. Check SELinux (if you have it)
sudo restorecon -R -v ~/.ssh
```

**"Too many authentication failures"**
```bash
# Your SSH client is trying too many keys
# Fix: Specify exactly which key to use

ssh -i ~/.ssh/id_ed25519 -p 888 user@server

# Or in ~/.ssh/config:
Host server
    HostName server-ip
    Port 888
    User username
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
```

### Docker Problems

**"Cannot connect to Docker daemon"**
```bash
# 1. Check Docker is running
sudo systemctl status docker

# Start Docker
sudo systemctl start docker

# Enable Docker
sudo systemctl enable docker

# 2. Check your group membership
groups
# Should contain "docker"

# If not, add manually:
sudo usermod -aG docker $USER
# Log out and back in

# 3. Check Docker socket permissions
ls -la /var/run/docker.sock
# Must be owner: root:docker

sudo chmod 666 /var/run/docker.sock
```

**"docker compose: command not found"**
```bash
# Script installs Docker Compose as plugin
# Use "docker compose" (with space) not "docker-compose"

# Test:
docker compose version

# If this doesn't work:
sudo apt-get install docker-compose-plugin

# Legacy standalone version (not recommended):
sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose
```

**"Error response from daemon: pull access denied"**
```bash
# Image doesn't exist or typo in name
# Check exact image name on Docker Hub

# Pull manually to see error:
docker pull image-name:tag

# For private images:
docker login
```

**Container won't start / crashes**
```bash
# Check logs
docker logs container-name

# Check events
docker events --since 1h

# Check resource limits
docker stats

# Start container in debug mode
docker run -it --entrypoint /bin/bash image-name
```

### Firewall Problems

**"Cannot connect to service"**
```bash
# 1. Check if service is running
docker ps
sudo ss -tlnp | grep PORT_NUMBER

# 2. Check firewall
sudo ufw status numbered
# Look for your port

# 3. Add port if missing
sudo ufw allow PORT_NUMBER/tcp
sudo ufw reload

# 4. Check if UFW itself is running
sudo ufw status
# Must show: Status: active
```

**"Lockout - can't login anymore"**
```bash
# Via rescue console / physical access:

# Temporarily disable firewall
sudo ufw disable

# Login via SSH

# Fix firewall rules
sudo ufw allow 888/tcp
sudo ufw enable

# Or reset completely:
sudo ufw --force reset
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 888/tcp
sudo ufw enable
```

### Performance Problems

**"Server is slow"**
```bash
# Check resources
htop
# Look at CPU and RAM usage

# Check historical data (what happened before?)
atop
# Press 't' to go back in time, analyze past performance

# Check disk I/O
sudo iotop
# Look at high disk usage

# Check network
sudo nethogs
# Look at bandwidth usage

# Check Docker containers
docker stats
# See if a container is using too much

# Check system logs
sudo journalctl -xe
# Look for errors
```

**"Disk full"**
```bash
# Check usage
df -h
du -sh /* | sort -hr | head -10

# Common causes:

# 1. Docker images
docker system df
docker system prune -a
# Removes all unused images

# 2. Logs
sudo du -sh /var/log/*
sudo journalctl --vacuum-time=7d
# Keep only last 7 days

# 3. APT cache
sudo du -sh /var/cache/apt/archives
sudo apt-get clean
```

**"RAM full"**
```bash
# Check memory
free -h

# Check swap usage
swapon --show

# Check processes
ps aux --sort=-%mem | head -10

# Temporary fix: restart containers
docker restart container-name

# Permanent fix:
# - Limit container resources in docker-compose.yaml
# - Upgrade server RAM
# - Optimize applications
```

### Monitoring Issues

**"Netdata dashboard empty"**
```bash
# Check container logs
docker logs netdata

# Restart container
docker restart netdata

# Check disk space (Netdata stops when low on space)
df -h

# Reset Netdata data
docker compose -f ~/docker/netdata/docker-compose.yaml down
docker volume rm netdatacache
docker compose -f ~/docker/netdata/docker-compose.yaml up -d
```

**"No Telegram alerts"**
```bash
# Test manually (Netdata)
docker exec netdata /usr/libexec/netdata/plugins.d/alarm-notify.sh test

# Test security scripts
sudo /usr/local/bin/rkhunter-telegram.sh

# Check credentials
sudo cat /etc/cron.d/security-scans
# Tokens must be correct

# Test bot token manually:
curl -X POST "https://api.telegram.org/bot<BOT_TOKEN>/sendMessage" \
  -d chat_id=<CHAT_ID> \
  -d text="Test"
# Replace <BOT_TOKEN> and <CHAT_ID>
```

### Security Audit & Recommendations

**View Lynis Security Recommendations:**

```bash
# View all Lynis recommendations
grep 'suggestion\[\]=' /var/log/lynis-report.dat | cut -d'=' -f2-

# Count total suggestions
grep -c 'suggestion\[\]=' /var/log/lynis-report.dat

# View top 10 suggestions
grep 'suggestion\[\]=' /var/log/lynis-report.dat | cut -d'=' -f2- | head -10

# View hardening score
grep 'hardening_index=' /var/log/lynis-report.dat | cut -d'=' -f2

# Run new Lynis scan
sudo lynis audit system --quick

# View detailed test results
sudo lynis show details <TEST-ID>
```

**Lynis Report Locations:**
- Main report: `/var/log/lynis-report.dat` (machine-readable format)
- Detailed log: `/var/log/lynis.log` (human-readable format)
- Last scan results available after installation completes

**Understanding Lynis Output:**
- **Hardening Index**: 0-100 score
- **Suggestions**: Recommendations to improve security further
- **Warnings**: Potential security issues that should be addressed
- **Tests**: Individual security checks performed

**Example Recommendations You Might See:**
- Add legal banners (already optional)
- Configure additional firewall rules for specific services
- Enable compiler restrictions (already optional for production)
- File integrity monitoring improvements
- Additional SSH hardening options

### Check Logs

**Most important logs:**
```bash
# Installation log
sudo cat /var/log/server_install_*.log

# System log
sudo journalctl -xe

# Auth log (SSH logins)
sudo tail -f /var/log/auth.log

# Docker logs
sudo journalctl -u docker

# Firewall logs
sudo tail -f /var/log/ufw.log

# Fail2ban logs
sudo tail -f /var/log/fail2ban.log

# Specific container
docker logs container-name
docker logs -f container-name  # Follow mode
```

---

## Contributing

Contributions are welcome! If you have improvements:

1. Fork this repository
2. Create a feature branch (`git checkout -b feature/AmazingFeature`)
3. Commit your changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to the branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

**What we're looking for:**
- Bug fixes
- Documentation improvements
- Support for more Linux distros
- Additional security measures
- Performance optimizations

**Code guidelines:**
- Use descriptive variable names
- Add comments for complex sections
- Test on at least Ubuntu 22.04 LTS
- Maintain error handling and logging
- Update README with new features

---

## Support

**Need help?**
- Open a [GitHub Issue](https://github.com/MadeByAdem/linux-server-management-scripts/issues)
- Check [FAQ section](#faq) first
- Check [Troubleshooting section](#troubleshooting) first

**When reporting problems, include:**
- OS version: `cat /etc/os-release`
- Server specs: `free -h && df -h`
- Error message from: `/var/log/server_install_*.log`
- Which step failed
- What you've already tried

---

## License

This project is licensed under the MIT License - see the [LICENSE.md](LICENSE.md) file for details.

**What does this mean?**
- You may use the script for free
- You may modify the script
- You may share the script
- Commercial use is allowed
- No warranties - use at your own risk

---

## Credits

**Developed by:** MadeByAdem

**Built with:**
- Docker & Docker Compose
- Netdata Monitoring
- Portainer Container Management
- Cloudflare Tunnel
- UFW Firewall
- Fail2ban
- Ubuntu/Debian Linux

**Special thanks to the open-source community!**

---

## Changelog

### Current Release - Comprehensive Lynis-Based Hardening

- **NEW: 17 Advanced Security Hardening Sections** (Based on Lynis audit recommendations):
  - **Security Repository Configuration**: Verifies and configures official security update repositories
  - **Password Policies & PAM Hardening**: SHA-512 with 65536 rounds, libpam-pwquality, libpam-tmpdir
  - **Extended Kernel Hardening**: 15+ additional sysctl parameters (kptr_restrict, BPF hardening, protected files, ptrace restrictions)
  - **USB Storage Control**: Optional blacklisting with Raspberry Pi awareness
  - **Complete Core Dump Protection**: limits.d, systemd, and profile configuration
  - **File Permissions Hardening**: Secures crontab, cron directories, SSH config, at.deny
  - **Legal Warning Banners**: Optional /etc/issue and /etc/issue.net configuration
  - **/proc Filesystem Hardening**: hidepid=2 for process isolation
  - **Enhanced SSH Hardening**: Configurable MaxSessions (default: 2), TCPKeepAlive disabled
  - **Fail2ban Best Practices**: jail.local usage (DEB-0880 compliance)
  - **Systemd Service Hardening**: PrivateTmp, ProtectSystem, ProtectHome, NoNewPrivileges for SSH/Docker/Fail2ban/Cron
  - **Sysstat Monitoring**: System performance statistics collection (sar, iostat, mpstat, pidstat)
  - **AIDE File Integrity Monitoring**: Production server option with daily checks and email alerts
  - **Compiler Restrictions**: Production server option to restrict gcc/g++/make access
  - **Deprecated Package Cleanup**: Removes nis, rsh-client, telnet, tftp, xinetd

- **NEW: Backwards Compatibility System**:
  - All 13 new security sections support `skip_if_completed()` checks
  - Safe re-run on existing installations without re-prompting
  - Only new/unconfigured features are prompted
  - State tracking in `/var/lib/server-setup/installation.state`
  - Seamless upgrade path from older script versions

- **NEW: Interactive Configuration Prompts**:
  - SSH MaxSessions: User-configurable (1-10, default: 2) with validation
  - USB Storage: Platform-aware prompt (Raspberry Pi warning, default: no)
  - Legal Banners: Optional (recommended for business, default: no)
  - AIDE: Production server check (not for RPi/dev servers, default: no)
  - Compiler Restrictions: Production-only check (breaks dev workflows, default: no)
  - Systemd Service Restart: Optional immediate restart after hardening

- **Enhanced Security Defaults**:
  - Lynis hardening score improvement: Expected 73 → 90-95+
  - Reduced Lynis suggestions from 34 to ~10-15
  - All configurations follow security best practices
  - Conservative defaults (security over convenience)

- **Platform Compatibility**:
  - Raspberry Pi support with platform-specific warnings
  - VPS/Cloud server optimizations
  - Production vs. development server detection
  - Appropriate defaults per platform type

- **Improved User Experience**:
  - Clear explanations for each security section
  - Impact descriptions before configuration
  - Raspberry Pi-specific warnings where relevant
  - Default values shown in prompts
  - Dry-run mode shows all new sections

### Previous Release - Interactive & Safe for Existing Servers

- **NEW: Three Operation Modes:**
  - `--fresh-install`: Minimal prompts for fresh servers (fast setup)
  - `--interactive`: Safe mode for existing servers with component-by-component confirmation
  - `--dry-run`: Preview mode showing what would be done without making changes
  - Auto-detection mode: Automatically detects if server has existing installations

- **NEW: Comprehensive Safety Features:**
  - Automatic backup creation before any modifications (in interactive mode)
  - Rollback script generation for easy restoration
  - Component status detection (Docker, UFW, SSH, swap, etc.)
  - Context-aware prompts showing current state and implications

- **NEW: Docker Safety Guards:**
  - Detects running Docker containers before reinstallation
  - Critical warning with double confirmation if containers are running
  - Shows container count and data loss warnings
  - Option to skip Docker installation to preserve existing setup

- **NEW: UFW Firewall Merge Mode:**
  - Three options: MERGE (add rules, keep existing), RESET (delete all), or SKIP
  - Merge mode preserves existing firewall rules (recommended for production)
  - Reset mode requires explicit "DELETE ALL RULES" confirmation
  - Shows current rule count before making changes

- **NEW: Interactive Component Prompts:**
  - Each major component (timezone, system updates, Docker, UFW, etc.) asks for confirmation
  - Shows current status, clear descriptions, and implications for each component
  - Configurable timeouts (60-90 seconds) with sensible defaults
  - In fresh-install mode: auto-accepts non-critical components for speed

- **Enhanced Detection:**
  - Detects existing Docker installations and running containers
  - Detects active UFW rules and configuration
  - Detects custom SSH configurations
  - Detects existing swap files
  - Detects timezone and other system settings

- **Improved Error Handling:**
  - Dry-run mode for safe preview of all operations
  - Better state management for skipped components
  - Graceful handling of user cancellations
  - Detailed logging of all decisions in dry-run mode

- **Better User Experience:**
  - Color-coded output (green=info, yellow=warning, red=critical, cyan=dry-run)
  - Clear mode indicators at script start
  - Progress visibility with component status
  - Help command with usage examples (`--help`)
  - Automatic backup location display in summary

- **Production-Ready:**
  - Safe for servers with existing services (interactive mode)
  - Prevents accidental data loss (Docker container protection)
  - Preserves existing configurations (UFW merge mode)
  - Rollback capabilities for quick restoration
  - Suitable for both development and production environments

### Earlier Release - Enhanced Security
- **Enhanced Kernel Hardening:**
  - Fixed `net.ipv4.conf.default.accept_source_route = 0` (IP source routing disabled on new interfaces)
  - Fixed `net.ipv4.conf.default.log_martians = 1` (log suspicious packets on new interfaces)
  - Added IPv6 source routing protection (`net.ipv6.conf.all.accept_source_route = 0`)
  - Added `kernel.sysrq = 0` (disable kernel debugging keys for security)
  - Improved core dump security with `fs.suid_dumpable = 0`

- **Protocol Security:**
  - Disabled uncommon network protocols (DCCP, SCTP, RDS, TIPC)
  - Reduces attack surface by blacklisting rarely-used protocols
  - Configuration in `/etc/modprobe.d/disable-protocols.conf`

- **SSH Security Enhancements:**
  - SSH LogLevel set to VERBOSE for enhanced security auditing
  - Configurable SSH forwarding (AllowTcpForwarding, AllowAgentForwarding)
  - Default: **Enabled** for flexibility (user can disable for maximum security)
  - Interactive prompt with clear security implications

- **Advanced Package Security Tools:**
  - `apt-listchanges` - Shows important package changes before upgrade
  - `debsums` - Verifies installed package file integrity
  - `apt-show-versions` - Better package version management
  - `needrestart` - Detects which services need restart after updates
  - Note: `apt-listbugs` excluded (Debian-only, not available on Ubuntu)

- **Rkhunter Configuration:**
  - Automatic configuration for custom SSH port (888)
  - `ALLOW_SSH_ROOT_USER=prohibit-password` matches SSH config
  - `PORT_NUMBER=888` for accurate SSH scanning

- **Netdata Monitoring Enhancements:**
  - **Systemd journal log access** - Mounts `/var/log/journal` and `/run/log/journal` for complete system log visibility
  - **Automatic systemd-journal plugin configuration** - Pre-configured to monitor host logs
  - Telegram environment variables passed directly in docker-compose (when configured)
  - Full Docker container monitoring with socket access
  - Fixes "Required filters are needed" warning in Netdata Cloud

- **Ubuntu Compatibility:**
  - Removed Debian-specific packages
  - All security tools now Ubuntu-compatible
  - Better cross-distribution support

### Earlier Release - Core Functionality
- Resume functionality on interrupts
- Telegram integration for monitoring and security alerts
- Rkhunter and Lynis security scanning with automatic reports
- Audit logging with auditd
- SSH trusted IP whitelist functionality
- Improved error handling and logging
- Journald configuration with log rotation
- Smart swap configuration based on RAM

### Initial Release
- Initial release
- Basic server setup and hardening
- Docker, Python, Node.js installation
- SSH hardening
- UFW firewall configuration
- Fail2ban setup
- Portainer and Cloudflare Tunnel
- Optional Netdata monitoring

---

## Disclaimer

**USE AT YOUR OWN RISK**

This script is intended as a tool for server configuration. The authors are not responsible for:
- Data loss
- Server downtime
- Security breaches
- Configuration problems
- Any other damage

**Recommendations:**
- Always make backups before running this script
- Test first on a test server
- Read the full documentation
- Understand what each section does
- Use in production at your own risk

**Security Notice:**
While this script implements many security measures, **no system is 100% secure**. This script is a good foundation, but always stay alert for security updates and best practices.

For enterprise/critical systems, consult a professional security specialist.

---

**Good luck with your server setup!** 🚀

If you find this script useful, give it a ⭐ on GitHub!
