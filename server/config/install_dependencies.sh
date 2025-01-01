#!/usr/bin/env bash

# Install required dependencies for the OQS-SSH setup
echo "[Installing dependencies...]"
apt-get update -y
apt-get install -y \
  build-essential autoconf automake libtool make cmake ninja-build \
  pkg-config libssl-dev libkrb5-dev libz-dev libpam0g-dev libselinux1-dev git

echo "[Dependencies installed successfully!]"
