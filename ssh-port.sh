#!/bin/bash

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
GRAY='\033[0;90m'
NC='\033[0m'

# Status symbols
CHECK="✓"
CROSS="✗"
WARNING="!"
INFO="*"
ARROW="→"

# SSH Port Configuration Script
echo
echo -e "${PURPLE}=======================${NC}"
echo -e "${WHITE}SSH PORT CONFIGURATION${NC}"
echo -e "${PURPLE}=======================${NC}"

SSH_CONFIG="/etc/ssh/sshd_config"
FIREWALL_CMD="ufw"
BACKUP_CONFIG="${SSH_CONFIG}.bak.$(date +%F_%T)"

check_command() {
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}${CHECK}${NC} $1"
    else
        echo -e "${RED}${CROSS}${NC} Failed: $1"
        exit 1
    fi
}

echo
echo -e "${GREEN}Port Input${NC}"
echo -e "${GREEN}==========${NC}"
echo

echo -ne "${CYAN}Enter new SSH port (default 2222): ${NC}"
read NEW_SSH_PORT
NEW_SSH_PORT=${NEW_SSH_PORT:-2222}

if ! [[ "$NEW_SSH_PORT" =~ ^[0-9]+$ ]] || [ "$NEW_SSH_PORT" -lt 1 ] || [ "$NEW_SSH_PORT" -gt 65535 ]; then
    echo -e "${RED}${CROSS}${NC} Invalid port number. Please enter a number between 1 and 65535."
    exit 1
fi

echo -e "${GREEN}${CHECK}${NC} Port validation successful!"

echo
echo -e "${GREEN}─────────────────────────────────────${NC}"
echo -e "${GREEN}${CHECK}${NC} Port input completed successfully!"
echo -e "${GREEN}─────────────────────────────────────${NC}"
echo

echo -e "${GREEN}System Verification${NC}"
echo -e "${GREEN}===================${NC}"
echo

echo -e "${CYAN}${INFO}${NC} Checking current configuration..."
CURRENT_PORT=$(grep -E "^Port " ${SSH_CONFIG} | awk '{print $2}' || echo "22")
if [ -z "$CURRENT_PORT" ]; then
    CURRENT_PORT="22"
fi
echo -e "${GRAY}  ${ARROW}${NC} Current SSH port: ${CURRENT_PORT}"
echo -e "${GRAY}  ${ARROW}${NC} New SSH port: ${NEW_SSH_PORT}"

echo -e "${CYAN}${INFO}${NC} Verifying firewall status..."
if ! command -v ${FIREWALL_CMD} &> /dev/null || ! ${FIREWALL_CMD} status | grep -q "Status: active" > /dev/null 2>&1; then
    echo -e "${RED}${CROSS}${NC} UFW is not installed or not active. Please install and enable it first."
    exit 1
fi
echo -e "${GRAY}  ${ARROW}${NC} UFW firewall verified"
echo -e "${GREEN}${CHECK}${NC} System verification completed!"

echo
echo -e "${GREEN}──────────────────────────────────────────────${NC}"
echo -e "${GREEN}${CHECK}${NC} System verification completed successfully!"
echo -e "${GREEN}──────────────────────────────────────────────${NC}"
echo

echo -e "${GREEN}Configuration Backup${NC}"
echo -e "${GREEN}====================${NC}"
echo

echo -e "${CYAN}${INFO}${NC} Creating configuration backup..."
echo -e "${GRAY}  ${ARROW}${NC} Backing up to ${BLUE}${BACKUP_CONFIG}${NC}"
cp ${SSH_CONFIG} ${BACKUP_CONFIG}
check_command "Configuration backup created"

echo
echo -e "${GREEN}───────────────────────────────────────────────${NC}"
echo -e "${GREEN}${CHECK}${NC} Configuration backup completed successfully!"
echo -e "${GREEN}───────────────────────────────────────────────${NC}"
echo

echo -e "${GREEN}SSH Configuration Update${NC}"
echo -e "${GREEN}========================${NC}"
echo

echo -e "${CYAN}${INFO}${NC} Updating SSH configuration..."
if grep -q "^Port " ${SSH_CONFIG}; then
    echo -e "${GRAY}  ${ARROW}${NC} Modifying existing Port directive"
    sed -i "s/^Port .*/Port ${NEW_SSH_PORT}/" ${SSH_CONFIG}
else
    echo -e "${GRAY}  ${ARROW}${NC} Adding new Port directive"
    echo "Port ${NEW_SSH_PORT}" >> ${SSH_CONFIG}
fi
check_command "SSH port configuration updated to ${NEW_SSH_PORT}"
echo

