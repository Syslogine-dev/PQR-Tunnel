#!/usr/bin/env bash
#
# client.sh
#
# Combined script: Builds and installs liboqs & OQS-SSH, configures SSH, 
# generates Falcon keys, and optionally sets up a systemd service for OQS-SSH.
#
# Tested on Debian/Ubuntu-like systems only.

set -euo pipefail

# ---------------------------
# CONFIGURABLE VARIABLES
# ---------------------------
INSTALL_PREFIX="/usr/local"
LIBOQS_REPO="https://github.com/open-quantum-safe/liboqs.git"
LIBOQS_VERSION="0.12.0"

OQS_SSH_REPO="https://github.com/open-quantum-safe/openssh.git"
OQS_SSH_VERSION="OQS-OpenSSH-snapshot-2024-08"

LIBOQS_DIR="/opt/liboqs"
OQS_SSH_DIR="/opt/oqs-ssh"

# Where to place OQS-SSH config & keys
SSHD_CONFIG_DIR="$INSTALL_PREFIX/etc/ssh"
CUSTOM_SSHD_BIN="$INSTALL_PREFIX/sbin/sshd"

# Optional systemd service path
SYSTEMD_SERVICE_PATH="/etc/systemd/system/oqs-sshd.service"

LOG_FILE="/var/log/pqr_tunnel_installer.log"

# ---------------------------
# LOGGING & ERROR HANDLING
# ---------------------------
log() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

error_exit() {
  log "ERROR: $1"
  exit 1
}

# ---------------------------
# RUNTIME VALIDATIONS
# ---------------------------
validate_root() {
  if [[ $(id -u) -ne 0 ]]; then
    error_exit "This script must be run as root or with sudo."
  fi
}

check_distro_support() {
  if ! command -v apt-get >/dev/null 2>&1; then
    error_exit "Unsupported distribution. apt-get not found."
  fi
}

# ---------------------------
# INSTALL DEPENDENCIES
# ---------------------------
install_dependencies() {
  log "Installing dependencies..."
  apt-get update -y || error_exit "apt-get update failed"
  DEPS=(
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
  )
  apt-get install -y "${DEPS[@]}" || error_exit "Dependency installation failed"
  log "All dependencies installed."
}

# ---------------------------
# BUILD liboqs
# ---------------------------
build_liboqs() {
  log "Building liboqs..."
  rm -rf "$LIBOQS_DIR"
  git clone --depth 1 -b "$LIBOQS_VERSION" "$LIBOQS_REPO" "$LIBOQS_DIR" \
    || error_exit "Failed to clone liboqs"
  mkdir -p "$LIBOQS_DIR/build"
  cd "$LIBOQS_DIR/build"
  cmake -GNinja -DCMAKE_INSTALL_PREFIX="$INSTALL_PREFIX" -DOQS_USE_OPENSSL=OFF \
        -DBUILD_SHARED_LIBS=ON .. || error_exit "liboqs CMake config failed"
  ninja || error_exit "liboqs build failed"
  ninja install || error_exit "liboqs install failed"
  log "liboqs installed to $INSTALL_PREFIX."
}

# ---------------------------
# BUILD OQS-SSH
# ---------------------------
build_oqs_ssh() {
  log "Building OQS-SSH..."
  rm -rf "$OQS_SSH_DIR"
  git clone --depth 1 -b "$OQS_SSH_VERSION" "$OQS_SSH_REPO" "$OQS_SSH_DIR" \
    || error_exit "Failed to clone OQS-SSH"
  cd "$OQS_SSH_DIR"
  autoreconf -i || error_exit "autoreconf failed"
  ./configure \
    --prefix="$INSTALL_PREFIX" \
    --with-libs=-loqs \
    --with-liboqs-dir="$INSTALL_PREFIX" \
    --with-cflags="-DWITH_KYBER=1 -DWITH_FALCON=1" \
    --enable-hybrid-kex \
    --enable-pq-kex \
    || error_exit "OQS-SSH configure failed"
  make -j"$(nproc)" || error_exit "OQS-SSH build failed"
  make install || error_exit "OQS-SSH install failed"
  log "OQS-SSH installed to $INSTALL_PREFIX."
}

