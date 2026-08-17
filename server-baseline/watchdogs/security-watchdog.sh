#!/bin/bash
###############################################################################
# Security watchdog - alerts on STATE CHANGES of security-relevant things
#
# The daily self-check is level-triggered: it reports what is true at 06:00.
# This is edge-triggered: it reports the moment something changes, and says
# nothing the rest of the time.
#
# That distinction is the whole point. In the incident this was written for,
# auditd was stopped at 07:24:49 as the first step of the compromise and the
# payload was deployed 25 seconds later. A daily check would have reported it
# hours afterwards. Nothing alerted at all.
#
# WHAT IS WATCHED
#
#   Units (WATCH_UNITS)           systemd state, alerting on stop and on return
#     auditd                      stopping it is the first move of this attack class
#     fail2ban                    if it stops, SSH accepts unlimited attempts
#     acct                        process accounting; it was found off AFTER a reboot,
#                                 losing the command history for the window that mattered
#     fail2ban-jail               synthetic: is the sshd jail actually reachable?
#
#   Monitors (WATCH_MONITORS)     content snapshots, alerting on what changed
#     listeners                   a new port bound to 0.0.0.0 / ::
#     root-keys                   authorized_keys for root and admin users
#     persistence-files           /etc/profile, /root/.profile, /etc/cron* contents
#     tmpfs-exec                  executable files appearing in /tmp, /var/tmp, /dev/shm
#     mount-flags                 noexec/nosuid/nodev disappearing from a mount
#     path-hijack                 .local/bin under a system path, shim directories
#     hidden-dirs                 hidden working directories under system paths
#     ld-preload                  /etc/ld.so.preload is non-empty
#     ufw                         firewall disabled or default policy changed
#     docker-daemons              a second dockerd/containerd appearing
#     container-images            a container image never seen on this host before
#     boot-id                     the machine rebooted (context for the rest)
#
# fail2ban-jail is tracked separately from the fail2ban unit because "fail2ban
# is active" was true throughout the incident while the jail banned nothing.
# A unit being up is not the same as the control working.
#
# Alerts state WHAT changed, not merely that something did. A message saying
# "authorized_keys changed" at 03:00 without the diff is not actionable.
#
# Usage:
#   security-watchdog.sh           # check and alert on change (for cron/timer)
#   security-watchdog.sh --test    # send a test alert, verifying the alert path
#   security-watchdog.sh --status  # print current state, change nothing
#   security-watchdog.sh --reset   # re-baseline everything without alerting
#
# Config, from /etc/server-baseline/selfcheck.env:
#   TELEGRAM_BOT_TOKEN=...
#   TELEGRAM_CHAT_ID=...
#   WATCH_UNITS="auditd fail2ban acct"
#   WATCH_JAIL="sshd"                   # "" disables the jail check
#   WATCH_MONITORS="listeners root-keys persistence-files tmpfs-exec mount-flags path-hijack hidden-dirs ld-preload ufw docker-daemons container-images boot-id"
#
# Drop any monitor from WATCH_MONITORS that turns out to be too noisy for your
# environment. Each one is independent.
###############################################################################

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
set -u

# Credentials live with the project checkout, not in /etc. Resolution order:
#   1. $CONFIG_FILE                        explicit override
#   2. $ENV_FILE_DEFAULT                   absolute path recorded at install time
#   3. .env near this script                for running straight from the checkout
#   4. /etc/server-baseline/selfcheck.env  legacy location, still honoured
#
# The recorded path is the fragile part: move or re-clone the project and it
# stops resolving, which would make every alert silently stop. That is why
# security-selfcheck fails outright when no credentials resolve anywhere - the
# breakage shows up within a day instead of as permanent silence.
ENV_FILE_DEFAULT=""   # replaced with an absolute path at install time

resolve_env_file() {
    local self_dir c
    self_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" 2>/dev/null && pwd)" || self_dir=""
    for c in "${CONFIG_FILE:-}" "$ENV_FILE_DEFAULT"              "$self_dir/.env" "$self_dir/../.env" "$self_dir/../../.env"              /etc/server-baseline/selfcheck.env; do
        if [ -n "$c" ] && [ -r "$c" ]; then echo "$c"; return 0; fi
    done
    return 1
}
CONFIG_FILE="$(resolve_env_file || true)"
[ -n "$CONFIG_FILE" ] && . "$CONFIG_FILE"
STATE_DIR="/var/lib/server-baseline"

