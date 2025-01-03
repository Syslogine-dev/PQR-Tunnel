#!/usr/bin/env bash
#
# client.sh
#
# Hardened installation script for liboqs & OQS-SSH with comprehensive error handling
# and system validation.

set -euo pipefail

# ---------------------------
# CONFIGURABLE VARIABLES
# ---------------------------
INSTALL_PREFIX="/usr/local"
LIBOQS_REPO="https://github.com/open-quantum-safe/liboqs.git"
LIBOQS_VERSION="main"
LIBOQS_BACKUP_REPO="https://gitlab.com/open-quantum-safe/liboqs.git"  # Fallback mirror

OQS_SSH_REPO="https://github.com/open-quantum-safe/openssh.git"
OQS_SSH_VERSION="OQS-OpenSSH-snapshot-2024-08"
OQS_SSH_BACKUP_REPO="https://gitlab.com/open-quantum-safe/openssh.git"

LIBOQS_DIR="/opt/liboqs"
OQS_SSH_DIR="/opt/oqs-ssh"

# Installation configuration
SSHD_CONFIG_DIR="$INSTALL_PREFIX/etc/ssh"
CUSTOM_SSHD_BIN="$INSTALL_PREFIX/sbin/sshd"
SSH_PORT=8022

# System service configuration
SYSTEMD_SERVICE_PATH="/etc/systemd/system/oqs-sshd.service"
LOG_FILE="/var/log/pqr_tunnel_installer.log"

# System requirements
REQUIRED_DISK_SPACE_GB=10
REQUIRED_MEMORY_GB=4
MIN_KERNEL_VERSION="4.0.0"
MAX_BUILD_JOBS=4  # Limit parallel build jobs

# Backup directory for existing configurations
BACKUP_DIR="/root/oqs_ssh_backup_$(date +%Y%m%d_%H%M%S)"

# ---------------------------
# LOGGING & ERROR HANDLING
# ---------------------------
declare -a CLEANUP_TASKS=()

log() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp="$(date +'%Y-%m-%d %H:%M:%S')"
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

info() { log "INFO" "$1"; }
warn() { log "WARN" "$1" >&2; }
error() { log "ERROR" "$1" >&2; }

error_exit() {
    error "$1"
    cleanup
    exit 1
}

add_cleanup_task() {
    CLEANUP_TASKS+=("$1")
}

cleanup() {
    info "Performing cleanup..."
    for task in "${CLEANUP_TASKS[@]}"; do
        eval "$task" || warn "Cleanup task failed: $task"
    done
}

trap cleanup EXIT

# ---------------------------
# SYSTEM VALIDATION
# ---------------------------
validate_system_requirements() {
    info "Validating system requirements..."

    # Check root privileges
    if [[ $(id -u) -ne 0 ]]; then
        error_exit "This script must be run as root or with sudo"
    }

    # Check distribution
    if ! command -v apt-get >/dev/null 2>&1; then
        error_exit "This script requires a Debian-based distribution"
    }

    # Check kernel version
    local kernel_version
    kernel_version=$(uname -r | cut -d'-' -f1)
    if ! printf '%s\n%s\n' "$MIN_KERNEL_VERSION" "$kernel_version" | sort -V -C; then
        error_exit "Kernel version $kernel_version is below minimum required version $MIN_KERNEL_VERSION"
    }

    # Check available memory
    local available_memory_kb
    available_memory_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
    local required_memory_kb=$((REQUIRED_MEMORY_GB * 1024 * 1024))
    if ((available_memory_kb < required_memory_kb)); then
        error_exit "Insufficient memory: ${available_memory_kb}KB available, ${required_memory_kb}KB required"
    }

    # Check available disk space
    local available_space_kb
    available_space_kb=$(df -k "$INSTALL_PREFIX" | awk 'NR==2 {print $4}')
    local required_space_kb=$((REQUIRED_DISK_SPACE_GB * 1024 * 1024))
    if ((available_space_kb < required_space_kb)); then
        error_exit "Insufficient disk space: ${available_space_kb}KB available, ${required_space_kb}KB required"
    }

    # Verify required commands
    local required_commands=(git cmake make gcc g++ ninja-build)
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            error_exit "Required command not found: $cmd"
        }
    done

    info "System requirements validated successfully"
}

