# Running this baseline on a Raspberry Pi

Everything in this repository works on a Pi. Three things need a decision that
a server does not, and all three come down to the same trade: a Pi has less CPU
than the hosts these scripts were written for, and it often boots from an SD
card, which wears out from writes in a way an SSD does not.

None of this is about weakening the baseline. It is about which controls earn
their cost on this particular machine.

---

## Is this host on flash?

```bash
lsblk -o NAME,ROTA,TRAN,MOUNTPOINT | head
findmnt -no SOURCE /
```

A root filesystem on `mmcblk0…` is an SD card. On `sda`/`nvme0n1` over USB or
PCIe it is an SSD, and none of the wear guidance below applies — run the
baseline exactly as you would on a server.

`update-baseline` performs the same check and prints the SD-specific notes only
when they are relevant.

---

## AIDE

**A full `aide --check` can take hours on a Pi and has been known to knock one
over.** It walks every monitored file and hashes it with SHA-512; on a Pi 4
with an SD card that is an order of magnitude slower than on the servers this
baseline targets.

Leaving it out is a legitimate choice, and the tooling handles it:

| What | Behaviour without AIDE |
|---|---|
| `security-selfcheck` | `[WARN] AIDE is not installed` — a warning, never a failure |
| `update-baseline` section 5 | touches `/etc/aide/aide.conf` only if it exists |
| `update-baseline` section 12 | skipped unless both the binary and a database exist |
| Anything | never installs AIDE by itself |

What you give up is real: file integrity monitoring is the control that would
tell you a system binary changed. On a Pi the compensating controls are the
per-minute watchdog (persistence files, authorized keys, listeners) and
`debsums`, which verifies package files against their checksums and costs a
fraction of an AIDE run:

```bash
sudo debsums -s          # only reports files that fail
```

If you do want AIDE on a Pi, run it weekly rather than daily and expect the
scan to take a long time:

```bash
# /etc/cron.d/security-scans - weekly instead of daily
0 5 * * 0 root /usr/local/bin/aide-telegram.sh
```

---

## The watchdog on an SD card

`security-watchdog.timer` fires every minute. Each run reads a handful of
files, hashes the startup and cron files, and lists listeners and containers.
On an SSD that is free. On an SD card it is 1,440 rounds of small reads a day,
and the state files under `/var/lib/server-baseline` are rewritten each time.

The reads are the cheap part; the writes are what wears flash. If you want to
reduce them:

```bash
sed -i 's/^OnUnitActiveSec=1min/OnUnitActiveSec=5min/' /etc/systemd/system/security-watchdog.timer
systemctl daemon-reload && systemctl restart security-watchdog.timer
```

**Know what you are trading.** The watchdog exists because auditd was stopped
25 seconds before a payload landed. At one minute you hear about that within
the minute; at five minutes you hear about it up to five minutes later. On a
Pi running a home workload that is usually an acceptable trade. On a Pi doing
anything internet-facing, it is not.

`update-baseline` rewrites the timer whenever the watchdog itself is updated,
so re-apply the interval after an update. The self-check does not police the
interval, deliberately — it is a local decision, not a defect.

---

## rkhunter

The daily scan hashes several thousand files. On an SD card that is the single
heaviest scheduled job on the machine. Weekly is a reasonable compromise:

```bash
# /etc/cron.d/security-scans
0 3 * * 0 root /usr/local/bin/rkhunter-telegram.sh
```

The self-check verifies that the last scan *completed*, and allows a log up to
eight days old, so a weekly schedule does not make it complain.

---

## noexec on /tmp, /var/tmp and /dev/shm

`update-baseline` offers all three together. On a **headless** Pi, accept it —
there is nothing to break.

On a Pi running a desktop, `/dev/shm` with `noexec` breaks Chromium and every
Electron application. Decline the offer and apply the other two by hand:

```bash
cp /etc/fstab /etc/fstab.bak.$(date +%F)
printf '/tmp     /tmp     none  rw,noexec,nosuid,nodev,bind  0 0\n' >> /etc/fstab
printf '/var/tmp /var/tmp none  rw,noexec,nosuid,nodev,bind  0 0\n' >> /etc/fstab
mount --bind /tmp /tmp         && mount -o remount,noexec,nosuid,nodev /tmp
mount --bind /var/tmp /var/tmp && mount -o remount,noexec,nosuid,nodev /var/tmp
findmnt -no OPTIONS /tmp
```

Do **not** install `shm-noexec.service` on a desktop Pi: it re-applies the
setting at every boot, which is exactly what you do not want there.

---

## auditd and process accounting

Both write continuously. On an SD card, cap the audit log so it cannot grow
without bound:

```bash
# /etc/audit/auditd.conf
max_log_file = 8
num_logs = 3
max_log_file_action = ROTATE
```

`update-baseline` reports auditd and acct as advisory when they are absent —
it never installs them. On a Pi where you have decided against them, that
advisory line is the honest record of a decision, not a defect to fix.

---

## What stays exactly the same

Everything that costs nothing to run: SSH hardening, the fail2ban jail, UFW and
the `DOCKER-USER` filter, the reporters and their alert paths, the
`/etc/fstab` and `ssh.socket` consistency checks, and the daily self-check
itself. None of those poll, hash or write in any volume worth counting.

Run the same order as anywhere else:

```bash
sudo bash server-baseline/security-selfcheck.sh      # read-only, see the state
sudo bash server-baseline/update-baseline.sh --check # detect, change nothing
sudo bash server-baseline/update-baseline.sh         # apply, one prompt per fix
sudo bash server-baseline/test-alerts.sh --quick     # prove the alert path
```

`test-alerts.sh` without `--quick` runs rkhunter, Lynis and AIDE back to back.
On a Pi that is a long afternoon; `--quick` proves the watchdog and self-check
in seconds and leaves the rest to the scheduled runs.

And the closing sequence — after pulling changes, this updates everything and
then proves it. Without AIDE the two `aide-refresh` steps from the server
version drop out:

```bash
git pull --ff-only origin main \
 && sudo bash server-baseline/update-baseline.sh \
 && sudo bash server-baseline/test-alerts.sh; \
 sudo security-selfcheck | tail -3
```

Four messages instead of five — the AIDE job is reported as "not installed"
rather than silently skipped, which is the honest version of a host that made
that choice on purpose.

---

## See also

- [COMMANDS.md](COMMANDS.md) — every operator command
- [AIDE-TUNING.md](AIDE-TUNING.md) — if you do run AIDE here
- [REMEDIATION-EXISTING-SERVERS.md](REMEDIATION-EXISTING-SERVERS.md)
