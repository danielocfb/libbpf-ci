#!/bin/bash
set -eu

THISDIR="$(cd "$(dirname "$0")" && pwd)"
source "${THISDIR}"/../helpers.sh

foldable start install_clang "Install LLVM ${LLVM_VERSION}"

source /etc/os-release

# Deliberately *not* installed: lldb, liblldb-dev, libc++, libc++abi, libomp
# and libunwind. apt.llvm.org ships those under unversioned names (libc++1,
# libc++abi1, libomp5, llvm-libunwind1, python3-lldb-${LLVM_VERSION}) that
# claim the same "<foo>-x.y" virtual packages as the distribution's own LLVM
# stack, so they are unsolvable on any image that already carries one -- e.g.
# the GitHub-hosted ubuntu-24.04 runner, which comes with LLVM 18. The lldb
# packages additionally drag in the libpython of the *repository's* release,
# not the one of the running system. None of them are needed to build the
# kernel, the selftests or scx.
PACKAGES=(
    "clang-${LLVM_VERSION}"
    "clang-format-${LLVM_VERSION}"
    "clang-tidy-${LLVM_VERSION}"
    "clang-tools-${LLVM_VERSION}"
    "clangd-${LLVM_VERSION}"
    "libclang-${LLVM_VERSION}-dev"
    "libclang-common-${LLVM_VERSION}-dev"
    "libclang-cpp${LLVM_VERSION}-dev"
    "libclang-rt-${LLVM_VERSION}-dev"
    "libpolly-${LLVM_VERSION}-dev"
    "lld-${LLVM_VERSION}"
    "llvm-${LLVM_VERSION}-dev"
    "llvm-${LLVM_VERSION}-tools"
)

case "${ID}" in
ubuntu)
    # Ubuntu does not carry the LLVM versions we need, so pull them from
    # apt.llvm.org. We set the repository up by hand instead of going through
    # https://apt.llvm.org/llvm.sh, because that script insists on installing
    # a package set of its own choosing.
    sudo apt-get update -y
    sudo -E apt-get install --no-install-recommends -y \
        ca-certificates curl gnupg wget
    KEYRING=/etc/apt/keyrings/apt.llvm.org.asc
    curl --fail --silent --show-error --location \
        https://apt.llvm.org/llvm-snapshot.gpg.key |
        sudo install -D -m 0644 /dev/stdin "${KEYRING}"
    # Derivatives keep the upstream Ubuntu release in UBUNTU_CODENAME, which
    # is the one apt.llvm.org publishes under.
    CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME}}"
    echo "deb [signed-by=${KEYRING}] https://apt.llvm.org/${CODENAME}/ llvm-toolchain-${CODENAME}-${LLVM_VERSION} main" |
        sudo tee "/etc/apt/sources.list.d/llvm-${LLVM_VERSION}.list"
    ;;
debian)
    # Everything we need is in the distribution repositories already,
    # assuming LLVM_VERSION is available there.
    ;;
*)
    echo "$(basename "$0") unexpected distro: ${ID}" >&2
    exit 1
    ;;
esac

sudo apt-get update -y
sudo -E apt-get install --no-install-recommends -y "${PACKAGES[@]}"

foldable end install_clang
