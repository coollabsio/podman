#!/bin/bash
# Optional. Prepares this host so that a user can run rootless Podman containers.
# Run it as root once for each user: sudo ./setup-rootless.sh <user>
set -euo pipefail

user="${1:-}"
if [ -z "$user" ]; then
    echo "Usage: sudo $0 <user>" >&2
    exit 1
fi
if [ "$(id -u)" -ne 0 ]; then
    echo "Run this script as root." >&2
    exit 1
fi
id "$user" >/dev/null

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

# Give the user 65536 subordinate IDs after the highest range in use, if it has none.
for file in /etc/subuid /etc/subgid; do
    touch "$file"
    if ! grep -q "^$user:" "$file"; then
        start="$(awk -F: 'BEGIN { next_id = 100000 } { end = $2 + $3; if (end > next_id) next_id = end } END { print next_id }' "$file")"
        echo "$user:$start:65536" >> "$file"
        echo "Added $user:$start:65536 to $file."
    fi
done

# The AppArmor profile of Ubuntu applies only to /usr/bin/podman. Without this change,
# /usr/local/bin/podman cannot run again in the user namespace ("reexec: Permission denied").
profile=/etc/apparmor.d/podman
if [ -f "$profile" ] && grep -q '^profile podman /usr/bin/podman ' "$profile"; then
    sed -Ei 's!^profile podman /usr/bin/podman !profile podman /usr/{bin,local/bin}/podman !' "$profile"
    apparmor_parser -r "$profile"
    echo "Changed $profile to also apply to /usr/local/bin/podman."
fi

echo "$user can run rootless containers. Log in again as $user, then run: podman run --rm docker.io/library/alpine:3 id"
