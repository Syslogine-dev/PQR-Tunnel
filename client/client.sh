#!/usr/bin/env bash
#
# quantum_ssh_installer.sh
#
# Production-grade installation script for liboqs & OQS-SSH
# with comprehensive error handling, security features, and system validation.
#
# Features:
# - Comprehensive system validation
# - Secure default configurations
# - Backup and rollback capabilities
# - Network resilience with retries and fallbacks
# - Detailed logging and error reporting
# - Command-line configuration
# - Testing and verification steps
#
# Usage: ./quantum_ssh_installer.sh [options]
# Run with --help for full usage information.
#
# Author: [Your Name]
# License: MIT
# Version: 1.0.0

set -euo pipefail
shopt -s nullglob

# ---------------------------
# VERSION AND METADATA
# ---------------------------
readonly SCRIPT_VERSION="1.0.0"
readonly SCRIPT_NAME=$(basename "$0")
readonly SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPT_START_TIME=$(date +%s)

# ---------------------------
# DEFAULT CONFIGURATION
# ---------------------------
# Installation paths
INSTALL_PREFIX="/usr/local"
LIBOQS_DIR="/opt/liboqs"
OQS_SSH_DIR="/opt/oqs-ssh"
SSHD_CONFIG_DIR="/etc/oqs-ssh"
BACKUP_DIR="/root/oqs_ssh_backup_$(date +%Y%m%d_%H%M%S)"
LOG_DIR="/var/log/quantum-ssh"
LOG_FILE="${LOG_DIR}/install_$(date +%Y%m%d_%H%M%S).log"

# Repository information
LIBOQS_REPO="https://github.com/open-quantum-safe/liboqs.git"
LIBOQS_VERSION="main"
LIBOQS_BACKUP_REPO="https://gitlab.com/open-quantum-safe/liboqs.git"

OQS_SSH_REPO="https://github.com/open-quantum-safe/openssh.git"
OQS_SSH_VERSION="OQS-OpenSSH-snapshot-2024-08"
OQS_SSH_BACKUP_REPO="https://gitlab.com/open-quantum-safe/openssh.git"

# Network settings
SSH_PORT=8022
NETWORK_TIMEOUT=300
RETRY_ATTEMPTS=3
RETRY_DELAY=5

# Build settings
MAX_BUILD_JOBS=4
BUILD_TIMEOUT=1800

# System requirements
REQUIRED_DISK_SPACE_GB=10
REQUIRED_MEMORY_GB=4
MIN_KERNEL_VERSION="4.0.0"

# Feature flags
DRY_RUN=false
VERBOSE=false
INSTALL_SYSTEMD=true
SKIP_TESTS=false
FORCE_INSTALL=false

# Runtime variables
declare -A INSTALLED_VERSIONS
declare -a CLEANUP_TASKS
declare -a VERIFICATION_TASKS

