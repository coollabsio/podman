# Podman with systemd support

Up-to-date Podman for Linux distributions that ship an old Podman, such as Ubuntu 24.04 LTS (Podman 4.9.3).

Each release has the same version as the [Podman release](https://github.com/containers/podman/releases) that it is built from. One archive works on all supported distributions, so every host runs the same Podman version.

Why not [podman-static](https://github.com/mgoltzsche/podman-static)? Its `podman` is built without systemd support, so health checks never run on a timer. This build adds systemd support and keeps the other tools of podman-static.

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
- `crun`, `runc`, `conmon`, `netavark`, `aardvark-dns`, `pasta`, `catatonit`, `fuse-overlayfs`, the systemd units, and the configuration files from podman-static with the same version.

These settings differ from podman-static:

- `etc/containers/containers.conf.d/10-coolify-podman.conf` sets the paths of `crun`, `runc`, `conmon`, and the helper tools of the archive, so an older version from the distribution is not used. It also sets `log_driver = "k8s-file"`, because the static `conmon` cannot write to journald.
- The `fuse-overlayfs` storage setting is removed, so rootful containers use the kernel overlay.

## Known limits

- Container logs use `k8s-file`, not journald. The log files have no size limit by default. To set one, add a file in `/etc/containers/containers.conf.d/`:

  ```toml
  [containers]
  log_size_max = 52428800
  ```

- Containers use the `cgroupfs` cgroup manager, because the static `crun` has no systemd support.
- Rootless containers need `newuidmap` and `newgidmap` (package `uidmap` on Debian and Ubuntu) and a range in `/etc/subuid` and `/etc/subgid`. See the [podman-static README](https://github.com/mgoltzsche/podman-static#host-configuration), which also explains an AppArmor fix for rootless Podman on Ubuntu.
- The archive has no man pages.

## Build a new version

1. Wait for the podman-static release of the new Podman version.
2. Verify the GPG signatures of its two archives (see `versions.env`).
3. In `versions.env`, set `PODMAN_VERSION` and the two `PODMAN_STATIC_SHA256_*` values. Set `GO_VERSION` if Podman needs a newer Go.
4. Open a pull request. CI builds both architectures on native runners and runs `smoke-test.sh`.
5. Merge it. CI publishes the release `v<PODMAN_VERSION>`.

A release is published once for each Podman version. To rebuild the same version, delete its release and tag, then run the workflow again. The checksums change, so tell users that pin them.

Build locally:

```sh
docker run --rm -v "$PWD:/work" -w /work ubuntu:22.04 bash build.sh
```

`smoke-test.sh` installs the archive on the host it runs on. Run it only on a disposable host or VM.

## License

Podman and the tools in the archive have their own licenses. See the [Podman](https://github.com/containers/podman) and [podman-static](https://github.com/mgoltzsche/podman-static) repositories.
