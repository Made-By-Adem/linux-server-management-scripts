#!/bin/bash
# =============================================================================
# Password Aging Configuration Wizard
# =============================================================================
# Interactive wizard to configure password aging policies with compliance
# recommendations and explanations.
#
# Features:
# - Interactive password aging configuration
# - Compliance framework recommendations (PCI-DSS, ISO 27001, NIST, CIS)
# - Clear explanations of security implications
# - Validation of input values
# - Preview of changes before applying
#
# =============================================================================

# Color codes for output
COLOR_RESET='\033[0m'
COLOR_BOLD='\033[1m'
COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[0;33m'
COLOR_BLUE='\033[0;34m'
COLOR_CYAN='\033[0;36m'

# =============================================================================
# Display Functions
# =============================================================================

show_wizard_header() {
    echo -e "${COLOR_BOLD}${COLOR_CYAN}"
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║                                                                  ║"
    echo "║          Password Aging Configuration Wizard                    ║"
    echo "║                                                                  ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo -e "${COLOR_RESET}"
    echo ""
}

show_current_config() {
    echo -e "${COLOR_BOLD}Current Configuration:${COLOR_RESET}"
    echo "  Password Maximum Age:    ${PASSWORD_MAX_DAYS} days"
    echo "  Password Minimum Age:    ${PASSWORD_MIN_DAYS} days"
    echo "  Password Warning Period: ${PASSWORD_WARN_DAYS} days"
    echo ""
}

show_compliance_recommendations() {
    echo -e "${COLOR_BOLD}${COLOR_BLUE}Compliance Framework Recommendations:${COLOR_RESET}"
    echo ""
    echo -e "${COLOR_BOLD}PCI-DSS (Payment Card Industry):${COLOR_RESET}"
    echo "  └─ Maximum Age: ${COLOR_GREEN}90 days${COLOR_RESET} (Required)"
    echo "     Rationale: Frequent rotation reduces window of compromised credentials"
    echo ""
    echo -e "${COLOR_BOLD}ISO 27001 (Information Security):${COLOR_RESET}"
    echo "  └─ Maximum Age: ${COLOR_GREEN}90-180 days${COLOR_RESET} (Recommended)"
    echo "     Rationale: Balance between security and user experience"
    echo ""
    echo -e "${COLOR_BOLD}NIST 800-53 (US Federal):${COLOR_RESET}"
    echo "  └─ Maximum Age: ${COLOR_GREEN}365 days${COLOR_RESET} (Baseline)"
    echo "     Rationale: Annual rotation with strong passwords is acceptable"
    echo ""
    echo -e "${COLOR_BOLD}CIS Benchmark:${COLOR_RESET}"
    echo "  └─ Maximum Age: ${COLOR_GREEN}365 days${COLOR_RESET} (Recommended)"
    echo "     Rationale: Focus on password strength over frequent changes"
    echo ""
    echo -e "${COLOR_BOLD}Development/Testing:${COLOR_RESET}"
    echo "  └─ Maximum Age: ${COLOR_YELLOW}-1 (disabled)${COLOR_RESET} (Convenience)"
    echo "     Rationale: ${COLOR_RED}⚠ NOT for production!${COLOR_RESET} Dev convenience only"
    echo ""
}

show_security_implications() {
    local max_days="$1"

    echo -e "${COLOR_BOLD}Security Implications:${COLOR_RESET}"
    echo ""

    if [[ "$max_days" -eq -1 ]]; then
        echo -e "  ${COLOR_RED}⚠ WARNING: Passwords never expire!${COLOR_RESET}"
        echo "  ✗ Compromised passwords remain valid indefinitely"
        echo "  ✗ No forced credential rotation"
        echo "  ✗ Fails all compliance frameworks"
        echo "  ${COLOR_RED}✗ NEVER use this in production environments${COLOR_RESET}"
        echo ""
    elif [[ "$max_days" -le 60 ]]; then
        echo -e "  ${COLOR_GREEN}✓ Very High Security${COLOR_RESET} (Aggressive rotation)"
        echo "  ✓ Minimal window for compromised credentials"
        echo "  ✓ Exceeds all compliance requirements"
        echo "  ${COLOR_YELLOW}⚠ May lead to password fatigue${COLOR_RESET}"
        echo "  ${COLOR_YELLOW}⚠ Users might write passwords down${COLOR_RESET}"
        echo ""
    elif [[ "$max_days" -le 90 ]]; then
        echo -e "  ${COLOR_GREEN}✓ High Security${COLOR_RESET} (Quarterly rotation)"
        echo "  ✓ Short window for compromised credentials"
        echo "  ✓ Meets PCI-DSS and ISO 27001 requirements"
        echo "  ✓ Good balance for high-security environments"
        echo ""
    elif [[ "$max_days" -le 180 ]]; then
        echo -e "  ${COLOR_GREEN}✓ Good Security${COLOR_RESET} (Semi-annual rotation)"
        echo "  ✓ Reasonable window for credential rotation"
        echo "  ✓ Meets most compliance frameworks"
        echo "  ✓ Better user experience than quarterly"
        echo ""
    elif [[ "$max_days" -le 365 ]]; then
        echo -e "  ${COLOR_GREEN}✓ Moderate Security${COLOR_RESET} (Annual rotation)"
        echo "  ✓ Meets NIST 800-53 and CIS Benchmark"
        echo "  ✓ Good user experience"
        echo "  ✓ Suitable for strong password + MFA environments"
        echo ""
    else
        echo -e "  ${COLOR_YELLOW}⚠ Low Security${COLOR_RESET} (Infrequent rotation)"
        echo "  ⚠ Long window for compromised credentials"
        echo "  ⚠ May not meet compliance requirements"
        echo "  ${COLOR_YELLOW}⚠ Consider shorter rotation period${COLOR_RESET}"
        echo ""
    fi
}

# =============================================================================
# Input Functions
# =============================================================================

prompt_max_age() {
    local default_value="${PASSWORD_MAX_DAYS:-365}"

    echo -e "${COLOR_BOLD}Password Maximum Age Configuration${COLOR_RESET}"
    echo ""
    echo "How often should users be required to change their passwords?"
    echo ""
    echo "Common options:"
    echo "  [1] 90 days   - High security (PCI-DSS compliant)"
    echo "  [2] 180 days  - Balanced security (ISO 27001)"
    echo "  [3] 365 days  - Moderate security (NIST 800-53, CIS)"
    echo "  [4] Custom    - Specify your own value"
    echo "  [5] Disable   - Never expire (${COLOR_RED}NOT recommended for production${COLOR_RESET})"
    echo ""
    echo -e "Current value: ${COLOR_CYAN}${default_value} days${COLOR_RESET}"
    echo ""

    while true; do
        read -r -p "Select option [1-5] or press Enter to keep current: " choice

        # If empty, keep current value
        if [[ -z "$choice" ]]; then
            echo "Keeping current value: ${default_value} days"
            PASSWORD_MAX_DAYS="$default_value"
            return 0
        fi

        case "$choice" in
            1)
                PASSWORD_MAX_DAYS=90
                echo -e "${COLOR_GREEN}✓ Set to 90 days (PCI-DSS compliant)${COLOR_RESET}"
                return 0
                ;;
            2)
                PASSWORD_MAX_DAYS=180
                echo -e "${COLOR_GREEN}✓ Set to 180 days (ISO 27001)${COLOR_RESET}"
                return 0
                ;;
            3)
                PASSWORD_MAX_DAYS=365
                echo -e "${COLOR_GREEN}✓ Set to 365 days (NIST/CIS)${COLOR_RESET}"
                return 0
                ;;
            4)
                # Custom value
                read -r -p "Enter custom value (1-999 days): " custom_days
                if [[ "$custom_days" =~ ^[0-9]+$ ]] && [[ "$custom_days" -ge 1 ]] && [[ "$custom_days" -le 999 ]]; then
                    PASSWORD_MAX_DAYS="$custom_days"
                    echo -e "${COLOR_GREEN}✓ Set to ${custom_days} days${COLOR_RESET}"
                    return 0
                else
                    echo -e "${COLOR_RED}Invalid value. Please enter a number between 1 and 999.${COLOR_RESET}"
                fi
                ;;
            5)
                # Disable
                echo -e "${COLOR_RED}⚠ WARNING: This will disable password expiration!${COLOR_RESET}"
                echo "This is NOT recommended for production environments."
                echo ""
                read -r -p "Are you sure you want to disable password expiration? (yes/no): " confirm
                if [[ "$confirm" == "yes" ]]; then
                    PASSWORD_MAX_DAYS=-1
                    echo -e "${COLOR_YELLOW}✓ Password expiration disabled${COLOR_RESET}"
                    return 0
                else
                    echo "Cancelled. Please choose another option."
                fi
                ;;
            *)
                echo -e "${COLOR_RED}Invalid option. Please select 1-5.${COLOR_RESET}"
                ;;
        esac
    done
}