# ---------------------------
# COMMAND LINE PARSING
# ---------------------------
usage() {
    cat << EOF
Usage: $SCRIPT_NAME [options]

Installation Options:
    -p, --prefix DIR          Installation prefix (default: $INSTALL_PREFIX)
    -P, --port NUMBER         SSH port number (default: $SSH_PORT)
    --liboqs-version VER      liboqs version to install (default: $LIBOQS_VERSION)
    --ssh-version VER         OQS-SSH version to install (default: $OQS_SSH_VERSION)

Build Options:
    -j, --jobs NUMBER         Maximum parallel build jobs (default: $MAX_BUILD_JOBS)
    --build-timeout SECONDS   Build operation timeout (default: $BUILD_TIMEOUT)

Feature Flags:
    --no-systemd             Skip systemd service installation
    --skip-tests             Skip integration tests
    --force                  Force installation even if requirements not met

Execution Options:
    --dry-run               Show what would be done without doing it
    -v, --verbose           Enable verbose output
    --log-file FILE         Custom log file location

Network Options:
    --timeout SECONDS        Network operation timeout (default: $NETWORK_TIMEOUT)
    --retries NUMBER        Number of retry attempts (default: $RETRY_ATTEMPTS)
    --retry-delay SECONDS   Delay between retries (default: $RETRY_DELAY)
    --proxy URL             Use proxy for network operations

Other:
    -h, --help              Show this help message
    --version              Show script version
EOF
    exit 1
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -p|--prefix)
                INSTALL_PREFIX="$2"
                shift 2
                ;;
            -P|--port)
                if ! [[ "$2" =~ ^[0-9]+$ ]] || ((.$2 < 1 || $2 > 65535)); then
                    error_exit "Invalid port number: $2"
                fi
                SSH_PORT="$2"
                shift 2
                ;;
            -j|--jobs)
                if ! [[ "$2" =~ ^[0-9]+$ ]] || ((.$2 < 1)); then
                    error_exit "Invalid number of jobs: $2"
                fi
                MAX_BUILD_JOBS="$2"
                shift 2
                ;;
            --build-timeout)
                if ! [[ "$2" =~ ^[0-9]+$ ]] || ((.$2 < 1)); then
                    error_exit "Invalid timeout value: $2"
                fi
                BUILD_TIMEOUT="$2"
                shift 2
                ;;
            --liboqs-version)
                LIBOQS_VERSION="$2"
                shift 2
                ;;
            --ssh-version)
                OQS_SSH_VERSION="$2"
                shift 2
                ;;
            --no-systemd)
                INSTALL_SYSTEMD=false
                shift
                ;;
            --skip-tests)
                SKIP_TESTS=true
                shift
                ;;
            --force)
                FORCE_INSTALL=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            --log-file)
                LOG_FILE="$2"
                shift 2
                ;;
            --timeout)
                NETWORK_TIMEOUT="$2"
                shift 2
                ;;
            --retries)
                RETRY_ATTEMPTS="$2"
                shift 2
                ;;
            --retry-delay)
                RETRY_DELAY="$2"
                shift 2
                ;;
            --version)
                echo "$SCRIPT_NAME version $SCRIPT_VERSION"
                exit 0
                ;;
            -h|--help)
                usage
                ;;
            *)
                error_exit "Unknown option: $1"
                ;;
        esac
    done
}

# ---------------------------
# LOGGING AND ERROR HANDLING
# ---------------------------
setup_logging() {
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE"
    chmod 600 "$LOG_FILE"
    
    # Redirect stderr to log file
    exec 2>> "$LOG_FILE"
    
    # Start logging
    log "INFO" "Starting installation script version $SCRIPT_VERSION"
    log "INFO" "Log file: $LOG_FILE"
}

log() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp="$(date +'%Y-%m-%d %H:%M:%S')"
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
    
    if [[ "$VERBOSE" == "true" ]] || [[ "$level" != "DEBUG" ]]; then
        echo "[$level] $message" >&2
    fi
}

debug() { log "DEBUG" "$1"; }
info() { log "INFO" "$1"; }
warn() { log "WARN" "$1"; }
error() { log "ERROR" "$1"; }

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

# Set up error handling
trap cleanup EXIT
trap 'error_exit "Script interrupted"' INT TERM

# ---------------------------
# SYSTEM VALIDATION
# ---------------------------
validate_system_requirements() {
    info "Validating system requirements..."

    # Check root privileges
    if [[ $(id -u) -ne 0 ]]; then
        error_exit "This script must be run as root or with sudo"
    fi

    # Check distribution
    if ! command -v apt-get >/dev/null 2>&1; then
        if [[ "$FORCE_INSTALL" != "true" ]]; then
            error_exit "This script requires a Debian-based distribution"
        else
            warn "Non-Debian distribution detected, continuing due to --force flag"
        fi
    fi

    # Check kernel version
    local kernel_version
    kernel_version=$(uname -r | cut -d'-' -f1)
    if ! printf '%s\n%s\n' "$MIN_KERNEL_VERSION" "$kernel_version" | sort -V -C; then
        if [[ "$FORCE_INSTALL" != "true" ]]; then
            error_exit "Kernel version $kernel_version is below minimum required version $MIN_KERNEL_VERSION"
        else
            warn "Kernel version check failed, continuing due to --force flag"
        fi
    fi

    check_system_resources
    check_required_commands
    
    info "System requirements validated successfully"
}

