#!/usr/bin/env bash
#
# client.sh
#
# Compiles and installs liboqs and OQS-SSH, then configures SSH to use
# post-quantum algorithms. Must be run as root or with sudo.

# Enable safer bash options:
# -e: exit immediately if a command exits with a non-zero status
# -u: treat unset variables as an error
# -o pipefail: the return value of a pipeline is the status of
#              the last command to exit with a non-zero status
set -euo pipefail

###############################################################################
# 1. Show help/usage if requested
###############################################################################
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

###############################################################################
# 2. Source .env and validate environment variables
###############################################################################
source "$(dirname "$0")/config/.env"

: "${LIBOQS_DIR:?Environment variable LIBOQS_DIR is not set or is empty}"
: "${OQS_SSH_DIR:?Environment variable OQS_SSH_DIR is not set or is empty}"
: "${INSTALL_PREFIX:?Environment variable INSTALL_PREFIX is not set or is empty}"
: "${LIBOQS_REPO:?Environment variable LIBOQS_REPO is not set or is empty}"
: "${OQS_SSH_REPO:?Environment variable OQS_SSH_REPO is not set or is empty}"
: "${LIBOQS_VERSION:?Environment variable LIBOQS_VERSION is not set or is empty}"
: "${OQS_SSH_VERSION:?Environment variable OQS_SSH_VERSION is not set or is empty}"

# Ensure we're running with sudo/root
if [[ $EUID -ne 0 ]]; then
    echo "Error: This script must be run with sudo or as root."
    exit 1
fi

###############################################################################
# 3. Define functions for each logical step
###############################################################################
install_dependencies() {
    echo "[1/5] Installing dependencies..."
    bash "$(dirname "$0")/config/install_dependencies.sh"
}

build_liboqs() {
    echo "[2/5] Building liboqs..."
    rm -rf "$LIBOQS_DIR"
    # Safely handle potential git clone failure
    if ! git clone -b "$LIBOQS_VERSION" "$LIBOQS_REPO" "$LIBOQS_DIR"; then
        echo "Failed to clone liboqs from $LIBOQS_REPO."
        echo "Check your network connection or verify the URL/branch."
        exit 1
    fi

    cd "$LIBOQS_DIR"
    mkdir build && cd build
    cmake -GNinja -DCMAKE_INSTALL_PREFIX="$INSTALL_PREFIX" \
          -DOQS_USE_OPENSSL=OFF \
          -DBUILD_SHARED_LIBS=ON \
          ..
    ninja
    ninja install
}

build_oqs_ssh() {
    echo "[3/5] Building OQS-SSH..."
    rm -rf "$OQS_SSH_DIR"
    # Safely handle potential git clone failure
    if ! git clone -b "$OQS_SSH_VERSION" "$OQS_SSH_REPO" "$OQS_SSH_DIR"; then
        echo "Failed to clone OQS-SSH from $OQS_SSH_REPO."
        echo "Check your network connection or verify the URL/branch."
        exit 1
    fi

    cd "$OQS_SSH_DIR"
    autoreconf -i
    ./configure \
      --prefix="$INSTALL_PREFIX" \
      --with-libs=-loqs \
      --with-liboqs-dir="$INSTALL_PREFIX" \
      --with-cflags="-DWITH_KYBER_KEM=1 -DWITH_FALCON=1" \
      --enable-hybrid-kex \
      --enable-pq-kex

    make -j"$(nproc)"
}

configure_ssh() {
    echo "[4/5] Setting up SSH configuration..."

    # Optionally, warn if another SSH server is detected
    if command -v sshd &>/dev/null; then
        echo "Warning: Another SSH server might be installed on this system."
        echo "Proceeding with the installation will not automatically replace or disable it."
    fi

    mkdir -p /usr/local/etc/ssh

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
    cp "$OQS_SSH_DIR"/{ssh,scp,ssh-keygen} "$INSTALL_PREFIX/bin/"
    chmod +x "$INSTALL_PREFIX/bin/ssh" "$INSTALL_PREFIX/bin/scp" "$INSTALL_PREFIX/bin/ssh-keygen"

    # Generate the server's Falcon-512 host key
    "$INSTALL_PREFIX/bin/ssh-keygen" -t ssh-falcon512 \
      -f /usr/local/etc/ssh/ssh_host_falcon512_key \
      -N ""

    # Refresh dynamic linker cache so the system sees liboqs
    ldconfig

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
# 4. Main function orchestrates all steps
###############################################################################
main() {
    install_dependencies
    build_liboqs
    build_oqs_ssh
    configure_ssh
    install_and_generate_keys
}

# Entry point
main "$@"
