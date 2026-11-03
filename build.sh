#!/bin/bash
# Builds dist/podman-linux-<arch>.tar.gz for the architecture of this machine.
# Run it in an ubuntu:22.04 container, so the binaries need only glibc 2.34 or later:
#   docker run --rm -v "$PWD:/work" -w /work ubuntu:22.04 bash build.sh
set -euo pipefail

source ./versions.env
arch="$(dpkg --print-architecture)"
case "$arch" in
    amd64 | arm64) ;;
    *) echo "Unsupported architecture: $arch" >&2; exit 1 ;;
esac
static_sha256_variable="PODMAN_STATIC_SHA256_$arch"
static_sha256="${!static_sha256_variable}"
work="$(mktemp -d)"
bundle="podman-linux-$arch"

export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q --no-install-recommends gcc libc6-dev make pkg-config git curl ca-certificates jq python3 \
    autoconf automake libtool \
    libseccomp-dev libsystemd-dev libapparmor-dev libglib2.0-dev libcap-dev libjson-c-dev
# This container is thrown away after the build. Without the shared libraries, conmon and crun link
# glib, libcap, and json-c statically, so a host needs only glibc, libseccomp, and libsystemd.
lib_dir="/usr/lib/$(gcc -dumpmachine)"
rm -f "$lib_dir"/libglib-2.0.so "$lib_dir"/libpcre.so "$lib_dir"/libcap.so "$lib_dir"/libjson-c.so

go_archive="go$GO_VERSION.linux-$arch.tar.gz"
go_sha256="$(curl -fsSL 'https://go.dev/dl/?mode=json&include=all' | jq -r --arg file "$go_archive" '.[].files[] | select(.filename == $file) | .sha256')"
test -n "$go_sha256"
curl -fsSL -o "$work/go.tar.gz" "https://go.dev/dl/$go_archive"
echo "$go_sha256  $work/go.tar.gz" | sha256sum -c -
tar -xzf "$work/go.tar.gz" -C /usr/local
export PATH="/usr/local/go/bin:$PATH" GOTOOLCHAIN=local GOFLAGS=-buildvcs=false

# Podman with the systemd build tag: health check timers and sd-notify work.
git clone -q --depth 1 --branch "v$PODMAN_VERSION" https://github.com/containers/podman.git "$work/podman"
make -C "$work/podman" bin/podman EXTRA_LDFLAGS='-s -w' \
    BUILDTAGS='grpcnotrace seccomp apparmor systemd containers_image_openpgp exclude_graphdriver_btrfs'
"$work/podman/bin/podman" --version | grep -qxF "podman version $PODMAN_VERSION"
make -C "$work/podman" .install.md2man docs

# conmon with journald support.
git clone -q --depth 1 --branch "v$CONMON_VERSION" https://github.com/containers/conmon.git "$work/conmon"
make -C "$work/conmon" bin/conmon PKG_CONFIG='pkg-config --static' LDFLAGS='-s -w'
"$work/conmon/bin/conmon" --version | grep -qF "conmon version $CONMON_VERSION"

# crun with systemd cgroup support.
git clone -q --depth 1 --recurse-submodules --shallow-submodules --branch "$CRUN_VERSION" https://github.com/containers/crun.git "$work/crun"
(cd "$work/crun" && ./autogen.sh && ./configure --enable-embedded-yajl && make LDFLAGS='-s -w')
"$work/crun/crun" --version | grep -qxF "crun version $CRUN_VERSION"

# podman loads libsystemd at run time. conmon and crun link it, which every systemd distribution has.
check_libraries() {
    local needed
    needed="$(objdump -p "$1" | awk '/NEEDED/ && $2 !~ /^ld-linux/ { print $2 }' | sort | tr '\n' ' ')"
    if [ "$needed" != "$2" ]; then
        echo "$1 links unexpected libraries: $needed" >&2
        exit 1
    fi
}
check_libraries "$work/podman/bin/podman" 'libc.so.6 libseccomp.so.2 '
check_libraries "$work/conmon/bin/conmon" 'libc.so.6 libsystemd.so.0 '
check_libraries "$work/crun/crun" 'libc.so.6 libm.so.6 libseccomp.so.2 libsystemd.so.0 '

# The other tools (runc, netavark, aardvark-dns, pasta, catatonit, fuse-overlayfs) come from podman-static.
curl -fsSL -o "$work/static.tar.gz" \
    "https://github.com/mgoltzsche/podman-static/releases/download/v$PODMAN_VERSION/podman-linux-$arch.tar.gz"
echo "$static_sha256  $work/static.tar.gz" | sha256sum -c -
tar -xzf "$work/static.tar.gz" -C "$work"
install -m 0755 "$work/podman/bin/podman" "$work/$bundle/usr/local/bin/podman"
install -m 0755 "$work/conmon/bin/conmon" "$work/$bundle/usr/local/lib/podman/conmon"
install -m 0755 "$work/crun/crun" "$work/$bundle/usr/local/bin/crun"
make -C "$work/podman" install.man DESTDIR="$work/$bundle" PREFIX=/usr/local
# Optional rootless setup. It stays next to usr/ and etc/, so the install does not copy it.
install -m 0755 setup-rootless.sh "$work/$bundle/setup-rootless.sh"

# podman-static sets cgroupfs and file events, because its tools have no systemd support. Use the
# defaults of a systemd build instead: journald logs and events, and the systemd cgroup manager.
printf '# Settings are in containers.conf.d/10-podman.conf.\n' > "$work/$bundle/etc/containers/containers.conf"
# Use only the tools of this archive. Podman looks in /usr/bin and /usr/libexec first, where an
# older crun or conmon of the distribution can be.
mkdir -p "$work/$bundle/etc/containers/containers.conf.d"
cat > "$work/$bundle/etc/containers/containers.conf.d/10-podman.conf" <<'CONF'
[containers]
init_path = "/usr/local/lib/podman/catatonit"
# Applies only to the k8s-file log driver. journald rotates its own files.
log_size_max = 52428800

[engine]
cgroup_manager = "systemd"
events_logger = "journald"
conmon_path = ["/usr/local/lib/podman/conmon"]
helper_binaries_dir = ["/usr/local/libexec/podman", "/usr/local/lib/podman"]
runtime = "crun"

[engine.runtimes]
crun = ["/usr/local/bin/crun"]
runc = ["/usr/local/bin/runc"]
CONF
# fuse-overlayfs is for rootless containers. Rootful containers use the kernel overlay.
rm -f "$work/$bundle/etc/containers/storage.conf.d/00-podman-static.conf"
cat > "$work/$bundle/BUILD-INFO" <<INFO
Podman $PODMAN_VERSION, $arch
podman: built from https://github.com/containers/podman/tree/v$PODMAN_VERSION with Go $GO_VERSION and the systemd build tag
conmon: built from https://github.com/containers/conmon/tree/v$CONMON_VERSION with journald support
crun: built from https://github.com/containers/crun/tree/$CRUN_VERSION with systemd support
other tools: https://github.com/mgoltzsche/podman-static/releases/tag/v$PODMAN_VERSION (sha256 $static_sha256)
INFO

mkdir -p dist
tar -czf "dist/$bundle.tar.gz" -C "$work" "$bundle"
(cd dist && sha256sum "$bundle.tar.gz" > "$bundle.tar.gz.sha256")
cat "dist/$bundle.tar.gz.sha256"