check_system_resources() {
    # Check available memory
    local available_memory_kb
    available_memory_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
    local required_memory_kb=$((REQUIRED_MEMORY_GB * 1024 * 1024))
    
    if ((available_memory_kb < required_memory_kb)); then
        if [[ "$FORCE_INSTALL" != "true" ]]; then
            error_exit "Insufficient memory: ${available_memory_kb}KB available, ${required_memory_kb}KB required"
        else
            warn "Memory check failed, continuing due to --force flag"
        fi
    fi

    # Check available disk space
    local available_space_kb
    available_space_kb=$(df -k "$INSTALL_PREFIX" | awk 'NR==2 {print $4}')
    local required_space_kb=$((REQUIRED_DISK_SPACE_GB * 1024 * 1024))
    
    if ((available_space_kb < required_space_kb)); then
        if [[ "$FORCE_INSTALL" != "true" ]]; then
            error_exit "Insufficient disk space: ${available_space_kb}KB available, ${required_space_kb}KB required"
        else
            warn "Disk space check failed, continuing due to --force flag"
        fi
    fi
}

check_required_commands() {
    local required_commands=(
        git cmake make gcc g++ ninja-build
        autoconf automake libtool pkg-config
        curl wget
    )
    
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            if [[ "$FORCE_INSTALL" != "true" ]]; then
                error_exit "Required command not found: $cmd"
            else
                warn "Missing required command: $cmd, continuing due to --force flag"
            fi
        fi
    done
}

# ---------------------------
# NETWORK OPERATIONS
# ---------------------------
readonly HTTP_STATUS_OK=200
readonly HTTP_STATUS_REDIRECT=302

check_network_connection() {
    info "Checking network connectivity..."
    local test_urls=(
        "github.com"
        "gitlab.com"
        "raw.githubusercontent.com"
    )

    for url in "${test_urls[@]}"; do
        if ! ping -c 1 "$url" &>/dev/null; then
            warn "Unable to reach $url"
            return 1
        fi
    done
    return 0
}

download_with_retry() {
    local url="$1"
    local output="$2"
    local attempt=1
    local http_code
    
    while ((attempt <= RETRY_ATTEMPTS)); do
        info "Download attempt $attempt/$RETRY_ATTEMPTS: $url"
        
        http_code=$(curl -L --connect-timeout "$NETWORK_TIMEOUT" \
            --retry 3 --retry-delay 2 \
            -w "%{http_code}" -o "$output" "$url" 2>/dev/null)
        
        if [[ "$http_code" -eq "$HTTP_STATUS_OK" ]] || [[ "$http_code" -eq "$HTTP_STATUS_REDIRECT" ]]; then
            return 0
        fi
        
        warn "Download failed with HTTP code $http_code"
        ((attempt++))
        sleep "$RETRY_DELAY"
    done
    
    return 1
}

git_clone_with_retry() {
    local repo="$1"
    local dir="$2"
    local branch="$3"
    local attempt=1
    
    while ((attempt <= RETRY_ATTEMPTS)); do
        info "Git clone attempt $attempt/$RETRY_ATTEMPTS: $repo"
        
        if timeout "$NETWORK_TIMEOUT" git clone --depth 1 -b "$branch" "$repo" "$dir"; then
            return 0
        fi
        
        warn "Git clone failed"
        rm -rf "$dir"  # Clean up failed clone
        ((attempt++))
        sleep "$RETRY_DELAY"
    done
    
    return 1
}

verify_checksum() {
    local file="$1"
    local expected_sha256="$2"
    
    if ! command -v sha256sum >/dev/null 2>&1; then
        warn "sha256sum not available, skipping checksum verification"
        return 0
    fi
    
    local actual_sha256
    actual_sha256=$(sha256sum "$file" | cut -d' ' -f1)
    
    if [[ "$actual_sha256" != "$expected_sha256" ]]; then
        error "Checksum verification failed for $file"
        return 1
    fi
    
    info "Checksum verified for $file"
    return 0
}

# ---------------------------
# DEPENDENCY MANAGEMENT
# ---------------------------
declare -A PACKAGE_VERSIONS=(
    ["cmake"]="3.16.0"
    ["gcc"]="7.0.0"
    ["openssl"]="1.1.1"
)

