#!/bin/bash
# Sets versions.env to the latest podman-static release, if it is newer than PODMAN_VERSION.
# Prints the new Podman version, or nothing if versions.env is up to date.
# It needs curl, jq, gpg, and sha256sum.
set -euo pipefail

source ./versions.env
# The signing key of podman-static (see versions.env).
key=0CCF102C4F95D89E583FF1D4F8B5AF50344BB503

tag="$(curl -fsSL https://api.github.com/repos/mgoltzsche/podman-static/releases/latest | jq -r .tag_name)"
version="${tag#v}"
if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Unexpected podman-static tag: $tag" >&2
    exit 1
fi
# Do nothing if the release is not newer, for example a patch release of an older Podman series.
if [ "$(printf '%s\n' "$PODMAN_VERSION" "$version" | sort -V | tail -n 1)" = "$PODMAN_VERSION" ]; then
    exit 0
fi

dockerfile="$(curl -fsSL "https://raw.githubusercontent.com/mgoltzsche/podman-static/$tag/Dockerfile")"
conmon="$(sed -n 's/^ARG CONMON_VERSION=v\([0-9.]*\)$/\1/p' <<<"$dockerfile")"
crun="$(sed -n 's/^ARG CRUN_VERSION=\([0-9.]*\)$/\1/p' <<<"$dockerfile")"
test -n "$conmon" && test -n "$crun"

# The latest Go patch release of the Go minor version in Podman's go.mod.
go_minor="$(curl -fsSL "https://raw.githubusercontent.com/containers/podman/$tag/go.mod" |
    sed -n 's/^go \([0-9]*\.[0-9]*\).*/\1/p')"
test -n "$go_minor"
go="$(curl -fsSL 'https://go.dev/dl/?mode=json&include=all' |
    jq -r --arg prefix "go$go_minor." '.[] | select(.stable) | .version | select(startswith($prefix)) | ltrimstr("go")' |
    sort -V | tail -n 1)"
test -n "$go"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export GNUPGHOME="$work/gnupg"
mkdir -m 0700 "$GNUPGHOME"
gpg --batch --quiet --keyserver hkps://keyserver.ubuntu.com --recv-keys "$key"
declare -A sha256
for arch in amd64 arm64; do
    url="https://github.com/mgoltzsche/podman-static/releases/download/$tag/podman-linux-$arch.tar.gz"
    curl -fsSL -o "$work/$arch.tar.gz" "$url"
    curl -fsSL -o "$work/$arch.tar.gz.asc" "$url.asc"
    # VALIDSIG ends with the fingerprint of the primary key.
    gpg --batch --status-fd 1 --verify "$work/$arch.tar.gz.asc" "$work/$arch.tar.gz" 2>/dev/null |
        grep -q "^\[GNUPG:\] VALIDSIG .* $key\$"
    sha256[$arch]="$(sha256sum "$work/$arch.tar.gz" | cut -d ' ' -f 1)"
done

sed -i \
    -e "s/^PODMAN_VERSION=.*/PODMAN_VERSION=$version/" \
    -e "s/^CONMON_VERSION=.*/CONMON_VERSION=$conmon/" \
    -e "s/^CRUN_VERSION=.*/CRUN_VERSION=$crun/" \
    -e "s/^GO_VERSION=.*/GO_VERSION=$go/" \
    -e "s/^PODMAN_STATIC_SHA256_amd64=.*/PODMAN_STATIC_SHA256_amd64=${sha256[amd64]}/" \
    -e "s/^PODMAN_STATIC_SHA256_arm64=.*/PODMAN_STATIC_SHA256_arm64=${sha256[arm64]}/" \
    versions.env
echo "$version"
