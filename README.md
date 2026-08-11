# Server Management Scripts

A collection of professional bash scripts for Ubuntu/Debian server and desktop management, automation, and Docker container maintenance.

> [!IMPORTANT]
> **These scripts are built for single-admin servers.** They assume every account with shell access on the machine is trusted — typically a VPS, homelab box, or Raspberry Pi that you alone administer. Several deliberate design choices trade local privilege-boundary hardening for practicality and lockout safety. If your server has untrusted local users, read the **Security model** section below before running anything here.

## 📦 What's Inside?

This repository contains two main toolsets:

### 1. [Server Baseline Setup](server-baseline/)

**Purpose:** Fresh server/desktop installation and hardening automation

A comprehensive script for setting up and securing new Ubuntu/Debian servers and desktops (including Raspberry Pi). Features interactive mode for existing systems, fresh-install mode for new deployments, and a `--desktop` mode for Ubuntu Desktop with less restrictive security defaults.

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
- **Desktop mode** (`--desktop`): adapted security for Ubuntu Desktop (password auth, USB, printing preserved)
- **Control verification** ([`security-selfcheck.sh`](server-baseline/security-selfcheck.sh)): a daily check that the security controls actually produce a result, rather than merely being installed. Runs standalone on any host.
- **Security watchdog** ([`watchdogs/security-watchdog.sh`](server-baseline/watchdogs/security-watchdog.sh)): per-minute alert when `auditd`, `fail2ban`, or the fail2ban sshd jail stops or comes back, with a monthly self-test of the alert path.
- **Verify mode** (`--verify`): read-only check that the controls actually work — is fail2ban banning, is sshd on the right port only, does auditd have rules, is anything on `0.0.0.0` that should not be.

**Use Cases:**

- Setting up new servers from scratch
- Hardening existing servers
- **Securing Ubuntu Desktop installations**
- Standardizing server configurations
- Automated deployments

[→ Full Documentation](server-baseline/README.md)
[→ Remediating servers provisioned by an older version](docs/REMEDIATION-EXISTING-SERVERS.md)

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

### Server Baseline Setup — Choose Your Platform

