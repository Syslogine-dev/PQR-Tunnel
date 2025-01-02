#!/usr/bin/env bash
#
# client.sh
#
# Compiles and installs liboqs and OQS-SSH, then configures SSH to use
# post-quantum algorithms. Must be run as root or with sudo.

# -----------------------------------------------------------------------------
# 1. Enable safer bash options:
#    -e   : Exit immediately if a command exits with a non-zero status
#    -u   : Treat unset variables as an error
#    -o pipefail : The return value of a pipeline is the status of the
#                  last command to exit with a non-zero status
# -----------------------------------------------------------------------------
set -euo pipefail

# -----------------------------------------------------------------------------
# 2. Check for --help or -h to display usage
# -----------------------------------------------------------------------------
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  cat << EOF
Usage: sudo ./client.sh [options]

This script compiles and installs liboqs and OQS-SSH, then configures SSH
to use post-quantum algorithms. Make sure to run it with sudo.

Options:
  -h, --help    Show this help message and exit
EOF
  exit 0
fi

# -----------------------------------------------------------------------------
# 3. Source the .env file and validate required variables
# -----------------------------------------------------------------------------
source "$(dirname "$0")/config/.env"

: "${LIBOQS_DIR:?Environment variable LIBOQS_DIR is not set or is empty}"
: "${OQS_SSH_DIR:?Environment variable OQS_SSH_DIR is not set or is empty}"
: "${INSTALL_PREFIX:?Environment variable INSTALL_PREFIX is not set or is empty}"
: "${LIBOQS_REPO:?Environment variable LIBOQS_REPO is not set or is empty}"
: "${OQS_SSH_REPO:?Environment variable OQS_SSH_REPO is not set or is empty}"
: "${LIBOQS_VERSION:?Environment variable LIBOQS_VERSION is not set or is empty}"
: "${OQS_SSH_VERSION:?Environment variable OQS_SSH_VERSION is not set or is empty}"

# Ensure the script is run with sudo/root privileges
if [[ $EUID -ne 0 ]]; then
    echo "Error: This script must be run with sudo or as root."
    exit 1
fi

# -----------------------------------------------------------------------------
# 4. Define Functions for Each Logical Step
# -----------------------------------------------------------------------------

install_dependencies() {
    echo "[1/5] Installing dependencies..."
    bash "$(dirname "$0")/config/install_dependencies.sh"
}

build_liboqs() {
    echo "[2/5] Building liboqs..."
    # Remove any existing liboqs source directory
    rm -rf "$LIBOQS_DIR"

    # Clone the specified liboqs version
    if ! git clone -b "$LIBOQS_VERSION" "$LIBOQS_REPO" "$LIBOQS_DIR"; then
        echo "Failed to clone liboqs from $LIBOQS_REPO."
        echo "Check your network connection or verify the URL/branch."
        exit 1
    fi

    cd "$LIBOQS_DIR"
    mkdir build && cd build

    # Configure build with CMake
    cmake -GNinja \
          -DCMAKE_INSTALL_PREFIX="$INSTALL_PREFIX" \
          -DOQS_USE_OPENSSL=OFF \
          -DBUILD_SHARED_LIBS=ON \
          ..

    # Build and install liboqs
    ninja
    ninja install
}

build_oqs_ssh() {
    echo "[3/5] Building OQS-SSH..."
    # Remove any existing OQS-SSH source directory
    rm -rf "$OQS_SSH_DIR"

    # Clone the specified OQS-SSH branch
    if ! git clone -b "$OQS_SSH_VERSION" "$OQS_SSH_REPO" "$OQS_SSH_DIR"; then
        echo "Failed to clone OQS-SSH from $OQS_SSH_REPO."
        echo "Check your network connection or verify the URL/branch."
        exit 1
    fi

    cd "$OQS_SSH_DIR"
    autoreconf -i

    # Configure OQS-SSH with necessary flags
    ./configure \
        --prefix="$INSTALL_PREFIX" \
        --with-libs=-loqs \
        --with-liboqs-dir="$INSTALL_PREFIX" \
        --with-cflags="-DWITH_KYBER_KEM=1 -DWITH_FALCON=1" \
        --enable-hybrid-kex \
        --enable-pq-kex

    # Compile OQS-SSH
    make -j"$(nproc)"
}

###############################################################################
# Continue the file here -- Part 2
###############################################################################

configure_ssh() {
    echo "[4/5] Setting up SSH configuration..."

    # Optional: Warn if another SSH server is detected
    if command -v sshd &>/dev/null; then
        echo "Warning: Another SSH server might be installed on this system."
        echo "Proceeding with this setup does not automatically replace or disable it."
    fi

    # Create SSH configuration directory
    mkdir -p /usr/local/etc/ssh

    # Write a basic config that references the new PQ host key
    cat > /usr/local/etc/sshd_config << EOF
HostKey /usr/local/etc/ssh/ssh_host_falcon512_key
HostKeyAlgorithms ssh-falcon512
KexAlgorithms ml-kem-512-sha256
PubkeyAcceptedAlgorithms ssh-falcon512
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
PasswordAuthentication no
EOF
}

install_and_generate_keys() {
    echo "[5/5] Installing binaries and generating keys..."

    # Install the built SSH binaries into the chosen install prefix
    cp "$OQS_SSH_DIR"/{ssh,scp,ssh-keygen} "$INSTALL_PREFIX/bin/"
    chmod +x "$INSTALL_PREFIX/bin/ssh" "$INSTALL_PREFIX/bin/scp" "$INSTALL_PREFIX/bin/ssh-keygen"

    # -------------------------------------------------------------------------
    # Run ldconfig with Correct Configuration
    # -------------------------------------------------------------------------
    # 1. Ensure /usr/local/lib is in /etc/ld.so.conf.d/local.conf
    local_conf="/etc/ld.so.conf.d/local.conf"
    if ! grep -q "/usr/local/lib" "$local_conf" 2>/dev/null; then
        echo "Adding /usr/local/lib to $local_conf..."
        echo "/usr/local/lib" >> "$local_conf"
    fi

    # 2. Reload the dynamic linker cache
    ldconfig

    # 3. Generate the host's Falcon-512 SSH key
    "$INSTALL_PREFIX/bin/ssh-keygen" -t ssh-falcon512 \
        -f /usr/local/etc/ssh/ssh_host_falcon512_key \
        -N ""

    echo "
PQR-Tunnel client setup completed!

Generate your own client keys with:
  $INSTALL_PREFIX/bin/ssh-keygen -t ssh-falcon512

Connect using:
  $INSTALL_PREFIX/bin/ssh -o HostKeyAlgorithms=ssh-falcon512 -o PubkeyAcceptedAlgorithms=+ssh-falcon512 hostname

Recommended aliases for .bashrc:
  alias qssh='$INSTALL_PREFIX/bin/ssh -o HostKeyAlgorithms=ssh-falcon512 -o PubkeyAcceptedAlgorithms=+ssh-falcon512'
  alias qscp='$INSTALL_PREFIX/bin/scp'
"
}

###############################################################################
# 5. Main function to orchestrate all steps
###############################################################################
main() {
    install_dependencies
    build_liboqs
    build_oqs_ssh
    configure_ssh
    install_and_generate_keys
}

# -----------------------------------------------------------------------------
# 6. Entry point
# -----------------------------------------------------------------------------
main "$@"
