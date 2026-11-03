#!/bin/bash
# Installs dist/podman-linux-<arch>.tar.gz on this host and checks that a rootful container
# runs and that its health check runs on a systemd timer. Run it as root on a disposable host.
set -euo pipefail

source ./versions.env
arch="$(dpkg --print-architecture)"
bundle="podman-linux-$arch"
work="$(mktemp -d)"

tar -xzf "dist/$bundle.tar.gz" -C "$work"
systemctl stop podman.socket podman.service 2>/dev/null || true
cp -r "$work/$bundle/usr" "$work/$bundle/etc" /
systemctl daemon-reload
/usr/local/bin/podman --version | grep -qxF "podman version $PODMAN_VERSION"

podman=/usr/local/bin/podman
"$podman" info --format '{{.Host.LogDriver}} {{.Host.EventLogger}} {{.Host.CgroupManager}} {{.Store.GraphDriverName}} {{.Host.DatabaseBackend}} {{.Host.OCIRuntime.Path}} {{.Host.Conmon.Path}}' |
    grep -qx 'journald journald systemd overlay sqlite /usr/local/bin/crun /usr/local/lib/podman/conmon'
"$podman" run --rm --memory 64m docker.io/library/alpine:3 cat /sys/fs/cgroup/memory.max | grep -qx 67108864
"$podman" run -d --name smoke-test --health-cmd 'test -f /tmp/healthy' --health-interval 2s --health-retries 1 \
    docker.io/library/alpine:3 sh -c 'touch /tmp/healthy; sleep 300' >/dev/null
trap '"$podman" rm -f -t 0 smoke-test >/dev/null 2>&1 || true' EXIT

wait_for_health() {
    for _ in $(seq 1 30); do
        if [ "$("$podman" inspect smoke-test --format '{{.State.Health.Status}}')" = "$1" ]; then
            return 0
        fi
        sleep 1
    done
    echo "The health status did not become $1." >&2
    "$podman" inspect smoke-test --format '{{json .State.Health}}' >&2
    return 1
}
wait_for_health healthy
"$podman" exec smoke-test sh -c 'echo smoke-test-log > /proc/1/fd/1'
"$podman" logs smoke-test | grep -qx smoke-test-log
systemctl is-active --quiet "libpod-$("$podman" inspect smoke-test --format '{{.Id}}').scope"
man -w podman >/dev/null 2>&1 || test -f /usr/local/share/man/man1/podman.1
"$podman" exec smoke-test rm /tmp/healthy
wait_for_health unhealthy
echo "Podman $PODMAN_VERSION runs containers and their health checks."
