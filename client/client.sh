#!/bin/bash

set -exo pipefail

# Stap 1: Systeemvereisten installeren
echo "Installeren van vereiste pakketten..."
sudo apt update && sudo apt -y install \
    autoconf \
    automake \
    cmake \
    gcc \
    libtool \
    libssl-dev \
    make \
    ninja-build \
    zlib1g-dev \
    doxygen \
    graphviz

# Stap 2: SSH-gebruiker en groep aanmaken
echo "Instellen van SSH-gebruiker en groep..."
sudo mkdir -p -m 0755 /var/empty
sudo groupadd -f sshd || true
sudo useradd -g sshd -c 'sshd privsep' -d /var/empty -s /bin/false sshd || true

# Stap 3: liboqs installeren
echo "Clonen en installeren van liboqs..."
LIBOQS_REPO=${LIBOQS_REPO:-"https://github.com/open-quantum-safe/liboqs.git"}
LIBOQS_BRANCH=${LIBOQS_BRANCH:-"main"}
LIBOQS_BUILD_DIR="oqs-scripts/tmp/liboqs/build"
PREFIX=${PREFIX:-"`pwd`/oqs"}

rm -rf oqs-scripts/tmp && mkdir -p oqs-scripts/tmp

git clone --branch ${LIBOQS_BRANCH} --single-branch ${LIBOQS_REPO} oqs-scripts/tmp/liboqs
mkdir -p ${LIBOQS_BUILD_DIR}
cd ${LIBOQS_BUILD_DIR}

cmake .. -GNinja \
    -DBUILD_SHARED_LIBS=ON \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DCMAKE_INSTALL_PREFIX=${PREFIX}

ninja
ninja install
cd ../../../..

# Stap 4: PQS-SSH installeren
echo "Clonen en installeren van Open Quantum Safe OpenSSH..."
OQS_OPENSSH_REPO=${OQS_OPENSSH_REPO:-"https://github.com/open-quantum-safe/openssh.git"}
OQS_OPENSSH_BRANCH=${OQS_OPENSSH_BRANCH:-"OQS-v9"}
PQS_BUILD_DIR="oqs-scripts/tmp/openssh"

rm -rf ${PQS_BUILD_DIR}
git clone --branch ${OQS_OPENSSH_BRANCH} --single-branch ${OQS_OPENSSH_REPO} ${PQS_BUILD_DIR}
cd ${PQS_BUILD_DIR}

autoreconf
./configure --prefix=/usr/local --with-ssl-dir=/usr/local/lib
make -j$(nproc)
sudo make install
cd ../../..

# Stap 5: Testen en configureren
echo "Controleren op beschikbare algoritmen..."
/usr/local/bin/ssh -Q key

echo "Setup voltooid. Je kunt nu post-quantum sleutels genereren en gebruiken."
