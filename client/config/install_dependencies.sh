#!/usr/bin/env bash
#
# install_dependencies.sh
#
# Installs required packages for building liboqs and OQS-SSH on
# Debian/Ubuntu-based systems.

# Enable safer bash options:
# -e: exit immediately if a command exits with a non-zero status
# -u: treat unset variables as an error
# -o pipefail: the return value of a pipeline is the status of
#              the last command to exit with a non-zero status
set -euo pipefail

# Log file for storing output and errors
LOG_FILE="/var/log/install_dependencies.log"
exec > >(tee -a "$LOG_FILE") 2>&1

###############################################################################
# 1. Show help/usage if requested
###############################################################################
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
 cat << EOF
Usage: sudo ./install_dependencies.sh

Installs packages required to build liboqs and OQS-SSH on Debian/Ubuntu-based
systems. Make sure to run this script as root or with sudo.

Options:
 -h, --help    Show this help message and exit
EOF
 exit 0
fi

###############################################################################
# 2. Ensure we're running with sudo/root
###############################################################################
if [[ $(id -u) -ne 0 ]]; then
 echo "Error: This script must be run with sudo or as root."
 exit 1
fi

###############################################################################
# 3. Define the install function
###############################################################################
install_packages() {
 echo "Updating package lists..."
 if ! apt-get update -y; then
   echo "Error: Failed to update package lists. Check your network connection."
   exit 1
 fi

 echo "Installing required packages..."
 if ! apt-get install -y \
   build-essential \
   autoconf \
   automake \
   libtool \
   make \
   cmake \
   ninja-build \
   pkg-config \
   libssl-dev \
   zlib1g-dev \
   git \
   doxygen \
   graphviz --no-install-recommends; then
   echo "Error: Failed to install required packages. Check logs for details."
   exit 1
 fi

 echo "Cleaning up unnecessary files..."
 apt-get autoremove -y && apt-get clean

 echo "Dependencies installed successfully."
}

###############################################################################
# 4. Main function orchestrating the install
###############################################################################
main() {
 install_packages
}

# Entry point
main "$@"