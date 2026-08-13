#!/bin/bash
###############################################################################
# Security Self-Check
#
# Answers one question: are the security controls on this host actually WORKING,
# or do they merely exist?
#
# Every check in here exists because the corresponding control was installed,
# reported healthy, and did nothing:
#   - fail2ban ran for months against a log file that no longer exists
#   - AIDE reported "no changes" while its own check was failing
#   - auditd was stopped by malware and nothing noticed
#   - a rootkit put itself in front of /usr/bin via /etc/profile
#
# "systemctl is-active" is not evidence. Each check below demands a real result.
#
# Usage:
#   sudo bash security-selfcheck.sh              # human-readable report
#   sudo bash security-selfcheck.sh --quiet      # only output when something is wrong
#   sudo bash security-selfcheck.sh --telegram   # send failures to Telegram
#   sudo bash security-selfcheck.sh --deep       # also run a full aide --check (10-20 min)
#   sudo bash security-selfcheck.sh --test-alert # send even when there is nothing wrong
#
# --test-alert is how you prove the alert path works. The daily run is silent
# on a healthy host, and silence is also what a broken reporter looks like -
# so there has to be one command that forces the message out.
#
# Configuration comes from the .env beside the project checkout (the legacy
# /etc/server-baseline/selfcheck.env is still read if that is where yours is):
#
#   TELEGRAM_BOT_TOKEN=...
#   TELEGRAM_CHAT_ID=...
#
#   # Containers that are SUPPOSED to hold host-level access. Without this the
#   # same three lines about Portainer and Netdata arrive every single day,
#   # which is how you learn to stop reading them. Format: name=risk,risk
#   SELFCHECK_ACK_HOST_ACCESS="portainer=docker.sock netdata=docker.sock"
#
#   # Ports a cloud firewall in front of this machine lets through. That layer
#   # leaves no trace on the host, so without this every port behind it is
#   # reported as internet-reachable. DECLARED, never measured - re-verify from
#   # outside whenever you change the provider's rules.
#   SELFCHECK_EXTERNAL_ALLOW="888 1000"
#
#   # This host's own intended services, on top of SSH and HTTP/HTTPS. Anything
#   # reachable and not listed here is what the report is actually for.
#   SELFCHECK_EXPECTED_PUBLIC="1000"
#
# Exit codes: 0 = all checks passed, 1 = at least one FAIL, 2 = only WARNs.
###############################################################################

# Reset PATH to system directories before doing anything else. If this host has
# a PATH hijack installed, inheriting the environment's PATH means running the
# attacker's replacements for the very tools used to detect them. Every command
# below is additionally invoked through an absolute path where it matters.
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

set -u

QUIET=false
TELEGRAM=false
DEEP=false
TEST_ALERT=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --quiet)    QUIET=true; shift ;;
        --telegram) TELEGRAM=true; shift ;;
        --deep)     DEEP=true; shift ;;
        # Implies --telegram: asking to test the alert without sending one is
        # not a thing anybody wants.
        --test-alert) TEST_ALERT=true; TELEGRAM=true; shift ;;
        --help|-h)
            # To the end of the header block, not to a line number: the header
            # has grown three times today and a hard-coded range silently cuts
            # the newest option out of the help text.
            /bin/sed -n '3,/^#####/p' "$0" | /bin/sed '$d'
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

FAILURES=()
WARNINGS=()
PASSES=()

pass() { PASSES+=("$1");   [ "$QUIET" = false ] && echo -e "  ${GREEN}[PASS]${NC} $1"; return 0; }
warn() { WARNINGS+=("$1"); [ "$QUIET" = false ] && echo -e "  ${YELLOW}[WARN]${NC} $1"; return 0; }
fail() { FAILURES+=("$1"); [ "$QUIET" = false ] && echo -e "  ${RED}[FAIL]${NC} $1"; return 0; }

section() { [ "$QUIET" = false ] && { echo ""; echo "── $1"; }; return 0; }