# ---------------------------
# BACKUP FUNCTIONALITY
# ---------------------------
backup_existing_configuration() {
    info "Backing up existing configuration..."
    
    if [[ -d "$SSHD_CONFIG_DIR" ]]; then
        mkdir -p "$BACKUP_DIR/ssh"
        cp -r "$SSHD_CONFIG_DIR"/* "$BACKUP_DIR/ssh/" || warn "Failed to backup SSH config"
    }

    if [[ -f "$SYSTEMD_SERVICE_PATH" ]]; then
        mkdir -p "$BACKUP_DIR/systemd"
        cp "$SYSTEMD_SERVICE_PATH" "$BACKUP_DIR/systemd/" || warn "Failed to backup systemd service"
    }

    info "Configuration backed up to $BACKUP_DIR"
}

# ---------------------------
# DEPENDENCY MANAGEMENT
# ---------------------------
install_dependencies() {
    info "Installing dependencies..."
    
    # Update package list with timeout
    timeout 300 apt-get update -y || error_exit "apt-get update failed"

    local DEPS=(
        build-essential
        cmake
        ninja-build
        autoconf
        automake
        libtool
        pkg-config
        libssl-dev
        zlib1g-dev
        git
        doxygen
        graphviz
        curl
        wget
        ca-certificates
    )

    # Try to install packages with retry mechanism
    local retries=3
    while ((retries > 0)); do
        if apt-get install -y "${DEPS[@]}"; then
            break
        fi
        ((retries--))
        if ((retries == 0)); then
            error_exit "Failed to install dependencies after 3 attempts"
        fi
        info "Retrying dependency installation..."
        sleep 5
    done

    # Verify installations
    for pkg in "${DEPS[@]}"; do
        if ! dpkg -l "$pkg" >/dev/null 2>&1; then
            error_exit "Package verification failed for: $pkg"
        fi
    done

    info "Dependencies installed successfully"
}

# ---------------------------
# BUILD liboqs
# ---------------------------
build_liboqs() {
    info "Building liboqs..."
    local build_dir="$LIBOQS_DIR/build"

    # Backup existing installation
    if [[ -d "$LIBOQS_DIR" ]]; then
        info "Backing up existing liboqs directory..."
        mv "$LIBOQS_DIR" "${LIBOQS_DIR}.bak.$(date +%s)"
    }

    # Clone with fallback
    if ! timeout 300 git clone --depth 1 -b "$LIBOQS_VERSION" "$LIBOQS_REPO" "$LIBOQS_DIR"; then
        info "Primary repository failed, trying backup..."
        if ! timeout 300 git clone --depth 1 -b "$LIBOQS_VERSION" "$LIBOQS_BACKUP_REPO" "$LIBOQS_DIR"; then
            error_exit "Failed to clone liboqs from both primary and backup repositories"
        fi
    }

    # Verify source code integrity
    cd "$LIBOQS_DIR"
    if ! git verify-commit HEAD 2>/dev/null; then
        warn "Could not verify git commit signature"
    }

    # Create and enter build directory
    mkdir -p "$build_dir"
    cd "$build_dir"

    # Configure build
    if ! cmake -GNinja \
        -DCMAKE_INSTALL_PREFIX="$INSTALL_PREFIX" \
        -DOQS_USE_OPENSSL=OFF \
        -DBUILD_SHARED_LIBS=ON \
        -DCMAKE_BUILD_TYPE=Release \
        ..; then
        error_exit "liboqs CMake configuration failed"
    }

    # Build with limited jobs
    if ! ninja -j"$MAX_BUILD_JOBS"; then
        error_exit "liboqs build failed"
    }

    # Install
    if ! ninja install; then
        error_exit "liboqs installation failed"
    }

    info "liboqs built and installed successfully"
}

# ---------------------------
# BUILD OQS-SSH
# ---------------------------
build_oqs_ssh() {
    info "Building OQS-SSH..."

    if [[ -d "$OQS_SSH_DIR" ]]; then
        info "Backing up existing OQS-SSH directory..."
        mv "$OQS_SSH_DIR" "${OQS_SSH_DIR}.bak.$(date +%s)"
    }

    # Clone with fallback
    if ! timeout 300 git clone --depth 1 -b "$OQS_SSH_VERSION" "$OQS_SSH_REPO" "$OQS_SSH_DIR"; then
        info "Primary repository failed, trying backup..."
        if ! timeout 300 git clone --depth 1 -b "$OQS_SSH_VERSION" "$OQS_SSH_BACKUP_REPO" "$OQS_SSH_DIR"; then
            error_exit "Failed to clone OQS-SSH from both primary and backup repositories"
        fi
    }

    cd "$OQS_SSH_DIR"

    # Run autoconf tools
    if ! autoreconf -i; then
        error_exit "autoreconf failed"
    }

    # Configure with safe flags
    if ! ./configure \
        --prefix="$INSTALL_PREFIX" \
        --with-libs=-loqs \
        --with-liboqs-dir="$INSTALL_PREFIX" \
        --with-cflags="-DWITH_KYBER=1 -DWITH_FALCON=1 -fstack-protector-strong -D_FORTIFY_SOURCE=2" \
        --with-ldflags="-Wl,-z,relro,-z,now" \
        --enable-hybrid-kex \
        --enable-pq-kex; then
        error_exit "OQS-SSH configure failed"
    }

    # Build with limited jobs and timeout
    if ! timeout 1800 make -j"$MAX_BUILD_JOBS"; then
        error_exit "OQS-SSH build failed"
    }

    if ! make install; then
        error_exit "OQS-SSH installation failed"
    }

    info "OQS-SSH built and installed successfully"
}

# ---------------------------
# CONFIGURE SYSTEM
# ---------------------------
configure_dynamic_linker() {
    info "Configuring dynamic linker..."
    local conf_file="/etc/ld.so.conf.d/local-liboqs.conf"

    # Add library path if not present
    if ! grep -q "^${INSTALL_PREFIX}/lib" "$conf_file" 2>/dev/null; then
        echo "${INSTALL_PREFIX}/lib" >> "$conf_file"
    }

    # Update linker cache
    if ! ldconfig; then
        error_exit "ldconfig failed"
    }

    # Verify library is found
    if ! ldconfig -p | grep -q liboqs; then
        error_exit "liboqs not found by dynamic linker"
    }

    info "Dynamic linker configured successfully"
}

create_sshd_user() {
    info "Setting up SSHD user..."

    if ! getent group sshd >/dev/null; then
        groupadd -r sshd || error_exit "Failed to create sshd group"
    }

    if ! id -u sshd >/dev/null 2>&1; then
        useradd -r -g sshd -d /var/empty/sshd -s /sbin/nologin \
            -c "Privilege-separated SSH" sshd || error_exit "Failed to create sshd user"
        
        # Create and secure home directory
        install -d -m 0755 -o sshd -g sshd /var/empty/sshd
    fi

    info "SSHD user setup completed"
}

configure_ssh() {
    info "Configuring OQS-SSH..."

    # Create config directory with secure permissions
    install -d -m 0755 "$SSHD_CONFIG_DIR"

    # Generate configuration
    cat > "$SSHD_CONFIG_DIR/sshd_config" <<EOF
# OQS-SSH Security Configuration
Protocol 2
HostKey $SSHD_CONFIG_DIR/ssh_host_falcon512_key
HostKeyAlgorithms falcon512
PubkeyAcceptedAlgorithms falcon512
KexAlgorithms kyber512-sha256

# Authentication
PubkeyAuthentication yes
PasswordAuthentication no
PermitRootLogin no
StrictModes yes
MaxAuthTries 3

# Network
Port $SSH_PORT
AddressFamily any
ListenAddress 0.0.0.0
TCPKeepAlive yes
ClientAliveInterval 300
ClientAliveCountMax 2

# Security
X11Forwarding no
AllowTcpForwarding no
PermitTunnel no
AllowAgentForwarding no
PermitUserEnvironment no
MaxStartups 10:30:100

# Logging
SyslogFacility AUTH
LogLevel VERBOSE

# File locations
PidFile /var/run/oqs-sshd.pid
AuthorizedKeysFile .ssh/authorized_keys
EOF

    # Set secure permissions
    chmod 600 "$SSHD_CONFIG_DIR/sshd_config"

    # Validate configuration
    if ! "$CUSTOM_SSHD_BIN" -t -f "$SSHD_CONFIG_DIR/sshd_config"; then
        error_exit "SSH configuration validation failed"
    }

    info "SSH configured successfully"
}

generate_host_keys() {
    info "Generating host keys..."
    local KEYGEN_CMD="$INSTALL_PREFIX/bin/ssh-keygen"

    if [[ ! -x "$KEYGEN_CMD" ]]; then
        error_exit "ssh-keygen not found at $KEYGEN_CMD"
    }

    local key_file="$SSHD_CONFIG_DIR/ssh_host_falcon512_key"
    if [[ -f "$key_file" ]]; then
        info "Backing up existing host key..."
        mv "$key_file" "$key_file.bak.$(date +%s)"
        mv "$key_file.pub" "$key_file.pub.bak.$(date +%s)" 2>/dev/null || true
    }

    if ! "$KEYGEN_CMD" -t falcon512 -f "$key_file" -N ""; then
        error_exit "Host key generation failed"
    }

    # Secure permissions
    chmod 600 "$key_file"
    chmod 644 "$key_file.pub"

    info "Host keys generated successfully"
}

install_systemd_service() {
    info "Installing systemd service..."

    # Check if systemd is available
    if ! command -v systemctl >/dev/null 2>&1; then
        error_exit "systemd not found"
    }

    cat > "$SYSTEMD_SERVICE_PATH" <<EOF
[Unit]
Description=OQS-SSH Daemon
After=network.target auditd.service
ConditionPathExists=!/etc/ssh/sshd_not_to_be_run

[Service]
EnvironmentFile=-/etc/default/ssh
ExecStart=$CUSTOM_SSHD_BIN -f $SSHD_CONFIG_DIR/sshd_config -D
ExecReload=/bin/kill -HUP \$MAINPID
KillMode=process
Restart=on-failure
RestartPreventExitStatus=255
Type=notify
RuntimeDirectory=sshd
RuntimeDirectoryMode=0755
LimitNOFILE=1048576
LimitNPROC=1024
LimitCORE=infinity

[Install]
WantedBy=multi-user.target
EOF

    # Reload systemd and enable service
    systemctl daemon-reload || error_exit "Failed to reload systemd"
    systemctl enable oqs-sshd || warn "Failed to enable oqs-sshd service"

    info "Systemd service installed successfully"
}

# ---------------------------
# MAIN
# ---------------------------
main() {
    # Initialize log file
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE"
    chmod 600 "$LOG_FILE"

    info "Starting OQS-SSH installation..."

    validate_system_requirements
    backup_existing_configuration
    install_dependencies
    build_liboqs
    build_oqs_ssh
    configure_dynamic_linker
    create_sshd_user
    configure_ssh
    generate_host_keys
    install_systemd_service

    info "Installation completed successfully"
    info "OQS-SSH is configured and ready to use on port $SSH_PORT"
    info "Use 'systemctl start oqs-sshd' to start the service"
    info "Configuration backups are stored in $BACKUP_DIR"
}

main "$@"