# ---------------------------
# CONFIGURE DYNAMIC LINKER
# ---------------------------
configure_dynamic_linker() {
  log "Configuring dynamic linker..."
  local conf_file="/etc/ld.so.conf.d/local-liboqs.conf"
  if ! grep -q "/usr/local/lib" "$conf_file" 2>/dev/null; then
    echo "/usr/local/lib" >> "$conf_file"
  fi
  ldconfig || error_exit "ldconfig failed"
  if ! ldconfig -p | grep -q liboqs; then
    error_exit "liboqs not found by dynamic linker"
  fi
  log "Dynamic linker configured."
}

# ---------------------------
# CREATE SSHD USER
# ---------------------------
create_sshd_user() {
  log "Checking 'sshd' user..."
  if ! id -u sshd >/dev/null 2>&1; then
    log "Creating 'sshd' group & user..."
    groupadd -r sshd || error_exit "Failed to create group 'sshd'"
    useradd -r -g sshd -d /var/empty -s /usr/sbin/nologin -c "Privilege-separated SSH" sshd \
      || error_exit "Failed to create user 'sshd'"
    log "'sshd' user & group created."
  else
    log "'sshd' user already exists; skipping."
  fi
}

# ---------------------------
# CONFIGURE OQS-SSH
# ---------------------------
configure_ssh() {
  log "Configuring OQS-SSH in $SSHD_CONFIG_DIR..."
  mkdir -p "$SSHD_CONFIG_DIR"
  cat <<EOF > "$SSHD_CONFIG_DIR/sshd_config"
# OQS-SSH config
HostKey $SSHD_CONFIG_DIR/ssh_host_falcon512_key
HostKeyAlgorithms falcon512
PubkeyAcceptedAlgorithms falcon512
KexAlgorithms kyber512-sha256
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
PasswordAuthentication no

# Change port to avoid clashing with default SSH:
Port 8022
EOF

  if ! "$CUSTOM_SSHD_BIN" -t -f "$SSHD_CONFIG_DIR/sshd_config"; then
    error_exit "OQS-SSH config validation failed"
  fi
  log "OQS-SSH config placed & validated."
}

# ---------------------------
# GENERATE HOST KEYS
# ---------------------------
generate_host_keys() {
  log "Generating Falcon-512 host key..."
  mkdir -p "$SSHD_CONFIG_DIR"
  local KEYGEN_CMD="$INSTALL_PREFIX/bin/ssh-keygen"
  [[ -x "$KEYGEN_CMD" ]] || error_exit "OQS-based ssh-keygen not found at $KEYGEN_CMD"

  if [[ -f "$SSHD_CONFIG_DIR/ssh_host_falcon512_key" ]]; then
    log "Host key already exists; skipping."
  else
    "$KEYGEN_CMD" -t falcon512 -f "$SSHD_CONFIG_DIR/ssh_host_falcon512_key" -N "" \
      || error_exit "Falcon-512 key generation failed"
    log "Falcon-512 host key generated."
  fi
}

# ---------------------------
# SYSTEMD SERVICE
# ---------------------------
install_systemd_service() {
  log "Installing systemd service at $SYSTEMD_SERVICE_PATH..."
  cat <<EOF > "$SYSTEMD_SERVICE_PATH"
[Unit]
Description=OQS-SSH Daemon
After=network.target

[Service]
ExecStart=$CUSTOM_SSHD_BIN -f $SSHD_CONFIG_DIR/sshd_config -D
ExecReload=/bin/kill -HUP \$MAINPID
Type=simple
PIDFile=/var/run/oqs_sshd.pid
NonBlocking=true
RuntimeDirectory=sshd
RuntimeDirectoryMode=0755

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload || error_exit "systemctl daemon-reload failed"
  log "Use 'systemctl enable oqs-sshd' and 'systemctl start oqs-sshd' to run OQS-SSH."
}

# ---------------------------
# MAIN
# ---------------------------
main() {
  validate_root
  check_distro_support

  log "Starting installation..."
  install_dependencies
  build_liboqs
  build_oqs_ssh
  configure_dynamic_linker
  create_sshd_user
  configure_ssh
  generate_host_keys
  install_systemd_service

  log "Installation complete. OQS-SSH is configured under $SSHD_CONFIG_DIR."
  log "Run $CUSTOM_SSHD_BIN -f $SSHD_CONFIG_DIR/sshd_config -D to launch manually, or set up systemd."
}

main "$@"