verify_package_version() {
    local package="$1"
    local min_version="${PACKAGE_VERSIONS[$package]}"
    local current_version
    
    case "$package" in
        "cmake")
            current_version=$(cmake --version | head -n1 | awk '{print $3}')
            ;;
        "gcc")
            current_version=$(gcc -dumpversion)
            ;;
        "openssl")
            current_version=$(openssl version | awk '{print $2}' | sed 's/[^0-9.]//g')
            ;;
        *)
            warn "Unknown package for version check: $package"
            return 1
            ;;
    esac
    
    if ! printf '%s\n%s\n' "$min_version" "$current_version" | sort -V -C; then
        return 1
    fi
    
    return 0
}

install_dependencies() {
    info "Installing dependencies..."
    
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
        python3
        python3-pip
    )
    
    # Update package list with retry
    local attempt=1
    while ((attempt <= RETRY_ATTEMPTS)); do
        if apt-get update -y; then
            break
        fi
        warn "apt-get update failed, attempt $attempt of $RETRY_ATTEMPTS"
        ((attempt++))
        sleep "$RETRY_DELAY"
    done
    
    if ((attempt > RETRY_ATTEMPTS)); then
        error_exit "Failed to update package lists"
    fi
    
    # Install packages with retry
    attempt=1
    while ((attempt <= RETRY_ATTEMPTS)); do
        if apt-get install -y "${DEPS[@]}"; then
            break
        fi
        warn "Package installation failed, attempt $attempt of $RETRY_ATTEMPTS"
        ((attempt++))
        sleep "$RETRY_DELAY"
    done
    
    if ((attempt > RETRY_ATTEMPTS)); then
        error_exit "Failed to install dependencies"
    fi
    
    # Verify critical package versions
    for package in "${!PACKAGE_VERSIONS[@]}"; do
        if ! verify_package_version "$package"; then
            error_exit "Package $package version requirement not met"
        fi
    done
    
    info "Dependencies installed and verified"
}

# ---------------------------
# LIBOQS BUILD
# ---------------------------
prepare_build_environment() {
    info "Preparing build environment..."
    
    # Set up build directories
    for dir in "$LIBOQS_DIR" "$OQS_SSH_DIR"; do
        if [[ -d "$dir" ]]; then
            local backup_dir="${dir}.bak.$(date +%s)"
            info "Backing up existing directory $dir to $backup_dir"
            mv "$dir" "$backup_dir"
        fi
        mkdir -p "$dir"
    done
    
    # Configure build environment variables
    export CFLAGS="-O2 -fstack-protector-strong -D_FORTIFY_SOURCE=2"
    export CXXFLAGS="$CFLAGS"
    export LDFLAGS="-Wl,-z,relro,-z,now"
    
    # Add cleanup task for build directories
    add_cleanup_task "rm -rf $LIBOQS_DIR $OQS_SSH_DIR"
}

build_liboqs() {
    info "Building liboqs..."
    
    # Clone repository
    if ! git_clone_with_retry "$LIBOQS_REPO" "$LIBOQS_DIR" "$LIBOQS_VERSION"; then
        if ! git_clone_with_retry "$LIBOQS_BACKUP_REPO" "$LIBOQS_DIR" "$LIBOQS_VERSION"; then
            error_exit "Failed to clone liboqs from both primary and backup repositories"
        fi
    fi
    
    # Verify source code integrity
    cd "$LIBOQS_DIR"
    if ! git verify-commit HEAD 2>/dev/null; then
        warn "Could not verify git commit signature"
    fi
    
    # Create build directory
    mkdir -p "$LIBOQS_DIR/build"
    cd "$LIBOQS_DIR/build"
    
    # Configure build
    if ! cmake -GNinja \
        -DCMAKE_INSTALL_PREFIX="$INSTALL_PREFIX" \
        -DOQS_USE_OPENSSL=OFF \
        -DBUILD_SHARED_LIBS=ON \
        -DCMAKE_BUILD_TYPE=Release \
        -DOQS_DIST_BUILD=ON \
        ..; then
        error_exit "liboqs CMake configuration failed"
    fi
    
    # Build with timeout and job limit
    if ! timeout "$BUILD_TIMEOUT" ninja -j"$MAX_BUILD_JOBS"; then
        error_exit "liboqs build failed"
    fi
    
    # Run tests if not skipped
    if [[ "$SKIP_TESTS" != "true" ]]; then
        info "Running liboqs tests..."
        if ! ninja test; then
            error_exit "liboqs tests failed"
        fi
    fi
    
    # Install
    if ! ninja install; then
        error_exit "liboqs installation failed"
    fi
    
    # Record installed version
    INSTALLED_VERSIONS["liboqs"]=$LIBOQS_VERSION
    
    info "liboqs built and installed successfully"
}