| Platform | New system | Existing system |
| -------- | ---------- | --------------- |
| [**Ubuntu Server**](server-baseline/README.md#-ubuntu-server) | `sudo bash install-script.sh --fresh-install` | `sudo bash install-script.sh --interactive` |
| [**Raspberry Pi**](server-baseline/README.md#-raspberry-pi) | `sudo bash install-script.sh --fresh-install` | `sudo bash install-script.sh --section` |
| [**Ubuntu Desktop**](server-baseline/README.md#-ubuntu-desktop) | `sudo bash install-script.sh --fresh-install --desktop` | `sudo bash install-script.sh --interactive --desktop` |

```bash
# 1. Download
git clone https://github.com/Made-By-Adem/linux-server-management-scripts.git
cd linux-server-management-scripts/server-baseline

# 2. Preview changes first (recommended)
sudo bash install-script.sh --dry-run

# 3. Run the command for your platform (see table above)

# 4. Afterwards, verify the controls actually work (read-only)
sudo bash install-script.sh --verify
```

Already running an older version of these scripts? Use the update script instead
of a full re-run — it only prompts about what is genuinely wrong on that host:

```bash
sudo bash server-baseline/update-baseline.sh --check   # detect only
sudo bash server-baseline/update-baseline.sh           # detect, then fix per prompt
```

[→ Full platform-specific instructions](server-baseline/README.md#-quickstart---choose-your-platform)

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
git clone https://github.com/Made-By-Adem/linux-server-management-scripts.git
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

### Scenario 1: New System Setup

```bash
# 1. Clone repository (skip if already cloned)
git clone https://github.com/Made-By-Adem/linux-server-management-scripts.git
cd linux-server-management-scripts/server-baseline

# 2. Run fresh installation (pick one):
sudo bash install-script.sh --fresh-install            # Ubuntu Server / Raspberry Pi
sudo bash install-script.sh --fresh-install --desktop   # Ubuntu Desktop

# 3. Follow the interactive prompts
```

> [!TIP]
> See the [full platform-specific instructions](server-baseline/README.md#-quickstart---choose-your-platform) for detailed steps per platform.

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

## 🛡️ Security Model

### Threat model

These scripts harden a server against **remote attackers** — the internet-facing surface. They are **not** designed to defend against an unprivileged local user who already has shell access on the same machine.

**In scope:**

- Remote attackers: SSH brute force, exposed services, network-level attacks
- Automated scanners and opportunistic bots
- Unpatched packages and known CVEs

**Explicitly out of scope:**

- Privilege escalation by an unprivileged local user who already has a shell
- Isolation between multiple users sharing the same host
- Defending against a malicious administrator

If your server has untrusted local users — shared hosting, a jump box with several operators, or a CI runner executing untrusted code — **these scripts are not a good fit as they stand**. See *Hardening beyond the default* below.

### Deliberate design choices

The following are conscious trade-offs that follow from the threat model above, not oversights. Each one is safe under "every local user is trusted" and becomes a real risk if that assumption does not hold for you.

| Choice | Rationale | What it means for you |
| ------ | --------- | --------------------- |
| **Port 22 stays open** alongside the hardened SSH port (888) | Lockout prevention. If the new port, the firewall, or the SSH config turns out to be wrong, you can still get in — especially on a remote VPS with no console access. | Port 888 is rate-limited with `ufw limit`; port 22 is a plain `ufw allow`. Fail2ban monitors both (`port = 22,888`). This is a fallback that is easy to leave open forever — scope it to your own address with `ufw allow from <your-ip> to any port 22`, or remove port 22 from `sshd_config` and UFW once you have verified that 888 works. |
| **`PermitRootLogin prohibit-password`** | Key-based root login stays available for rescue and automation. | CIS and Lynis (SSH-7412) recommend `PermitRootLogin no`. Direct root login also bypasses the sudo audit trail. Change it if you don't need root over SSH. |
| **Docker publishes ports on all interfaces** — Portainer (9443), Portainer Agent (8000), Netdata (19999) | These services are meant to be reachable; that is the point of installing them. | Docker writes its own DNAT rules and **bypasses the UFW `INPUT` chain**. A UFW rule is not what makes these ports reachable, and declining the UFW prompt does *not* close them. Two ways to close this: answer **yes** to the Cloudflare-only prompt (binds everything to `127.0.0.1`), or accept the **DOCKER-USER filtering** prompt near the end of the run, which drops external inbound traffic to containers by default. |
| **Netdata runs without authentication** and mounts the systemd journal, `/etc/passwd`, and `docker.sock` | Full host visibility out of the box, no extra configuration. | Combined with the row above, an unauthenticated Netdata on a public IP exposes system logs, usernames, and the process table — and journald on a server like this routinely contains tokens and API keys. Note that mounting `docker.sock` with `:ro` does **not** make the Docker API read-only: the flag applies to the socket inode, every API verb still works, so the container is root-equivalent on the host. Either use Cloudflare-only mode, put it behind a reverse proxy with authentication, or restrict it with `ufw allow from <trusted-ip> to any port 19999` **plus** a DOCKER-USER rule. |
| **Config files are written as root** into the admin's home directory, and predictable `/tmp` paths are used for dry-run reports and downloads | Simplicity, and the paths are easy to find afterwards. | Symlink and TOCTOU races against these paths are possible, but they require an unprivileged local user — out of scope by design. |
| **`update-containers.sh` discovers compose files under `/home/*/docker/`** and runs them as root | Finds your stacks wherever they live, without configuration. | Anyone who can write to those directories can influence what root executes. Fine when you are the only user; not fine on a shared box. |
| **The admin is added to the `docker` group** | Run Docker without `sudo` for every command. | Docker group membership is functionally equivalent to root (`docker run -v /:/host --privileged`). Treat that account as a root account. |

### What the scripts do protect

- **SSH hardening:** password authentication disabled in server mode (kept in `--desktop` mode by design), public-key authentication enforced, non-standard port with rate limiting, `MaxSessions` limits
- **UFW firewall:** default-deny inbound, explicit rules per service, and an optional `DOCKER-USER` filter so container ports are actually covered (see the Docker caveat above)
- **Fail2ban:** intrusion prevention on SSH (ports 22 and 888), reading the systemd journal, with a post-install check that the jail is genuinely active
- **Automatic security updates:** unattended-upgrades for security patches
- **Kernel and system hardening:** 15+ sysctl parameters, USB storage control, core dump protection, `/proc` hardening, PAM and password policies (SHA-512, 65536 rounds)
- **Writable filesystem hardening:** `/tmp`, `/var/tmp` and `/dev/shm` mounted `noexec,nosuid,nodev`
- **File integrity monitoring:** AIDE with SHA-512 checksums, plus rkhunter and Lynis scans
- **Runtime auditing:** auditd rules covering shell profiles, cron, systemd units, the dynamic loader, SSH keys and execution from temporary directories
- **Control verification:** a daily self-check (`security-selfcheck.sh`) that asserts the controls above actually work, rather than merely being installed
- **HTTPS-only downloads:** all package sources over TLS; the Docker APT repository is added with a verified `signed-by` keyring
- **Backups before changes:** critical files such as `sshd_config` are backed up with a timestamp before modification
- **Installation logging:** every action logged to `/var/log/server_install_[timestamp].log` (this is the installer's own log, not runtime security auditing — that is auditd, above)

**Known gaps, honestly stated:**

- **Input validation is partial.** Numeric inputs (port numbers, session limits, container selection) and the Netdata Telegram credentials are validated with explicit checks. Free-text inputs — the DNS domain, the MOTD server description, and the security-scan Telegram token — are not. They are interpolated into `sed` expressions and generated scripts as-is. Malformed input can break the run; it is not a remote attack surface, but do not paste untrusted text into these prompts.
- **Container images are not pinned.** Netdata, Portainer, and cloudflared use `:latest`/`:lts`. A compromised upstream image would be pulled by the next `update-containers.sh` run, and both Portainer and Netdata mount `docker.sock`. Pin to a digest if that matters to you. `update-containers.sh` records the digest it deployed in its log, so you can at least reconstruct after the fact which image was running when.
- **Egress is unrestricted by default.** `ufw default allow outgoing` means anything that lands on the host can dial out on any port. The installer offers an opt-in egress allowlist; it is not the default because it breaks any service that uses a non-standard outbound port. Note that it governs **host** traffic only — container traffic is forwarded, not output, so it is not covered.
- **Not every download is integrity-checked.** The Lynis tarball and the NodeSource setup script are fetched over HTTPS but without a checksum or GPG signature.
- **Rollback is partial.** `sshd_config` always gets a timestamped backup, and interactive mode generates a `rollback.sh`. In `--fresh-install` mode there is no backup of `journald.conf`, `jail.local`, or the sysctl settings.

### Already running an older version of these scripts?

Servers provisioned before this change have a fail2ban jail that cannot ban, an
AIDE reporter that cannot report, audit rules that miss every common persistence
path, and container ports that UFW does not actually gate.

Run the update script:

```bash
sudo bash server-baseline/update-baseline.sh
```

It checks the host for each known problem, reports what is already correct, and
prompts you only about what is genuinely wrong there. Every fix verifies its own
result afterwards. `--check` detects without changing anything, `--dry-run`
shows what each fix would do, `--yes` accepts every default.

Safe to run repeatedly, and **it never closes SSH access** — port 22 is reported
as advice only.

[docs/REMEDIATION-EXISTING-SERVERS.md](docs/REMEDIATION-EXISTING-SERVERS.md)
has the same fixes as standalone commands, for applying one by hand or working
on a host without a checkout.

### Verifying that the controls work

```bash
sudo bash server-baseline/install-script.sh --verify
```

Installs nothing, changes nothing. It asks only whether each control produces a
result: is fail2ban **banning** (not just running), is sshd listening on the
expected port only, does auditd have rules loaded, is anything on `0.0.0.0` that
does not belong there, does `aide --check` complete, has `PATH` been hijacked.

Read-only and safe on production. Run it monthly and after every change. Exit
codes: `0` all passed, `1` at least one failure, `2` warnings only.

Every check in it exists because the corresponding control was installed,
reported healthy, and did nothing:

| Check | The failure it catches |
| ----- | ---------------------- |
| fail2ban bans vs. journal failures | A jail pointed at `/var/log/auth.log`, which Ubuntu 24.04 no longer writes. Starts fine, reports enabled, bans nothing. |
| sshd listening ports | Port 22 left open "temporarily" forever, or 888 never actually activating. `sshd_config` is not the authority here — socket activation and `sshd_config.d` drop-ins override it. |
| Listeners on `0.0.0.0` | A management interface (Portainer 9443, Netdata 19999, a bot API) exposed to the internet — including container ports, which UFW does not gate. |
| `aide --check` exit code | A check that errors out, reported as "no changes" — and then refreshes its own baseline. |
| auditd rules loaded, stop events | auditd stopped by malware in one second, with no alert anywhere. |
| PATH resolution of `top`/`crontab`/`lsof` | A directory prepended to `PATH` in `/etc/profile`, with replacements that filter their own output. |
| Second `dockerd`/`containerd` | Container workloads on a separate daemon with its own data-root, invisible to `docker ps`. |
| Executables in `/tmp`, `/dev/shm` | Payloads staged in world-writable directories. |
| Secrets in process argv | Tokens passed on a container command line, readable through `/proc`. |

It runs daily at 06:00 when installed by the baseline, and stays silent unless
something fails.

Alongside it, [`watchdogs/security-watchdog.sh`](server-baseline/watchdogs/security-watchdog.sh)
runs every minute and alerts on **state transitions**, in either direction, of
`auditd`, `fail2ban`, and — separately — whether the fail2ban **sshd jail** is
actually reachable. That last one is tracked on its own because "fail2ban is
active" was true throughout the incident while the jail banned nothing. The two are complementary: the self-check is level-triggered and
answers "is everything healthy right now", the watchdog is edge-triggered and
answers "did something just change". auditd can be stopped and a payload
deployed inside a single minute, which a daily check reports far too late.

```bash
sudo security-watchdog --test      # prove the alert path works
sudo security-watchdog --status    # current vs. last recorded state
```

It also fires a deliberate test alert monthly, because an alerting chain that
has gone quiet is indistinguishable from "nothing happened" until you make it
speak on purpose.

> Run these from somewhere other than the host they watch, too. Alerting that
> lives on the machine it monitors goes quiet at exactly the moment it matters.

### Optional Docker daemon hardening

Two `daemon.json` settings are worth knowing about but are **not** applied by
default, because both have real breakage potential on a running host:

| Setting | What it does | Why it is not the default |
| ------- | ------------ | ------------------------- |
| `"no-new-privileges": true` | Blocks gaining privileges through setuid binaries and file capabilities, for all containers. | Netdata's plugins rely on file capabilities; this breaks `apps.plugin`. Apply per-container with `security_opt: [no-new-privileges:true]` on the containers that tolerate it. |
| `"icc": false` | Blocks container-to-container traffic on the default bridge. | Breaks most compose stacks, which rely on services reaching each other by name. Use explicit user-defined networks instead. |

### Hardening beyond the default

If your threat model includes untrusted local users, make at least these changes before using the scripts:

1. Bind all Docker services to `127.0.0.1` (use Cloudflare-only mode) and reach them through a tunnel, VPN, or authenticated reverse proxy.
2. Remove `/home/*/docker` from the search paths in `update-containers.sh`, or require that compose files are owned by root before executing them.
3. Set `PermitRootLogin no` and close port 22 once port 888 is verified.
4. Do not add regular users to the `docker` group; consider rootless Docker instead.
5. Add `umask 077` to the scripts so generated files are not world-readable by default.

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


## 💡 Next Step: Remote Monitoring & Control

Once your server is set up and hardened, consider adding [Linux Server Telegram Bot](https://github.com/Made-By-Adem/linux-server-telegram-bot) — a lightweight companion tool that lets you monitor and manage your server directly from Telegram.

- **Automated monitoring** — tracks CPU, memory, disk, Docker containers, and systemd services every 5 minutes
- **Auto-recovery** — automatically restarts failed services and containers before you even notice
- **Remote control** — start/stop/restart services, view logs, reboot, and run commands — all from your phone
- **No VPN or SSH needed** — manage your server from anywhere via Telegram

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
