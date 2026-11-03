#!/bin/bash
# Optional. Prepares this host for rootless Podman containers. Run it once as root: sudo ./setup-rootless.sh
# useradd gives each new user a range in /etc/subuid and /etc/subgid, as with a distribution Podman.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Run this script as root." >&2
    exit 1
fi

# newuidmap and newgidmap must be setuid root, so they come from the distribution.
if ! command -v newuidmap >/dev/null || ! command -v newgidmap >/dev/null; then
    if command -v apt-get >/dev/null; then
        DEBIAN_FRONTEND=noninteractive apt-get update -q
        DEBIAN_FRONTEND=noninteractive apt-get install -y -q uidmap
    elif command -v dnf >/dev/null; then
        dnf install -y shadow-utils
    elif command -v yum >/dev/null; then
        yum install -y shadow-utils
    else
        echo "Install newuidmap and newgidmap, then run this script again." >&2
        exit 1
    fi
fi

# The AppArmor profile of Ubuntu applies only to /usr/bin/podman. Without this change,
# /usr/local/bin/podman cannot run again in the user namespace ("reexec: Permission denied").
profile=/etc/apparmor.d/podman
if [ -f "$profile" ] && grep -q '^profile podman /usr/bin/podman ' "$profile"; then
    sed -Ei 's!^profile podman /usr/bin/podman !profile podman /usr/{bin,local/bin}/podman !' "$profile"
    apparmor_parser -r "$profile"
    echo "Changed $profile to also apply to /usr/local/bin/podman."
fi

touch /etc/subuid /etc/subgid
missing="$(getent passwd | awk -F: '$3 >= 1000 && $3 < 60000 { print $1 }' | while read -r user; do
    grep -q "^$user:" /etc/subuid && grep -q "^$user:" /etc/subgid || echo "$user"
done)"
if [ -n "$missing" ]; then
    echo "These users have no range in /etc/subuid or /etc/subgid. Add one for each user that runs rootless containers:"
    for user in $missing; do
        echo "  usermod --add-subuids <first>-<last> --add-subgids <first>-<last> $user"
    done
fi
echo "This host can run rootless containers."
