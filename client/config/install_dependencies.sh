#!/usr/bin/env bash

echo "[Installing dependencies...]"
apt-get update -y
apt-get install -y \
  build-essential autoconf automake libtool make cmake ninja-build \
  pkg-config libssl-dev zlib1g-dev git