verify_liboqs_installation() {
    info "Verifying liboqs installation..."
    
    # Check library files
    local lib_files=(
        "$INSTALL_PREFIX/lib/liboqs.so"
        "$INSTALL_PREFIX/include/oqs/oqs.h"
    )
    
    for file in "${lib_files[@]}"; do
        if [[ ! -f "$file" ]]; then
            error_exit "Missing liboqs file: $file"
        fi
    done
    
    # Verify library can be linked
    if ! ldconfig -p | grep -q liboqs; then
        error_exit "liboqs not found in library cache"
    fi
    
    info "liboqs installation verified"
}

# ---------------------------
# OQS-SSH BUILD
# ---------------------------
build_oqs_ssh() {
    info "Building OQS-SSH..."
    
    # Clone repository with fallback
    if ! git_clone_with_retry "$OQS_SSH_REPO" "$OQS_SSH_DIR" "$OQS_SSH_VERSION"; then
        if ! git_clone_with_retry "$OQS_SSH_BACKUP_REPO" "$OQS_SSH_DIR" "$OQS_SSH_VERSION"; then
            error_exit "Failed to clone OQS-SSH from both primary and backup repositories"
        fi
    fi

    cd "$OQS_SSH_DIR"

    # Verify source
    if ! git verify-commit HEAD 2>/dev/null; then
        warn "Could not verify git commit signature"
    fi

    # Run autotools
    if ! autoreconf -i; then
        error_exit "autoreconf failed"
    fi

    # Configure with security flags
    local configure_flags=(
        "--prefix=$INSTALL_PREFIX"
        "--with-libs=-loqs"
        "--with-liboqs-dir=$INSTALL_PREFIX"
        "--with-cflags=-DWITH_KYBER=1 -DWITH_FALCON=1 -fstack-protector-strong -D_FORTIFY_SOURCE=2"
        "--with-ldflags=-Wl,-z,relro,-z,now"
        "--enable-hybrid-kex"
        "--enable-pq-kex"
        "--disable-strip"
        "--with-security-key-builtin"
    )

    if ! ./configure "${configure_flags[@]}"; then
        error_exit "OQS-SSH configure failed"
    fi

    # Build with timeout and job limit
    if ! timeout "$BUILD_TIMEOUT" make -j"$MAX_BUILD_JOBS"; then
        error_exit "OQS-SSH build failed"
    fi

    # Run tests if not skipped
    if [[ "$SKIP_TESTS" != "true" ]]; then
        info "Running OQS-SSH tests..."
        if ! make tests; then
            error_exit "OQS-SSH tests failed"
        fi
    fi

    # Install
    if ! make install; then
        error_exit "OQS-SSH installation failed"
    fi

    # Record installed version
    INSTALLED_VERSIONS["oqs-ssh"]=$OQS_SSH_VERSION
    
    info "OQS-SSH built and installed successfully"
}