# Accept the alternative variable names some setups already use
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-${SECRET_TOKEN:-}}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-${CHAT_ID_PERSON1:-}}"
WATCH_UNITS="${WATCH_UNITS:-auditd fail2ban acct}"
WATCH_JAIL="${WATCH_JAIL-sshd}"
WATCH_MONITORS="${WATCH_MONITORS:-listeners root-keys persistence-files tmpfs-exec mount-flags path-hijack hidden-dirs ld-preload ufw docker-daemons container-images boot-id}"

MODE="check"
case "${1:-}" in
    --test)   MODE="test" ;;
    --status) MODE="status" ;;
    --reset)  MODE="reset" ;;
    # To the end of the header block, not to a line number: the header grows
    # whenever a monitor is added, and a hard-coded range silently cuts the
    # newest one out of the help text.
    --help|-h) sed -n '2,/^#####/p' "$0" | sed '$d'; exit 0 ;;
    "") : ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
esac

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must run as root" >&2
    exit 1
fi

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"

# Syslog is the trace that survives when Telegram does not. Never let its
# absence produce noise on a scheduled run.
syslog() {
    if command -v logger >/dev/null 2>&1; then
        logger -t security-watchdog "$1"
    fi
    return 0
}

# Telegram's HTML parse mode rejects a message containing a raw <, > or &.
# A journal line or a key comment with any of those would make the API return
# 400 and the alert would vanish silently - the exact failure class this
# watchdog exists to catch, so it must not be reintroduced here.
html_escape() {
    sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

send_telegram() {
    local msg="$1"

    if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
        syslog "no Telegram credentials configured; alert not sent"
        echo "$msg" >&2
        return 1
    fi

    # Retried, and this one matters most: the watchdog is edge-triggered, so a
    # dropped alert is never re-sent. The state file has already moved on, and
    # the event - auditd stopping, a new listener appearing - is gone with it.
    # Attempts 2 and 3 force IPv4: api.telegram.org resolves to IPv6 first on
    # these hosts, and a flapping v6 route returns HTTP 000, no response at all.
    local http_code attempt v4
    for attempt in 1 2 3; do
        v4=(); [ "$attempt" -gt 1 ] && v4=(-4)
        http_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
            "${v4[@]}" \
            -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            -d chat_id="${TELEGRAM_CHAT_ID}" \
            -d parse_mode="HTML" \
            -d disable_web_page_preview="true" \
            --data-urlencode text="$msg")
        [ "$http_code" = "200" ] && return 0
        case "$http_code" in 4*) break ;; esac   # refused; retrying changes nothing
        [ "$attempt" -lt 3 ] && sleep $((attempt * 3))
    done

    if [ "$http_code" = "200" ]; then
        return 0
    fi
    # A silently failing alerter is worse than none, so make it loud in syslog.
    syslog "Telegram send FAILED with HTTP ${http_code}"
    return 1
}

###############################################################################
# Unit checks - state is a single word, alerting on stop and on return
###############################################################################

impact_of() {
    case "$1" in
        auditd)
            echo "Syscall auditing is off. Changes to shell profiles, cron, systemd units and SSH keys are no longer recorded. Stopping auditd is a normal part of a reboot - and also the first step of a compromise." ;;
        fail2ban)
            echo "Brute-force protection is off. SSH is now accepting unlimited authentication attempts without banning anything." ;;
        acct)
            echo "Process accounting is off. No record is being kept of which commands ran. This has been observed to fail silently after a reboot, leaving no command history for exactly the window an investigation needs." ;;
        fail2ban-jail)
            echo "The fail2ban service is running but the sshd jail is not reachable. This is the dangerous case: the service reports healthy while banning nothing at all." ;;
        *)
            echo "This security control is no longer running." ;;
    esac
}

recovery_of() {
    case "$1" in
        auditd)        echo "Audit logging is running again." ;;
        fail2ban)      echo "Brute-force protection is running again." ;;
        acct)          echo "Process accounting is recording again." ;;
        fail2ban-jail) echo "The sshd jail is reachable again." ;;
        *)             echo "The control is running again." ;;
    esac
}

state_of() {
    case "$1" in
        fail2ban-jail)
            if ! systemctl is-active fail2ban >/dev/null 2>&1; then
                echo "service-down"
            elif fail2ban-client status "$WATCH_JAIL" >/dev/null 2>&1; then
                echo "active"
            else
                echo "jail-unreachable"
            fi
            ;;
        *)
            systemctl is-active "$1" 2>/dev/null || echo "inactive"
            ;;
    esac
}

