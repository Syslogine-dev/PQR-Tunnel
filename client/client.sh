#!/usr/bin/env bash
#
# advanced_client.sh
#
# Fully automated script for building and configuring liboqs and OQS-SSH
# with known-working PQ algorithm names (Falcon + Kyber).
# Features enhanced error handling, environment validation, and dynamic configuration.

set -euo pipefail

# -----------------------------------------------------------------------------
# CONFIGURATION VARIABLES
# -----------------------------------------------------------------------------
INSTALL_PREFIX="/usr/local"
LIBOQS_REPO="https://github.com/open-quantum-safe/liboqs.git"
LIBOQS_VERSION="main"

# Use the OQS-SSH fork/branch that supports Falcon + Kyber, etc.
OQS_SSH_REPO="https://github.com/open-quantum-safe/openssh.git"
OQS_SSH_VERSION="OQS-OpenSSH-snapshot-2024-08"

LIBOQS_DIR="/opt/liboqs"
OQS_SSH_DIR="/opt/oqs-ssh"

LOG_FILE="/var/log/pqr_tunnel_installer.log"

# -----------------------------------------------------------------------------
# UTILITY FUNCTIONS
# -----------------------------------------------------------------------------
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

error_exit() {
    log "ERROR: $1"
    exit 1
}

validate_root() {
    if [[ $(id -u) -ne 0 ]]; then
        error_exit "This script must be run as root or with sudo."
    fi
}

# -----------------------------------------------------------------------------
# INSTALL/BUILD FUNCTIONS
# -----------------------------------------------------------------------------
install_dependencies() {
    log "Installing system dependencies..."
    apt-get update -y && apt-get install -y \
        build-essential \
        cmake \
        ninja-build \
        autoconf \
        automake \
        libtool \
        pkg-config \
        libssl-dev \
        zlib1g-dev \
        git \
        doxygen \
        graphviz || error_exit "Failed to install dependencies."
    log "System dependencies installed."
}

configure_dynamic_linker() {
    log "Configuring dynamic linker..."
    local local_conf="/etc/ld.so.conf.d/local-liboqs.conf"

    echo "/usr/local/lib" | tee "$local_conf" > /dev/null
    ldconfig || error_exit "Failed to configure dynamic linker."

    if ! ldconfig -p | grep -q liboqs; then
        error_exit "Dynamic linker configuration failed for liboqs."
    fi
    log "Dynamic linker configured successfully."
}

build_liboqs() {
    log "Building liboqs..."
    rm -rf "$LIBOQS_DIR"
    git clone -b "$LIBOQS_VERSION" "$LIBOQS_REPO" "$LIBOQS_DIR" || error_exit "Failed to clone liboqs repository."

    mkdir -p "$LIBOQS_DIR/build"
    cd "$LIBOQS_DIR/build"
    cmake -GNinja \
        -DCMAKE_INSTALL_PREFIX="$INSTALL_PREFIX" \
        -DOQS_USE_OPENSSL=OFF \
        -DBUILD_SHARED_LIBS=ON \
        .. || error_exit "CMake configuration failed for liboqs."

    ninja || error_exit "Build failed for liboqs."
    ninja install || error_exit "Installation failed for liboqs."

    log "liboqs successfully built and installed."
}

build_oqs_ssh() {
    log "Building OQS-SSH..."
    rm -rf "$OQS_SSH_DIR"
    git clone -b "$OQS_SSH_VERSION" "$OQS_SSH_REPO" "$OQS_SSH_DIR" || error_exit "Failed to clone OQS-SSH repository."

    cd "$OQS_SSH_DIR"
    autoreconf -i || error_exit "autoreconf failed for OQS-SSH."

    ./configure \
        --prefix="$INSTALL_PREFIX" \
        --with-libs=-loqs \
        --with-liboqs-dir="$INSTALL_PREFIX" \
        --with-cflags="-DWITH_KYBER=1 -DWITH_FALCON=1" \
        --enable-hybrid-kex \
        --enable-pq-kex || error_exit "Configuration failed for OQS-SSH."

    make -j"$(nproc)" || error_exit "Build failed for OQS-SSH."
    make install || error_exit "Installation failed for OQS-SSH."

    log "OQS-SSH successfully built and installed."
}

# -----------------------------------------------------------------------------
# SYSTEM & SSH CONFIGURATION FUNCTIONS
# -----------------------------------------------------------------------------
create_sshd_user() {
    log "Creating privilege separation user 'sshd'..."
    if ! id -u sshd >/dev/null 2>&1; then
        groupadd -r sshd || error_exit "Failed to create 'sshd' group."
        useradd -r -g sshd -d /var/empty -s /usr/sbin/nologin -c "Privilege-separated SSH" sshd || error_exit "Failed to create 'sshd' user."
        log "'sshd' user and group created successfully."
    else
        log "'sshd' user already exists. Skipping creation."
    fi
}

configure_ssh() {
    log "Configuring SSH..."
    mkdir -p /usr/local/etc/ssh

    # The key type must match what we’ll generate (falcon512).
    # The KexAlgorithms must match a PQ KEM that’s actually built into OQS-SSH (e.g., kyber512-sha256).
    # You can adjust to suit your environment, e.g. sntrup761x25519-sha512, bike1l1cpa-sha384, etc.
    cat << EOF > /usr/local/etc/sshd_config
HostKey /usr/local/etc/ssh/ssh_host_falcon512_key

# Post-quantum algorithms
HostKeyAlgorithms falcon512
PubkeyAcceptedAlgorithms falcon512
KexAlgorithms kyber512-sha256

# Basic OpenSSH directives
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
PasswordAuthentication no
EOF

    # Validate the SSH configuration
    if ! /usr/local/sbin/sshd -t -f /usr/local/etc/sshd_config; then
        error_exit "SSH configuration validation failed."
    fi
    log "SSH configuration set up successfully."
}

ensure_user_ssh_directory() {
    # Note: Since we run as root, $HOME is /root. If you want an unprivileged user’s .ssh,
    # you might need to specify that user explicitly.
    log "Ensuring the .ssh directory exists for the current user (root)..."
    if [[ ! -d "$HOME/.ssh" ]]; then
        mkdir -p "$HOME/.ssh"
        chmod 700 "$HOME/.ssh"
        log ".ssh directory created at $HOME/.ssh."
    else
        log ".ssh directory already exists."
    fi
}

generate_host_keys() {
    log "Generating SSH host keys..."
    mkdir -p /usr/local/etc/ssh

    # Updated to falcon512 instead of ssh-falcon512
    ssh-keygen -t falcon512 -f /usr/local/etc/ssh/ssh_host_falcon512_key -N "" \
        || error_exit "Failed to generate Falcon-512 host key."

    log "SSH host keys generated successfully."
}

cleanup() {
    log "Cleaning up build artifacts..."
    rm -rf "$LIBOQS_DIR/build" "$OQS_SSH_DIR/build"
    log "Cleanup completed."
}

# -----------------------------------------------------------------------------
# MAIN INSTALLATION SCRIPT
# -----------------------------------------------------------------------------
main() {
    validate_root
    log "Starting PQR-Tunnel installation..."

    install_dependencies
    build_liboqs
    configure_dynamic_linker
    build_oqs_ssh
    create_sshd_user
    configure_ssh
    ensure_user_ssh_directory
    generate_host_keys

    cleanup
    log "PQR-Tunnel installation completed successfully."
}

main "$@"
