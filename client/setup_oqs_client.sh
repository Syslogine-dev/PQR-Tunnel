#!/bin/bash

# Set default values
INSTALL_DIR="$(pwd)/oqs-client"
OQS_KEX="kyber-512-sha256"
OQS_SIG="ssh-mldsa44"
SERVER_HOST="192.168.11.73"
SERVER_PORT="22"
SERVER_USER="unknown"

# Create client config
create_client_config() {
    cat > ${INSTALL_DIR}/ssh_config << EOF
Host ${SERVER_HOST}
    HostKeyAlgorithms ${OQS_SIG}
    KexAlgorithms ${OQS_KEX}
    PubkeyAcceptedKeyTypes ${OQS_SIG}
    IdentityFile ~/.ssh/id_${OQS_SIG}
    Port ${SERVER_PORT}
    User ${SERVER_USER}
EOF
}

# Main function
main() {
    echo "Setting up OQS-OpenSSH client..."
    
    # Generate client keys
    ${INSTALL_DIR}/bin/ssh-keygen -t ${OQS_SIG} -f ~/.ssh/id_${OQS_SIG} -N ""
    
    # Create client config
    create_client_config
    
    echo "Copying public key to server..."
    ${INSTALL_DIR}/bin/ssh-copy-id -i ~/.ssh/id_${OQS_SIG}.pub -p ${SERVER_PORT} ${SERVER_USER}@${SERVER_HOST}
    
    echo "Testing connection..."
    ${INSTALL_DIR}/bin/ssh -F ${INSTALL_DIR}/ssh_config ${SERVER_HOST} "echo 'Connection successful!'"
}

# Prompt for server details
read -p "Enter server IP address: " SERVER_HOST
read -p "Enter server port [22]: " SERVER_PORT
SERVER_PORT=${SERVER_PORT:-22}
read -p "Enter username: " SERVER_USER

main