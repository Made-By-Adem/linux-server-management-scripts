#!/bin/bash

###############################################################################
# Module: Password & PAM Hardening
# Description: Configure password policies and PAM security
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${SCRIPT_DIR}/modules/00-core/common.sh"

MODULE_NAME="passwords"
MODULE_DESCRIPTION="Password and PAM hardening"

should_run() {
    skip_if_completed "$MODULE_NAME" "$MODULE_DESCRIPTION" && return 1
    return 0
}

run() {
    log_section "Password & PAM Hardening"

    # Get configuration from config system
    local max_days="${PASSWORD_MAX_DAYS:-365}"
    local min_days="${PASSWORD_MIN_DAYS:-7}"
    local warn_days="${PASSWORD_WARN_DAYS:-30}"
    local min_length="${PASSWORD_MIN_LENGTH:-12}"
    local hash_rounds="${PASSWORD_HASH_ROUNDS:-65536}"

    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Would set password max age to $max_days days"
        log_dry_run "Would set password min length to $min_length"
        log_dry_run "Would set password hash rounds to $hash_rounds"
        log_dry_run "Would configure PAM quality requirements"
        return 0
    fi

    # Install PAM modules
    install_packages "PAM security modules" libpam-pwquality libpam-tmpdir

    # Configure login.defs
    log_info "Configuring password aging policies..."
    backup_file "/etc/login.defs"

    sed -i "s/^PASS_MAX_DAYS.*/PASS_MAX_DAYS\t$max_days/" /etc/login.defs
    sed -i "s/^PASS_MIN_DAYS.*/PASS_MIN_DAYS\t$min_days/" /etc/login.defs
    sed -i "s/^PASS_WARN_AGE.*/PASS_WARN_AGE\t$warn_days/" /etc/login.defs
    sed -i "s/^SHA_CRYPT_MIN_ROUNDS.*/SHA_CRYPT_MIN_ROUNDS\t$hash_rounds/" /etc/login.defs
    sed -i "s/^SHA_CRYPT_MAX_ROUNDS.*/SHA_CRYPT_MAX_ROUNDS\t$hash_rounds/" /etc/login.defs

    # Add SHA_CRYPT if not present
    grep -q "^SHA_CRYPT_MIN_ROUNDS" /etc/login.defs || echo "SHA_CRYPT_MIN_ROUNDS $hash_rounds" >> /etc/login.defs
    grep -q "^SHA_CRYPT_MAX_ROUNDS" /etc/login.defs || echo "SHA_CRYPT_MAX_ROUNDS $hash_rounds" >> /etc/login.defs

    log_info "✓ Password aging: max=$max_days, min=$min_days, warn=$warn_days"

    # Configure pwquality
    backup_file "/etc/security/pwquality.conf"
    cat > /etc/security/pwquality.conf <<PWQUALITY
# Password quality configuration
minlen = $min_length
minclass = 3
maxrepeat = 3
dcredit = -1
ucredit = -1
lcredit = -1
ocredit = -1
PWQUALITY

    log_info "✓ Password quality requirements configured"

    # Apply to existing user
    if [ -n "$ACTUAL_USER" ] && [ "$ACTUAL_USER" != "root" ]; then
        chage -M "$max_days" -m "$min_days" -W "$warn_days" "$ACTUAL_USER" 2>/dev/null
        log_info "✓ Password aging applied to user: $ACTUAL_USER"
    fi

    mark_completed "$MODULE_NAME"
    echo ""
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    should_run && run
fi
