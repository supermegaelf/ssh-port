#!/bin/bash

#==================
# SSH PORT MANAGER
#==================

# Color constants
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly PURPLE='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly WHITE='\033[1;37m'
readonly GRAY='\033[0;90m'
readonly NC='\033[0m'

# Status symbols
readonly CHECK="✓"
readonly CROSS="✗"
readonly WARNING="!"
readonly INFO="*"
readonly ARROW="→"

# Global variables
SSH_CONFIG="/etc/ssh/sshd_config"
FIREWALL_CMD="ufw"
BACKUP_CONFIG="${SSH_CONFIG}.bak.$(date +%F_%T)"
SOCKET_ACTIVE=false
SOCKET_OVERRIDE="/etc/systemd/system/ssh.socket.d/listen.conf"
SOCKET_BACKUP=""
CONFIG_CHANGED=false
SOCKET_CHANGED=false
FIREWALL_ADDED=()

#======================
# VALIDATION FUNCTIONS
#======================

check_command() {
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}${CHECK}${NC} $1"
    else
        echo -e "${RED}${CROSS}${NC} Failed: $1"
        exit 1
    fi
}

get_socket_ports() {
    local listen
    listen=$(systemctl show ssh.socket --property=Listen 2>/dev/null) || return 1
    echo "$listen" | grep -oE '[0-9]+ (\(Stream\)|type=Stream)' | grep -oE '^[0-9]+' | sort -u
}

restart_ssh() {
    local expected_port=${1:-$NEW_SSH_PORT} socket_ports
    if $SOCKET_ACTIVE; then
        systemctl daemon-reload > /dev/null 2>&1 || return 1
        if ! socket_ports=$(get_socket_ports) || [ "$socket_ports" != "$expected_port" ]; then
            echo -e "${RED}${CROSS}${NC} SSH socket port does not match ${expected_port}. Check socket overrides."
            return 1
        fi
        systemctl restart ssh.socket ssh.service > /dev/null 2>&1
    else
        systemctl restart ssh > /dev/null 2>&1
    fi
}

revert_socket() {
    if $SOCKET_CHANGED; then
        if [ -n "$SOCKET_BACKUP" ] && [ -f "$SOCKET_BACKUP" ]; then
            cp "$SOCKET_BACKUP" "${SOCKET_OVERRIDE}"
        else
            rm -f "${SOCKET_OVERRIDE}"
        fi
    fi
}

revert_firewall() {
    local address
    if [ "${#FIREWALL_ADDED[@]}" -gt 0 ]; then
        echo -e "${GRAY}  ${ARROW}${NC} Removing new firewall rule"
    fi
    for address in "${FIREWALL_ADDED[@]}"; do
        if ! ${FIREWALL_CMD} --force delete allow proto tcp from any to "$address" port "${NEW_SSH_PORT}" > /dev/null 2>&1; then
            echo -e "${RED}${CROSS}${NC} Failed to remove new firewall rule. Check manually!"
            return 1
        fi
    done
    FIREWALL_ADDED=()
}

firewall_rule_active() {
    local rules
    rules=$("$1" -S ufw-user-input 2>/dev/null) || return 1
    echo "$rules" | \
        sed -E 's/ -m comment --comment ("[^"]*"|[^ ]+)//' | \
        awk -v port="$NEW_SSH_PORT" '
            function contains_port(spec, parts, bounds, n, i) {
                n = split(spec, parts, ",")
                for (i = 1; i <= n; i++) {
                    if (parts[i] == port) return 1
                    if (index(parts[i], ":")) {
                        split(parts[i], bounds, ":")
                        if (port >= (bounds[1] == "" ? 0 : bounds[1]) &&
                            port <= (bounds[2] == "" ? 65535 : bounds[2])) return 1
                    }
                }
                return 0
            }
            $0 == "-A ufw-user-input -p tcp -m tcp --dport " port " -j ACCEPT" { found = 1; exit }
            $1 == "-A" {
                protocol = ""; target = ""; ports = ""; negated = 0
                for (i = 3; i <= NF; i++) {
                    if ($i == "-p") protocol = $(i+1)
                    if ($i == "-j") target = $(i+1)
                    if ($i == "--dport" || $i == "--dports") ports = $(i+1)
                    if ($i == "!") negated = 1
                }
                if ((target == "DROP" || target == "REJECT") &&
                    (negated || protocol == "" || protocol == "all" || protocol == "tcp") &&
                    (negated || ports == "" || contains_port(ports))) { conflict = 1; exit }
            }
            END { exit (conflict ? 2 : !found) }
        '
}

