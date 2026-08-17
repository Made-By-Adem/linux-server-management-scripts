# Command reference

Every command an operator needs on a host provisioned by this repository, in
one place. Grouped by what you are trying to achieve, not by which file
implements it.

Two conventions throughout:

- **From the checkout** means `sudo bash <path>` inside the cloned repository.
- **As a command** means the symlink in `/usr/local/bin`, created by the shell
  improvements section of the installer. The symlinks point back at the
  checkout, so `git pull` updates the command too.

| Command | Points at |
|---|---|
| `server-setup` | `server-baseline/install-script.sh` |
| `update-baseline` | `server-baseline/update-baseline.sh` |
| `update-containers` | `update-containers/update-containers.sh` |
| `backup-folders` | `backup-script/backup.sh` |

These four are symlinks. The next four are *installed copies* — `update-baseline`
refreshes them from the checkout, so after pulling repository changes you have
to run it for the copies to catch up:

| Command | Installed to |
|---|---|
| `security-selfcheck` | `/usr/local/bin/security-selfcheck.sh` |
| `security-watchdog` | `/usr/local/bin/security-watchdog.sh` |
| `aide-refresh` | `/usr/local/bin/aide-refresh.sh` |
| — | `/usr/local/bin/aide-telegram.sh`, `rkhunter-telegram.sh`, `lynis-telegram.sh` |

---

## Provisioning and updating

```bash
sudo bash server-baseline/install-script.sh --fresh-install    # new server, minimal prompts
sudo bash server-baseline/install-script.sh --interactive      # existing server, confirm per component
sudo bash server-baseline/install-script.sh --section          # pick individual sections from a menu
sudo bash server-baseline/install-script.sh --dry-run          # change nothing, show what it would do
sudo bash server-baseline/install-script.sh --verify           # change nothing, check whether controls WORK
sudo bash server-baseline/install-script.sh --desktop          # Ubuntu Desktop: keeps password auth, USB, printing
sudo bash server-baseline/install-script.sh --help
```

For a host provisioned by an older version of the installer, `update-baseline`
detects which of the known problems this host actually has and offers to fix
them one at a time. It is safe to run repeatedly and nothing in it closes SSH
access.

```bash
sudo update-baseline              # detect, then prompt per fix
sudo update-baseline --check      # detect only, change nothing
sudo update-baseline --dry-run    # show what each fix would do
sudo update-baseline --yes        # accept the default for every prompt
```

**Run `update-baseline` after every `git pull`.** It is what re-installs the
reporters, the self-check and `aide-refresh` from the checkout. Pulling alone
leaves the old copies in `/usr/local/bin`.

---

## Verifying that the controls work

The self-check answers one question: are the controls actually working, or do
they merely exist. Exit codes: `0` all passed, `1` at least one FAIL, `2` only
warnings.

```bash
sudo security-selfcheck                  # full human-readable report
sudo security-selfcheck --quiet          # output only when something is wrong (this is what cron runs)
sudo security-selfcheck --telegram       # send failures to Telegram
sudo security-selfcheck --deep           # also run a real aide --check (10-20 minutes)
sudo security-selfcheck --test-alert     # send even when nothing is wrong — proves the alert path
```

The watchdog is edge-triggered: it alerts the moment something changes and is
silent the rest of the time.

```bash
sudo security-watchdog                   # check and alert on change (what the timer runs)
sudo security-watchdog --status          # print current state, change nothing
sudo security-watchdog --test            # send a test alert, verifying the alert path
sudo security-watchdog --reset           # re-baseline everything without alerting

systemctl status security-watchdog.timer
journalctl -u security-watchdog -n 50
```

`--reset` is the command to reach for after a deliberate change that the
watchdog has flagged — a new listening port, a new authorized key.

---

## AIDE — file integrity

### Daily use

```bash
sudo /usr/local/bin/aide-telegram.sh     # full check + Telegram report (10-20 min) — same as the 05:00 cron
sudo aide-refresh --reason 'apt upgrade 2026-08-17'   # check, report what it absorbs, then update the baseline
sudo aide-refresh --check-only            # report only, never touch the database
sudo aide-refresh --help
```

Never run a bare `aide --update`. That turns whatever is on disk into the new
normal without leaving a record of what was accepted. `aide-refresh` reports
first, and `--reason` ends up in the Telegram record.

