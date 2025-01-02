#!/usr/bin/env bash
set -e

source "$(dirname "$0")/config/.env"

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run with sudo."
    exit 1
fi

echo "[1/5] Installing dependencies..."
bash "$(dirname "$0")/config/install_dependencies.sh"

echo "[2/5] Building liboqs..."
rm -rf "$LIBOQS_DIR"
git clone -b "$LIBOQS_VERSION" "$LIBOQS_REPO" "$LIBOQS_DIR"
cd "$LIBOQS_DIR"
mkdir build && cd build
cmake -GNinja -DCMAKE_INSTALL_PREFIX="$INSTALL_PREFIX" -DOQS_USE_OPENSSL=OFF -DBUILD_SHARED_LIBS=ON ..
ninja
ninja install

echo "[3/5] Building OQS-SSH..."
rm -rf "$OQS_SSH_DIR"
git clone -b "$OQS_SSH_VERSION" "$OQS_SSH_REPO" "$OQS_SSH_DIR"
cd "$OQS_SSH_DIR"

autoreconf -i
./configure --prefix="$INSTALL_PREFIX" \
           --with-libs=-loqs \
           --with-liboqs-dir="$INSTALL_PREFIX" \
           --with-cflags="-DWITH_KYBER_KEM=1 -DWITH_FALCON=1" \
           --enable-hybrid-kex \
           --enable-pq-kex
make -j$(nproc)

echo "[4/5] Setting up SSH configuration..."
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

echo "[5/5] Installing binaries and generating keys..."
cp ssh scp ssh-keygen "$INSTALL_PREFIX/bin/"
chmod +x "$INSTALL_PREFIX/bin/ssh" "$INSTALL_PREFIX/bin/scp" "$INSTALL_PREFIX/bin/ssh-keygen"
/usr/local/bin/ssh-keygen -t ssh-falcon512 -f /usr/local/etc/ssh/ssh_host_falcon512_key -N ""

ldconfig

echo "
PQR-Tunnel client setup completed!

Generate your client keys with:
  /usr/local/bin/ssh-keygen -t ssh-falcon512

Connect using:
  /usr/local/bin/ssh -o HostKeyAlgorithms=ssh-falcon512 -o PubkeyAcceptedAlgorithms=+ssh-falcon512 hostname

Recommended aliases for .bashrc:
  alias qssh='/usr/local/bin/ssh -o HostKeyAlgorithms=ssh-falcon512 -o PubkeyAcceptedAlgorithms=+ssh-falcon512'
  alias qscp='/usr/local/bin/scp'
"