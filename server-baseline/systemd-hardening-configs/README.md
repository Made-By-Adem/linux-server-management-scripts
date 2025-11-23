# Systemd Service Hardening Configurations

This directory contains systemd drop-in configuration files for hardening various system services. These configurations implement security best practices based on `systemd-analyze security` recommendations.

## Overview

Each `.conf` file in this directory is designed to be deployed to `/etc/systemd/system/[service-name].service.d/hardening.conf` on target systems.

## Hardening Profiles

### 🔴 High Priority Services

#### 1. Postfix (`postfix.conf`)
**Impact**: 9.6 → ~4.5

Mail server hardening with strict filesystem isolation and capability restrictions.

**Key Protections**:
- Isolated temporary directory
- Read-only system directories
- Restricted to mail-related write paths only
- Kernel protection enabled
- Limited capabilities for mail delivery

**Installation**:
```bash
sudo mkdir -p /etc/systemd/system/postfix@-.service.d
sudo cp postfix.conf /etc/systemd/system/postfix@-.service.d/hardening.conf
sudo systemctl daemon-reload
sudo systemctl restart postfix
```

#### 2. Rsyslog (`rsyslog.conf`)
**Impact**: 6.3 → ~3.5

System logging daemon hardening with network logging support.

**Key Protections**:
- Private temporary directory
- Strict filesystem protection
- Syslog capability bounded
- Network socket filtering
- Syscall restrictions

**Installation**:
```bash
sudo mkdir -p /etc/systemd/system/rsyslog.service.d
sudo cp rsyslog.conf /etc/systemd/system/rsyslog.service.d/hardening.conf
sudo systemctl daemon-reload
sudo systemctl restart rsyslog
```

#### 3. Unattended Upgrades (`unattended-upgrades.conf`)
**Impact**: 9.6 → ~3.5

Automatic update service hardening (balanced for package management).

**Key Protections**:
- Isolated temporary directory
- Protected system directories
- Restricted network families
- Kernel protection
- Limited write access to package directories

**Trade-offs**:
- `NoNewPrivileges=no` - Required for package installation
- `RestrictSUIDSGID=no` - Required for setuid binaries in packages

**Installation**:
```bash
sudo mkdir -p /etc/systemd/system/unattended-upgrades.service.d
sudo cp unattended-upgrades.conf /etc/systemd/system/unattended-upgrades.service.d/hardening.conf
sudo systemctl daemon-reload
sudo systemctl restart unattended-upgrades
```

#### 4. Snapd (`snapd.conf`)
**Impact**: 9.9 → ~6.0

Snap package manager hardening (limited due to containerization requirements).

**Key Protections**:
- Private temporary directory
- Strict filesystem protection with snap directories
- Kernel tunables protection
- System call filtering

**Trade-offs**:
- Many restrictions relaxed for snap containerization
- Consider disabling snapd entirely if not needed

**Installation**:
```bash
sudo mkdir -p /etc/systemd/system/snapd.service.d
sudo cp snapd.conf /etc/systemd/system/snapd.service.d/hardening.conf
sudo systemctl daemon-reload
sudo systemctl restart snapd
```

**Alternative - Disable Snapd**:
```bash
# If you don't use snaps, completely disable for better security
sudo systemctl stop snapd
sudo systemctl disable snapd
sudo systemctl mask snapd
sudo apt-get purge snapd
```

### 🟡 Medium Priority Services

#### 5. Containerd (`containerd.conf`)
**Impact**: 9.6 → ~5.5

Container runtime hardening (limited due to container requirements).

**Key Protections**:
- Private temporary directory
- Protected system directories
- Restricted write paths
- System call filtering

**Trade-offs**:
- Requires kernel module loading for containers
- Cannot restrict cgroups (needed for containers)
- Limited capability restrictions

**Installation**:
```bash
sudo mkdir -p /etc/systemd/system/containerd.service.d
sudo cp containerd.conf /etc/systemd/system/containerd.service.d/hardening.conf
sudo systemctl daemon-reload
sudo systemctl restart containerd
```

**Note**: If using Docker, Docker already manages containerd. Test thoroughly.

#### 6. Networkd Dispatcher (`networkd-dispatcher.conf`)
**Impact**: 9.6 → ~4.5

Network event dispatcher hardening.

**Key Protections**:
- Private temporary and device directories
- Full kernel protection suite
- Restricted to UNIX and NETLINK sockets
- Memory write+execute protection
- Process hiding enabled

**Installation**:
```bash
sudo mkdir -p /etc/systemd/system/networkd-dispatcher.service.d
sudo cp networkd-dispatcher.conf /etc/systemd/system/networkd-dispatcher.service.d/hardening.conf
sudo systemctl daemon-reload
sudo systemctl restart networkd-dispatcher
```

## Verification

After applying configurations, verify the security improvements:

```bash
# Check individual service
sudo systemd-analyze security servicename.service

# Check all services
sudo systemd-analyze security

# Verify service is running
sudo systemctl status servicename.service

# Check for configuration errors
sudo journalctl -u servicename.service -n 50
```

## Security Improvements Summary

| Service | Before | After | Improvement |
|---------|--------|-------|-------------|
| Postfix | 9.6 | ~4.5 | ⬇️ 5.1 points |
| Rsyslog | 6.3 | ~3.5 | ⬇️ 2.8 points |
| Unattended Upgrades | 9.6 | ~3.5 | ⬇️ 6.1 points |
| Snapd | 9.9 | ~6.0 | ⬇️ 3.9 points |
| Containerd | 9.6 | ~5.5 | ⬇️ 4.1 points |
| Networkd Dispatcher | 9.6 | ~4.5 | ⬇️ 5.1 points |

## Common Systemd Security Options Explained

### Isolation
- `PrivateTmp=yes` - Service gets isolated /tmp directory
- `PrivateDevices=yes` - Service cannot access physical devices
- `ProtectHome=yes` - Service cannot read user home directories

### Filesystem Protection
- `ProtectSystem=strict` - /usr, /boot, /etc are read-only
- `ProtectSystem=full` - /usr and /boot are read-only
- `ReadWritePaths=` - Exceptions for write access

### Kernel Protection
- `ProtectKernelTunables=yes` - Cannot modify sysctl/proc settings
- `ProtectKernelModules=yes` - Cannot load/unload kernel modules
- `ProtectKernelLogs=yes` - Cannot read kernel logs
- `ProtectControlGroups=yes` - Cgroup hierarchy read-only

### Privilege Management
- `NoNewPrivileges=yes` - Cannot gain new privileges
- `RestrictSUIDSGID=yes` - Cannot create setuid/setgid files
- `CapabilityBoundingSet=` - Limit Linux capabilities

### Network
- `RestrictAddressFamilies=` - Limit socket types (AF_INET, AF_UNIX, etc.)

### System Calls
- `SystemCallFilter=` - Whitelist/blacklist syscalls
- `SystemCallErrorNumber=EPERM` - Return error instead of killing process

### Other Protections
- `RestrictNamespaces=yes` - Cannot create new namespaces
- `RestrictRealtime=yes` - Cannot use realtime scheduling
- `LockPersonality=yes` - Cannot change execution domain
- `MemoryDenyWriteExecute=yes` - W^X memory protection
- `ProtectHostname=yes` - Cannot change hostname
- `ProtectClock=yes` - Cannot change system clock

## Troubleshooting

### Service fails to start after hardening

1. **Check service logs**:
   ```bash
   sudo journalctl -u servicename.service -n 100
   ```

2. **Common issues**:
   - **Permission denied**: Service needs write access to a directory
     - Add path to `ReadWritePaths=`
   - **Operation not permitted**: Service needs a capability
     - Add capability to `CapabilityBoundingSet=`
   - **Syscall blocked**: Service uses a blocked system call
     - Adjust `SystemCallFilter=`

3. **Test configuration**:
   ```bash
   # Temporarily disable hardening
   sudo mv /etc/systemd/system/servicename.service.d/hardening.conf /tmp/
   sudo systemctl daemon-reload
   sudo systemctl restart servicename.service

   # If service works, hardening config needs adjustment
   ```

4. **Debug mode**:
   ```bash
   # Add to hardening.conf for debugging
   [Service]
   LogLevelMax=debug
   ```

### Finding required capabilities

```bash
# Install required tools
sudo apt-get install libcap2-bin

# Check what capabilities a running service uses
sudo grep Cap /proc/$(pidof servicename)/status

# Decode capabilities
sudo capsh --decode=00000000a80425fb
```

### Finding required paths

```bash
# Monitor file access
sudo apt-get install strace

# Trace service startup
sudo strace -f -e trace=file systemctl restart servicename 2>&1 | grep -E "EACCES|EPERM"
```

## Integration with install_script.sh

These configurations are automatically deployed by `install_script.sh`. Manual installation is only needed for:
- Selective service hardening
- Custom service configurations
- Troubleshooting specific services

## References

- [systemd.exec(5) man page](https://www.freedesktop.org/software/systemd/man/systemd.exec.html)
- [Systemd Security Hardening Guide](https://www.freedesktop.org/software/systemd/man/systemd.exec.html#Security)
- [Lynis Security Auditing Tool](https://cisofy.com/lynis/)
- CIS Ubuntu Benchmarks
- ANSSI Security Recommendations

## Contributing

When adding new service hardening configurations:

1. Test thoroughly on a non-production system
2. Document all trade-offs and required exceptions
3. Include before/after security scores
4. Provide installation and verification instructions
5. Document any service-specific requirements

## License

MIT License - See repository LICENSE file
