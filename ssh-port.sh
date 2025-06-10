#!/bin/bash

SSH_CONFIG="/etc/ssh/sshd_config"
FIREWALL_CMD="ufw"
BACKUP_CONFIG="${SSH_CONFIG}.bak.$(date +%F_%T)"

check_command() {
    if [ $? -eq 0 ]; then
        echo "$1 Done."
    else
        echo "Failed: $1"
        exit 1
    fi
}

read -p "Enter new SSH port (default 2222): " NEW_SSH_PORT
NEW_SSH_PORT=${NEW_SSH_PORT:-2222}

if ! [[ "$NEW_SSH_PORT" =~ ^[0-9]+$ ]] || [ "$NEW_SSH_PORT" -lt 1 ] || [ "$NEW_SSH_PORT" -gt 65535 ]; then
    echo "Error: Invalid port number. Please enter a number between 1 and 65535."
    exit 1
fi

CURRENT_PORT=$(grep -E "^Port " ${SSH_CONFIG} | awk '{print $2}' || echo "22")
if [ -z "$CURRENT_PORT" ]; then
    CURRENT_PORT="22"
fi
echo "Current SSH port: ${CURRENT_PORT}"

if ! command -v ${FIREWALL_CMD} &> /dev/null || ! ${FIREWALL_CMD} status | grep -q "Status: active"; then
    echo "Error: UFW is not installed or not active. Please install and enable it first."
    exit 1
fi

cp ${SSH_CONFIG} ${BACKUP_CONFIG}
check_command "Backing up SSH config to ${BACKUP_CONFIG}"

if grep -q "^Port " ${SSH_CONFIG}; then
    sed -i "s/^Port .*/Port ${NEW_SSH_PORT}/" ${SSH_CONFIG}
else
    echo "Port ${NEW_SSH_PORT}" >> ${SSH_CONFIG}
fi
check_command "Changing SSH port to ${NEW_SSH_PORT}"

systemctl restart ssh
if [ $? -ne 0 ]; then
    echo "Failed: Restarting SSH service. Reverting changes..."
    if [[ -f "${BACKUP_CONFIG}" ]]; then
        cp ${BACKUP_CONFIG} ${SSH_CONFIG}
        systemctl restart ssh
        if [ $? -ne 0 ]; then
            echo "Error: Failed to restart SSH after reverting config. Check manually!"
            exit 1
        fi
        ${FIREWALL_CMD} delete allow ${NEW_SSH_PORT}/tcp 2>/dev/null || true
        echo "Reverted to original SSH config due to error."
    else
        echo "Error: Backup file ${BACKUP_CONFIG} not found. Cannot revert."
    fi
    exit 1
fi
check_command "Restarting SSH service"

${FIREWALL_CMD} allow ${NEW_SSH_PORT}/tcp comment "SSH"
check_command "Adding new SSH port ${NEW_SSH_PORT}"

echo "Please test SSH connection to this server using the new port (${NEW_SSH_PORT}) in a new terminal."
echo "Command example: ssh -p ${NEW_SSH_PORT} user@<server-ip>"
echo "Do not close this session until you confirm connectivity!"
read -p "Connection successful? (y/n): " success

if [[ "$success" =~ ^[Yy]$ ]]; then
    if ${FIREWALL_CMD} status | grep -q "${CURRENT_PORT}/tcp.*ALLOW"; then
        ${FIREWALL_CMD} delete allow ${CURRENT_PORT}/tcp
        check_command "Removing old SSH port ${CURRENT_PORT}"
    else
        echo "No rule for port ${CURRENT_PORT} found, skipping removal."
    fi
    echo "Done. SSH port changed to ${NEW_SSH_PORT}."
else
    echo "Connection failed. Reverting changes..."
    cp ${BACKUP_CONFIG} ${SSH_CONFIG}
    systemctl restart ssh
    check_command "Restoring SSH service after failed connection"
    ${FIREWALL_CMD} delete allow ${NEW_SSH_PORT}/tcp
    echo "Reverted to original SSH config. Check your settings."
    exit 1
fi
