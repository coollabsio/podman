# Podman with systemd support

Up-to-date Podman for Linux distributions that ship an old Podman, such as Ubuntu 24.04 LTS (Podman 4.9.3).

Each release has the same version as the [Podman release](https://github.com/containers/podman/releases) that it is built from. One archive works on all supported distributions, so every host runs the same Podman version.

Why not [podman-static](https://github.com/mgoltzsche/podman-static)? Its tools are built without systemd support: health checks never run on a timer, logs cannot go to journald, and containers cannot use the systemd cgroup manager. This build adds systemd support to `podman`, `conmon`, and `crun`, and keeps the other tools of podman-static.

## Supported systems

- Architectures: `amd64` and `arm64`
- Linux with systemd, glibc 2.34 or later, and `libseccomp.so.2`
- Tested on Ubuntu 24.04. It also works on Ubuntu 22.04 and later, Debian 12 and later, and RHEL 9 and later (and its rebuilds).
- It does not work on RHEL 8 (glibc 2.28) or Alpine (musl).

## Install

Replace `<version>` with a release tag, for example `v6.1.4`.

```sh
version=<version>
arch=amd64 # or arm64
curl -fsSLO "https://github.com/coollabsio/podman/releases/download/$version/podman-linux-$arch.tar.gz"
curl -fsSLO "https://github.com/coollabsio/podman/releases/download/$version/SHA256SUMS"
sha256sum -c --ignore-missing SHA256SUMS
tar -xzf "podman-linux-$arch.tar.gz"
sudo systemctl stop podman.socket podman.service 2>/dev/null || true
sudo cp -r "podman-linux-$arch/usr" "podman-linux-$arch/etc" /
sudo systemctl daemon-reload
sudo systemctl enable --now podman.socket
podman --version
```

The files go to `/usr/local` and `/etc/containers`. A Podman from the distribution in `/usr/bin` can stay installed: `/usr/local/bin` comes first in `PATH`, and the configuration uses only the tools of this archive.

Optional: to use Docker clients with Podman, link the socket:

```sh
sudo ln -sfn /run/podman/podman.sock /var/run/docker.sock
```

### Update

Stop all containers, then do the install steps again with the new version.

Podman 5 and later cannot read the BoltDB database of Podman 4 (`/var/lib/containers/storage/libpod/bolt_state.db`). Remove the containers of the old Podman before you install, or use a clean host.

## What the archive contains

- `podman`, built from the Podman release with the `systemd` build tag. Health check timers and `sd_notify` need it.
- `conmon`, built with journald support, and `crun`, built with systemd support. They have the same versions as in podman-static.
- `runc`, `netavark`, `aardvark-dns`, `pasta`, `catatonit`, `fuse-overlayfs`, the systemd units, and the configuration files from podman-static with the same version.
- The Podman man pages.

The binaries link only glibc, `libseccomp.so.2`, and `libsystemd.so.0`.

The configuration is in `etc/containers/containers.conf.d/10-podman.conf`:

- journald for container logs and events, and the systemd cgroup manager, as in a distribution package.
- The paths of `crun`, `runc`, `conmon`, and the helper tools of the archive, so an older version from the distribution is not used.
- `log_size_max = 52428800` (50 MiB) for containers that use the `k8s-file` log driver.

The `fuse-overlayfs` storage setting of podman-static is removed, so rootful containers use the kernel overlay.

## Known limits

- Rootless containers need `newuidmap` and `newgidmap` (package `uidmap` on Debian and Ubuntu) and a range in `/etc/subuid` and `/etc/subgid`. See the [podman-static README](https://github.com/mgoltzsche/podman-static#host-configuration), which also explains an AppArmor fix for rootless Podman on Ubuntu.
- Containers that were created with the `cgroupfs` cgroup manager of an older install keep it. Create them again to use the systemd cgroup manager.

## License

Podman and the tools in the archive have their own licenses. See the [Podman](https://github.com/containers/podman) and [podman-static](https://github.com/mgoltzsche/podman-static) repositories.