prompt_min_age() {
    local default_value="${PASSWORD_MIN_DAYS:-7}"

    echo ""
    echo -e "${COLOR_BOLD}Password Minimum Age Configuration${COLOR_RESET}"
    echo ""
    echo "Minimum days before a user can change their password again."
    echo "This prevents users from rapidly cycling through passwords to"
    echo "return to their old password."
    echo ""
    echo "Recommended values:"
    echo "  • 7 days  - Standard (prevents immediate password cycling)"
    echo "  • 1 day   - Lenient (allows quick password changes)"
    echo "  • 0 days  - No restriction (development only)"
    echo ""
    echo -e "Current value: ${COLOR_CYAN}${default_value} days${COLOR_RESET}"
    echo ""

    while true; do
        read -r -p "Enter minimum days [0-${PASSWORD_MAX_DAYS}] or press Enter to keep current: " min_days

        # If empty, keep current value
        if [[ -z "$min_days" ]]; then
            echo "Keeping current value: ${default_value} days"
            PASSWORD_MIN_DAYS="$default_value"
            return 0
        fi

        # Validate input
        if [[ "$min_days" =~ ^[0-9]+$ ]]; then
            if [[ "$PASSWORD_MAX_DAYS" -ne -1 ]] && [[ "$min_days" -ge "$PASSWORD_MAX_DAYS" ]]; then
                echo -e "${COLOR_RED}Minimum days must be less than maximum days (${PASSWORD_MAX_DAYS}).${COLOR_RESET}"
            elif [[ "$min_days" -ge 0 ]] && [[ "$min_days" -le 365 ]]; then
                PASSWORD_MIN_DAYS="$min_days"
                echo -e "${COLOR_GREEN}✓ Set to ${min_days} days${COLOR_RESET}"
                return 0
            else
                echo -e "${COLOR_RED}Invalid value. Please enter a number between 0 and 365.${COLOR_RESET}"
            fi
        else
            echo -e "${COLOR_RED}Invalid input. Please enter a number.${COLOR_RESET}"
        fi
    done
}

