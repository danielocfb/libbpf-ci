#!/bin/bash

set -euo pipefail

LLVM_VERSION=${LLVM_VERSION:-21}

sudo apt-get update -y

# The guest runs off the host's file system, so everything the tests need
# inside the VM has to be installed out here.
sudo -E apt-get install --no-install-recommends -y \
     binutils ethtool gawk iproute2 iptables iputils-ping \
     keyutils libasan8 libpcap-dev libz3-4 make zlib1g

# Install specific version of libllvm on Ubuntu
source /etc/os-release
if [[ "$ID" == "ubuntu" ]]; then
     wget -qO- https://apt.llvm.org/llvm-snapshot.gpg.key | sudo tee /etc/apt/trusted.gpg.d/apt.llvm.org.asc
     CODENAME=$(lsb_release -cs)
     echo "deb http://apt.llvm.org/${CODENAME}/ llvm-toolchain-${CODENAME}-${LLVM_VERSION} main" | \
          sudo tee /etc/apt/sources.list.d/llvm-${LLVM_VERSION}.list
     sudo apt-get update -y
     sudo apt-get install --no-install-recommends -y libllvm${LLVM_VERSION}
fi
