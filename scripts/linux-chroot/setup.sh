#!/bin/bash
# Companion Viewer: create the rootless Ubuntu 24.04 build chroot used for Linux builds.
#
#   scripts/linux-chroot/setup.sh [CHROOT_DIR]      (default: <repo>/.chroot)
#
# Needs: a user with a /etc/subuid and /etc/subgid range, `unshare` with user namespaces,
# curl, tar, and network access. Takes a few minutes and about 2 GB of disk. Nothing runs as
# real root: root inside the chroot is the current user, other ids map into the subuid range.
# Afterwards use  <CHROOT_DIR>/enter [command]  (default command: bash).
set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
CHROOT="$(readlink -m "${1:-$HERE/../../.chroot}")"
ROOTFS="$CHROOT/rootfs"
BASE_URL=https://cdimage.ubuntu.com/ubuntu-base/releases/24.04/release
AUTOBUILD_VERSION=3.10.2
LLSD_VERSION=1.2.4

[ -e "$ROOTFS/etc/os-release" ] && { echo "$ROOTFS already exists; remove it first to start over" >&2; exit 1; }
grep -q "^$(id -un):" /etc/subuid && grep -q "^$(id -un):" /etc/subgid \
    || { echo "no subuid/subgid range for $(id -un); see man subuid" >&2; exit 1; }

mkdir -p "$ROOTFS"
cp "$HERE/enter" "$CHROOT/enter"

# Newest 24.04.x ubuntu-base tarball.
TARBALL="$(curl -fsS "$BASE_URL/" | grep -o 'ubuntu-base-24[0-9.]*-base-amd64\.tar\.gz' | sort -uV | tail -1)"
echo "Downloading $TARBALL"
curl -fL -o "$CHROOT/$TARBALL" "$BASE_URL/$TARBALL"

# Extract inside a user namespace so file ownership maps onto the subuid range.
unshare --map-auto --map-root-user tar -xpf "$CHROOT/$TARBALL" -C "$ROOTFS" --exclude='dev/*'
rm "$CHROOT/$TARBALL"

# Inside, apt must not drop to its _apt user (not mappable here), and GCC 14 comes from the
# ubuntu-toolchain-r/test PPA (stock noble stops at 13).
"$CHROOT/enter" bash -euc '
export DEBIAN_FRONTEND=noninteractive
APT="apt-get -o APT::Sandbox::User=root -y"
$APT update
$APT install software-properties-common ca-certificates gpg-agent curl
add-apt-repository -y ppa:ubuntu-toolchain-r/test
$APT update
$APT install build-essential gcc-14 g++-14 cmake ninja-build git curl wget unzip xz-utils zstd \
    python3 python3-pip python3-venv python-is-python3 mesa-common-dev libgl1-mesa-dev \
    libglu1-mesa-dev libfontconfig1-dev libfreetype-dev libssl-dev libpulse-dev \
    libxinerama-dev libxrandr-dev
# Companion Viewer: the rest of the upstream CI package list (.github/workflows/build.yaml).
# Viewer 7.3 builds the VLC, GStreamer, PipeWire and Wayland parts against system libraries.
$APT install pkg-config libosmesa6-dev libxcursor-dev libxfixes-dev libxft-dev libunwind-dev \
    libpipewire-0.3-dev libdbus-1-dev libglib2.0-dev libgstreamer1.0-dev \
    libgstreamer-plugins-base1.0-dev libvlc-dev libwayland-dev libfreetype6-dev
python3 -m venv /opt/autobuild
/opt/autobuild/bin/pip install autobuild=='$AUTOBUILD_VERSION' llsd=='$LLSD_VERSION'
'
echo "Done. Enter with: $CHROOT/enter"
