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
| `/var/lib/rkhunter/tmp`, `/var/lib/rkhunter/db` | rkhunter's scratch copies and its own properties database, both rewritten daily |
| `/root/.cache`, `/root/.vscode-server`, `/root/.copilot`, `/root/.bash_history` | editor and shell session data |
| `<checkout>/.git/{objects,logs,refs,index,…}` | git rewrites these on every pull |

Two of these are worth understanding rather than just accepting.

**Package metadata costs nothing to exclude.** Apt indexes are
signature-verified, so a tampered index makes apt fail rather than install
something. There was no attack here that AIDE was catching.

**rkhunter's own database was kept monitored, and that was wrong.** The
reasoning was sound — an attacker who edits `rkhunter_prop_list.dat` makes
rkhunter blind, so watching it seems like exactly what AIDE is for. But the
file is rewritten by every scan and by rkhunter's apt hook, so it changes for
legitimate reasons every single day. AIDE could never have distinguished
tampering from normal operation there, and what it produced instead was a
nightly alert on every host. That is the same trade already accepted for
`/var/lib/aide` and `/var/lib/server-baseline`: a control you cannot read is
worth less than one you can.

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

## Working an alert down to zero

The procedure above assumes you are tuning a fresh baseline. More often the
starting point is a Telegram alert with ten entries and a count of two hundred,
and the question is which handful of rules makes tomorrow silent. That is an
iterative drill-down, and it converges fast — one fleet went from 210 changed
entries to structurally zero in three rounds of exactly this.

**Round: concentrate, drill, name, exclude.**

```bash
LOG=/var/log/aide-check-$(date +%Y%m%d).log

# Where do the changes concentrate? Start shallow.
grep -E '^[^[:space:]]+: /' "$LOG" \
  | sed 's/.*: //' | cut -d/ -f1-5 | sort | uniq -c | sort -rn | head -10

# Then drill into the biggest group, one path level deeper each time,
# until the count splits into directories you can NAME:
grep -E ': /home/docker/myapp' "$LOG" \
  | sed 's/.*: //' | cut -d/ -f1-9 | sort | uniq -c | sort -rn | head -10
```

Stop drilling when every group is attributable — "that is the database's WAL",
"those are the app's own logs". A group you cannot name is not an exclusion
candidate; it is the finding.

**The categories that keep coming back.** Every churn source found across six
hosts fell into one of these, and the same reasoning applies each time:

| Category | Examples | Why AIDE never had signal there |
|---|---|---|
| Live database files | `postgres/pg_wal`, sqlite `-wal`/`-shm` | change on every transaction |
| Rotated logs and dated backups | `tailscaled.log1.txt`, `backup-20260817.sql.gz` | rewritten or rotated daily by design |
| Agent/session state | sqlite session stores, `sessions/`, `state/` | rewritten every run |
| App-managed content | a skills/plugins dir the app syncs itself | the sync source is the authority, not the copy on disk |
| Tool scratch space | `rkhunter/tmp`, `rkhunter/db`, apt metadata | rewritten by the tool's own timers |

The last two deserve a named trade when you exclude them: app-managed content
can be *code the app executes*, and a scanner's own database is what keeps the
scanner honest. Both were deliberately kept monitored at first, on sound
reasoning — and both produced an alert every single day, which meant the whole
report stopped being read. A file that changes daily for legitimate reasons is
one AIDE cannot police, whatever it contains. Write the trade into the comment
above the rule, so the decision survives you.

**One rule can cover a file family.** Rules are prefix regexes, so

```
!/var/www/remotely/Remotely\.db
```

matches `Remotely.db`, `Remotely.db-wal` and `Remotely.db-shm` in one line.
The flip side of the same property: an unescaped dot or a too-short prefix
matches more than you meant — check with the marker test below.

**Timing: never edit aide.conf mid-sequence.** If a maintenance round with a
closing refresh is still running, wait for it. Editing the config after the
final refresh means the next check reports your own exclusion rules as a
change; editing it during a run means two AIDE processes and a report about
half a state. The order is always: sequence finishes → add rules →
`--config-check` → one `aide-refresh` with a reason naming what was excluded.

**Expect a tail.** Agent-style workloads invent new state directories — the
first round caught the session store, the second caught the WAL, the third
caught a skills sync. Each round is five minutes with the drill above. The
trend is what matters: if the counts shrink toward the known monthly entries,
you are done; if a new group appears that you cannot name, that is not tuning
noise anymore.

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

## `Directory: /` on the first of the month — do not exclude this

Once a month the report will contain a single entry:

```
Changed: 1
- Directory: /
```

That is Lynis. Its monthly audit tests whether the root filesystem is writable
and whether it honours `noexec`, by dropping a probe file in `/`, using it, and
removing it again. Nothing is left behind except the directory's mtime.

It is tempting to silence it the way everything else on this page is silenced,
with a rule that watches `/` without its timestamps:

```
=/ p+u+g+i+n         # DO NOT add this without checking the next paragraph
```

Do not do that on the assumption it is free. Whether it costs anything depends
on something you have to look up per host: if the ruleset has no recursive
entry covering files that sit directly in `/`, then the directory's mtime is
the **only** signal that something appeared there. Removing it to save one line
a month would trade away the detection of a file dropped in the root of the
filesystem — which is a place attackers genuinely use, precisely because it is
so rarely looked at.

Check before deciding:

```bash
aide --config=/etc/aide/aide.conf --check 2>&1 | grep -c '^Added'
echo test > /aide-root-marker
aide --config=/etc/aide/aide.conf --check 2>&1 | grep -c 'aide-root-marker'
rm -f /aide-root-marker
```

If the marker is reported, files in `/` are covered on their own and the
attribute rule is safe. If it is not, keep the mtime and accept the monthly
line — it is one entry, on a known date, with a known cause.

That is the whole distinction this page is about. `update-success-stamp`
changed daily and meant nothing, so it went. This changes monthly, means
something specific, and you can name it. Those are not the same problem, and
the fact that both produce a line in the report does not make them so.

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
