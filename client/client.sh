#!/usr/bin/env bash

# -- Load Configuration --
source "$(dirname "$0")/config/.env"

# -- 0) Check for root privileges --
if [[ $EUID -ne 0 ]]; then
  echo "This script must be run with sudo."
  exit 1
fi

# -- 1) Install dependencies --
echo "[1/4] Installing dependencies..."
bash "$(dirname "$0")/config/install_dependencies.sh"

# -- 2) Build and install liboqs --
echo "[2/4] Building and installing liboqs..."
rm -rf "$LIBOQS_DIR"
git clone "$LIBOQS_REPO" "$LIBOQS_DIR"
cd "$LIBOQS_DIR" || { echo "Error: Could not navigate to $LIBOQS_DIR."; exit 1; }
mkdir build && cd build || { echo "Error: Could not navigate to $LIBOQS_DIR/build."; exit 1; }
cmake -GNinja -DCMAKE_INSTALL_PREFIX="$INSTALL_PREFIX" ..
ninja
ninja install

# -- 3) Clone and compile OQS-SSH --
echo "[3/4] Cloning and compiling OQS-SSH..."
rm -rf "$OQS_SSH_DIR"
git clone "$OQS_SSH_REPO" "$OQS_SSH_DIR"
cd "$OQS_SSH_DIR" || { echo "Error: Could not navigate to $OQS_SSH_DIR."; exit 1; }

autoreconf -i
CPPFLAGS="-I$INSTALL_PREFIX/include" LDFLAGS="-L$INSTALL_PREFIX/lib" \
./configure --prefix="$INSTALL_PREFIX" --with-libs=-loqs
make -j$(nproc)

# -- 4) Install client binaries --
echo "[4/4] Installing client binaries..."
if [[ -f "ssh" ]]; then
  # Install only the client tools
  cp ssh scp "$INSTALL_PREFIX/bin/"
  echo "Client binaries installed in $INSTALL_PREFIX/bin/"
else
  echo "Error: Could not find OQS-SSH binaries. Build failed."
  exit 1
fi

# Update library cache
ldconfig

echo "
OQS-SSH client setup successfully completed!

You can now connect to an OQS-SSH server using:
  $ $INSTALL_PREFIX/bin/ssh -p 2222 user@server -i ~/.ssh/id_kyber512

Tip: Add the following aliases to your ~/.bashrc for convenience:
  alias qssh='$INSTALL_PREFIX/bin/ssh'
  alias qscp='$INSTALL_PREFIX/bin/scp'
"