prompt_warn_age() {
    local default_value="${PASSWORD_WARN_DAYS:-30}"

    echo ""
    echo -e "${COLOR_BOLD}Password Warning Period Configuration${COLOR_RESET}"
    echo ""
    echo "Days before password expiration to start warning the user."
    echo "Users will see warnings when logging in during this period."
    echo ""
    echo "Recommended values:"
    echo "  • 30 days - Standard (gives users plenty of notice)"
    echo "  • 14 days - Balanced (two week notice)"
    echo "  • 7 days  - Short (one week notice)"
    echo ""
    echo -e "Current value: ${COLOR_CYAN}${default_value} days${COLOR_RESET}"
    echo ""

    while true; do
        read -r -p "Enter warning days [1-90] or press Enter to keep current: " warn_days

        # If empty, keep current value
        if [[ -z "$warn_days" ]]; then
            echo "Keeping current value: ${default_value} days"
            PASSWORD_WARN_DAYS="$default_value"
            return 0
        fi

        # Validate input
        if [[ "$warn_days" =~ ^[0-9]+$ ]]; then
            if [[ "$warn_days" -ge 1 ]] && [[ "$warn_days" -le 90 ]]; then
                PASSWORD_WARN_DAYS="$warn_days"
                echo -e "${COLOR_GREEN}✓ Set to ${warn_days} days${COLOR_RESET}"
                return 0
            else
                echo -e "${COLOR_RED}Invalid value. Please enter a number between 1 and 90.${COLOR_RESET}"
            fi
        else
            echo -e "${COLOR_RED}Invalid input. Please enter a number.${COLOR_RESET}"
        fi
    done
}

# =============================================================================
# Summary and Confirmation
# =============================================================================