| Situation | Command |
|---|---|
| Alert you caused and recognise | `aide-refresh --reason '<what you did>'` |
| Alert you cannot explain | do **not** refresh — investigate |
| After a deliberate `apt upgrade` | `aide-refresh --reason 'apt upgrade <date>'` |
| After container/system updates | `update-containers --interactive` offers the refresh itself |
| After pulling repository changes | `update-baseline` |

### Reading a report

```bash
LOG=/var/log/aide-check-$(date +%Y%m%d).log

# What kind of change is it? Mostly Mtime/Ctime means a bulk file operation,
# thousands of SHA512/Size means something rewrote real data.
grep -oE '^[[:space:]]*(Mtime|Ctime|Size|SHA256|SHA512|Inode|Perm|Uid|Gid|Linkcount)' "$LOG" \
  | tr -d ' ' | sort | uniq -c | sort -rn

# Which files actually changed contents — the list to read line by line
awk '/^File: /{f=$2} /SHA512|Size/{print f}' "$LOG" | sort -u

# Where are the differences concentrated — your exclusion candidates
grep -E '^[^[:space:]]+: /' "$LOG" | sed 's/.*: //' | cut -d/ -f1-4 | sort | uniq -c | sort -rn | head -20

# When did it happen — one cluster means one operation, and one operation can be named
find /path/that/churned -type f -newermt 'yesterday' -printf '%TH:%TM\n' | sort | uniq -c | sort -rn | head
```

### Exclusions

Site-specific rules go at the end of `/etc/aide/aide.conf`, under the
`# LOCAL EXCLUSIONS` marker. That block is written once and never touched
again, so what you put there survives every later `update-baseline`.

```bash
cat >> /etc/aide/aide.conf <<'EOF'

# Local: application runtime output.
!/home/docker/xibo/shared/backup
!/home/docker/xibo/shared/cms/library
!/home/docker/xibo/shared/db
!/root/\.config/Code
!/root/\.config/htop
EOF

aide --config=/etc/aide/aide.conf --config-check && echo OK
aide-refresh --reason 'excluded application runtime dirs'
```

Two syntax rules: a rule **must start with `/`** (AIDE rejects the entire
configuration otherwise, and every check then exits 17), and **a dot is a regex
metacharacter** — escape it as `\.`. Exclude the directory that changes, never
the application tree around it. Exclusions only take effect after the refresh.

Full reasoning and the per-host tuning procedure:
[AIDE-TUNING.md](AIDE-TUNING.md).

### Proving the exclusions do what you think

```bash
echo test > /etc/aide-test-marker                     # monitored
echo test > /home/myapp/logs/aide-test-marker         # excluded
aide --config=/etc/aide/aide.conf --check | grep -c aide-test-marker   # must be 1

rm -f /etc/aide-test-marker /home/myapp/logs/aide-test-marker
aide-refresh --reason 'after test markers'
```

---

## rkhunter — rootkit scanning

```bash
sudo rkhunter --config-check                       # does the config parse? if not, every scan aborts
sudo rkhunter --update                             # refresh the signature database
sudo rkhunter --check --skip-keypress              # full scan, no prompts
sudo rkhunter --check --skip-keypress --nocolors   # what the reporter runs
sudo /usr/local/bin/rkhunter-telegram.sh           # scan + Telegram report — same as the 03:00 cron
sudo grep '^Warning:' /var/log/rkhunter.log        # the findings of the last scan
```

**`--propupd` is the one to be careful with.** It tells rkhunter that the
current file properties are the correct ones, so running it on a compromised
host makes the compromise the new baseline. Only after a deliberate change you
can name:

```bash
sudo rkhunter --propupd --skip-keypress            # after an apt upgrade you performed
```

The failure mode this repository ran into: rkhunter installed, cron firing
daily, every report green — because the scan aborted on a configuration error
before it checked anything. *No warnings in the log is not the same as no
findings.* The self-check therefore verifies that the log contains a
`System checks summary` line; `rkhunter --config-check` is what tells you why it
does not.

Common warnings after this baseline is applied are expected rather than
alarming: a hidden file that a package legitimately ships, or a script replaced
by a distribution update. Read them, then whitelist deliberately in
`/etc/rkhunter.conf` (`ALLOWHIDDENFILE=`, `SCRIPTWHITELIST=`) — never by
lowering `ALLOW_SSH_ROOT_USER` or the SSH settings the installer set.

---

## Lynis — system audit

