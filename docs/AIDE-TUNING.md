# Tuning AIDE for a new server

AIDE compares the filesystem against a recorded baseline and reports every
difference. On a bare server that is exactly what you want. On a server that
actually runs something, a handful of directories change every day by design —
application logs, session data, database files — and if you leave them in, every
scheduled check reports differences forever.

That failure mode is worse than it sounds. An integrity monitor that always
fires is one nobody reads, and a monitor nobody reads is the same as no monitor
at all. Tuning is not weakening it; leaving it noisy is.

This document is about the part that cannot ship in the repository: which paths
on **your** server change by design.

---

## What ships by default

`install-script.sh` and `update-baseline.sh` both write the same generic set.
You do not have to do anything for these:

| Path | Why |
|---|---|
| `/var/lib/aide` | AIDE leaves `aide.db.new` behind on every update |
| `/var/lib/server-baseline` | the security watchdog rewrites its state every minute |
| `/var/lib/containerd`, `/var/lib/docker` | container snapshot contents |
| `/var/lib/systemd` | systemd's own bookkeeping |
| `/var/lib/apt/lists`, `/var/lib/ubuntu-advantage`, `/var/lib/landscape`, `/var/lib/update-notifier`, `/var/lib/PackageKit` | package metadata, refreshed by apt's timers |
| `/root/.cache`, `/root/.vscode-server`, `/root/.copilot`, `/root/.bash_history` | editor and shell session data |
| `<checkout>/.git/{objects,logs,refs,index,…}` | git rewrites these on every pull |

Two of these are worth understanding rather than just accepting.

**Package metadata costs nothing to exclude.** Apt indexes are
signature-verified, so a tampered index makes apt fail rather than install
something. There was no attack here that AIDE was catching.

**The `.git` exclusion is deliberately partial.** `hooks` and `config` stay
monitored, because a git hook is executable code that runs as whoever runs
`git`. Excluding `.git` wholesale would create a persistence location inside the
very tree this repository deploys to every host.

---

## Finding what churns on a new server

Do not guess, and do not exclude a directory because it appears in the first
report. Run the baseline, let one real check happen, then read what it actually
found.

**Step 1 — what kind of change is it?**

```bash
grep -oE '^[[:space:]]*(Mtime|Ctime|Size|SHA256|SHA512|Inode|Perm|Uid|Gid|Linkcount)' \
  /var/log/aide-check-$(date +%Y%m%d).log | tr -d ' ' | sort | uniq -c | sort -rn
```

This is the question that matters most, and it is cheap. If the counts are
almost entirely `Mtime` and `Ctime` with only a handful of `SHA512`, then
nothing's *contents* changed — you are looking at a bulk file operation such as
a restore, a redeploy or an rsync. If `SHA512` and `Size` run into the
thousands, something rewrote real data and that needs an explanation before
anything gets excluded.

**Step 2 — which files actually changed contents?**

```bash
awk '/^File: /{f=$2} /SHA512|Size/{print f}' \
  /var/log/aide-check-$(date +%Y%m%d).log | sort -u
```

This is the list to read line by line. On a healthy host every entry is
attributable: a package you upgraded, a config you edited, a log the
application is writing. Anything you cannot place is the finding.

**Step 3 — where are the differences concentrated?**

```bash
grep -E '^[^[:space:]]+: /' /var/log/aide-check-$(date +%Y%m%d).log \
  | sed 's/.*: //' | cut -d/ -f1-4 | sort | uniq -c | sort -rn | head -20
```

The directories at the top of this list are your exclusion candidates.

**Step 4 — when did it happen?**

```bash
find /path/that/churned -type f -newermt 'yesterday' \
  -printf '%TH:%TM\n' | sort | uniq -c | sort -rn | head
```

Timestamps clustered in one or two minutes mean one operation, and one
operation can be named. Spread across the day means normal application
activity, which is what exclusions are for.

---

## Writing the rules

Site-specific rules go at the end of `/etc/aide/aide.conf`, under the
`LOCAL EXCLUSIONS` marker. `update-baseline` writes that block once and never
touches it again, so what you put there survives every later update.

