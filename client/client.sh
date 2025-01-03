#!/usr/bin/env bash
#
# install_oqs_ssh.sh - Installeert liboqs en OQS-OpenSSH, genereert hybride (Kyber+ECDSA) key,
#                      en configureert een minimale server/client setup.
#

set -euo pipefail

#=== 1. Controleren of we root/sudo zijn ===#
if [ "$EUID" -ne 0 ]; then
  echo "Voer dit script als root of via sudo uit."
  exit 1
fi

#=== 2. Systeemupdates en vereiste pakketten ===#
echo "[INFO] Systeem updaten en vereiste pakketten installeren..."
apt-get update
apt-get install -y build-essential cmake ninja-build git libssl-dev wget \
                   autoconf automake libtool curl make gcc pkg-config \
                   libxml2-dev libz-dev doxygen graphviz

#=== 3. liboqs downloaden en bouwen ===#
echo "[INFO] liboqs downloaden en compileren..."
cd /usr/local/src
if [ ! -d liboqs ]; then
  git clone --branch main https://github.com/open-quantum-safe/liboqs.git
fi
cd liboqs
mkdir -p build && cd build
cmake -GNinja -DCMAKE_INSTALL_PREFIX=/opt/liboqs -DBUILD_SHARED_LIBS=ON ..
ninja
ninja install

#=== 4. OQS-OpenSSH downloaden en bouwen ===#
echo "[INFO] OQS-OpenSSH downloaden en compileren..."
cd /usr/local/src
if [ ! -d oqs-openssh ]; then
  git clone https://github.com/open-quantum-safe/openssh.git oqs-openssh
fi
cd oqs-openssh

# Let op: kies de tak/branch die je wilt gebruiken. "OQS-master" is vaak de meest recente.
git checkout OQS-v7.6

./configure --prefix=/opt/oqs-openssh \
            --with-liboqs-dir=/opt/liboqs \
            --sysconfdir=/etc/ssh \
            --with-ssl-engine
make -j"$(nproc)"
make install

#=== Backup van originele OpenSSH binaries (optioneel, maar sterk aanbevolen) ===#
if [ -f /usr/bin/ssh ]; then
  echo "[INFO] Backup van de originele SSH binaries maken in /usr/bin/ssh.backup"
  mv /usr/bin/ssh /usr/bin/ssh.backup || true
fi
if [ -f /usr/sbin/sshd ]; then
  echo "[INFO] Backup van de originele SSHD binaries maken in /usr/sbin/sshd.backup"
  mv /usr/sbin/sshd /usr/sbin/sshd.backup || true
fi

#=== Nieuwe binaries symlinken ===#
ln -s /opt/oqs-openssh/bin/ssh /usr/bin/ssh
ln -s /opt/oqs-openssh/sbin/sshd /usr/sbin/sshd

#=== 5. Hybride sleutel (Kyber+ECDSA) genereren ===#
echo "[INFO] Hybride (Kyber+ECDSA) SSH-sleutel genereren..."
# We nemen aan dat de huidige gebruiker (niet root) de key moet krijgen.
# Als je die gebruiker expliciet kent, pas het dan aan (bv. MYUSER='bob').

if [ -z "${SUDO_USER:-}" ]; then
  # Als we geen SUDO_USER hebben, dan is er misschien geen user-sessie of doen we alles als root.
  # We maken de key dan in root's .ssh:
  MYUSER="root"
else
  MYUSER="$SUDO_USER"
fi

USER_HOME="$(eval echo ~${MYUSER})"
mkdir -p "$USER_HOME/.ssh"
cd "$USER_HOME/.ssh"

# Controleer of de key al bestaat; zo niet, dan genereren we deze
if [ ! -f id_oqsdefault ]; then
  # Voorbeeld: Kyber768 + ECDSA P-384
  su -c "/opt/oqs-openssh/bin/ssh-keygen -t oqsdefault -O hybrid=kyber768+ecdsa-p384 -f id_oqsdefault -N ''" "$MYUSER"
fi

#=== 6. SSHD configureren voor hybride key-acceptatie ===#
echo "[INFO] Minimale configuratie van /etc/ssh/sshd_config voor hybride keys..."
SSHD_CONFIG="/etc/ssh/sshd_config"

# We zorgen dat pubkey auth aanstaat
sed -i 's/#\?PubkeyAuthentication.*/PubkeyAuthentication yes/g' "$SSHD_CONFIG"

# Voeg onze hybride key-algoritmes toe (voor serveracceptatie)
# Let op: afhankelijk van OQS-versie kan de precieze naam anders zijn!
# Voorbeeld: "oqsdefault-kyber768+ecdsa-p384"
if ! grep -q "PubkeyAcceptedAlgorithms.*oqsdefault-kyber768+ecdsa-p384" "$SSHD_CONFIG" ; then
  echo "PubkeyAcceptedAlgorithms oqsdefault-kyber768+ecdsa-p384" >> "$SSHD_CONFIG"
fi

# Herstart SSHD
echo "[INFO] Herstarten van sshd..."
systemctl daemon-reload
systemctl restart ssh

#=== 7. Clientconfig voor user aanmaken ===#
CLIENT_CONFIG="$USER_HOME/.ssh/config"
if [ ! -f "$CLIENT_CONFIG" ]; then
  touch "$CLIENT_CONFIG"
fi

if ! grep -q "Host oqs-server" "$CLIENT_CONFIG" 2>/dev/null; then
cat << EOF >> "$CLIENT_CONFIG"

Host oqs-server
    HostName <VUL_HIER_IP_OF_DOMEIN_IN>
    User $MYUSER
    IdentityFile ~/.ssh/id_oqsdefault
    PubkeyAcceptedAlgorithms oqsdefault-kyber768+ecdsa-p384
EOF
fi
chown "$MYUSER":"$MYUSER" "$CLIENT_CONFIG"
chmod 600 "$CLIENT_CONFIG"

echo
echo "======================================================================================"
echo "[SUCCES] Installatie en configuratie van OQS-OpenSSH is voltooid (testversie)."
echo "[INFO] 1. Pas <VUL_HIER_IP_OF_DOMEIN_IN> in ~/.ssh/config aan naar jouw eigen server-adres."
echo "[INFO] 2. Plaats de publieke sleutel '~/.ssh/id_oqsdefault.pub' in ~/.ssh/authorized_keys op de server."
echo "[INFO]    (Als dit dezelfde machine is, kopieer je hem naar '~/.ssh/authorized_keys'.)"
echo "[INFO] 3. Verbind met:  ssh oqs-server"
echo "[INFO] 4. Check in /var/log/auth.log of 'journalctl -u sshd' of je key correct wordt geaccepteerd."
echo "======================================================================================"
