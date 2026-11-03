#!/bin/bash
# Builds dist/podman-linux-<arch>.tar.gz for the architecture of this machine.
# Run it in an ubuntu:22.04 container, so the binary needs only glibc 2.34 or later:
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
apt-get install -y -q --no-install-recommends gcc libc6-dev make pkg-config git curl ca-certificates jq \
    libseccomp-dev libsystemd-dev libapparmor-dev

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
# libsystemd is loaded at run time, so the binary works on any distribution with glibc 2.34 or later.
needed="$(objdump -p "$work/podman/bin/podman" | awk '/NEEDED/ && $2 !~ /^ld-linux/ { print $2 }' | sort | tr '\n' ' ')"
if [ "$needed" != "libc.so.6 libseccomp.so.2 " ]; then
    echo "podman links unexpected libraries: $needed" >&2
    exit 1
fi

# The other tools (crun, conmon, netavark, aardvark-dns, pasta, catatonit) come from podman-static.
curl -fsSL -o "$work/static.tar.gz" \
    "https://github.com/mgoltzsche/podman-static/releases/download/v$PODMAN_VERSION/podman-linux-$arch.tar.gz"
echo "$static_sha256  $work/static.tar.gz" | sha256sum -c -
tar -xzf "$work/static.tar.gz" -C "$work"
install -m 0755 "$work/podman/bin/podman" "$work/$bundle/usr/local/bin/podman"

# Use only the tools of this archive. Podman looks in /usr/bin and /usr/libexec first, where an
# older crun or conmon of the distribution can be. The static conmon cannot write to journald,
# which is the default log driver of a systemd build.
mkdir -p "$work/$bundle/etc/containers/containers.conf.d"
cat > "$work/$bundle/etc/containers/containers.conf.d/10-podman.conf" <<'CONF'
[containers]
log_driver = "k8s-file"
init_path = "/usr/local/lib/podman/catatonit"

[engine]
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
other tools: https://github.com/mgoltzsche/podman-static/releases/tag/v$PODMAN_VERSION (sha256 $static_sha256)
INFO

mkdir -p dist
tar -czf "dist/$bundle.tar.gz" -C "$work" "$bundle"
(cd dist && sha256sum "$bundle.tar.gz" > "$bundle.tar.gz.sha256")
cat "dist/$bundle.tar.gz.sha256"