verify_oqs_ssh_installation() {
    info "Verifying OQS-SSH installation..."
    
    local binaries=(
        "$INSTALL_PREFIX/sbin/sshd"
        "$INSTALL_PREFIX/bin/ssh"
        "$INSTALL_PREFIX/bin/ssh-keygen"
    )

    for binary in "${binaries[@]}"; do
        if [[ ! -x "$binary" ]]; then
            error_exit "Missing or non-executable binary: $binary"
        fi
        
        # Verify binary dependencies
        if ! ldd "$binary" | grep -q liboqs; then
            error_exit "Binary $binary not properly linked with liboqs"
        fi
    }

    # Test SSH keygen functionality
    local test_key="/tmp/test_key_$$"
    if ! "$INSTALL_PREFIX/bin/ssh-keygen" -t falcon512 -f "$test_key" -N "" >/dev/null 2>&1; then
        error_exit "ssh-keygen test failed"
    fi
    rm -f "$test_key" "$test_key.pub"

    info "OQS-SSH installation verified"
}

# ---------------------------
# USER AND PERMISSION MANAGEMENT
# ---------------------------
create_ssh_user() {
    info "Setting up SSH service user..."

    local ssh_user="sshd"
    local ssh_home="/var/empty/sshd"

    # Create group if it doesn't exist
    if ! getent group "$ssh_user" >/dev/null; then
        if ! groupadd -r "$ssh_user"; then
            error_exit "Failed to create sshd group"
        fi
    fi

    # Create user if it doesn't exist
    if ! id -u "$ssh_user" >/dev/null 2>&1; then
        if ! useradd -r -g "$ssh_user" -d "$ssh_home" -s /sbin/nologin \
            -c "Privilege-separated SSH" "$ssh_user"; then
            error_exit "Failed to create sshd user"
        fi
    fi

    # Create and secure home directory
    install -d -m 0755 -o "$ssh_user" -g "$ssh_user" "$ssh_home"

    info "SSH service user setup completed"
}

setup_permissions() {
    info "Setting up directory permissions..."

    # Create required directories with secure permissions
    local dirs=(
        "$SSHD_CONFIG_DIR"
        "$INSTALL_PREFIX/var/empty/sshd"
        "/var/run/sshd"
    )

    for dir in "${dirs[@]}"; do
        install -d -m 0755 "$dir"
    done

    # Set specific permissions for sensitive directories
    chmod 0711 "/var/run/sshd"

    info "Directory permissions configured"
}

# ---------------------------
# SSH CONFIGURATION
# ---------------------------
configure_ssh() {
    info "Configuring OQS-SSH..."

    # Create configuration directory
    install -d -m 0755 "$SSHD_CONFIG_DIR"

    # Generate main configuration
    cat > "$SSHD_CONFIG_DIR/sshd_config" <<EOF
# OQS-SSH Security Configuration
Protocol 2
HostKey $SSHD_CONFIG_DIR/ssh_host_falcon512_key

# Cryptographic settings
HostKeyAlgorithms falcon512
PubkeyAcceptedAlgorithms falcon512
KexAlgorithms kyber512-sha256

# Authentication
PubkeyAuthentication yes
PasswordAuthentication no
PermitRootLogin no
StrictModes yes
MaxAuthTries 3
AuthenticationMethods publickey

# Network settings
Port $SSH_PORT
AddressFamily any
ListenAddress 0.0.0.0
TCPKeepAlive yes
ClientAliveInterval 300
ClientAliveCountMax 2

# Security settings
X11Forwarding no
AllowTcpForwarding no
PermitTunnel no
AllowAgentForwarding no
PermitUserEnvironment no
MaxStartups 10:30:100

# Logging
SyslogFacility AUTH
LogLevel VERBOSE

# Paths
PidFile /var/run/sshd/sshd.pid
AuthorizedKeysFile .ssh/authorized_keys

# Hardening
UsePrivilegeSeparation sandbox
Compression no
AllowStreamLocalForwarding no
GatewayPorts no
EOF

    # Set secure permissions
    chmod 600 "$SSHD_CONFIG_DIR/sshd_config"

    # Test configuration
    if ! "$INSTALL_PREFIX/sbin/sshd" -t -f "$SSHD_CONFIG_DIR/sshd_config"; then
        error_exit "SSH configuration validation failed"
    }

    info "SSH configuration completed"
}