###############################################################################
# Monitors - state is a content snapshot, alerting on what changed
###############################################################################

# Human-readable title per monitor
monitor_title() {
    case "$1" in
        listeners)         echo "PUBLIC LISTENERS CHANGED" ;;
        root-keys)         echo "AUTHORIZED SSH KEYS CHANGED" ;;
        persistence-files) echo "STARTUP OR CRON FILE CHANGED" ;;
        tmpfs-exec)        echo "EXECUTABLE IN A TEMPORARY DIRECTORY" ;;
        mount-flags)       echo "MOUNT HARDENING CHANGED" ;;
        path-hijack)      echo "PATH HIJACK DETECTED" ;;
        hidden-dirs)      echo "HIDDEN DIRECTORY UNDER A SYSTEM PATH" ;;
        ld-preload)       echo "LD_PRELOAD HIJACK DETECTED" ;;
        ufw)              echo "FIREWALL STATE CHANGED" ;;
        docker-daemons)   echo "DOCKER DAEMON SET CHANGED" ;;
        container-images) echo "NEW CONTAINER IMAGE" ;;
        boot-id)          echo "SYSTEM REBOOTED" ;;
        *)                echo "STATE CHANGED: $1" ;;
    esac
}

monitor_impact() {
    case "$1" in
        listeners)
            echo "A port bound to all interfaces is reachable from the internet unless a firewall stops it - and for container ports, UFW does not. In the incident this watchdog was built for, a management API came back online after a reboot and was exploited 25 seconds later." ;;
        root-keys)
            echo "An added key grants permanent access and survives password changes and reboots. Verify you made this change." ;;
        persistence-files)
            echo "A file that runs automatically changed - a login shell profile or a cron entry. This is where persistence is installed: one appended line survives every reboot. Package upgrades legitimately touch /etc/cron.daily, so check whether an upgrade ran." ;;
        tmpfs-exec)
            echo "An executable file appeared in a world-writable directory. This is the standard staging pattern: write the payload somewhere anyone can write, then run it. If these directories are mounted noexec it cannot execute, but its presence still needs explaining." ;;
        mount-flags)
            echo "A mount lost or gained one of noexec, nosuid, nodev or ro. Losing noexec on /tmp, /var/tmp or /dev/shm re-opens the standard dropper staging path, and it happens silently: a duplicate fstab entry was enough to make one host drop it at the next daemon-reload, ten minutes after the hardening was applied and verified." ;;
        hidden-dirs)
            echo "A hidden directory appeared where nothing legitimate lives. This kit family used /usr/bin/wbin for its second Docker daemon, /var/.i.* and /tmp/.t.* as working directories, and /dev/shm/.config for proxyware configuration." ;;
        path-hijack)
            echo "A directory under a system path now precedes /usr/bin in PATH. This is how top, htop, lsof, crontab, df and mount get replaced with versions that filter their own output. Treat every observation made through those tools as unreliable." ;;
        ld-preload)
            echo "Every dynamically linked binary on this host now loads the listed library first. This is a full userland rootkit hook." ;;
        ufw)
            echo "The host firewall state changed. If it is now inactive, every service on this machine is exposed." ;;
        docker-daemons)
            echo "A second Docker daemon with its own data-root runs containers that do not appear in 'docker ps'. That is not filtering - it is a separate container environment." ;;
        container-images)
            echo "A container image not previously seen on this host is now running. Verify it is one of yours." ;;
        boot-id)
            echo "The machine rebooted. Expect accompanying alerts about services stopping - that is normal for a reboot. If you did not initiate it, that is the finding." ;;
        *)
            echo "This monitored state changed." ;;
    esac
}

# Severity: crit = always an incident, warn = verify it was you,
# info = context only. Drives the emoji and nothing else.
monitor_level() {
    case "$1" in
        path-hijack|ld-preload|docker-daemons|hidden-dirs) echo "crit" ;;
        persistence-files|tmpfs-exec|mount-flags) echo "warn" ;;
        boot-id)                               echo "info" ;;
        *)                                     echo "warn" ;;
    esac
}

# Whether a non-empty snapshot is inherently bad. Those alert on the very first
# run too - a host that is already compromised at install time must not have
# that state silently accepted as the baseline.
monitor_expects_empty() {
    case "$1" in
        path-hijack|ld-preload|tmpfs-exec|hidden-dirs) return 0 ;;
        *)                      return 1 ;;
    esac
}

