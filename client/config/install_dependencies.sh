#!/usr/bin/env bash

# Exit on error
set -e

check_dependency_versions() {
    echo "Checking dependency versions..."
    local cmake_version=$(cmake --version | head -n1 | cut -d' ' -f3)
    if ! printf '%s\n' "$MIN_CMAKE_VERSION" "$cmake_version" | sort -C -V; then
        echo "CMake version >= $MIN_CMAKE_VERSION required"
        exit 1
    fi
}

install_dependencies() {
    echo "[Installing dependencies...]"
    if ! apt-get update -y; then
        echo "Failed to update package lists"
        exit 1
    fi

    local packages=(
        build-essential
        autoconf
        automake
        libtool
        make
        cmake
        ninja-build
        pkg-config
        libssl-dev
        zlib1g-dev
        git
    )

    if ! apt-get install -y "${packages[@]}"; then
        echo "Failed to install required packages"
        exit 1
    fi
}

verify_installations() {
    local required_commands=(
        cmake
        ninja
        git
        make
        autoconf
    )

    echo "Verifying installations..."
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "Failed to install: $cmd"
            exit 1
        fi
    done
}

# Main execution
install_dependencies
check_dependency_versions
verify_installations
echo "All dependencies installed and verified successfully."