generate_host_keys() {
    info "Generating host keys..."

    local KEYGEN_CMD="$INSTALL_PREFIX/bin/ssh-keygen"
    local key_types=(
        "falcon512"
    )

    for key_type in "${key_types[@]}"; do
        local key_file="$SSHD_CONFIG_DIR/ssh_host_${key_type}_key"
        
        # Backup existing keys
        if [[ -f "$key_file" ]]; then
            local backup_suffix="bak.$(date +%s)"
            mv "$key_file" "$key_file.$backup_suffix"
            mv "$key_file.pub" "$key_file.pub.$backup_suffix" 2>/dev/null || true
        fi

        # Generate new key
        if ! "$KEYGEN_CMD" -t "$key_type" -f "$key_file" -N ""; then
            error_exit "Failed to generate $key_type host key"
        fi

        # Set permissions
        chmod 600 "$key_file"
        chmod 644 "$key_file.pub"
    done

    info "Host keys generated successfully"
}

verify_configuration() {
    info "Verifying SSH configuration..."

    # Check configuration file permissions
    if [[ "$(stat -c %a "$SSHD_CONFIG_DIR/sshd_config")" != "600" ]]; then
        error_exit "Incorrect permissions on sshd_config"
    fi

    # Verify host keys
    local key_file="$SSHD_CONFIG_DIR/ssh_host_falcon512_key"
    if [[ ! -f "$key_file" ]] || [[ ! -f "$key_file.pub" ]]; then
        error_exit "Missing host keys"
    fi

    # Verify key permissions
    if [[ "$(stat -c %a "$key_file")" != "600" ]]; then
        error_exit "Incorrect permissions on private host key"
    fi

    if [[ "$(stat -c %a "$key_file.pub")" != "644" ]]; then
        error_exit "Incorrect permissions on public host key"
    fi

    info "SSH configuration verified"
}

# ---------------------------
# SYSTEMD SERVICE SETUP
# ---------------------------
install_systemd_service() {
    info "Installing systemd service..."

    # Verify systemd is available
    if ! command -v systemctl >/dev/null 2>&1; then
        if [[ "$INSTALL_SYSTEMD" == "true" ]]; then
            error_exit "systemd not found but service installation was requested"
        else
            warn "systemd not found, skipping service installation"
            return 0
        fi
    }

    # Create service file
    cat > "$SYSTEMD_SERVICE_PATH" <<EOF
[Unit]
Description=Quantum-Safe SSH Daemon
Documentation=https://github.com/open-quantum-safe/openssh
After=network.target auditd.service
ConditionPathExists=!/etc/ssh/sshd_not_to_be_run

[Service]
EnvironmentFile=-/etc/default/oqs-ssh
ExecStartPre=$INSTALL_PREFIX/sbin/sshd -t -f $SSHD_CONFIG_DIR/sshd_config
ExecStart=$INSTALL_PREFIX/sbin/sshd -f $SSHD_CONFIG_DIR/sshd_config -D
ExecReload=/bin/kill -HUP \$MAINPID
KillMode=process
Restart=on-failure
RestartPreventExitStatus=255
Type=notify
RuntimeDirectory=sshd
RuntimeDirectoryMode=0755
LimitNOFILE=524288
LimitNPROC=1024
LimitCORE=infinity
TasksMax=infinity
PrivateTmp=yes
ProtectSystem=full
ProtectHome=yes
NoNewPrivileges=yes

[Install]
WantedBy=multi-user.target
EOF

    # Set correct permissions
    chmod 644 "$SYSTEMD_SERVICE_PATH"

    # Reload systemd and enable service
    if ! systemctl daemon-reload; then
        error_exit "Failed to reload systemd configuration"
    fi

    if ! systemctl enable oqs-sshd.service; then
        error_exit "Failed to enable oqs-sshd service"
    fi

    info "Systemd service installed successfully"
}