# Current snapshot for a monitor: zero or more lines, order-independent.
# Must never include PIDs or timestamps - those change constantly and would
# turn every monitor into a source of noise.
monitor_snapshot() {
    case "$1" in

    listeners)
        # port + owning process, never the PID
        ss -tlnpH 2>/dev/null | while read -r line; do
            local addr port proc
            addr=$(echo "$line" | awk '{print $4}')
            case "$addr" in
                0.0.0.0:*|'*':*|'[::]':*) : ;;
                *) continue ;;
            esac
            port=${addr##*:}
            proc=$(echo "$line" | grep -oE 'users:\(\("[^"]+"' | grep -oE '"[^"]+"' | tr -d '"' | head -1)
            echo "${port} ${proc:-unknown}"
        done | sort -u
        ;;

    persistence-files)
        # Hash the contents, so ANY change is caught - not only the .local/bin
        # signature that path-hijack looks for. These are the files that run
        # automatically: one appended line survives every reboot.
        # sha256sum marks binary-mode reads with a leading '*' on the filename;
        # strip it so the snapshot is identical however the tool was invoked.
        for f in /etc/profile /etc/bash.bashrc /etc/environment \
                 /root/.profile /root/.bashrc /etc/crontab; do
            [ -f "$f" ] && sha256sum "$f" 2>/dev/null | awk '{sub(/^\*/,"",$2); print $2" "$1}'
        done
        for d in /etc/profile.d /etc/cron.d /etc/cron.hourly /etc/cron.daily \
                 /etc/cron.weekly /etc/cron.monthly /var/spool/cron/crontabs; do
            [ -d "$d" ] || continue
            find "$d" -maxdepth 1 -type f -exec sha256sum {} + 2>/dev/null | \
                awk '{sub(/^\*/,"",$2); print $2" "$1}'
        done
        true
        ;;

    tmpfs-exec)
        find /tmp /var/tmp /dev/shm -maxdepth 3 -type f -executable 2>/dev/null | head -50
        true
        ;;

    mount-flags)
        # tmpfs-exec above watches for payloads appearing; this watches whether
        # the mount that is supposed to stop them running is still in force.
        #
        # It reverts silently. On one host /dev/shm had two identical fstab
        # entries and the next `systemctl daemon-reload` dropped its noexec,
        # ten minutes after the hardening had been applied and verified. Nothing
        # was logged, /tmp and /var/tmp were unaffected, and the only reason it
        # surfaced was a self-check run by hand that same afternoon.
        for m in /tmp /var/tmp /dev/shm /home /var; do
            findmnt -no OPTIONS "$m" 2>/dev/null | \
                tr ',' '\n' | grep -xE 'noexec|nosuid|nodev|ro' | sort | \
                tr '\n' ',' | sed "s|^|${m} |; s|,\$||"
            echo ""
        done | grep -v '^$'
        true
        ;;

    root-keys)
        for f in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
            [ -f "$f" ] || continue
            # Fingerprints, not raw keys: stable, and safe to put in a message
            ssh-keygen -lf "$f" 2>/dev/null | while read -r bits fp comment rest; do
                echo "$f ${fp} ${comment}"
            done
        done | sort -u
        ;;

    path-hijack)
        grep -ls '/bin/\.local/bin\|/usr/bin/\.local/bin' \
            /etc/profile /etc/profile.d/* /etc/environment /etc/bash.bashrc \
            /root/.bashrc /root/.profile 2>/dev/null | sed 's/^/profile: /'
        for d in /usr/bin/.local /bin/.local; do
            [ -d "$d" ] && echo "shim-dir: $d"
        done
        for b in top htop lsof crontab df mount strace ldd; do
            for d in /usr/bin /bin; do
                [ -f "$d/.local/bin/$b" ] && echo "shim: $d/.local/bin/$b"
            done
        done
        true
        ;;

    ld-preload)
        [ -s /etc/ld.so.preload ] && sed 's/^/preload: /' /etc/ld.so.preload
        true
        ;;

    ufw)
        if command -v ufw >/dev/null 2>&1; then
            ufw status verbose 2>/dev/null | grep -iE '^status:|^default:' | tr -s ' '
        fi
        ;;

    docker-daemons)
        # Normalised command lines, no PIDs. Legitimate daemons are excluded by
        # their standard invocation; anything else is reported.
        ps -eo args 2>/dev/null | \
            grep -E '(^|/)(dockerd|containerd)( |$)' | \
            grep -v grep | \
            grep -vE -- '-H fd://|--config /etc/containerd|^/usr/bin/containerd$|containerd-shim' | \
            cut -c1-120 | sort -u
        ;;

    container-images)
        # 'ps -a', not 'ps': the loader containers in the incident ran for well
        # under a minute each. A poll of running containers alone would have
        # missed them entirely; as exited containers they stayed visible for
        # hours. Anything started with --rm still escapes this.
        if command -v docker >/dev/null 2>&1; then
            docker ps -a --format '{{.Image}}' 2>/dev/null | sort -u
        fi
        ;;

    hidden-dirs)
        # Working directories used by this kit family. Each is a hidden name
        # under a system path, where nothing legitimate lives.
        for d in /usr/bin/wbin /bin/wbin /usr/lib/exi /dev/shm/.config \
                 /root/.config/cron; do
            [ -e "$d" ] && echo "dir: $d"
        done
        ls -d /var/.i.* /tmp/.t.* /var/tmp/.* 2>/dev/null | \
            grep -vE '/\.{1,2}$' | sed 's/^/dir: /'
        true
        ;;

    boot-id)
        cat /proc/sys/kernel/random/boot_id 2>/dev/null
        ;;

    esac
}

###############################################################################
# Which checks apply to this host
###############################################################################

WATCH_LIST=""
for unit in $WATCH_UNITS; do
    if systemctl cat "$unit" >/dev/null 2>&1; then
        WATCH_LIST="$WATCH_LIST $unit"
    fi
done
if [ -n "$WATCH_JAIL" ] && command -v fail2ban-client >/dev/null 2>&1; then
    WATCH_LIST="$WATCH_LIST fail2ban-jail"
fi
WATCH_LIST="${WATCH_LIST# }"

HOST=$(hostname)
TS=$(date '+%d-%m-%Y %H:%M:%S')

###############################################################################
# --test / --status / --reset
###############################################################################

if [ "$MODE" = "test" ]; then
    LINES=""
    for unit in $WATCH_LIST; do
        LINES="${LINES}• <code>${unit}</code>: $(state_of "$unit")
"
    done
    for m in $WATCH_MONITORS; do
        n=$(monitor_snapshot "$m" 2>/dev/null | grep -c . || true)
        LINES="${LINES}• <code>${m}</code>: ${n:-0} entries
"
    done
    MSG="<b>🧪 WATCHDOG TEST</b>
<b>Host:</b> <code>${HOST}</code>
<b>Time:</b> ${TS}

<b>Currently watching:</b>
${LINES}
<i>This is a deliberate test. If you are reading it, the alert path works.</i>"
    if send_telegram "$MSG"; then
        echo "Test alert sent."
        exit 0
    fi
    echo "Test alert FAILED - see: journalctl -t security-watchdog" >&2
    exit 1
fi

if [ "$MODE" = "status" ]; then
    echo "Units:"
    for unit in $WATCH_LIST; do
        printf '  %-18s now=%-18s last_seen=%s\n' \
            "$unit" "$(state_of "$unit")" \
            "$(cat "${STATE_DIR}/${unit}.state" 2>/dev/null || echo '(none)')"
    done
    echo "Monitors:"
    for m in $WATCH_MONITORS; do
        now=$(monitor_snapshot "$m" 2>/dev/null | grep -c . || true)
        was=$(grep -c . "${STATE_DIR}/${m}.snapshot" 2>/dev/null || true)
        printf '  %-18s now=%-4s entries   baseline=%s\n' "$m" "${now:-0}" "${was:-none}"
    done
    exit 0
fi

if [ "$MODE" = "reset" ]; then
    for unit in $WATCH_LIST; do
        state_of "$unit" > "${STATE_DIR}/${unit}.state"
        chmod 600 "${STATE_DIR}/${unit}.state"
    done
    for m in $WATCH_MONITORS; do
        monitor_snapshot "$m" 2>/dev/null > "${STATE_DIR}/${m}.snapshot"
        chmod 600 "${STATE_DIR}/${m}.snapshot"
    done
    echo "Baseline reset. Nothing was alerted."
    exit 0
fi

###############################################################################
# Transition check
###############################################################################

EXIT_CODE=0

# --- Units ------------------------------------------------------------------

for unit in $WATCH_LIST; do
    STATE_FILE="${STATE_DIR}/${unit}.state"

    NOW=$(state_of "$unit")
    NOW=${NOW:-unknown}

    # First run has no baseline. Assume "active" so a control that is already
    # broken at install time is reported rather than silently accepted.
    PREV=$(cat "$STATE_FILE" 2>/dev/null || echo "active")

    # Persist before alerting. If the send fails we would otherwise re-fire
    # every minute; the send failure itself is logged separately.
    echo "$NOW" > "$STATE_FILE"
    chmod 600 "$STATE_FILE"

    [ "$NOW" = "$PREV" ] && continue

    LABEL=$(echo "$unit" | tr '[:lower:]-' '[:upper:] ')

    if [ "$NOW" = "active" ]; then
        MSG="<b>✅ ${LABEL} RESTORED</b>
<b>Host:</b> <code>${HOST}</code>
<b>Time:</b> ${TS}
<b>Status:</b> active (was <code>${PREV}</code>)

$(recovery_of "$unit")"
        syslog "${unit} restored on ${HOST} (was ${PREV})"
    else
        case "$unit" in
            fail2ban-jail) JOURNAL_UNIT="fail2ban" ;;
            *)             JOURNAL_UNIT="$unit" ;;
        esac
        LAST=$(journalctl -u "$JOURNAL_UNIT" -n1 --no-pager -o cat 2>/dev/null | head -c 300 | html_escape)
        WHO=$(who 2>/dev/null | wc -l)

        MSG="<b>🚨 ${LABEL} STOPPED</b>
<b>Host:</b> <code>${HOST}</code>
<b>Time:</b> ${TS}
<b>Status:</b> <code>${NOW}</code> (was <code>${PREV}</code>)
<b>Sessions:</b> ${WHO} logged in

<b>Impact:</b>
$(impact_of "$unit")

<b>Last log entry:</b>
<pre>${LAST}</pre>

<i>Verify whether this was expected.</i>"
        syslog "${unit} STOPPED on ${HOST} (state=${NOW}, was ${PREV})"
        EXIT_CODE=1
    fi

    send_telegram "$MSG" || true
done

# --- Monitors ---------------------------------------------------------------

TMP_NOW=$(mktemp) || exit 1
TMP_PREV=$(mktemp) || exit 1
trap 'rm -f "$TMP_NOW" "$TMP_PREV"' EXIT

for m in $WATCH_MONITORS; do
    SNAP_FILE="${STATE_DIR}/${m}.snapshot"

    monitor_snapshot "$m" 2>/dev/null | grep -v '^$' > "$TMP_NOW"

    FIRST_RUN=false
    if [ -f "$SNAP_FILE" ]; then
        cp "$SNAP_FILE" "$TMP_PREV"
    else
        : > "$TMP_PREV"
        FIRST_RUN=true
    fi

    # Persist before alerting, same reasoning as the unit checks above.
    cp "$TMP_NOW" "$SNAP_FILE"
    chmod 600 "$SNAP_FILE"

    if cmp -s "$TMP_NOW" "$TMP_PREV"; then
        continue
    fi

    # On the very first run there is nothing to compare against. Stay quiet,
    # unless the monitor is one where any content at all is a finding.
    if [ "$FIRST_RUN" = true ]; then
        if monitor_expects_empty "$m" && [ -s "$TMP_NOW" ]; then
            : # fall through and alert
        else
            continue
        fi
    fi

    ADDED=$(grep -vxF -f "$TMP_PREV" "$TMP_NOW" 2>/dev/null | head -10 | html_escape)
    REMOVED=$(grep -vxF -f "$TMP_NOW" "$TMP_PREV" 2>/dev/null | head -10 | html_escape)

    DETAIL=""
    [ -n "$ADDED" ]   && DETAIL="${DETAIL}<b>Appeared:</b>
<pre>${ADDED}</pre>
"
    [ -n "$REMOVED" ] && DETAIL="${DETAIL}<b>Gone:</b>
<pre>${REMOVED}</pre>
"
    [ -z "$DETAIL" ]  && DETAIL="<i>Content changed but the diff is empty - check manually.</i>
"

    case "$(monitor_level "$m")" in
        crit) ICON="🚨"; EXIT_CODE=1 ;;
        info) ICON="ℹ️" ;;
        *)    ICON="⚠️" ;;
    esac

    WHO=$(who 2>/dev/null | wc -l)

    MSG="<b>${ICON} $(monitor_title "$m")</b>
<b>Host:</b> <code>${HOST}</code>
<b>Time:</b> ${TS}
<b>Sessions:</b> ${WHO} logged in

${DETAIL}
<b>Why this matters:</b>
$(monitor_impact "$m")

<i>Verify whether this was expected.</i>"

    syslog "${m} changed on ${HOST}"
    send_telegram "$MSG" || true
done

exit "$EXIT_CODE"
