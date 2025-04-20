#!/bin/bash

NEW_SSH_PORT=2222
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
check_command "Restarting SSH service"

${FIREWALL_CMD} allow ${NEW_SSH_PORT}/tcp comment "SSH"
check_command "Adding new SSH port ${NEW_SSH_PORT}"

echo "Please test SSH connection to this server using the new port (${NEW_SSH_PORT}) in a new terminal."
echo "Command example: ssh -p ${NEW_SSH_PORT} user@<server-ip>"
echo "Do not close this session until you confirm connectivity!"
read -p "Connection successful? (y/n): " success

if [[ "$success" =~ ^[Yy]$ ]]; then
    if ${FIREWALL_CMD} status | grep -q "22/tcp.*ALLOW"; then
        ${FIREWALL_CMD} delete allow 22/tcp
        check_command "Removing old SSH port 22"
    else
        echo "No rule for port 22 found, skipping removal."
    fi
    echo "Done. SSH port changed to ${NEW_SSH_PORT}."
else
    echo "Connection failed. Reverting changes..."
    cp ${BACKUP_CONFIG} ${SSH_CONFIG}
    systemctl restart ssh
    ${FIREWALL_CMD} delete allow ${NEW_SSH_PORT}/tcp
    echo "Reverted to original SSH config. Check your settings."
    exit 1
fi
