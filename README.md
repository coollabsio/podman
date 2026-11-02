# Podman for Coolify Nodes

Coolify installs this Podman on every Node, so all Nodes run the same Podman version, whatever their distribution ships.

Each release has one archive for each architecture:

- `podman-linux-amd64.tar.gz`
- `podman-linux-arm64.tar.gz`
- `SHA256SUMS`

## What the archive contains

- `podman`, built from the [Podman release](https://github.com/containers/podman/releases) with the `systemd` build tag. Health check timers need it.
- `crun`, `conmon`, `netavark`, `aardvark-dns`, `pasta`, `catatonit`, the systemd units, and the configuration files from the static build of [podman-static](https://github.com/mgoltzsche/podman-static) with the same version.

Two settings differ from podman-static:

- `containers.conf.d/10-coolify-podman.conf` sets the paths of `crun`, `runc`, `conmon`, and the helper tools of the archive, so an older version from the distribution is not used. It also sets `log_driver = "k8s-file"`, because the static `conmon` cannot write to journald.
- The `fuse-overlayfs` storage setting is removed, so rootful containers use the kernel overlay.

`podman` needs glibc 2.34 or later and `libseccomp.so.2`. It loads libsystemd at run time. It works on Ubuntu 22.04 and later, Debian 12 and later, and RHEL 9 and later. It does not work on RHEL 8 or Alpine.

## Install

```sh
arch=amd64 # or arm64
curl -fsSLO "https://github.com/coollabsio/podman/releases/download/<tag>/podman-linux-$arch.tar.gz"
sha256sum -c --ignore-missing <(curl -fsSL "https://github.com/coollabsio/podman/releases/download/<tag>/SHA256SUMS")
tar -xzf "podman-linux-$arch.tar.gz"
sudo systemctl stop podman.socket podman.service 2>/dev/null || true
sudo cp -r "podman-linux-$arch/usr" "podman-linux-$arch/etc" /
sudo systemctl daemon-reload
sudo systemctl enable --now podman.socket
```

## Build a new version

1. Wait for the podman-static release of the new Podman version.
2. Verify the GPG signatures of its two archives (see `versions.env`).
3. In `versions.env`, set `PODMAN_VERSION` and the two `PODMAN_STATIC_SHA256_*` values. Set `GO_VERSION` if Podman needs a newer Go.
4. Open a pull request. CI builds both architectures and runs `smoke-test.sh`.
5. Merge it. CI publishes the release `v<PODMAN_VERSION>`, with the same tag as the Podman release.

A release is published once for each Podman version. To rebuild the same version, delete its release and tag, then run the workflow again. Coolify pins the SHA-256 of each archive, so also update the values in Coolify.

Build locally:

```sh
docker run --rm -v "$PWD:/work" -w /work ubuntu:22.04 bash build.sh
```

`smoke-test.sh` installs the archive on the host it runs on. Run it only on a disposable host or VM.