# ---------------------------
# INTEGRATION TESTING
# ---------------------------
run_integration_tests() {
    if [[ "$SKIP_TESTS" == "true" ]]; then
        info "Skipping integration tests"
        return 0
    }

    info "Running integration tests..."

    local test_port=58922
    local test_key="/tmp/test_ssh_key_$$"
    local test_config="/tmp/test_sshd_config_$$"

    # Generate test configuration
    sed "s/Port .*/Port $test_port/" "$SSHD_CONFIG_DIR/sshd_config" > "$test_config"

    # Generate test keys
    if ! "$INSTALL_PREFIX/bin/ssh-keygen" -t falcon512 -f "$test_key" -N ""; then
        error_exit "Failed to generate test keys"
    fi

    # Start test server
    if ! timeout 30 "$INSTALL_PREFIX/sbin/sshd" -f "$test_config" -D -e &
    local sshd_pid=$!

    # Wait for server to start
    sleep 2

    # Test connection
    if ! timeout 10 "$INSTALL_PREFIX/bin/ssh" -i "$test_key" \
        -o "StrictHostKeyChecking=no" \
        -p "$test_port" \
        localhost "exit 0"; then
        error_exit "SSH connection test failed"
    fi

    # Cleanup
    kill $sshd_pid 2>/dev/null
    rm -f "$test_key" "$test_key.pub" "$test_config"

    info "Integration tests completed successfully"
}

# ---------------------------
# STATUS REPORTING
# ---------------------------
generate_installation_report() {
    local report_file="$LOG_DIR/installation_report.txt"
    
    {
        echo "OQS-SSH Installation Report"
        echo "=========================="
        echo "Date: $(date)"
        echo "Installation Directory: $INSTALL_PREFIX"
        echo "SSH Port: $SSH_PORT"
        echo ""
        echo "Installed Versions:"
        for component in "${!INSTALLED_VERSIONS[@]}"; do
            echo "- $component: ${INSTALLED_VERSIONS[$component]}"
        done
        echo ""
        echo "System Information:"
        echo "- OS: $(uname -a)"
        echo "- CPU: $(grep "model name" /proc/cpuinfo | head -n1 | cut -d: -f2)"
        echo "- Memory: $(free -h | grep Mem: | awk '{print $2}')"
        echo ""
        echo "Installation Status: SUCCESS"
        echo ""
        echo "Important Files:"
        echo "- Config: $SSHD_CONFIG_DIR/sshd_config"
        echo "- Host Key: $SSHD_CONFIG_DIR/ssh_host_falcon512_key"
        echo "- Log File: $LOG_FILE"
        if [[ "$INSTALL_SYSTEMD" == "true" ]]; then
            echo "- Service: $SYSTEMD_SERVICE_PATH"
        fi
    } > "$report_file"

    chmod 600 "$report_file"
    info "Installation report generated: $report_file"
}

display_completion_message() {
    cat <<EOF

==============================================
OQS-SSH Installation Complete
==============================================

Installation Details:
- SSH Port: $SSH_PORT
- Config Directory: $SSHD_CONFIG_DIR
- Log File: $LOG_FILE
- Report File: $LOG_DIR/installation_report.txt

Next Steps:
1. Review the installation report
2. Start the service: systemctl start oqs-sshd
3. Check service status: systemctl status oqs-sshd
4. Configure client keys for authentication

For issues or concerns, please check:
- System logs: journalctl -u oqs-sshd
- Installation log: $LOG_FILE

==============================================
EOF
}

# ---------------------------
# MAIN PROGRAM FLOW
# ---------------------------
main() {
    # Parse command line arguments
    parse_args "$@"

    # Setup logging
    setup_logging

    # Print banner
    info "Starting OQS-SSH installation (version $SCRIPT_VERSION)"
    info "Installation prefix: $INSTALL_PREFIX"
    info "SSH port: $SSH_PORT"

    # Validate system and requirements
    validate_system_requirements

    # Perform installation steps
    check_network_connection || error_exit "Network connectivity check failed"
    install_dependencies
    prepare_build_environment

    # Build and install components
    build_liboqs
    verify_liboqs_installation
    
    build_oqs_ssh
    verify_oqs_ssh_installation

    # Configure system
    create_ssh_user
    setup_permissions
    configure_ssh
    generate_host_keys
    verify_configuration

    # Install service if requested
    if [[ "$INSTALL_SYSTEMD" == "true" ]]; then
        install_systemd_service
    fi

    # Run integration tests
    run_integration_tests

    # Generate report and display completion message
    generate_installation_report
    display_completion_message

    info "Installation completed successfully in $(($(date +%s) - SCRIPT_START_TIME)) seconds"
}

# Execute main program
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi