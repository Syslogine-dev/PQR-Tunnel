#!/usr/bin/env bash

# -- Load Configuration --
source "$(dirname "$0")/config/.env"

# -- 0) Check for root privileges --
if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root."
  exit 1
fi

# -- 1) Install dependencies --
echo "[1/7] Installing dependencies..."
bash "$(dirname "$0")/config/install_dependencies.sh"

# -- 2) Create system user/group (for privilege separation) --
echo "[2/7] Creating system user..."
if ! getent group "$SSHD_GROUP" >/dev/null; then
    groupadd -r "$SSHD_GROUP"
fi

if ! getent passwd "$SSHD_USER" >/dev/null; then
    useradd -r -g "$SSHD_GROUP" -d /var/empty -s /sbin/nologin \
        -c "OQS-SSH privilege separation user" "$SSHD_USER"
fi

# -- 3) Build and install liboqs --
echo "[3/7] Building and installing liboqs..."
rm -rf "$LIBOQS_DIR"
git clone "$LIBOQS_REPO" "$LIBOQS_DIR"
cd "$LIBOQS_DIR" || { echo "Error: Could not navigate to $LIBOQS_DIR."; exit 1; }
mkdir build && cd build || { echo "Error: Could not navigate to $LIBOQS_DIR/build."; exit 1; }
cmake -GNinja -DCMAKE_INSTALL_PREFIX="$INSTALL_PREFIX" ..
ninja
ninja install

# -- 4) Compile and install OQS-SSH --
echo "[4/7] Compiling OQS-SSH..."
rm -rf "$OQS_SSH_DIR"
git clone "$OQS_SSH_REPO" "$OQS_SSH_DIR"
cd "$OQS_SSH_DIR" || { echo "Error: Could not navigate to $OQS_SSH_DIR."; exit 1; }

autoreconf -i
CPPFLAGS="-I$INSTALL_PREFIX/include" LDFLAGS="-L$INSTALL_PREFIX/lib" \
    ./configure --prefix="$INSTALL_PREFIX" --with-libs=-loqs
make -j"$(nproc)"

if [[ -f "sshd" && -f "ssh-keygen" ]]; then
    install -m755 sshd "$INSTALL_PREFIX/bin/sshd_oqs"
    install -m755 ssh-keygen "$INSTALL_PREFIX/bin/ssh-keygen_oqs"
    echo "Binaries installed in $INSTALL_PREFIX/bin/"
else
    echo "Error: Could not find sshd or ssh-keygen. Build failed."
    exit 1
fi

# -- 5) Configure server --
echo "[5/7] Configuring server..."

# Backup existing configuration
mkdir -p "$BACKUP_DIR"
cp -r /etc/ssh/{config,*_config,ssh_*,*_key*} "$BACKUP_DIR/" 2>/dev/null || true
echo "Backup created at $BACKUP_DIR"

# Create directory for quantum-safe host keys
mkdir -p /etc/ssh/quantum_keys
chmod 755 /etc/ssh/quantum_keys

# Generate quantum-safe Falcon512 host key
"$INSTALL_PREFIX/bin/ssh-keygen_oqs" -t ssh-falcon512 \
    -f /etc/ssh/quantum_keys/ssh_host_falcon512_key -N "" -q
chmod 600 /etc/ssh/quantum_keys/ssh_host_falcon512_key
chmod 644 /etc/ssh/quantum_keys/ssh_host_falcon512_key.pub
chown "$SSHD_USER:$SSHD_GROUP" /etc/ssh/quantum_keys/ssh_host_falcon512_key*

# Generate classic RSA host key as backup (if not present)
if [ ! -f /etc/ssh/ssh_host_rsa_key ]; then
    ssh-keygen -t rsa -f /etc/ssh/ssh_host_rsa_key -N ""
    chmod 600 /etc/ssh/ssh_host_rsa_key
    chmod 644 /etc/ssh/ssh_host_rsa_key.pub
    chown "$SSHD_USER:$SSHD_GROUP" /etc/ssh/ssh_host_rsa_key*
fi

# Generate final SSH configuration
TEMPLATE_FILE="$(dirname "$0")/config/sshd_config_template"
FINAL_CONFIG_FILE="/etc/ssh/sshd_config_oqs"
sed "s/{{PORT}}/$NEW_SSH_PORT/" "$TEMPLATE_FILE" > "$FINAL_CONFIG_FILE"

# Ensure privilege separation directory exists
mkdir -p /var/empty
chown root:root /var/empty
chmod 755 /var/empty

# -- 6) Configure logrotate --
echo "[6/7] Setting up logrotate..."
cp "$(dirname "$0")/config/logrotate_sshd_oqs" /etc/logrotate.d/sshd_oqs

# Test SSH configuration
echo "Testing SSH configuration..."
if ! "$INSTALL_PREFIX/bin/sshd_oqs" -t -f "$FINAL_CONFIG_FILE"; then
    echo "Error: SSH configuration test failed!"
    exit 1
fi

# -- 7) Create systemd service --
echo "[7/7] Creating systemd service..."
SERVICE_TEMPLATE="$(dirname "$0")/config/sshd_oqs.service.template"
SYSTEMD_SERVICE_FILE="/etc/systemd/system/sshd_oqs.service"

sed -e "s|{{INSTALL_PREFIX}}|$INSTALL_PREFIX|g" \
    -e "s|{{FINAL_CONFIG_FILE}}|$FINAL_CONFIG_FILE|g" \
    -e "s|{{SSHD_USER}}|$SSHD_USER|g" \
    -e "s|{{SSHD_GROUP}}|$SSHD_GROUP|g" \
    "$SERVICE_TEMPLATE" > "$SYSTEMD_SERVICE_FILE"

ldconfig
systemctl daemon-reload
systemctl enable sshd_oqs
systemctl restart sshd_oqs

sleep 2
SERVICE_STATUS=$(systemctl is-active sshd_oqs)
if [ "$SERVICE_STATUS" = "active" ]; then
    echo "
OQS-SSH server setup successfully completed!
- Server is running on port $NEW_SSH_PORT
- Configuration file: $FINAL_CONFIG_FILE
- Quantum host keys: /etc/ssh/quantum_keys/
- Backup of old configuration: $BACKUP_DIR
- Systemd service: sshd_oqs is active
- Logrotate configuration installed

To test the connection:
  ssh -p $NEW_SSH_PORT -i ~/.ssh/id_falcon512 user@host

Check service status:
  systemctl status sshd_oqs

View logs:
  journalctl -u sshd_oqs
"
else
    echo "
WARNING: Service start appears to have failed.
Check the status with:
  systemctl status sshd_oqs
  journalctl -u sshd_oqs
"
fi