#!/bin/bash

###############################################################################
# Module: Compiler Restrictions
# Description: Restrict compiler access to root only (production servers)
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${SCRIPT_DIR}/modules/00-core/common.sh"

MODULE_NAME="compiler"
MODULE_DESCRIPTION="Compiler access restrictions"

should_run() {
    skip_if_completed "$MODULE_NAME" "$MODULE_DESCRIPTION" && return 1
    answer_is_yes "RESTRICT_COMPILERS" || return 1
    return 0
}

run() {
    log_section "Compiler Restrictions"

    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Would restrict gcc, g++, cc, make to root only"
        log_dry_run "Would set chmod 700 on compilers"
        return 0
    fi

    log_info "Restricting compiler access to root only..."

    local compilers=("/usr/bin/gcc" "/usr/bin/g++" "/usr/bin/cc" "/usr/bin/make" "/usr/bin/as")

    for compiler in "${compilers[@]}"; do
        if [ -f "$compiler" ]; then
            chmod 700 "$compiler" 2>/dev/null && log_info "✓ Restricted: $compiler"
        fi
    done

    log_warning "Note: To restore access: sudo chmod 755 /usr/bin/gcc /usr/bin/g++ /usr/bin/make"

    mark_completed "$MODULE_NAME"
    echo ""
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    should_run && run
fi
