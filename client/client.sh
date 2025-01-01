#!/usr/bin/env bash

# Exit on error
set -e

# Load Configuration
CONFIG_FILE="$(dirname "$0")/config/.env"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Configuration file not found: $CONFIG_FILE"
    exit 1
fi
source "$CONFIG_FILE"

# Redirect output to log file and console
exec 1> >(tee -a "$LOG_FILE") 2>&1

# Function declarations
handle_error() {
    local exit_code=$?
    echo "Error occurred on line $1"
    exit $exit_code
}

validate_config() {
    local vars=(
        "OQS_SSH_DIR"
        "LIBOQS_DIR"
        "INSTALL_PREFIX"
        "OQS_SSH_REPO"
        "LIBOQS_REPO"
        "LIBOQS_VERSION"
        "OQS_SSH_VERSION"
        "SSH_KEY_TYPE"
        "SSH_KEY_NAME"
    )
    
    for var in "${vars[@]}"; do
        if [ -z "${!var}" ]; then
            echo "Error: $var is not set in config/.env"
            exit 1
        fi
    done
}

check_resources() {
    echo "Checking system resources..."
    local available_space=$(df -k "$INSTALL_PREFIX" | tail -1 | awk '{print $4}')
    if [ "$available_space" -lt "$MIN_DISK_SPACE" ]; then
        echo "Insufficient disk space. Need at least 5GB."
        exit 1
    fi

    local available_memory=$(free -m | awk '/^Mem:/{print $2}')
    if [ "$available_memory" -lt "$MIN_RAM" ]; then
        echo "Warning: Less than 2GB RAM available. Build may be slow."
    fi
}

backup_existing() {
    echo "Creating backup of existing SSH installation..."
    if [ -f "$INSTALL_PREFIX/bin/ssh" ]; then
        cp "$INSTALL_PREFIX/bin/ssh" "$INSTALL_PREFIX/bin/ssh.bak"
    fi
    if [ -f "$INSTALL_PREFIX/bin/scp" ]; then
        cp "$INSTALL_PREFIX/bin/scp" "$INSTALL_PREFIX/bin/scp.bak"
    fi
}

setup_ssh_keys() {
    local SSH_DIR="$HOME/.ssh"
    local KEY_PATH="$SSH_DIR/$SSH_KEY_NAME"
    
    echo "Setting up SSH keys..."
    
    # Create .ssh directory if it doesn't exist
    if [ ! -d "$SSH_DIR" ]; then
        echo "Creating SSH directory..."
        mkdir -p "$SSH_DIR"
        chmod 700 "$SSH_DIR"
    fi

    # Generate quantum-safe key if it doesn't exist
    if [ ! -f "$KEY_PATH" ]; then
        echo "Generating quantum-safe SSH key..."
        "$INSTALL_PREFIX/bin/ssh-keygen" -t "$SSH_KEY_TYPE" -f "$KEY_PATH" -N ""
        chmod 600 "$KEY_PATH"
        chmod 644 "$KEY_PATH.pub"
        echo "SSH key pair generated:"
        echo "  Private key: $KEY_PATH"
        echo "  Public key:  $KEY_PATH.pub"
    else
        echo "SSH key already exists at $KEY_PATH"
    fi
}

cleanup() {
    if [ $? -eq 0 ]; then
        echo "Cleaning up build directories..."
        rm -rf "$LIBOQS_DIR/build"
        rm -rf "$OQS_SSH_DIR/build"
    else
        echo "Build failed. Leaving directories for inspection."
    fi
}

show_progress() {
    local pid=$1
    local delay=0.75
    local spinstr='|/-\'
    while [ "$(ps a | awk '{print $1}' | grep $pid)" ]; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "    \b\b\b\b"
}

# Set up error handling
trap 'handle_error $LINENO' ERR
trap cleanup EXIT

# Parse command line options
CLEAN_BUILD=0
GENERATE_KEYS=0

while getopts "cg" opt; do
    case $opt in
        c) CLEAN_BUILD=1 ;;
        g) GENERATE_KEYS=1 ;;
        *) echo "Usage: $0 [-c] [-g]" >&2
           echo "  -c: Clean build"
           echo "  -g: Generate SSH keys"
           exit 1 ;;
    esac
done

# -- Main Installation Process --

# 0) Initial checks
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run with sudo."
    exit 1
fi

validate_config
check_resources
backup_existing

# Clean build if requested
if [ "$CLEAN_BUILD" -eq 1 ]; then
    echo "Performing clean build..."
    rm -rf "$INSTALL_PREFIX/lib/liboqs*"
    rm -rf "$INSTALL_PREFIX/include/oqs"
fi

# 1) Install dependencies
echo "[1/4] Installing dependencies..."
bash "$(dirname "$0")/config/install_dependencies.sh"

# 2) Build and install liboqs
echo "[2/4] Building and installing liboqs..."
rm -rf "$LIBOQS_DIR"
git clone -b "$LIBOQS_VERSION" "$LIBOQS_REPO" "$LIBOQS_DIR"
cd "$LIBOQS_DIR" || { echo "Error: Could not navigate to $LIBOQS_DIR."; exit 1; }
mkdir build && cd build || { echo "Error: Could not create/navigate to build directory."; exit 1; }
cmake -GNinja -DCMAKE_INSTALL_PREFIX="$INSTALL_PREFIX" ..
ninja &
show_progress $!
ninja install

# 3) Clone and compile OQS-SSH
echo "[3/4] Cloning and compiling OQS-SSH..."
rm -rf "$OQS_SSH_DIR"
git clone -b "$OQS_SSH_VERSION" "$OQS_SSH_REPO" "$OQS_SSH_DIR"
cd "$OQS_SSH_DIR" || { echo "Error: Could not navigate to $OQS_SSH_DIR."; exit 1; }

autoreconf -i
CPPFLAGS="-I$INSTALL_PREFIX/include" LDFLAGS="-L$INSTALL_PREFIX/lib" \
./configure --prefix="$INSTALL_PREFIX" --with-libs=-loqs
make -j$(nproc) &
show_progress $!

# 4) Install client binaries
echo "[4/4] Installing client binaries..."
if [[ -f "ssh" ]]; then
    cp ssh scp "$INSTALL_PREFIX/bin/"
    echo "Client binaries installed in $INSTALL_PREFIX/bin/"
else
    echo "Error: Could not find OQS-SSH binaries. Build failed."
    exit 1
fi

# Update library cache
ldconfig

# Generate SSH keys if requested
if [ "$GENERATE_KEYS" -eq 1 ]; then
    setup_ssh_keys
fi

echo "
OQS-SSH client setup successfully completed!

You can now connect to an OQS-SSH server using:
  $ $INSTALL_PREFIX/bin/ssh -p 2222 user@server -i ~/.ssh/$SSH_KEY_NAME

Tip: Add the following aliases to your ~/.bashrc for convenience:
  alias qssh='$INSTALL_PREFIX/bin/ssh'
  alias qscp='$INSTALL_PREFIX/bin/scp'

Installation log available at: $LOG_FILE
"