###############################################################################
# Configuration
#
# Resolved once, here, because two unrelated parts of this script need it: the
# Telegram credentials at the very end, and SELFCHECK_ACK_HOST_ACCESS in the
# Docker section halfway down. Resolving it in both places means two copies of
# the same search order, and two copies drift.
#
# Order: explicit override, the absolute path recorded at install time, a .env
# beside the checkout, then the legacy /etc location.
###############################################################################
SC_ENV=""
SC_SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" 2>/dev/null && pwd)" || SC_SELF_DIR=""
for c in "${CONFIG_FILE:-}" \
         "$(/bin/grep -oP '^ENV_FILE_DEFAULT="\K[^"]+' /usr/local/bin/security-watchdog.sh 2>/dev/null | head -1)" \
         "$SC_SELF_DIR/.env" "$SC_SELF_DIR/../.env" "$SC_SELF_DIR/../../.env" \
         /etc/server-baseline/selfcheck.env; do
    if [ -n "$c" ] && [ -r "$c" ]; then SC_ENV="$c"; break; fi
done
if [ -n "$SC_ENV" ]; then
    # shellcheck disable=SC1090
    . "$SC_ENV"
fi

# On Debian and Ubuntu, `aide` does NOT read /etc/aide/aide.conf by itself.
# aide-common generates /var/lib/aide/aide.conf.autogenerated from that file
# plus /etc/aide/aide.conf.d/, and ships aide.wrapper to invoke it correctly.
# A bare `aide --check` therefore always fails with "missing configuration"
# (exit 17) on these distributions, which is indistinguishable from a genuinely
# broken config unless you know to look. Every AIDE call goes through this.
#
# Prints nothing when no usable configuration exists at all - typically because
# aide-common is missing, which is a different problem from a broken config and
# has a different fix.
aide_cmd() {
    if command -v aide.wrapper >/dev/null 2>&1; then
        echo "aide.wrapper"
    elif [ -x /usr/sbin/aide.wrapper ]; then
        echo "/usr/sbin/aide.wrapper"
    elif [ -f /var/lib/aide/aide.conf.autogenerated ]; then
        echo "aide --config=/var/lib/aide/aide.conf.autogenerated"
    elif [ -f /etc/aide/aide.conf ]; then
        echo "aide --config=/etc/aide/aide.conf"
    elif [ -f /etc/aide.conf ]; then
        echo "aide --config=/etc/aide.conf"
    fi
}

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must run as root (sudo bash $0)" >&2
    exit 1
fi

[ "$QUIET" = false ] && {
    echo ""
    echo "=========================================================================="
    echo "  Security Self-Check - $(/bin/hostname) - $(/bin/date '+%Y-%m-%d %H:%M')"
    echo "=========================================================================="
}

###############################################################################
section "PATH integrity"
###############################################################################
# The single most characteristic sign of the userland rootkit families that ship
# with proxyjacking payloads: a directory prepended to PATH inside a system path,
# holding replacements for top/htop/lsof/crontab/df/mount/strace/ldd.
#
# $HOME/.local/bin in a user's own .profile is normal (pip, npm, XDG) and is not
# matched here - only .local/bin under a SYSTEM path is.

if /bin/grep -qs '/bin/\.local/bin\|/usr/bin/\.local/bin' \
        /etc/profile /etc/profile.d/* /etc/environment /etc/bash.bashrc /root/.bashrc /root/.profile 2>/dev/null; then
    fail "PATH injection found in a system profile (.local/bin under a system path)"
else
    pass "No PATH injection in system profiles"
fi

SHIMS_FOUND=""
for d in /usr/bin/.local /bin/.local; do
    [ -d "$d" ] && SHIMS_FOUND="$SHIMS_FOUND $d"
done
if [ -n "$SHIMS_FOUND" ]; then
    fail "Shim directory present:$SHIMS_FOUND"
else
    pass "No shim directories under /usr/bin or /bin"
fi

HIJACKED=""
for b in top htop lsof crontab df mount strace ldd; do
    RESOLVED=$(command -v "$b" 2>/dev/null || true)
    case "$RESOLVED" in
        /usr/bin/*|/bin/*|/usr/sbin/*|/sbin/*|"") : ;;
        *) HIJACKED="$HIJACKED $b->$RESOLVED" ;;
    esac
    for d in /usr/bin /bin; do
        [ -f "$d/.local/bin/$b" ] && HIJACKED="$HIJACKED $d/.local/bin/$b"
    done
done
if [ -n "$HIJACKED" ]; then
    fail "Diagnostic tools resolve to non-system paths:$HIJACKED"
else
    pass "Diagnostic tools resolve to system paths"
fi

###############################################################################
section "Fail2ban"
###############################################################################
# The failure this catches: a jail that is "enabled" but pointed at a log file
# that no longer exists. It starts, reports healthy, and bans nothing - which is
# indistinguishable from "no attacks" unless you compare against the journal.

if ! command -v fail2ban-client >/dev/null 2>&1; then
    warn "fail2ban is not installed"
elif ! /bin/systemctl is-active fail2ban >/dev/null 2>&1; then
    fail "fail2ban is installed but not running"
elif ! fail2ban-client status sshd >/dev/null 2>&1; then
    fail "fail2ban is running but the sshd jail is not active"
else
    pass "fail2ban sshd jail is active"

    # A jail reading /var/log/auth.log on Ubuntu 24.04 is a dead jail.
    if fail2ban-client get sshd logpath 2>/dev/null | /bin/grep -q '/var/log/auth.log' && \
       [ ! -s /var/log/auth.log ]; then
        fail "sshd jail reads /var/log/auth.log, which does not exist on this system - it can never ban"
    else
        pass "sshd jail log source exists"
    fi

    # Ask fail2ban what it actually RESOLVED, not what the files say. The read
    # order is jail.conf -> jail.d/*.conf -> jail.local -> jail.d/*.local, so a
    # jail.local can silently override everything in jail.d/*.conf. A set
    # journalmatch is proof that the systemd backend survived that resolution.
    if fail2ban-client get sshd journalmatch 2>/dev/null | /bin/grep -q '_SYSTEMD_UNIT'; then
        pass "sshd jail resolved to the systemd backend (journalmatch is set)"
    else
        fail "sshd jail did NOT resolve to the systemd backend - it is reading a file, not the journal"
        if [ -f /etc/fail2ban/jail.local ] && /bin/grep -q '^\[sshd\]' /etc/fail2ban/jail.local 2>/dev/null; then
            warn "  /etc/fail2ban/jail.local defines [sshd] and is read AFTER jail.d/*.conf - it wins"
        fi
        if ! python3 -c "import systemd.journal" >/dev/null 2>&1; then
            warn "  python3-systemd is missing; the systemd backend cannot initialise"
            warn "  Fix: apt-get install -y python3-systemd && systemctl restart fail2ban"
        fi
        warn "  Inspect the resolved config with: fail2ban-client -d | grep sshd"
    fi

    # Compare bans against actual failed logins. Zero bans while the journal is
    # full of failures is a fault, not quiet.
    # Note: `grep -c` prints 0 AND exits 1 on no match, so `|| echo 0` would
    # produce "0\n0" and break the numeric test. wc -l always exits 0.
    #
    # Both counters must cover the SAME window. fail2ban's totals reset when the
    # service restarts, so comparing them against a fixed 7-day journal count
    # reports a freshly restarted jail as broken - which is exactly what this
    # check did on its first real run.
    F2B_STATUS=$(fail2ban-client status sshd 2>/dev/null)
    BANS=$(echo "$F2B_STATUS" | /bin/grep -i 'Total banned' | /bin/grep -oE '[0-9]+$' | /usr/bin/head -1)
    BANS=${BANS:-0}
    SEEN=$(echo "$F2B_STATUS" | /bin/grep -i 'Total failed' | /bin/grep -oE '[0-9]+$' | /usr/bin/head -1)
    SEEN=${SEEN:-0}

    # Count the journal over the jail's own uptime, not an arbitrary week.
    F2B_SINCE=$(/bin/systemctl show fail2ban --property=ActiveEnterTimestamp --value 2>/dev/null)
    if [ -n "$F2B_SINCE" ]; then
        ATTEMPTS=$(/bin/journalctl -u ssh --since "$F2B_SINCE" --no-pager 2>/dev/null | \
                   /bin/grep -iE 'Failed password|Invalid user|authentication failure' | /usr/bin/wc -l)
    else
        ATTEMPTS=0
    fi
    ATTEMPTS=${ATTEMPTS:-0}
    # Zero bans is the obvious failure. A handful of bans against thousands of
    # attempts is the same failure wearing a disguise: the jail is technically
    # alive but is not seeing most of what reaches sshd. With maxretry=3, even
    # allowing for repeat offenders being banned once, the ratio should not be
    # anywhere near this lopsided.
    # Two separate questions, in order:
    #   1. Is the jail SEEING what the journal sees? (reading the right source)
    #   2. Having seen them, is it BANNING? (acting on what it reads)
    if [ "$ATTEMPTS" -gt 20 ] && [ "$SEEN" -eq 0 ]; then
        fail "The journal shows $ATTEMPTS failed logins since fail2ban started, but the jail has seen 0"
        warn "  It is running against the wrong source. Check: fail2ban-client get sshd logpath"
    elif [ "$SEEN" -gt 30 ] && [ "$BANS" -eq 0 ]; then
        fail "The jail registered $SEEN failures but banned nothing - it reads but does not act"
        warn "  Check maxretry/findtime: fail2ban-client get sshd maxretry"
    elif [ "$SEEN" -gt 0 ] || [ "$BANS" -gt 0 ]; then
        pass "Jail has seen $SEEN failures and issued $BANS ban(s) since it started"
    else
        pass "No failed logins since fail2ban started - nothing to judge yet"
    fi
fi

###############################################################################
section "SSH listening ports"
###############################################################################
# Port 22 is kept open on purpose as a lockout fallback, but it is meant to be
# temporary and it is easy to leave open forever. This reports what sshd is
# actually bound to, which is not always what sshd_config appears to say -
# socket activation, drop-in files under sshd_config.d and a stale ssh.socket
# all override it.

SSH_PORTS=$(/bin/ss -tlnp 2>/dev/null | /bin/grep -i sshd | \
            /bin/grep -oE ':[0-9]+ ' | /bin/tr -d ': ' | sort -u | /bin/tr '\n' ' ')
SSH_PORTS=${SSH_PORTS:-none}

if [ "$SSH_PORTS" = "none" ]; then
    warn "Could not determine which ports sshd is listening on"
elif echo "$SSH_PORTS" | /bin/grep -qw 22; then
    if echo "$SSH_PORTS" | /bin/grep -qw 888; then
        warn "sshd listens on: $SSH_PORTS - port 22 is still open alongside 888"
        warn "  Close it only from a SECOND session after verifying 888 works:"
        warn "  sudo sed -i '/^Port 22\$/d' /etc/ssh/sshd_config && sudo systemctl restart ssh"
    else
        warn "sshd listens on port 22 only - the hardened port 888 is not active"
    fi
else
    pass "sshd listens on: $SSH_PORTS (port 22 is closed)"
fi

# Where is the port actually configured? On a socket-activated host the Port
# directive in sshd_config is ignored entirely, so a leftover "Port 22" there is
# both misleading and a trap: deleting it looks like it closed the port when it
# changed nothing at all.
SOCKET_ON=false
/bin/systemctl is-active ssh.socket >/dev/null 2>&1 && SOCKET_ON=true
CONF_PORTS=$(/bin/grep -oE '^Port +[0-9]+' /etc/ssh/sshd_config 2>/dev/null | /bin/grep -oE '[0-9]+' | sort -u | /bin/tr '\n' ' ')

if [ "$SOCKET_ON" = true ]; then
    if [ -n "$CONF_PORTS" ]; then
        warn "Socket activation is in use, but sshd_config still sets Port: $CONF_PORTS"
        warn "  Those lines are IGNORED. Editing them will not change anything."
        warn "  The real ports live in /etc/systemd/system/ssh.socket.d/ports.conf"
    else
        pass "Port configured in one place only (ssh.socket)"
    fi
elif [ -f /etc/systemd/system/ssh.socket.d/ports.conf ]; then
    warn "sshd_config is authoritative, but a stale ssh.socket.d/ports.conf exists"
    warn "  It would take over if socket activation is ever enabled. Remove it."
else
    pass "Port configured in one place only (sshd_config)"
fi

if [ -n "${SSH_PORTS##*none*}" ]; then
    UNEXPECTED_SSH=""
    for p in $SSH_PORTS; do
        case "$p" in
            22|888) : ;;
            *) UNEXPECTED_SSH="$UNEXPECTED_SSH $p" ;;
        esac
    done
    if [ -n "$UNEXPECTED_SSH" ]; then
        fail "sshd listens on unexpected port(s):$UNEXPECTED_SSH"
    fi
fi

###############################################################################
section "Listeners on all interfaces"
###############################################################################
# A socket bound to 0.0.0.0 is NOT the same thing as a port reachable from the
# internet, and the difference is which chain the packet actually traverses:
#
#   host process        -> filter INPUT              -> UFW governs it
#   container publish   -> nat PREROUTING + FORWARD  -> UFW INPUT never sees it
#
# This check used to ignore that and list everything bound to 0.0.0.0. On a host
# running a local MTA, a supervisor and a monitoring agent that is a wall of a
# dozen port numbers, of which UFW already drops most - and the one port that IS
# reachable is hiding in the middle of it. A warning that is present every single
# day is not a warning any more, it is wallpaper.
#
# So each port is classified by the path that governs it, and only the reachable
# ones get a verdict. Anything that cannot be classified counts as reachable:
# the bias is toward a false alarm, never toward a false all-clear.
#
# Expected: SSH (22, 888) and, when not in Cloudflare-only mode, HTTP/HTTPS.
# Everything else is worth a second look, especially management interfaces:
# 9443 Portainer, 8000 Portainer agent, 19999 Netdata, 8120 the bot API.

# SELFCHECK_EXPECTED_PUBLIC adds this host's own intended services. Port 1000
# on AC1 is a deliberate one, and re-confirming it every morning is how a list
# of intended exposures turns into a list you scroll past. Declaring it moves
# it from "verify this" to "you already did" - and anything NOT declared still
# stands out, which is the entire point of keeping the list short.
EXPECTED_PUBLIC="22 888 80 443 ${SELFCHECK_EXPECTED_PUBLIC:-}"
MGMT_PORTS="9443 8000 19999 8120 2375 2376 5432 3306 6379 27017"

# --- Ports Docker publishes on all interfaces --------------------------------
# "0.0.0.0:9443->9443/tcp, :::9443->9443/tcp" and the range form
# "0.0.0.0:21115-21119->21115-21119/tcp". Only the host-side port matters.
docker_published_ports() {
    command -v docker >/dev/null 2>&1 || return 0
    docker ps --format '{{.Ports}}' 2>/dev/null | /bin/tr ',' '\n' | \
        /bin/grep -E '^[[:space:]]*(0\.0\.0\.0|\[?::+\]?):' | \
        /bin/sed -nE 's/.*:([0-9]+)(-([0-9]+))?->.*/\1 \3/p' | \
        while read -r lo hi; do
            [ -z "$hi" ] && hi="$lo"
            # A published range is bounded here so a pathological mapping cannot
            # turn one container into 60k iterations.
            [ "$hi" -gt "$((lo + 1024))" ] && hi=$((lo + 1024))
            /usr/bin/seq "$lo" "$hi"
        done | sort -un
}

# --- What UFW would actually let through -------------------------------------
# Parsed once. UFW_USABLE stays false unless UFW is active AND its default
# incoming policy is deny/reject - with a default-allow policy the rule list
# below says nothing about what is blocked.
UFW_RULES=""
UFW_USABLE=false
UFW_OPAQUE=0

ufw_init() {
    local status
    command -v ufw >/dev/null 2>&1 || return 0
    status=$(/usr/sbin/ufw status verbose 2>/dev/null) || return 0
    printf '%s\n' "$status" | /bin/grep -q '^Status: active' || return 0
    printf '%s\n' "$status" | \
        /bin/grep -qE '^Default:.*(deny|reject) \(incoming\)' || return 0

    # Columns in `ufw status` are separated by runs of two or more spaces; the
    # To field itself may contain single spaces ("Nginx Full", "888 on eth0").
    # Only ALLOW/LIMIT from Anywhere counts - a rule scoped to one source
    # address does not make a port internet-reachable.
    UFW_RULES=$(printf '%s\n' "$status" | /usr/bin/awk -F'  +' \
        '$2 ~ /^(ALLOW|LIMIT)/ && $3 ~ /^Anywhere/ {print $1}' | \
        /bin/sed -e 's/ (v6)//' | /bin/grep -v '^$' | sort -u)

    # Rules naming an application profile ("Nginx Full") cannot be resolved to
    # port numbers from here. Counted once, at init - counting them inside
    # ufw_allows would multiply the same handful of rules by every port tested.
    if [ -n "$UFW_RULES" ]; then
        UFW_OPAQUE=$(printf '%s\n' "$UFW_RULES" | \
            /bin/grep -cvE '^[0-9]+(:[0-9]+)?(/(tcp|udp))?$' || true)
    fi
    UFW_USABLE=true
}

# 0 = reachable, or not determinable. 1 = positively blocked by UFW.
#
# Read line by line, not with word splitting: a To field is allowed to contain
# spaces ("Nginx Full"), and splitting it turns one unresolved rule into two.
ufw_allows() {
    local port="$1" spec lo hi
    [ "$UFW_USABLE" = true ] || return 0
    while IFS= read -r spec; do
        [ -n "$spec" ] || continue
        case "$spec" in Anywhere*) return 0 ;; esac   # blanket allow
        spec=${spec%%/*}                              # drop the /tcp or /udp suffix
        case "$spec" in
            *[!0-9:]*)  continue ;;                   # application profile, unresolved
            *:*)        lo=${spec%%:*}; hi=${spec##*:}
                        [ "$port" -ge "$lo" ] && [ "$port" -le "$hi" ] && return 0 ;;
            *)          [ "$port" = "$spec" ] && return 0 ;;
        esac
    done <<EOF
$UFW_RULES
EOF
    return 1
}

# --- What DOCKER-USER would do with a new connection from the internet -------
# The old check grepped this chain for the word DROP and passed if it found
# one. That is not a result, it is the presence of a rule: on AC3 that single
# "pass" was the only thing standing between eleven published container ports
# and the internet, and it would have said exactly the same had every one of
# them been deliberately opened.
#
# So walk the chain the way a packet does - first matching rule wins - for a
# NEW inbound TCP connection from an arbitrary internet address arriving on
# the default-route interface.
EXT_IF=$(ip route show default 2>/dev/null | \
    /usr/bin/awk '/^default/{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
DOCKER_USER_RULES=$(/usr/sbin/iptables -S DOCKER-USER 2>/dev/null | /bin/grep '^-A ' || true)

# Does an iptables port spec cover this port? Handles a single port, an a:b
# range, and the comma-separated list that -m multiport --dports produces.
port_spec_matches() {
    local spec="$1" port="$2" one lo hi oifs
    oifs=$IFS; IFS=,
    for one in $spec; do
        case "$one" in
            *:*) lo=${one%%:*}; hi=${one##*:}
                 if [ "$port" -ge "$lo" ] && [ "$port" -le "$hi" ]; then
                     IFS=$oifs; return 0
                 fi ;;
            *)   if [ "$port" = "$one" ]; then IFS=$oifs; return 0; fi ;;
        esac
    done
    IFS=$oifs
    return 1
}

# Echoes accept / drop / fallthrough. Recurses into user chains, because once
# DOCKER-USER is pointed at ufw-user-forward the answer lives one chain deeper
# and a walker that stops at the jump would call every open port closed.
chain_verdict() {
    local chain="$1" port="$2" depth="${3:-0}" rules rule dport lo hi sub
    if [ "$depth" -gt 4 ]; then echo fallthrough; return 0; fi
    rules=$(/usr/sbin/iptables -S "$chain" 2>/dev/null | /bin/grep '^-A ' || true)
    if [ -n "$rules" ]; then
        while IFS= read -r rule; do
            [ -n "$rule" ] || continue
            # A new connection is never RELATED or ESTABLISHED.
            case "$rule" in *"--ctstate"*) continue ;; esac
            # Source-scoped rules do not match an arbitrary internet address.
            case "$rule" in *" -s "*) continue ;; esac
            # Interface-scoped rules only match on the way in from outside.
            case "$rule" in
                *" -i "*) [ -n "$EXT_IF" ] || continue
                          case "$rule" in *" -i $EXT_IF "*) ;; *) continue ;; esac ;;
            esac
            case "$rule" in
                *" -p "*) case "$rule" in *" -p tcp "*) ;; *) continue ;; esac ;;
            esac
            # --dports (from -m multiport) is checked FIRST: it contains the
            # substring "--dport", so testing for that one first would treat a
            # multiport rule as having no port restriction at all - which reads
            # as "matches every port" and silently mislabels the whole chain.
            case "$rule" in
                *"--dports "*)
                    dport=${rule#*--dports }; dport=${dport%% *}
                    port_spec_matches "$dport" "$port" || continue ;;
                *"--dport "*)
                    dport=${rule#*--dport }; dport=${dport%% *}
                    port_spec_matches "$dport" "$port" || continue ;;
            esac
            case "$rule" in
                *" -j DROP"*|*" -j REJECT"*) echo drop;   return 0 ;;
                *" -j ACCEPT"*)              echo accept; return 0 ;;
                # RETURN leaves this chain. What that MEANS depends on where we
                # are, so it is reported as-is and the caller decides.
                *" -j RETURN"*)              echo fallthrough; return 0 ;;
                *)  sub=${rule##* -j }; sub=${sub%% *}
                    case "$sub" in ''|-*) continue ;; esac
                    sub=$(chain_verdict "$sub" "$port" $((depth + 1)))
                    [ "$sub" = fallthrough ] || { echo "$sub"; return 0; } ;;
            esac
        done <<EOF
$rules
EOF
    fi
    echo fallthrough
}

# At the top of DOCKER-USER, falling through means the packet goes back to
# FORWARD and on into Docker's own chains, which accept a published port. So
# anything that is not an explicit drop is reachable.
docker_user_allows() {
    [ -n "$DOCKER_USER_RULES" ] || return 0     # no chain: nothing filters here
    case "$(chain_verdict DOCKER-USER "$1")" in
        drop) return 1 ;;
        *)    return 0 ;;
    esac
}

# --- The layer this host cannot see ------------------------------------------
# A cloud firewall (Hetzner, AWS security groups, ...) sits in front of the NIC
# and leaves no trace on the machine. Declaring what it permits keeps the ports
# it already blocks out of the daily report.
#
# This is a DECLARATION, not a measurement. Nothing here notices when someone
# opens a port in the provider console, which is exactly why the report keeps
# saying so out loud rather than quietly treating the host as safe.
#
#   SELFCHECK_EXTERNAL_ALLOW="888 1000"
EXT_ALLOW="${SELFCHECK_EXTERNAL_ALLOW:-}"

ext_allows() {
    local port="$1" spec lo hi
    for spec in $EXT_ALLOW; do
        spec=${spec%%/*}
        case "$spec" in
            *:*) lo=${spec%%:*}; hi=${spec##*:}
                 [ "$port" -ge "$lo" ] && [ "$port" -le "$hi" ] && return 0 ;;
            *)   [ "$port" = "$spec" ] && return 0 ;;
        esac
    done
    return 1
}

PUBLIC_LISTENERS=$(/bin/ss -tlnH 2>/dev/null | \
    /usr/bin/awk '{print $4}' | \
    /bin/grep -E '^(0\.0\.0\.0|\*|\[::\]):' | \
    /bin/grep -oE '[0-9]+$' | sort -un)

if [ -z "$PUBLIC_LISTENERS" ]; then
    pass "Nothing is listening on all interfaces"
else
    ufw_init
    DOCKER_PUB=$(docker_published_ports)

    # `ufw status` reported "Status: active" on a host whose ufw.conf said
    # ENABLED=no: the chains were still resident in the kernel from an earlier
    # load, so the firewall looked healthy in every way you would normally
    # look, and would simply not have come back after a reboot. A rule that is
    # loaded is not a firewall that is running. Both have to agree.
    if command -v ufw >/dev/null 2>&1 && \
       ufw status 2>/dev/null | /bin/grep -q '^Status: active' && \
       ! /bin/grep -qi '^ENABLED=yes' /etc/ufw/ufw.conf 2>/dev/null; then
        fail "UFW rules are loaded but ufw.conf says ENABLED=no - the firewall will not come back after a reboot"
        warn "  Re-enable it with: ufw enable"
    fi

    REACHABLE=""; VIA_DOCKER=""; BLOCKED_UFW=""; BLOCKED_DU=""; BLOCKED_EXT=""
    for p in $PUBLIC_LISTENERS; do
        if printf '%s\n' "$DOCKER_PUB" | /bin/grep -qx "$p"; then
            # Published by Docker: UFW never sees it, DOCKER-USER is the filter.
            if docker_user_allows "$p"; then
                VIA_DOCKER="$VIA_DOCKER $p"
            else
                BLOCKED_DU="$BLOCKED_DU $p"; continue
            fi
        elif ! ufw_allows "$p"; then
            BLOCKED_UFW="$BLOCKED_UFW $p"; continue
        fi
        # Survived every filter that exists on this machine. The cloud firewall
        # is the last layer and it is not visible from in here.
        if [ -n "$EXT_ALLOW" ] && ! ext_allows "$p"; then
            BLOCKED_EXT="$BLOCKED_EXT $p"; continue
        fi
        REACHABLE="$REACHABLE $p"
    done

    # Informational, not a verdict - the verdicts follow below.
    if [ "$QUIET" = false ]; then
        echo "  ---- bound to all interfaces:$(printf ' %s' $PUBLIC_LISTENERS)"
        [ -n "$VIA_DOCKER" ]  && echo "  ---- published by Docker, allowed by DOCKER-USER:$VIA_DOCKER"
        [ -n "$BLOCKED_DU" ]  && echo "  ---- published by Docker, dropped by DOCKER-USER:$BLOCKED_DU"
        [ -n "$BLOCKED_UFW" ] && echo "  ---- bound on the host, dropped by UFW:$BLOCKED_UFW"
        if [ -n "$BLOCKED_EXT" ]; then
            echo "  ---- past UFW and DOCKER-USER, declared blocked upstream:$BLOCKED_EXT"
            echo "       SELFCHECK_EXTERNAL_ALLOW is a declaration, not a measurement."
            echo "       Re-verify from outside whenever the cloud firewall changes."
        fi
    fi

    UNEXPECTED=""
    MGMT_EXPOSED=""
    for p in $REACHABLE; do
        case " $EXPECTED_PUBLIC " in *" $p "*) continue ;; esac
        case " $MGMT_PORTS " in
            *" $p "*) MGMT_EXPOSED="$MGMT_EXPOSED $p"; continue ;;
        esac
        UNEXPECTED="$UNEXPECTED $p"
    done

    if [ -z "$MGMT_EXPOSED" ] && [ -z "$UNEXPECTED" ]; then
        BLOCKED_ANY="$BLOCKED_UFW$BLOCKED_DU$BLOCKED_EXT"
        if [ -n "$BLOCKED_ANY" ]; then
            # Counted, not listed: the three ---- lines above already name every
            # one of them, and a verdict that runs to twelve port numbers stops
            # being read as a verdict.
            BLOCKED_N=$(printf '%s ' $BLOCKED_ANY | /usr/bin/wc -w)
            pass "Reachable ports are only the expected ones ($BLOCKED_N more are bound but filtered before they arrive)"
        else
            pass "Only expected ports (SSH, HTTP/HTTPS) are open on all interfaces"
        fi
    fi

    # Named per port so the message says why it is a verdict and not a listing.
    port_path() {
        case " $VIA_DOCKER " in
            *" $1 "*) echo "published by Docker and let through by DOCKER-USER" ;;
            *)        echo "UFW allows it" ;;
        esac
    }

    if [ -n "$MGMT_EXPOSED" ]; then
        fail "Management interface reachable from the internet:$MGMT_EXPOSED"
        for p in $MGMT_EXPOSED; do
            OWNER=$(/bin/ss -tlnpH "sport = :$p" 2>/dev/null | \
                    /bin/grep -oE 'users:\(\("[^"]+"' | /bin/grep -oE '"[^"]+"' | /bin/tr -d '"' | head -1)
            warn "  port $p -> ${OWNER:-unknown} ($(port_path "$p")). Bind it to 127.0.0.1 and reach it through a tunnel."
        done
    fi

    if [ -n "$UNEXPECTED" ]; then
        warn "Other ports reachable from the internet:$UNEXPECTED (verify each is intended)"
        [ "$UFW_OPAQUE" -gt 0 ] && \
            warn "  $UFW_OPAQUE UFW rule(s) use an application profile and could not be resolved to port numbers - some of the above may in fact be closed"
    fi

    # Container-published ports are the ones UFW does not gate.
    if command -v docker >/dev/null 2>&1; then
        if ! /usr/sbin/iptables -L DOCKER-USER -n 2>/dev/null | /bin/grep -q DROP; then
            if docker ps --format '{{.Ports}}' 2>/dev/null | /bin/grep -qE '0\.0\.0\.0:|:::'; then
                fail "Containers publish on all interfaces and DOCKER-USER has no DROP rule"
                warn "  UFW does not filter these. Verify from ANOTHER machine, not from here."
            fi
        fi
    fi
fi

###############################################################################
section "auditd and process accounting"
###############################################################################
# auditd being stopped was the clearest signal in the AC2 incident and nothing
# reported it. This check is the alert that was missing.

if ! command -v auditctl >/dev/null 2>&1; then
    warn "auditd is not installed"
else
    if /bin/systemctl is-active auditd >/dev/null 2>&1; then
        pass "auditd is running"
    else
        fail "auditd is NOT running - syscall auditing is off"
    fi

    RULE_COUNT=$(auditctl -l 2>/dev/null | /usr/bin/wc -l)
    RULE_COUNT=${RULE_COUNT:-0}
    if [ "${RULE_COUNT:-0}" -lt 10 ]; then
        fail "auditd has only ${RULE_COUNT} rules loaded - expected 30+"
    else
        pass "auditd has ${RULE_COUNT} rules loaded"
    fi

    # Persistence paths must actually be covered, not merely present in a file.
    MISSING_WATCH=""
    for p in /etc/profile /etc/cron.d /var/spool/cron/crontabs /etc/systemd/system /root/.ssh /etc/ld.so.preload; do
        auditctl -l 2>/dev/null | /bin/grep -q -- "-w $p" || MISSING_WATCH="$MISSING_WATCH $p"
    done
    if [ -n "$MISSING_WATCH" ]; then
        warn "No audit watch on:$MISSING_WATCH"
    else
        pass "Persistence paths are covered by audit watches"
    fi

    # An auditd that stopped in the recent past is worth knowing about even if
    # it is running now.
    if /bin/journalctl -u auditd --since "-30 days" --no-pager 2>/dev/null | \
            /bin/grep -qiE 'stopped|exiting'; then
        warn "auditd was stopped at least once in the last 30 days - check: journalctl -u auditd"
    else
        pass "No auditd stop events in the last 30 days"
    fi
fi

if /bin/systemctl is-active acct >/dev/null 2>&1 || /bin/systemctl is-active psacct >/dev/null 2>&1; then
    pass "Process accounting is active"
else
    warn "Process accounting (acct) is not active - no command history will be recorded"
fi

###############################################################################
section "File integrity (AIDE)"
###############################################################################
# Catches the state where AIDE is installed, the cron job runs, and every report
# is green because the check itself is failing.

AIDE_CMD=$(aide_cmd)

if ! command -v aide >/dev/null 2>&1; then
    warn "AIDE is not installed"
elif [ -z "$AIDE_CMD" ]; then
    # The aide binary exists but the Debian/Ubuntu configuration layer does not.
    # Nothing can run in this state - it is not a broken config, it is an absent
    # one, and it means AIDE has never produced a result on this host.
    fail "AIDE is installed but has no usable configuration - it cannot run at all"
    warn "  No aide.wrapper, no /var/lib/aide/aide.conf.autogenerated, no /etc/aide/aide.conf."
    warn "  Almost always: the aide-common package is missing."
    warn "  Fix: apt-get install -y aide-common && aideinit"
elif ! $AIDE_CMD --config-check >/dev/null 2>&1; then
    # A broken config means every scheduled run aborts. Reported here because
    # the failure is otherwise invisible: an aborted check produces no findings,
    # which reads exactly like a clean result.
    fail "aide --config-check fails - the configuration is broken, no scan can run"
    warn "  See: sudo $AIDE_CMD --config-check"
elif [ ! -f /var/lib/aide/aide.db ]; then
    fail "AIDE is installed but has no database - it has never had a baseline"
else
    DB_AGE_DAYS=$(( ( $(/bin/date +%s) - $(/usr/bin/stat -c %Y /var/lib/aide/aide.db) ) / 86400 ))
    if [ "$DB_AGE_DAYS" -gt 30 ]; then
        warn "AIDE database is ${DB_AGE_DAYS} days old - stale baselines produce noise, then get ignored"
    else
        pass "AIDE database is ${DB_AGE_DAYS} days old"
    fi

    # Deliberately NOT running a full `aide --check` here. It takes 10-20
    # minutes, and a daily check that costs twenty minutes gets switched off
    # within a week - at which point this whole script stops running too.
    #
    # The evidence that AIDE completes is in the last scheduled run's log,
    # which is the same reasoning applied to rkhunter. --deep forces a real
    # check for when you want one.
    # Only consider logs written AFTER the current database. A rebuild makes
    # every earlier log irrelevant: they describe a baseline that no longer
    # exists, and judging the present by them reports failures that were
    # already fixed.
    # The installed reporter resolves AIDE independently of this script. That
    # logic lived in five places and drifted: one copy lacked a branch, fell
    # through to a bare `aide`, and reported exit 17 every night on a host whose
    # configuration was fine. Compare what the reporter would resolve against
    # what this script resolves, so a future divergence is caught here rather
    # than by a nightly alert nobody can act on.
    if [ -f /usr/local/bin/aide-telegram.sh ] && \
       ! /bin/grep -q 'config=/etc/aide/aide.conf' /usr/local/bin/aide-telegram.sh 2>/dev/null; then
        fail "The installed AIDE reporter cannot resolve this host's config layout"
        warn "  It will report exit 17 nightly regardless of the actual state."
        warn "  Fix: sudo update-baseline   (refreshes the reporter from the checkout)"
    fi

    # A log only says something about the present if it was written BOTH after
    # the current database AND by the current reporter. A log from the old
    # broken reporter post-dates the database on any host where the database
    # was never rebuilt, and reporting its error describes a defect that has
    # since been fixed.
    AIDE_CUTOFF=/var/lib/aide/aide.db
    if [ -f /usr/local/bin/aide-telegram.sh ] &&        [ /usr/local/bin/aide-telegram.sh -nt /var/lib/aide/aide.db ]; then
        AIDE_CUTOFF=/usr/local/bin/aide-telegram.sh
    fi
    # aide-refresh runs a check, then writes the new database - and aide closes
    # that database AFTER it has finished printing its report. The database is
    # therefore always a moment newer than the log of the check that produced
    # it. Requiring every log to be -newer than the database meant this warned
    # "no AIDE run since the current setup was put in place" on exactly the
    # hosts that had just refreshed, which is when you are most certain one ran.
    #
    # A refresh log is evidence by construction: aide-refresh cannot write one
    # without having run a check first. A check log still has to post-date the
    # cutoff, because that is what rules out a log left behind by the reporter
    # that used to report success without checking anything.
    LAST_AIDE_LOG=$( { /usr/bin/find /var/log -maxdepth 1 -name 'aide-refresh-*.log' 2>/dev/null
                       /usr/bin/find /var/log -maxdepth 1 -name 'aide-check-*.log' \
                           -newer "$AIDE_CUTOFF" 2>/dev/null
                     } | /usr/bin/xargs -r /bin/ls -1t 2>/dev/null | /usr/bin/head -1)

    if [ "$DEEP" = true ]; then
        echo "  ---- running a full aide --check (10-20 minutes)..."
        $AIDE_CMD --check >/dev/null 2>&1
        AIDE_RC=$?
        if [ "$AIDE_RC" -ge 14 ]; then
            fail "aide --check fails with exit ${AIDE_RC} - file integrity is UNVERIFIED"
        elif [ "$AIDE_RC" -ne 0 ]; then
            warn "aide --check reports differences (exit ${AIDE_RC}) - review them"
        else
            pass "aide --check completes cleanly"
        fi
    elif [ -z "$LAST_AIDE_LOG" ]; then
        warn "No AIDE run since the current setup was put in place - the first scheduled check is pending"
        warn "  Verify once with: sudo security-selfcheck --deep   (takes 10-20 minutes)"
    else
        LOG_AGE_DAYS=$(( ( $(/bin/date +%s) - $(/usr/bin/stat -c %Y "$LAST_AIDE_LOG") ) / 86400 ))
        if [ "$LOG_AGE_DAYS" -gt 3 ]; then
            fail "The last AIDE run was ${LOG_AGE_DAYS} days ago - the scheduled check is not running"
        elif /bin/grep -qE '^(ERROR|.*missing configuration|.*Invalid configure|.*Configuration error)' "$LAST_AIDE_LOG" 2>/dev/null; then
            fail "The last AIDE run ended in an error - integrity is UNVERIFIED"
            warn "  See: $LAST_AIDE_LOG"
        else
            pass "AIDE ran ${LOG_AGE_DAYS} day(s) ago and completed"
        fi
    fi
fi

###############################################################################
section "Rootkit scanning (rkhunter)"
###############################################################################
# The failure this catches: rkhunter installed, cron job firing daily, and every
# report green - because the scan aborts on a configuration error before it
# checks anything. No warnings in the log is not the same as no findings.

if ! command -v rkhunter >/dev/null 2>&1; then
    warn "rkhunter is not installed"
else
    if /usr/bin/rkhunter --config-check >/dev/null 2>&1; then
        pass "rkhunter configuration is valid"
    else
        fail "rkhunter --config-check fails - scans abort before checking anything"
        warn "  See: sudo rkhunter --config-check"
    fi

    # Did the most recent scan actually run to completion? The summary line is
    # the evidence; its absence means the log holds errors, not results.
    RK_LOG=""
    for f in /var/log/rkhunter.log /var/log/rkhunter/rkhunter.log; do
        [ -f "$f" ] && RK_LOG="$f" && break
    done

    if [ -z "$RK_LOG" ]; then
        warn "No rkhunter log found - it may never have run"
    else
        RK_AGE_DAYS=$(( ( $(/bin/date +%s) - $(/usr/bin/stat -c %Y "$RK_LOG") ) / 86400 ))
        if [ "$RK_AGE_DAYS" -gt 8 ]; then
            fail "rkhunter last wrote its log ${RK_AGE_DAYS} days ago - it is not running on schedule"
        else
            pass "rkhunter log is ${RK_AGE_DAYS} days old"
        fi

        if /bin/grep -q "System checks summary" "$RK_LOG" 2>/dev/null; then
            RK_WARN=$(/bin/grep -c "^Warning:" "$RK_LOG" 2>/dev/null || true)
            if [ "${RK_WARN:-0}" -gt 0 ]; then
                warn "Last rkhunter scan completed with ${RK_WARN} warning(s) - review $RK_LOG"
            else
                pass "Last rkhunter scan ran to completion with no warnings"
            fi
        else
            fail "The rkhunter log contains no completed scan - only errors or partial output"
            warn "  This host is NOT being scanned for rootkits. Check: sudo rkhunter --config-check"
        fi
    fi

    # An installed reporter with the counting bug reports green on an aborted scan.
    if [ -f /usr/local/bin/rkhunter-telegram.sh ] && \
       /bin/grep -q -- '--report-warnings-only' /usr/local/bin/rkhunter-telegram.sh 2>/dev/null && \
       ! /bin/grep -q 'System checks summary' /usr/local/bin/rkhunter-telegram.sh 2>/dev/null; then
        fail "rkhunter-telegram.sh cannot distinguish an aborted scan from a clean one"
        warn "  It reports '✅ All Clear' when the scan never ran. Re-run the installer's security section."
    fi
fi

###############################################################################
section "Reporters can actually report"
#
# Two bugs of this shape have shipped already: rkhunter-telegram.sh built its
# "All Clear" message and never sent it, and lynis-telegram.sh curled with
# >/dev/null 2>&1 so a rejected message looked exactly like a delivered one.
#
# Both were invisible from the outside, because the symptom of a broken
# reporter is silence - and silence is also what a healthy quiet week looks
# like. These are static checks on the installed copies: cheap, and they fire
# the same day the file drifts rather than the day you need the alert.
###############################################################################

REP_FOUND=0
REP_BAD=0

for REP in /usr/local/bin/aide-telegram.sh /usr/local/bin/rkhunter-telegram.sh \
           /usr/local/bin/lynis-telegram.sh /usr/local/bin/aide-refresh.sh; do
    [ -f "$REP" ] || continue
    REP_NAME="$(basename "$REP")"
    REP_FOUND=$((REP_FOUND + 1))

    # Talks to Telegram without ever looking at the HTTP status.
    if /bin/grep -q 'api\.telegram\.org' "$REP" 2>/dev/null && \
       ! /bin/grep -q 'http_code\|%{http_code}' "$REP" 2>/dev/null; then
        fail "$REP_NAME sends without checking the result - a rejected report looks delivered"
        REP_BAD=$((REP_BAD + 1))
    fi

    # Builds a message it never sends. Counting is deliberate rather than
    # exact: a reporter that assembles several messages and sends fewer times
    # than it has branches is worth a look either way.
    REP_BUILDS=$(/bin/grep -c '^[[:space:]]*MESSAGE="' "$REP" 2>/dev/null || true)
    REP_SENDS=$(/bin/grep -c '^[[:space:]]*send_telegram "' "$REP" 2>/dev/null || true)
    if [ "${REP_BUILDS:-0}" -gt 0 ] && [ "${REP_SENDS:-0}" -eq 0 ]; then
        fail "$REP_NAME builds a report but never calls send_telegram - it is silent by construction"
        REP_BAD=$((REP_BAD + 1))
    elif [ "${REP_BUILDS:-0}" -gt 1 ] && [ "${REP_SENDS:-0}" -gt 1 ] && \
         [ "${REP_SENDS:-0}" -lt "${REP_BUILDS:-0}" ]; then
        warn "$REP_NAME has ${REP_BUILDS} message branches but only ${REP_SENDS} sends - one path may be silent"
        REP_BAD=$((REP_BAD + 1))
    fi
done

# A healthy result here used to print nothing at all: an empty section under a
# heading, indistinguishable from a section that failed to run. In a script
# whose entire subject is controls that are quietly doing nothing, that is not
# a cosmetic problem. Say what was checked, or say that nothing was.
if [ "$REP_FOUND" -eq 0 ]; then
    warn "No reporters are installed - nothing on this host would send you an alert"
elif [ "$REP_BAD" -eq 0 ]; then
    pass "$REP_FOUND reporters check their send result and send on every path"
fi

###############################################################################
section "Writable filesystem hardening"
###############################################################################

for m in /tmp /var/tmp /dev/shm; do
    if /bin/findmnt -no OPTIONS "$m" 2>/dev/null | /bin/grep -q noexec; then
        pass "$m is mounted noexec"
    else
        warn "$m is executable - payloads dropped there can be run directly"
    fi
done

TMP_EXEC=$(/usr/bin/find /tmp /var/tmp /dev/shm -maxdepth 2 -type f -executable 2>/dev/null | /usr/bin/head -5)
if [ -n "$TMP_EXEC" ]; then
    fail "Executable files present in temporary directories: $(echo "$TMP_EXEC" | /bin/tr '\n' ' ')"
else
    pass "No executable files in /tmp, /var/tmp, /dev/shm"
fi

###############################################################################
section "Docker exposure"
###############################################################################

if command -v docker >/dev/null 2>&1; then
    # A second daemon with its own data-root is how container workloads are
    # hidden from `docker ps` - not by filtering output, but by running on a
    # completely separate daemon.
    EXTRA_DAEMONS=$(/bin/ps -eo args 2>/dev/null | \
        /bin/grep -E '(^|/)(dockerd|containerd)( |$)' | \
        /bin/grep -v grep | \
        /bin/grep -vE -- '-H fd://|--config /etc/containerd|^/usr/bin/containerd$|containerd-shim' || true)
    if [ -n "$EXTRA_DAEMONS" ]; then
        fail "Unexpected dockerd/containerd process: $(echo "$EXTRA_DAEMONS" | /usr/bin/head -2 | /bin/tr '\n' ' ')"
    else
        pass "No unexpected Docker daemons"
    fi

    # Container ports published on all interfaces. UFW does not gate these -
    # DOCKER-USER does, or nothing does.
    #
    # This used to grep the chain for the word DROP and pass on finding one.
    # A chain that drops nothing relevant contains that word just as readily as
    # a chain that drops everything, so the check could not tell a working
    # filter from a decorative one. It now asks per port.
    if [ -n "${DOCKER_PUB:-}" ]; then
        DU_OPEN=""
        for p in $DOCKER_PUB; do
            docker_user_allows "$p" && DU_OPEN="$DU_OPEN $p"
        done
        DU_PUB_N=$(printf '%s ' $DOCKER_PUB | /usr/bin/wc -w)
        DU_OPEN_N=$(printf '%s ' $DU_OPEN | /usr/bin/wc -w)

        # "Filters none of them" is not the same as "does not filter". On a
        # host that publishes one port and deliberately opens it, zero drops is
        # the correct outcome, and the first version of this check called that
        # a failure. What actually matters is whether a port nobody opened
        # would be dropped - so ask about ports nobody published.
        DU_PROBE_OPEN=true
        for probe in 64999 49998 38471; do
            case " $DOCKER_PUB " in *" $probe "*) continue ;; esac
            docker_user_allows "$probe" || { DU_PROBE_OPEN=false; break; }
        done

        if [ "$DU_PROBE_OPEN" = true ]; then
            fail "DOCKER-USER lets through ports nobody published - container traffic is unfiltered"
        elif [ "$DU_OPEN_N" -eq 0 ]; then
            pass "DOCKER-USER drops all $DU_PUB_N container port(s) published on all interfaces"
        else
            pass "DOCKER-USER filters container traffic - $DU_OPEN_N of $DU_PUB_N published port(s) deliberately open:$DU_OPEN"
        fi
    else
        pass "No containers published on all interfaces"
    fi

    # Known proxyjacking images.
    PROXYWARE=$(docker ps -a --format '{{.Names}} {{.Image}}' 2>/dev/null | \
        /bin/grep -iE 'repocket|packetstream|psclient|bitping|proxyrack|earnfm|wipter|antgain|traffmonetizer|pawns|honeygain|peer2profit' || true)
    if [ -n "$PROXYWARE" ]; then
        fail "Proxyware container present: $PROXYWARE"
    else
        pass "No known proxyware containers"
    fi

    # Containers holding root-equivalent access to the host.
    #
    # Portainer, its agent and Netdata all need the Docker socket to do their
    # job, so on these hosts this fires three times a day, every day, and says
    # the same thing every time. Left that way it teaches you to skim past the
    # block - including the day a fourth name appears in it.
    #
    # Acknowledge the ones you accepted, in the same .env as the credentials:
    #
    #   SELFCHECK_ACK_HOST_ACCESS="portainer=docker.sock netdata=docker.sock"
    #
    # The acknowledgement covers a container AND the exact access it was given.
    # If an acknowledged container later also becomes privileged, that is a new
    # fact and it warns again. A bare name with no "=" accepts anything, which
    # is convenient and worth strictly less.
    ACK_LIST="${SELFCHECK_ACK_HOST_ACCESS:-}"
    for c in $(docker ps --format '{{.Names}}' 2>/dev/null); do
        PRIV=$(docker inspect --format='{{.HostConfig.Privileged}}' "$c" 2>/dev/null)
        PIDMODE=$(docker inspect --format='{{.HostConfig.PidMode}}' "$c" 2>/dev/null)
        SOCK=$(docker inspect --format='{{range .Mounts}}{{.Source}} {{end}}' "$c" 2>/dev/null | /bin/grep -o 'docker.sock' | /usr/bin/wc -l)
        RISK=""
        [ "$PRIV" = "true" ] && RISK="$RISK privileged"
        [ "$PIDMODE" = "host" ] && RISK="$RISK pid=host"
        [ "${SOCK:-0}" -gt 0 ] && RISK="$RISK docker.sock"
        [ -z "$RISK" ] && continue

        # Sorted and comma-joined so the comparison does not depend on the order
        # the risks happen to be appended above.
        RISK_SET=$(printf '%s\n' $RISK | sort | /usr/bin/paste -sd, -)
        ACKED=false; ACK_NAMED=false
        for a in $ACK_LIST; do
            case "$a" in
                "$c")   ACKED=true; ACK_NAMED=true ;;
                "$c="*) ACK_NAMED=true
                        WANT=$(printf '%s\n' "${a#*=}" | /bin/tr ',' '\n' | \
                               /bin/grep -v '^$' | sort | /usr/bin/paste -sd, -)
                        [ "$WANT" = "$RISK_SET" ] && ACKED=true ;;
            esac
        done

        if [ "$ACKED" = true ]; then
            [ "$QUIET" = false ] && echo "  ---- container '$c' has $RISK_SET (acknowledged)"
        elif [ "$ACK_NAMED" = true ]; then
            warn "Container '$c' has host-level access:$RISK - this is NOT what was acknowledged for it"
        else
            warn "Container '$c' has host-level access:$RISK"
        fi
    done
    if [ -z "$ACK_LIST" ] && [ ${#WARNINGS[@]} -gt 0 ]; then
        [ "$QUIET" = false ] && \
            echo "  ---- accept the intended ones with SELFCHECK_ACK_HOST_ACCESS in ${SC_ENV:-your .env}"
    fi
else
    pass "Docker is not installed"
fi

###############################################################################
section "Persistence artefacts"
###############################################################################

if /bin/grep -rqs 'perfcc\|FPROF' /root/.profile /root/.bashrc /etc/cron.d/ \
        /etc/cron.hourly/ /etc/cron.daily/ /var/spool/cron/crontabs/ 2>/dev/null; then
    fail "perfctl-style persistence marker found (perfcc/FPROF)"
else
    pass "No perfctl-style persistence markers"
fi

HIDDEN_DIRS=$(/bin/ls -d /var/.i.* /tmp/.t.* /usr/bin/wbin /bin/wbin /usr/lib/exi /dev/shm/.config /root/.config/cron 2>/dev/null || true)
if [ -n "$HIDDEN_DIRS" ]; then
    fail "Hidden working directory present: $(echo "$HIDDEN_DIRS" | /bin/tr '\n' ' ')"
else
    pass "No known hidden working directories"
fi

if [ -s /etc/ld.so.preload ]; then
    fail "/etc/ld.so.preload is non-empty: $(/bin/cat /etc/ld.so.preload | /bin/tr '\n' ' ')"
else
    pass "/etc/ld.so.preload is empty"
fi

###############################################################################
section "Alerting is able to alert"
###############################################################################
# The credential file lives with the project checkout. That makes it easy to
# find and impossible to commit, but it also means moving or re-cloning the
# checkout silently detaches every scheduled alert from its credentials.
#
# This check is what makes that survivable: a detached alerting stack shows up
# here within a day, instead of as permanent silence that reads exactly like
# "nothing to report".

# Resolve the same way the installed scripts do: read back the path they
# recorded, rather than assuming a location.
ALERT_ENV=""
if [ -f /usr/local/bin/security-watchdog.sh ]; then
    ALERT_ENV=$(/bin/grep -oP '^ENV_FILE_DEFAULT="\K[^"]+' /usr/local/bin/security-watchdog.sh 2>/dev/null | head -1)
fi
[ -z "$ALERT_ENV" ] && [ -r /etc/server-baseline/selfcheck.env ] && ALERT_ENV=/etc/server-baseline/selfcheck.env

if [ ! -f /usr/local/bin/security-watchdog.sh ]; then
    warn "Security watchdog is not installed - no state-change alerting on this host"
elif [ -z "$ALERT_ENV" ]; then
    fail "The watchdog has no credential file recorded - it can never alert"
    warn "  Re-run update-baseline.sh; section 0 records the path."
elif [ ! -r "$ALERT_ENV" ]; then
    fail "Alert credentials are missing: $ALERT_ENV does not exist"
    warn "  The watchdog and the daily reports run but send nothing."
    warn "  Usually means the project checkout moved or was re-cloned without .env."
elif ! /bin/grep -q 'TELEGRAM_BOT_TOKEN=.' "$ALERT_ENV" 2>/dev/null; then
    fail "$ALERT_ENV exists but holds no bot token - alerting is silent"
else
    pass "Alert credentials resolve ($ALERT_ENV)"
    PERMS=$(/usr/bin/stat -c %a "$ALERT_ENV" 2>/dev/null)
    if [ "$PERMS" != "600" ] && [ "$PERMS" != "400" ]; then
        warn "  $ALERT_ENV is mode $PERMS - should be 600"
    fi
fi

###############################################################################
section "Secrets exposure"
###############################################################################
# Tokens on a command line are readable by anything that can read /proc,
# including any container running with pid: host.

# Report WHICH process and WHICH flag - never the value. This report gets piped
# to a file and pasted into tickets; printing the secret would copy it to every
# one of those places, which is the problem it is reporting.
# Capture the process list BEFORE the filter runs. In a pipeline both sides run
# concurrently, so grep's own argv - which contains the patterns being searched
# for - shows up in ps output and the check reports itself as a finding.
PS_SNAPSHOT=$(/bin/ps -eo comm=,args= 2>/dev/null)

CMDLINE_SECRETS=$(echo "$PS_SNAPSHOT" | \
    /bin/grep -iE -- '--token[= ]|--password[= ]|apikey=|api_key=|--secret[= ]' | \
    /bin/grep -v grep | \
    /usr/bin/awk '{proc=$1; flag="unknown";
                   if ($0 ~ /--token/)    flag="--token";
                   if ($0 ~ /--password/) flag="--password";
                   if ($0 ~ /[aA][pP][iI]_?[kK][eE][yY]=/) flag="apikey=";
                   if ($0 ~ /--secret/)   flag="--secret";
                   print proc" ("flag")"}' | sort -u | /bin/tr '\n' ' ' || true)

if [ -n "$CMDLINE_SECRETS" ]; then
    fail "Secret on a process command line: $CMDLINE_SECRETS"
    warn "  Value withheld on purpose. Inspect yourself with: ps -eo args | grep <process>"
    warn "  Readable via /proc by anything on this host, including a pid:host container."
else
    pass "No secrets on process command lines"
fi

###############################################################################
# Report
###############################################################################

TOTAL=$(( ${#PASSES[@]} + ${#WARNINGS[@]} + ${#FAILURES[@]} ))

if [ "$QUIET" = false ]; then
    echo ""
    echo "=========================================================================="
    echo "  ${#PASSES[@]} passed, ${#WARNINGS[@]} warnings, ${#FAILURES[@]} failures (of $TOTAL checks)"
    echo "=========================================================================="
    echo ""
fi

# --test-alert forces the send even when there is nothing to report.
#
# Without it there is no way to tell a healthy host from a broken reporter:
# both are silent. That is not a hypothetical - rkhunter's reporter built its
# "All Clear" message and never sent it, and nobody noticed for months, because
# the symptom of a dead reporter is indistinguishable from a quiet week.
#
# So: silence stays the default for the daily run, and this is the one command
# that proves the path still works end to end.
if [ ${#FAILURES[@]} -gt 0 ] || [ ${#WARNINGS[@]} -gt 0 ] || [ "$TEST_ALERT" = true ]; then
    if [ "$QUIET" = true ]; then
        echo "Security self-check on $(/bin/hostname): ${#FAILURES[@]} failures, ${#WARNINGS[@]} warnings"
        for f in "${FAILURES[@]}"; do echo "  [FAIL] $f"; done
        for w in "${WARNINGS[@]}"; do echo "  [WARN] $w"; done
    fi

    ###########################################################################
    # Alerting
    #
    # Three separate reasons this never delivered anything:
    #
    #  1. It only read /etc/server-baseline/selfcheck.env. Credentials moved to
    #     the project checkout, so on every current host that file does not
    #     exist, the guard was false, and the block never ran at all.
    #  2. parse_mode=Markdown answers HTTP 400 on a single unmatched _ * ` or
    #     [ - and these messages are made of paths and unit names. Every
    #     message with real content would have been rejected.
    #  3. The result was discarded, so 1 and 2 were indistinguishable from
    #     a successful send.
    #
    # This is the daily "did anything break" layer. Its own alert being dead is
    # the same class of failure it exists to catch.
    ###########################################################################
    if [ "$TELEGRAM" = true ]; then
        # $SC_ENV was resolved and sourced at the top of the script.
        if [ -z "$SC_ENV" ]; then
            echo "  No alert credentials resolved - this report was NOT sent" >&2
        else
            TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-${SECRET_TOKEN:-}}"
            TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-${CHAT_ID_PERSON1:-}}"
        fi

        if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
            sc_escape() { /bin/sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

            if [ "$TEST_ALERT" = true ]; then
                MSG="🧪 <b>Security Self-Check</b> (test)%0A%0A"
            else
                MSG="🔍 <b>Security Self-Check</b>%0A%0A"
            fi
            MSG+="Server: <code>$(/bin/hostname | sc_escape)</code>%0A"
            MSG+="Date: $(/bin/date '+%Y-%m-%d %H:%M')%0A%0A"
            MSG+="Failures: ${#FAILURES[@]} • Warnings: ${#WARNINGS[@]}%0A%0A"
            for f in "${FAILURES[@]}"; do MSG+="🚨 $(printf %s "$f" | sc_escape)%0A"; done
            for w in "${WARNINGS[@]}"; do MSG+="⚠️ $(printf %s "$w" | sc_escape)%0A"; done
            if [ ${#FAILURES[@]} -eq 0 ] && [ ${#WARNINGS[@]} -eq 0 ]; then
                MSG+="✅ ${#PASSES[@]} checks passed, nothing to report.%0A%0A"
                MSG+="<i>This message exists only to prove the alert path still works. "
                MSG+="The daily run stays silent when there is nothing wrong.</i>"
            fi

            SC_CODE=""
            for attempt in 1 2 3; do
                SC_V4=()
                [ "$attempt" -gt 1 ] && SC_V4=(-4)
                SC_CODE=$(/usr/bin/curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
                    "${SC_V4[@]}" \
                    -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
                    -d chat_id="${TELEGRAM_CHAT_ID}" \
                    -d parse_mode="HTML" \
                    -d text="${MSG}")
                [ "$SC_CODE" = "200" ] && break
                case "$SC_CODE" in 4*) break ;; esac   # Telegram refused it; retrying changes nothing
                [ "$attempt" -lt 3 ] && sleep $((attempt * 3))
            done

            if [ "$SC_CODE" != "200" ]; then
                echo "  Telegram send FAILED (HTTP ${SC_CODE:-000}) - this report was NOT delivered" >&2
                command -v logger >/dev/null 2>&1 && \
                    logger -t security-selfcheck "Telegram send FAILED with HTTP ${SC_CODE:-000}"
            fi
        fi
    fi
fi

[ ${#FAILURES[@]} -gt 0 ] && exit 1
[ ${#WARNINGS[@]} -gt 0 ] && exit 2
exit 0