```bash
cat >> /etc/aide/aide.conf <<'EOF'

# Local: application runtime output.
!/home/pos-servers/[^/]+/logs
!/home/pos-servers/[^/]+/scanapp-data
!/home/docker/[^/]+/data
!/var/www/remotely/logs
EOF
```

### Two syntax rules that will cost you an evening

**A rule must start with `/`.** AIDE matches selection lines as a regex
anchored at the beginning of the path, and it rejects anything that does not
begin with a slash. There is no way to express "any `.git` directory anywhere"
— `!.*/\.git/objects` is not a valid rule. It does not fail on that one line
either: AIDE refuses the entire configuration and every check exits 17,
"missing configuration", which looks exactly like a broken installation.

Use the real path instead. If it varies per host, generate it — that is why
`update-baseline` builds the `.git` rules from the checkout location rather
than shipping them as literals.

**A dot is a regex metacharacter.** `!/var/log/foo.log` also matches
`foo1log`, `fooXlog` and so on. Escape it: `!/var/log/foo\.log`.

### What to exclude, and what not to

Exclude the *directory that changes*, never the application tree around it.
`!/home/myapp/logs` is right. `!/home/myapp` is not — the code and configuration
beside those logs are exactly what an integrity monitor exists to watch.

If you find yourself wanting to exclude something because you cannot explain
it, stop. That is the case AIDE was installed for.

---

## Always validate, then rebuild

```bash
aide --config=/etc/aide/aide.conf --config-check && echo OK
```

On Debian and Ubuntu a bare `aide --config-check` fails with "missing
configuration" — `aide` does not read `/etc/aide/aide.conf` by itself. Pass
`--config` explicitly, or use `aide.wrapper` where it exists.

Then absorb the changes into the baseline:

```bash
aide-refresh --reason 'excluded application logs on first setup'
```

`aide-refresh` checks first, reports exactly what it is about to absorb, and
only then updates. Never run a bare `aide --update`: that turns whatever is on
disk into the new normal without leaving a record of what it accepted.

Exclusions only take effect after this rebuild. Until then the old entries are
still in the database and still reported.

---

## The routine afterwards

| When | Command |
|---|---|
| After a deliberate `apt upgrade` | `aide-refresh --reason 'apt upgrade <date>'` |
| Container and system updates | `update-containers --interactive` — offers the refresh itself |
| After pulling repository changes | `update-baseline` |
| Reviewing an alert you caused | `aide-refresh --reason '<what you did>'` |
| Reviewing an alert you cannot explain | do **not** refresh — investigate |

The `--reason` is not decoration. It ends up in the Telegram record, so in a
month's time it is still possible to answer why four hundred files changed on a
given evening.

Left alone, a stale baseline produces the same noise every night until someone
stops reading it. That is the state this repository's AIDE setup was actually
in for months: the reporter parsed its own output wrongly, reported "no
changes" every single night, and then ran `aide --update` to absorb whatever it
had failed to notice.

---

## When a server reports nothing

Silence from a healthy host is a real result — but only if a clean run is
actually delivered. Verify that end to end on a new server rather than
assuming:

```bash
aide-telegram.sh          # takes 10-20 minutes, sends the same message as the 05:00 cron
```

You should receive "✅ AIDE Daily Check — No changes detected". If nothing
arrives, the reporter is not reaching Telegram and every future silence is
meaningless.

To prove the exclusions do what you think, drop two markers and check that only
one is reported:

```bash
echo test > /etc/aide-test-marker                    # monitored
echo test > /home/myapp/logs/aide-test-marker        # excluded
aide --config=/etc/aide/aide.conf --check | grep -c aide-test-marker   # must be 1

rm -f /etc/aide-test-marker /home/myapp/logs/aide-test-marker
aide-refresh --reason 'after test markers'
```

---

## See also

- [REMEDIATION-EXISTING-SERVERS.md](REMEDIATION-EXISTING-SERVERS.md) — bringing
  an already-running server up to this baseline
- `server-baseline/security-selfcheck.sh` — runs `aide --config-check` daily, so
  a configuration broken by an edit surfaces the next morning rather than the
  next time someone looks