revert_changes() {
    local failed=0
    if $CONFIG_CHANGED; then
        echo -e "${GRAY}  ${ARROW}${NC} Restoring original configuration"
        if cp "${BACKUP_CONFIG}" "${SSH_CONFIG}" && revert_socket && sshd -t -f "${SSH_CONFIG}"; then
            if ${1:-true} && ! restart_ssh "$CURRENT_PORT"; then
                echo -e "${RED}${CROSS}${NC} Failed to restart SSH after reverting. Check manually!"
                failed=1
            fi
        else
            echo -e "${RED}${CROSS}${NC} Failed to restore SSH configuration. Check manually!"
            failed=1
        fi
    fi
    if [ "$failed" -ne 0 ]; then
        echo -e "${YELLOW}${WARNING}${NC} Firewall rules retained. Restore SSH manually before removing them!"
        return 1
    fi
    revert_firewall || failed=1
    return "$failed"
}

validate_ssh_config() {
    local effective
    echo -e "${GRAY}  ${ARROW}${NC} Validating SSH configuration"
    if sshd -t -f "${SSH_CONFIG}" && effective=$(sshd -T -f "${SSH_CONFIG}") && \
       [ "$(echo "$effective" | awk '$1 == "port" {print $2}' | sort -u)" = "$NEW_SSH_PORT" ] && \
       { $SOCKET_ACTIVE || [ "$(echo "$effective" | awk '$1 == "listenaddress" {sub(/^.*:/, "", $2); print $2}' | sort -u)" = "$NEW_SSH_PORT" ]; }; then
        return 0
    fi
    echo -e "${RED}${CROSS}${NC} Invalid or conflicting SSH configuration. Reverting changes..."
    return 1
}

#================
# MAIN FUNCTIONS
#================