show_configuration_summary() {
    echo ""
    echo -e "${COLOR_BOLD}${COLOR_CYAN}═══════════════════════════════════════════════════════${COLOR_RESET}"
    echo -e "${COLOR_BOLD}Configuration Summary${COLOR_RESET}"
    echo -e "${COLOR_BOLD}${COLOR_CYAN}═══════════════════════════════════════════════════════${COLOR_RESET}"
    echo ""
    echo -e "  ${COLOR_BOLD}Password Maximum Age:${COLOR_RESET}    ${COLOR_GREEN}${PASSWORD_MAX_DAYS} days${COLOR_RESET}"
    echo -e "  ${COLOR_BOLD}Password Minimum Age:${COLOR_RESET}    ${COLOR_GREEN}${PASSWORD_MIN_DAYS} days${COLOR_RESET}"
    echo -e "  ${COLOR_BOLD}Password Warning Period:${COLOR_RESET} ${COLOR_GREEN}${PASSWORD_WARN_DAYS} days${COLOR_RESET}"
    echo ""

    # Show security assessment
    show_security_implications "$PASSWORD_MAX_DAYS"

    echo -e "${COLOR_BOLD}${COLOR_CYAN}═══════════════════════════════════════════════════════${COLOR_RESET}"
    echo ""
}

confirm_configuration() {
    echo -e "${COLOR_BOLD}Apply this configuration?${COLOR_RESET}"
    echo ""
    echo "This will:"
    echo "  • Update /etc/login.defs with new password aging settings"
    echo "  • Apply settings to existing user accounts"
    echo "  • Create backup of original configuration"
    echo ""

    read -r -p "Continue? (yes/no): " confirm

    if [[ "$confirm" == "yes" ]]; then
        return 0
    else
        return 1
    fi
}

# =============================================================================
# Main Wizard Function
# =============================================================================

run_password_aging_wizard() {
    # Show header
    show_wizard_header

    # Show current configuration
    show_current_config

    # Show compliance recommendations
    show_compliance_recommendations

    # Prompt for maximum age
    prompt_max_age

    # Prompt for minimum age
    prompt_min_age

    # Prompt for warning period
    prompt_warn_age

    # Show summary
    show_configuration_summary

    # Confirm
    if confirm_configuration; then
        echo ""
        echo -e "${COLOR_GREEN}✓ Configuration confirmed!${COLOR_RESET}"
        echo ""
        echo "Next steps:"
        echo "  1. The installer will backup your current configuration"
        echo "  2. Apply new settings to /etc/login.defs"
        echo "  3. Update existing user accounts with 'chage' command"
        echo ""
        return 0
    else
        echo ""
        echo -e "${COLOR_YELLOW}Configuration cancelled. Using current settings.${COLOR_RESET}"
        echo ""
        return 1
    fi
}

# =============================================================================
# Quick Configuration Function (Non-Interactive)
# =============================================================================

set_password_aging_quick() {
    local preset="$1"

    case "$preset" in
        pci-dss|pci)
            PASSWORD_MAX_DAYS=90
            PASSWORD_MIN_DAYS=7
            PASSWORD_WARN_DAYS=14
            echo "Applied PCI-DSS preset: 90/7/14 days"
            ;;
        iso27001|iso)
            PASSWORD_MAX_DAYS=180
            PASSWORD_MIN_DAYS=7
            PASSWORD_WARN_DAYS=30
            echo "Applied ISO 27001 preset: 180/7/30 days"
            ;;
        nist|cis)
            PASSWORD_MAX_DAYS=365
            PASSWORD_MIN_DAYS=7
            PASSWORD_WARN_DAYS=30
            echo "Applied NIST/CIS preset: 365/7/30 days"
            ;;
        dev|development)
            PASSWORD_MAX_DAYS=-1
            PASSWORD_MIN_DAYS=0
            PASSWORD_WARN_DAYS=7
            echo "Applied Development preset: disabled/0/7 days (NOT for production!)"
            ;;
        *)
            echo "Unknown preset: $preset"
            echo "Available presets: pci-dss, iso27001, nist, cis, development"
            return 1
            ;;
    esac

    return 0
}

# =============================================================================
# Export Functions for Use in Main Script
# =============================================================================

# If this script is sourced, the functions are available
# If executed directly, run the wizard
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Script is being executed directly, run the wizard
    run_password_aging_wizard
fi
