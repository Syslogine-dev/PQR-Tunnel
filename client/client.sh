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

initialize_logging() {
    LOG_FILE="/var/log/pqr_tunnel_setup.log"
    exec > >(tee -a "$LOG_FILE") 2>&1
    echo "Logging configured. All output will be saved to $LOG_FILE."
}

validate_environment() {
    echo "[0/5] Validating environment..."

    # Check for root privileges
    if [[ $(id -u) -ne 0 ]]; then
        echo "Error: This script must be run as root or with sudo."
        exit 1
    fi

    # Check if required tools are available
    local required_tools=("git" "cmake" "ninja-build" "gcc" "ldconfig")
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            echo "Error: Required tool '$tool' is not installed."
            exit 1
        fi
    done

    echo "Validation complete. The environment is ready."
}

install_dependencies() {
    echo "[1/5] Installing dependencies..."
    bash "$(dirname "$0")/config/install_dependencies.sh"
}

build_liboqs() {
    echo "[2/5] Building liboqs..."

    # Required dependencies
    local dependencies=(cmake ninja-build gcc libssl-dev)
    for pkg in "${dependencies[@]}"; do
        if ! dpkg -s "$pkg" >/dev/null 2>&1; then
            echo "Error: Required dependency '$pkg' is not installed."
            exit 1
        fi
    done

    # Remove existing liboqs source directory
    rm -rf "$LIBOQS_DIR"

    # Clone the specified liboqs version
    if ! git clone -b "$LIBOQS_VERSION" "$LIBOQS_REPO" "$LIBOQS_DIR"; then
        echo "Error: Failed to clone liboqs from $LIBOQS_REPO (branch: $LIBOQS_VERSION)."
        echo "Check your network connection or verify the URL/branch."
        exit 1
    fi

    cd "$LIBOQS_DIR"
    mkdir build && cd build

    # Configure the build with CMake
    if ! cmake -GNinja \
               -DCMAKE_INSTALL_PREFIX="$INSTALL_PREFIX" \
               -DOQS_USE_OPENSSL=OFF \
               -DBUILD_SHARED_LIBS=ON \
               ..; then
        echo "Error: CMake configuration for liboqs failed."
        exit 1
    fi

    # Compile liboqs with Ninja
    if ! ninja; then
        echo "Error: Ninja build for liboqs failed."
        exit 1
    fi

    # Install liboqs
    if ! ninja install; then
        echo "Error: Installation for liboqs failed."
        exit 1
    fi

    echo "liboqs successfully built and installed."
}

build_oqs_ssh() {
    echo "[3/5] Building OQS-SSH..."

    # Required dependencies
    local dependencies=(autoconf automake libtool make cmake ninja-build pkg-config libssl-dev zlib1g-dev git)
    for pkg in "${dependencies[@]}"; do
        if ! dpkg -s "$pkg" >/dev/null 2>&1; then
            echo "Error: Required dependency '$pkg' is not installed."
            exit 1
        fi
    done

    # Remove existing OQS-SSH source directory
    rm -rf "$OQS_SSH_DIR"

    # Clone the specified OQS-SSH branch
    if ! git clone -b "$OQS_SSH_VERSION" "$OQS_SSH_REPO" "$OQS_SSH_DIR"; then
        echo "Error: Failed to clone OQS-SSH from $OQS_SSH_REPO (branch: $OQS_SSH_VERSION)."
        echo "Check your network connection or verify the URL/branch."
        exit 1
    fi

    cd "$OQS_SSH_DIR"

    # Generate configure script with autoreconf
    if ! autoreconf -i; then
        echo "Error: autoreconf failed for OQS-SSH."
        exit 1
    fi

    # Configure OQS-SSH with required flags
    if ! ./configure \
         --prefix="$INSTALL_PREFIX" \
         --with-libs=-loqs \
         --with-liboqs-dir="$INSTALL_PREFIX" \
         --with-cflags="-DWITH_KYBER_KEM=1 -DWITH_FALCON=1" \
         --enable-hybrid-kex \
         --enable-pq-kex; then
        echo "Error: Configuration step failed for OQS-SSH."
        exit 1
    fi

    # Compile OQS-SSH
    if ! make -j"$(nproc)"; then
        echo "Error: Build (make) failed for OQS-SSH."
        exit 1
    fi

    # Install OQS-SSH
    if ! make install; then
        echo "Error: Installation failed for OQS-SSH."
        exit 1
    fi

    echo "OQS-SSH successfully built and installed."
}

configure_ssh() {
    echo "[4/5] Setting up SSH configuration..."

    # Optional: Warn if another SSH server is detected
    if command -v sshd &>/dev/null; then
        echo "Warning: Another SSH server might be installed on this system."
        echo "Proceeding with this setup does not automatically replace or disable it."
    fi

    # Create SSH configuration directory
    if ! mkdir -p /usr/local/etc/ssh; then
        echo "Error: Failed to create /usr/local/etc/ssh directory."
        exit 1
    fi

    # Check if the chosen algorithms are available
    if ! "$INSTALL_PREFIX/bin/ssh" -Q key | grep -q "ssh-falcon512"; then
        echo "Error: The ssh-falcon512 algorithm is not supported by the installed SSH binaries."
        exit 1
    fi

    if ! "$INSTALL_PREFIX/bin/ssh" -Q kex | grep -q "ml-kem-512-sha256"; then
        echo "Error: The ml-kem-512-sha256 key exchange algorithm is not supported."
        exit 1
    fi

    # Write a basic config that references the new PQ host key
    cat << EOF > /usr/local/etc/sshd_config
HostKey /usr/local/etc/ssh/ssh_host_falcon512_key
HostKeyAlgorithms ssh-falcon512
KexAlgorithms ml-kem-512-sha256
PubkeyAcceptedAlgorithms ssh-falcon512
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
PasswordAuthentication no
EOF

    if [[ ! -s /usr/local/etc/sshd_config ]]; then
        echo "Error: Could not create sshd_config file or file is empty."
        exit 1
    fi

    # Validate the configuration
    if ! "$INSTALL_PREFIX/bin/sshd" -t -f /usr/local/etc/sshd_config; then
        echo "Error: SSH configuration validation failed."
        exit 1
    fi

    echo "SSH configuration has been set up successfully."
}


install_and_generate_keys() {
   echo "[5/5] Installing binaries and generating keys..."

   # Check if binaries exist before copying
   local binaries=("ssh" "scp" "ssh-keygen")
   for binary in "${binaries[@]}"; do
       if [[ ! -f "$OQS_SSH_DIR/$binary" ]]; then
           echo "Error: $binary binary not found in $OQS_SSH_DIR. Ensure the build was successful."
           exit 1
       fi
   done

   # Install the binaries
   mkdir -p "$INSTALL_PREFIX/bin/"
   cp "$OQS_SSH_DIR"/{ssh,scp,ssh-keygen} "$INSTALL_PREFIX/bin/"
   chmod +x "$INSTALL_PREFIX/bin/ssh" "$INSTALL_PREFIX/bin/scp" "$INSTALL_PREFIX/bin/ssh-keygen"

   # Verify binaries were installed successfully
   for binary in "${binaries[@]}"; do
       if [[ ! -x "$INSTALL_PREFIX/bin/$binary" ]]; then
           echo "Error: $binary could not be installed in $INSTALL_PREFIX/bin."
           exit 1
       fi
   done

   # -------------------------------------------------------------------------
   # Configure the dynamic linker
   # -------------------------------------------------------------------------
   local local_conf="/etc/ld.so.conf.d/local.conf"
   if [[ ! -f "$local_conf" ]] || ! grep -q "/usr/local/lib" "$local_conf"; then
       echo "Adding /usr/local/lib to $local_conf..."
       echo "/usr/local/lib" >> "$local_conf"
   fi

   # Reload the dynamic linker cache
   ldconfig
   if ! ldconfig -p | grep -q "/usr/local/lib"; then
       echo "Error: Dynamic linker cache could not be updated."
       exit 1
   fi

   # -------------------------------------------------------------------------
   # Generate the host's Falcon-512 SSH key
   # -------------------------------------------------------------------------
   mkdir -p /usr/local/etc/ssh
   if ! "$INSTALL_PREFIX/bin/ssh-keygen" -t ssh-falcon512 \
        -f /usr/local/etc/ssh/ssh_host_falcon512_key \
        -N ""; then
       echo "Error: Falcon-512 SSH key generation failed."
       exit 1
   fi

   echo "
PQR-Tunnel client setup complete!

Generate your own client keys with:
 $INSTALL_PREFIX/bin/ssh-keygen -t ssh-falcon512

Connect with:
 $INSTALL_PREFIX/bin/ssh -o HostKeyAlgorithms=ssh-falcon512 -o PubkeyAcceptedAlgorithms=+ssh-falcon512 hostname

Recommended aliases for .bashrc:
 alias qssh='$INSTALL_PREFIX/bin/ssh -o HostKeyAlgorithms=ssh-falcon512 -o PubkeyAcceptedAlgorithms=+ssh-falcon512'
 alias qscp='$INSTALL_PREFIX/bin/scp'
"
}

test_installation() {
   echo "[5.5/6] Testing installation..."

   # Check if liboqs is correctly installed
   if ! ldconfig -p | grep -q liboqs; then
       echo "Error: liboqs is not correctly installed."
       exit 1
   fi

   # Check if the SSH binaries work
   if ! "$INSTALL_PREFIX/bin/ssh" -V >/dev/null 2>&1; then
       echo "Error: OQS-SSH binaries are not functioning correctly."
       exit 1
   fi

   echo "All components are correctly installed and operational."
}

cleanup() {
   echo "[6/6] Cleaning up temporary files..."

   # Remove temporary build directories 
   rm -rf "$LIBOQS_DIR/build" "$OQS_SSH_DIR/build"

   echo "Cleanup completed."
}

rollback() {
   echo "Performing rollback..."

   # Remove installed files
   rm -rf "$LIBOQS_DIR" "$OQS_SSH_DIR" "$INSTALL_PREFIX"

   echo "Rollback completed. The system has been restored to its original state."
}


# -----------------------------------------------------------------------------
# 5. Main function to orchestrate all steps
# -----------------------------------------------------------------------------
main() {
    initialize_logging
    validate_environment

    install_dependencies || rollback
    build_liboqs || rollback
    build_oqs_ssh || rollback
    configure_ssh || rollback
    install_and_generate_keys || rollback

    test_installation
    cleanup
}

# -----------------------------------------------------------------------------
# 6. Entry point
# -----------------------------------------------------------------------------
main "$@"