echo -e "${CYAN}${INFO}${NC} Restarting SSH service..."
echo -e "${GRAY}  ${ARROW}${NC} Applying new configuration"
systemctl restart ssh > /dev/null 2>&1
if [ $? -ne 0 ]; then
    echo -e "${RED}${CROSS}${NC} Failed to restart SSH service. Reverting changes..."
    if [[ -f "${BACKUP_CONFIG}" ]]; then
        echo -e "${GRAY}  ${ARROW}${NC} Restoring original configuration"
        cp ${BACKUP_CONFIG} ${SSH_CONFIG}
        systemctl restart ssh > /dev/null 2>&1
        if [ $? -ne 0 ]; then
            echo -e "${RED}${CROSS}${NC} Failed to restart SSH after reverting config. Check manually!"
            exit 1
        fi
        ${FIREWALL_CMD} delete allow ${NEW_SSH_PORT}/tcp > /dev/null 2>&1 || true
        echo -e "${YELLOW}${WARNING}${NC} Reverted to original SSH config due to error."
    else
        echo -e "${RED}${CROSS}${NC} Backup file ${BACKUP_CONFIG} not found. Cannot revert."
    fi
    exit 1
fi
check_command "SSH service restarted successfully"

echo
echo -e "${GREEN}───────────────────────────────────────────────────${NC}"
echo -e "${GREEN}${CHECK}${NC} SSH configuration update completed successfully!"
echo -e "${GREEN}───────────────────────────────────────────────────${NC}"
echo

echo -e "${GREEN}Firewall Configuration${NC}"
echo -e "${GREEN}======================${NC}"
echo

echo -e "${CYAN}${INFO}${NC} Adding firewall rule for new SSH port..."
echo -e "${GRAY}  ${ARROW}${NC} Allowing port ${NEW_SSH_PORT}/tcp"
${FIREWALL_CMD} allow ${NEW_SSH_PORT}/tcp comment "SSH" > /dev/null 2>&1
check_command "Firewall rule added for port ${NEW_SSH_PORT}"

echo
echo -e "${GREEN}─────────────────────────────────────────────────${NC}"
echo -e "${GREEN}${CHECK}${NC} Firewall configuration completed successfully!"
echo -e "${GREEN}─────────────────────────────────────────────────${NC}"
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
read success

if [[ "$success" =~ ^[Yy]$ ]]; then
    echo
    echo -e "${CYAN}${INFO}${NC} Finalizing configuration..."
    if ${FIREWALL_CMD} status | grep -q "${CURRENT_PORT}/tcp.*ALLOW" > /dev/null 2>&1; then
        echo -e "${GRAY}  ${ARROW}${NC} Removing old firewall rule for port ${CURRENT_PORT}"
        ${FIREWALL_CMD} delete allow ${CURRENT_PORT}/tcp > /dev/null 2>&1
        check_command "Old SSH port ${CURRENT_PORT} removed from firewall"
    else
        echo -e "${GRAY}  ${ARROW}${NC} No rule for port ${CURRENT_PORT} found, skipping removal"
        echo -e "${GREEN}${CHECK}${NC} No old firewall rule to remove"
    fi
else
    echo
    echo -e "${YELLOW}${WARNING}${NC} Connection failed. Reverting changes..."
    echo -e "${GRAY}  ${ARROW}${NC} Restoring original configuration"
    cp ${BACKUP_CONFIG} ${SSH_CONFIG}
    systemctl restart ssh > /dev/null 2>&1
    check_command "SSH configuration restored"
    echo -e "${GRAY}  ${ARROW}${NC} Removing new firewall rule"
    ${FIREWALL_CMD} delete allow ${NEW_SSH_PORT}/tcp > /dev/null 2>&1
    echo -e "${YELLOW}${WARNING}${NC} Reverted to original SSH config. Check your settings."
    exit 1
fi

echo
echo -e "${GREEN}─────────────────────────────────────────────${NC}"
echo -e "${GREEN}${CHECK}${NC} Connection testing completed successfully!"
echo -e "${GREEN}─────────────────────────────────────────────${NC}"
echo

echo -e "${PURPLE}===========================${NC}"
echo -e "${GREEN}${CHECK}${NC} CONFIGURATION COMPLETED!"
echo -e "${PURPLE}===========================${NC}"
echo
echo -e "${CYAN}Configuration Summary:${NC}"
echo -e "${WHITE}• SSH port changed from ${CURRENT_PORT} to ${NEW_SSH_PORT}${NC}"
echo -e "${WHITE}• Firewall rule updated${NC}"
echo -e "${WHITE}• Original config backed up to: ${BACKUP_CONFIG}${NC}"
echo
