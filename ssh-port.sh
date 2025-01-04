#!/bin/bash

NEW_SSH_PORT=2222
SSH_CONFIG="/etc/ssh/sshd_config"
FIREWALL_CMD="ufw"

check_command() {
    if [ $? -eq 0 ]; then
        echo "✔ $1 Done."
    else
        echo "✖ Failed: $1"
        exit 1
    fi
}

sed -i "s/^#*Port .*/Port ${NEW_SSH_PORT}/" ${SSH_CONFIG}
check_command "Changing SSH port..."

systemctl restart ssh
check_command "Restarting SSH service..."

${FIREWALL_CMD} allow ${NEW_SSH_PORT}/tcp comment "SSH"
check_command "Adding new SSH port..."

echo "Check connection through port ${NEW_SSH_PORT}. Do not close current session!"

read -p "Connection successful? (y/n): " success
if [[ "$success" == "y" ]]; then
    ${FIREWALL_CMD} delete allow 22/tcp
    check_command "Removing old SSH port..."
    echo "DONE."
else
    echo "FAILED. Check your settings."
    exit 1
fi