get_port_input() {
    echo
    echo -e "${GREEN}Port Input${NC}"
    echo -e "${GREEN}==========${NC}"
    echo

    echo -ne "${CYAN}Enter new SSH port (default 40000, press Enter to use it): ${NC}"
    read -r NEW_SSH_PORT
    NEW_SSH_PORT=${NEW_SSH_PORT:-40000}

    if ! [[ "$NEW_SSH_PORT" =~ ^[0-9]+$ ]] || [ "$NEW_SSH_PORT" -lt 1 ] || [ "$NEW_SSH_PORT" -gt 65535 ]; then
        echo -e "${RED}${CROSS}${NC} Invalid port number. Please enter a number between 1 and 65535."
        exit 1
    fi
    NEW_SSH_PORT=$((10#$NEW_SSH_PORT))

    echo -e "${GREEN}${CHECK}${NC} Port validation successful!"
}

verify_system() {
    echo
    echo -e "${GREEN}System Verification${NC}"
    echo -e "${GREEN}===================${NC}"
    echo

    echo -e "${CYAN}${INFO}${NC} Checking current configuration..."

    local effective
    if ! effective=$(sshd -T -f "${SSH_CONFIG}"); then
        echo -e "${RED}${CROSS}${NC} Failed to read effective SSH configuration."
        exit 1
    fi

    if systemctl is-active ssh.socket > /dev/null 2>&1; then
        SOCKET_ACTIVE=true
        if ! CURRENT_PORT=$(get_socket_ports); then
            echo -e "${RED}${CROSS}${NC} Failed to read SSH socket configuration."
            exit 1
        fi
    else
        CURRENT_PORT=$(echo "$effective" | awk '$1 == "listenaddress" {sub(/^.*:/, "", $2); print $2}' | sort -u)
    fi

    if echo "$CURRENT_PORT" | grep -qx "$NEW_SSH_PORT"; then
        echo -e "${GREEN}${CHECK}${NC} SSH port ${NEW_SSH_PORT} is already configured. No changes needed."
        exit 0
    fi

    if ! [[ "$CURRENT_PORT" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}${CROSS}${NC} Cannot determine a single current SSH port. Check Include, ListenAddress and ssh.socket settings."
        exit 1
    fi

    echo -e "${GRAY}  ${ARROW}${NC} Current SSH port: ${CURRENT_PORT}"
    echo -e "${GRAY}  ${ARROW}${NC} New SSH port: ${NEW_SSH_PORT}"

    if ss -tlnp 2>/dev/null | grep -v "sshd" | grep -qE ":${NEW_SSH_PORT}[^0-9]"; then
        echo -e "${RED}${CROSS}${NC} Port ${NEW_SSH_PORT} is already in use by another service. Choose a different port."
        exit 1
    fi

    echo -e "${GREEN}${CHECK}${NC} Configuration analysis completed!"

    if ! command -v ${FIREWALL_CMD} &> /dev/null || ! ${FIREWALL_CMD} status | grep -q "Status: active" > /dev/null 2>&1; then
        echo -e "${RED}${CROSS}${NC} UFW is not installed or not active. Please install and enable it first."
        exit 1
    fi
}

create_backup() {
    echo
    echo -e "${GREEN}Configuration Backup${NC}"
    echo -e "${GREEN}====================${NC}"
    echo

    echo -e "${CYAN}${INFO}${NC} Creating configuration backup..."
    echo -e "${GRAY}  ${ARROW}${NC} Copying configuration to ${BLUE}${BACKUP_CONFIG}${NC}"
    cp "${SSH_CONFIG}" "${BACKUP_CONFIG}" > /dev/null 2>&1
    check_command "Configuration backup created successfully"

    if $SOCKET_ACTIVE && [ -f "${SOCKET_OVERRIDE}" ]; then
        SOCKET_BACKUP="${SOCKET_OVERRIDE}.bak.$(date +%F_%T)"
        cp "${SOCKET_OVERRIDE}" "${SOCKET_BACKUP}" > /dev/null 2>&1
        check_command "Socket configuration backup created successfully"
    fi
}

update_ssh_config() {
    echo
    echo -e "${GREEN}SSH Configuration Update${NC}"
    echo -e "${GREEN}========================${NC}"
    echo

    echo -e "${CYAN}${INFO}${NC} Updating SSH configuration..."
    CONFIG_CHANGED=true
    if grep -qiE '^[[:space:]]*Port[[:space:]]+' "${SSH_CONFIG}"; then
        echo -e "${GRAY}  ${ARROW}${NC} Modifying existing Port directive"
        sed -i "s/^[[:space:]]*[Pp][Oo][Rr][Tt][[:space:]].*/Port ${NEW_SSH_PORT}/" "${SSH_CONFIG}" > /dev/null 2>&1 || { revert_changes false; exit 1; }
    else
        echo -e "${GRAY}  ${ARROW}${NC} Adding new Port directive"
        sed -i "1iPort ${NEW_SSH_PORT}" "${SSH_CONFIG}" > /dev/null 2>&1 || { revert_changes false; exit 1; }
    fi

    if $SOCKET_ACTIVE; then
        mkdir -p "$(dirname "${SOCKET_OVERRIDE}")" || { revert_changes false; exit 1; }
        SOCKET_CHANGED=true
        printf "[Socket]\nListenStream=\nListenStream=0.0.0.0:%s\nListenStream=[::]:%s\n" "${NEW_SSH_PORT}" "${NEW_SSH_PORT}" > "${SOCKET_OVERRIDE}" || { revert_changes false; exit 1; }
        echo -e "${GRAY}  ${ARROW}${NC} Updating socket activation config"
    fi

    validate_ssh_config || { revert_changes false; exit 1; }

    echo -e "${GRAY}  ${ARROW}${NC} Restarting SSH service"
    restart_ssh
    if [ $? -ne 0 ]; then
        echo -e "${RED}${CROSS}${NC} Failed to restart SSH service. Reverting changes..."
        if revert_changes; then
            echo -e "${YELLOW}${WARNING}${NC} Reverted to original SSH config due to error."
        fi
        exit 1
    fi

    if ! $SOCKET_ACTIVE; then
        sleep 1
        if ss -tlnp 2>/dev/null | grep "sshd" | grep -q "\[::\]:${NEW_SSH_PORT}" && \
           ! ss -tlnp 2>/dev/null | grep "sshd" | grep -q "0\.0\.0\.0:${NEW_SSH_PORT}"; then
            if ! grep -q "^ListenAddress" "${SSH_CONFIG}"; then
                echo -e "${GRAY}  ${ARROW}${NC} IPv6-only detected, adding ListenAddress for IPv4 and IPv6"
                sed -i '1iListenAddress 0.0.0.0\nListenAddress ::' "${SSH_CONFIG}" || { revert_changes; exit 1; }
                validate_ssh_config || { revert_changes; exit 1; }
                echo -e "${GRAY}  ${ARROW}${NC} Restarting SSH service"
                restart_ssh
                if [ $? -ne 0 ]; then
                    echo -e "${RED}${CROSS}${NC} Failed to restart SSH after adding ListenAddress. Reverting..."
                    if revert_changes; then
                        echo -e "${YELLOW}${WARNING}${NC} Reverted to original SSH config due to error."
                    fi
                    exit 1
                fi
            fi
        fi
    fi

    echo -e "${GREEN}${CHECK}${NC} SSH configuration applied successfully"
}

configure_firewall() {
    local status address pattern table rule_status
    local addresses=(0.0.0.0/0)
    echo
    echo -e "${GREEN}Firewall Configuration${NC}"
    echo -e "${GREEN}======================${NC}"
    echo

    echo -e "${CYAN}${INFO}${NC} Adding firewall rule..."
    echo -e "${GRAY}  ${ARROW}${NC} Allowing port ${NEW_SSH_PORT}/tcp"
    if ! status=$(LC_ALL=C ${FIREWALL_CMD} status) || [ ! -r /etc/default/ufw ]; then
        echo -e "${RED}${CROSS}${NC} Failed to read firewall configuration."
        exit 1
    fi
    if grep -qiE "^[[:space:]]*IPV6=(yes|\"yes\"|'yes')[[:space:]]*$" /etc/default/ufw; then
        addresses+=(::/0)
    fi
    for address in "${addresses[@]}"; do
        table=iptables
        pattern="^${NEW_SSH_PORT}/tcp[[:space:]]+ALLOW([[:space:]]+IN)?[[:space:]]+Anywhere([[:space:]]+#.*)?[[:space:]]*$"
        if [ "$address" = "::/0" ]; then
            table=ip6tables
            pattern="^${NEW_SSH_PORT}/tcp[[:space:]]+\(v6\)[[:space:]]+ALLOW([[:space:]]+IN)?[[:space:]]+Anywhere[[:space:]]+\(v6\)([[:space:]]+#.*)?[[:space:]]*$"
        fi
        if ! echo "$status" | grep -qE "$pattern"; then
            FIREWALL_ADDED+=("$address")
            if ! ${FIREWALL_CMD} allow proto tcp from any to "$address" port "${NEW_SSH_PORT}" comment "SSH" > /dev/null 2>&1; then
                echo -e "${RED}${CROSS}${NC} Failed to add firewall rule for port ${NEW_SSH_PORT}"
                revert_firewall
                exit 1
            fi
        fi
        firewall_rule_active "$table"
        rule_status=$?
        if [ "$rule_status" -eq 2 ]; then
            echo -e "${RED}${CROSS}${NC} Conflicting firewall rule for port ${NEW_SSH_PORT}. Reverting changes..."
            revert_firewall
            exit 1
        fi
        if [ "$rule_status" -ne 0 ]; then
            echo -e "${GRAY}  ${ARROW}${NC} Rule not in iptables, reloading UFW"
            if ! ${FIREWALL_CMD} reload > /dev/null 2>&1 || \
               ! firewall_rule_active "$table"; then
                echo -e "${RED}${CROSS}${NC} Failed to add firewall rule for port ${NEW_SSH_PORT}"
                revert_firewall
                exit 1
            fi
        fi
    done
    echo -e "${GREEN}${CHECK}${NC} Firewall rule added for port ${NEW_SSH_PORT}"
}

test_connection() {
    echo
    echo -e "${GREEN}Connection Testing${NC}"
    echo -e "${GREEN}==================${NC}"
    echo

    echo -e "${YELLOW}${WARNING}${NC} Please test SSH connection to this server using the new port!"
    echo
    echo -e "${CYAN}Connection Information:${NC}"
    echo -e "${WHITE}• New SSH port: ${NEW_SSH_PORT}${NC}"
    echo -e "${WHITE}• Test command: ssh -p ${NEW_SSH_PORT} user@<server-ip>${NC}"
    echo -e "${WHITE}• Do not close this session until you confirm connectivity!${NC}"
    echo

    echo -ne "${CYAN}Connection successful? (y/n): ${NC}"
    read -r success

    if [[ "$success" =~ ^[Yy]$ ]]; then
        echo
        echo -e "${CYAN}${INFO}${NC} Finalizing configuration..."
        if ${FIREWALL_CMD} status | grep -qE "^${CURRENT_PORT}/tcp[[:space:]].*ALLOW" || \
           { [ "$CURRENT_PORT" = "22" ] && ${FIREWALL_CMD} status | grep -q "OpenSSH.*ALLOW"; }; then
            echo -e "${GRAY}  ${ARROW}${NC} Removing old firewall rule for port ${CURRENT_PORT}"
            ${FIREWALL_CMD} delete allow ${CURRENT_PORT}/tcp > /dev/null 2>&1 || true
            [ "$CURRENT_PORT" = "22" ] && ${FIREWALL_CMD} delete allow OpenSSH > /dev/null 2>&1 || true
            check_command "Old SSH port ${CURRENT_PORT} removed from firewall"
        else
            echo -e "${GRAY}  ${ARROW}${NC} No rule for port ${CURRENT_PORT} found, skipping removal"
            echo -e "${GREEN}${CHECK}${NC} No old firewall rule to remove"
        fi
    else
        echo
        echo -e "${YELLOW}${WARNING}${NC} Connection failed. Reverting changes..."
        if revert_changes; then
            echo -e "${GREEN}${CHECK}${NC} Reverted to original SSH config"
        fi
        echo -e "${YELLOW}${WARNING}${NC} Check your settings."
        exit 1
    fi
}

show_completion_summary() {
    echo
    echo -e "${PURPLE}=========================${NC}"
    echo -e "${GREEN}${CHECK}${NC} Installation complete!"
    echo -e "${PURPLE}=========================${NC}"
    echo
    echo -e "${CYAN}Configuration Summary:${NC}"
    echo -e "${WHITE}• SSH port changed from ${CURRENT_PORT} to ${NEW_SSH_PORT}${NC}"
    echo -e "${WHITE}• Firewall rule updated${NC}"
    echo -e "${WHITE}• Original config backed up to: ${BACKUP_CONFIG}${NC}"
}

#==================
# MAIN ENTRY POINT
#==================

main() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}${CROSS}${NC} This script must be run as root."
        exit 1
    fi

    echo
    echo -e "${PURPLE}=================${NC}"
    echo -e "${WHITE}SSH PORT MANAGER${NC}"
    echo -e "${PURPLE}=================${NC}"

    get_port_input
    verify_system
    create_backup
    configure_firewall
    update_ssh_config
    test_connection
    show_completion_summary
    echo
}

# Execute main function
main