```bash
sudo lynis audit system                            # full audit, interactive output
sudo lynis audit system --quick                    # no waiting between sections
sudo lynis audit system --quiet --quick            # what the reporter runs
sudo lynis show version
sudo lynis update info                             # is this Lynis release still current?
sudo /usr/local/bin/lynis-telegram.sh              # audit + Telegram report — same as the monthly cron

grep 'hardening_index=' /var/log/lynis-report.dat  # the score
grep 'suggestion\[\]=' /var/log/lynis-report.dat   # every suggestion, full list
grep 'warning\[\]=' /var/log/lynis-report.dat      # the ones that matter first
```

Reports live in `/var/log/lynis-report.dat` (machine-readable) and
`/var/log/lynis.log` (the run itself). Lynis is installed from the CISOfy
release tarball into `/usr/local/lynis`, not from apt, because the packaged
version is usually several releases behind.

Its monthly audit is also the reason AIDE reports `Changed: 1 — Directory: /`
on the first of the month: Lynis drops a probe file in `/` to test whether the
root filesystem honours `noexec`, and removes it again. Do not exclude that —
see [AIDE-TUNING.md](AIDE-TUNING.md#directory--on-the-first-of-the-month--do-not-exclude-this).

---

## debsums — package file integrity

Verifies the checksums of installed package files against the package database,
which catches a modified system binary that came from a package (Lynis
PKGS-7370). Runs daily via `/etc/cron.d/debsums` when `CRON_CHECK=yes` in
`/etc/default/debsums`.

```bash
sudo debsums -s                # silent: only report files that fail
sudo debsums -c                # list changed files only
sudo debsums -a                # include config files (noisy — they are meant to change)
grep CRON_CHECK /etc/default/debsums
```

---

## System package updates

```bash
sudo apt-get update && sudo apt-get upgrade -y     # or the `update` alias
sudo apt-get dist-upgrade                          # kernel and dependency changes too
sudo update-containers --unattended --update-system # system packages, then all containers

# unattended-upgrades: security patches install themselves. Verify that it does.
systemctl status unattended-upgrades
sudo unattended-upgrade --dry-run --debug          # what it would install right now
tail -50 /var/log/unattended-upgrades/unattended-upgrades.log
cat /var/run/reboot-required 2>/dev/null           # does a patch need a reboot?
```

Any deliberate upgrade changes hundreds of files under `/usr` and `/etc`, so it
produces an AIDE alert the next morning. Absorb it with a reason attached:

```bash
sudo aide-refresh --reason 'apt upgrade 2026-08-17'
```

---

## Scheduled jobs

What runs when, and from where. If a report does not arrive, this table is
where to start.

| When | What | Defined in |
|---|---|---|
| every minute | `security-watchdog.sh` | `security-watchdog.timer` (systemd) |
| 03:00 daily | `rkhunter-telegram.sh` | `/etc/cron.d/security-scans` |
| 05:00 daily | `aide-telegram.sh` | `/etc/cron.d/security-scans` |
| 06:00 daily | `security-selfcheck.sh --quiet --telegram` | `/etc/cron.d/security-selfcheck` |
| daily (cron.daily) | `debsums` package verification | `/etc/cron.d/debsums` + `/etc/default/debsums` |
| 04:00 on the 1st | `lynis-telegram.sh` | `/etc/cron.d/security-scans` |
| 09:00 on the 1st | `security-watchdog.sh --test` | `/etc/cron.d/security-watchdog-test` |

Verify they are all present:

```bash
cat /etc/cron.d/security-scans /etc/cron.d/security-selfcheck /etc/cron.d/security-watchdog-test
systemctl list-timers security-watchdog.timer
```

If the AIDE line is missing — which is exactly what "no AIDE message at all"
looks like — add it back:

```bash
grep -q 'aide-telegram.sh' /etc/cron.d/security-scans 2>/dev/null || {
  printf '\n# AIDE daily integrity check at 05:00\n0 5 * * * root /usr/local/bin/aide-telegram.sh\n' \
    | sudo tee -a /etc/cron.d/security-scans >/dev/null
  sudo chmod 644 /etc/cron.d/security-scans
}
```

Debian's own `aide-common` package also ships `/etc/cron.daily/dailyaidecheck`,
which mails root instead of alerting you. It duplicates a 20-minute scan and it
can absorb changes into the baseline by itself. Check what it is set to do:

```bash
grep -E 'CRON_DAILY_RUN|COPYNEWDB' /etc/default/aide
```

`COPYNEWDB` must not be `yes`. Once `aide-telegram.sh` is scheduled,
`CRON_DAILY_RUN=no` is the sane setting.

---

## When a report does not arrive

Silence is never a clean bill of health. All reporters send on **every** path —
a clean AIDE run sends `✅ AIDE Daily Check`, so no message at all means the
pipeline is broken, not that nothing changed.

```bash
# Is it scheduled at all?
grep -r aide /etc/cron.d/ /etc/cron.daily/ 2>/dev/null

# Did it run, and when?
ls -lat /var/log/aide-check-*.log | head -5

# What did it say about sending? Reporters log failures to syslog under their own name.
journalctl -t aide-telegram.sh --since -7d
journalctl -t rkhunter-telegram.sh --since -7d
journalctl -t lynis-telegram.sh --since -7d
journalctl -t security-selfcheck.sh --since -7d
journalctl -t security-watchdog.sh --since -7d

# Are the credentials resolvable?
ls -l /etc/server-baseline/selfcheck.env      # or the .env beside the checkout

# Force a message out, end to end
sudo security-selfcheck --test-alert
sudo security-watchdog --test
sudo /usr/local/bin/aide-telegram.sh          # 10-20 minutes
```

---

## Writable filesystem hardening

`/tmp`, `/var/tmp` and `/dev/shm` are world-writable and executable by default,
which is the standard staging ground for dropper malware. The installer mounts
them `noexec,nosuid,nodev` (Lynis FILE-6310). To apply it on a host that
skipped that section:

```bash
sudo cp /etc/fstab /etc/fstab.backup.$(date +%Y%m%d)
echo 'tmpfs /dev/shm tmpfs rw,noexec,nosuid,nodev 0 0' | sudo tee -a /etc/fstab
sudo mount -o remount,noexec,nosuid,nodev /dev/shm
findmnt -no OPTIONS /dev/shm
```

Docker gives every container its own `/dev/shm`, so containers are unaffected
unless one runs with `--ipc=host`. To undo:

```bash
sudo mount -o remount,exec /dev/shm    # and remove the line from /etc/fstab
```

---

## Containers

```bash
sudo update-containers --interactive                    # pick containers manually
sudo update-containers --unattended                     # update everything (for cron)
sudo update-containers --dry-run                        # preview, change nothing
sudo update-containers --interactive --update-system    # system packages first, then containers
sudo update-containers --help
```

Logs land in `/var/log/docker-updates/update_<timestamp>.log`.

Shell aliases installed by the baseline:

```bash
dps      # docker ps, formatted as name / status / ports
dlog     # docker logs -f --tail 100
ll       # ls -lah
update   # apt-get update && apt-get upgrade -y
```

---

## Backups

```bash
backup-folders          # uses backup-script/.env
backup-folders oc2      # uses backup-script/.env.oc2
```

The argument is a plain config name; only letters, digits, `_` and `-` are
accepted, because it is used to build a path that gets sourced. See
[backup-script/README.md](../backup-script/README.md).

---

## Logs

| Path | Contents |
|---|---|
| `/var/log/aide-check-<date>.log` | scheduled AIDE checks (kept 30 days) |
| `/var/log/aide-refresh-<date>.log` | every baseline refresh, with its `--reason` |
| `/var/log/server_install_<timestamp>.log` | installer's own run log |
| `/var/log/docker-updates/update_<timestamp>.log` | container updates |
| `/var/log/rkhunter.log` | last rootkit scan — `grep '^Warning:'` for the findings |
| `/var/log/lynis-report.dat` | last Lynis audit, machine-readable (hardening index, suggestions) |
| `/var/log/lynis.log` | the Lynis run itself |
| `/var/log/unattended-upgrades/` | which security patches installed themselves, and when |
| `journalctl -u auditd` | runtime auditing; `ausearch -k persist` for the persistence rules |

---

## See also

- [AIDE-TUNING.md](AIDE-TUNING.md) — which paths to exclude and why
- [REMEDIATION-EXISTING-SERVERS.md](REMEDIATION-EXISTING-SERVERS.md) — bringing
  an already-running server up to this baseline
- [server-baseline/README.md](../server-baseline/README.md)
- [linux-server-telegram-bot/README.md](../linux-server-telegram-bot/README.md)
  — on-demand control from Telegram (`/menu`, `/command`, container and service
  management)
