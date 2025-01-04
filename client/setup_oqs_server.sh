#!/bin/bash

# Set default values
INSTALL_DIR="$(pwd)/oqs-server"
OQS_KEX="kyber-512-sha256"
OQS_SIG="ssh-mldsa44"
SSH_PORT="22"  # Default SSH port

# Create server config
create_server_config() {
    cat > ${INSTALL_DIR}/sshd_config << EOF
Port ${SSH_PORT}
HostKey ${INSTALL_DIR}/ssh_host_${OQS_SIG}_key
KexAlgorithms ${OQS_KEX}
HostKeyAlgorithms ${OQS_SIG}
PubkeyAcceptedKeyTypes ${OQS_SIG}
PidFile ${INSTALL_DIR}/sshd.pid
PermitRootLogin no
StrictModes no
EOF
}

# Main function
main() {
    echo "Setting up OQS-OpenSSH server..."
    
    # Generate host keys
    ${INSTALL_DIR}/bin/ssh-keygen -t ${OQS_SIG} -f ${INSTALL_DIR}/ssh_host_${OQS_SIG}_key -N ""
    
    # Create server config
    create_server_config
    
    # Create required directories
    mkdir -p ${INSTALL_DIR}/empty
    
    echo "Starting sshd..."
    ${INSTALL_DIR}/sbin/sshd -D -f ${INSTALL_DIR}/sshd_config
}

main