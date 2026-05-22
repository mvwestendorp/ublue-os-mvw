#!/bin/bash
# Configure system to use data-ssd for heavy storage operations

set -oue pipefail

echo "Configuring data-ssd storage for containers and caches..."

# Note:
# Assumes data-ssd is mounted at:
#   /var/mnt/data-ssd
#
# This version fixes:
# - missing tmp directory races
# - invalid $USER expansion in TOML
# - boot ordering issues
# - safer handling when the SSD is unavailable

BASE="/var/mnt/data-ssd/system-storage"

###############################################################################
# 1. Ensure base directories exist immediately during image build
###############################################################################

mkdir -p "${BASE}/tmp"
mkdir -p "${BASE}/containers/storage"
mkdir -p "${BASE}/user-containers"

chmod 1777 "${BASE}/tmp"
chmod 755 "${BASE}/containers"
chmod 755 "${BASE}/user-containers"

###############################################################################
# 2. System-wide environment variables
###############################################################################

cat > /etc/profile.d/data-ssd-storage.sh <<'EOF'
# Use data-ssd for temporary build files (if available)

DATA_SSD_BASE="/var/mnt/data-ssd/system-storage"
DATA_SSD_TMP="${DATA_SSD_BASE}/tmp"

if [ -d "/var/mnt/data-ssd" ]; then
    # Ensure required directories exist
    mkdir -p "${DATA_SSD_TMP}" 2>/dev/null || true
    chmod 1777 "${DATA_SSD_TMP}" 2>/dev/null || true

    export TMPDIR="${DATA_SSD_TMP}"
    export TEMP="${TMPDIR}"
    export TMP="${TMPDIR}"

    export BUILDAH_TMPDIR="${TMPDIR}"
    export CONTAINERS_STORAGE_TMPDIR="${TMPDIR}"
fi
EOF

###############################################################################
# 3. System-wide containers storage configuration
###############################################################################

mkdir -p /etc/containers

cat > /etc/containers/storage.conf <<'EOF'
[storage]
driver = "overlay"
graphroot = "/var/mnt/data-ssd/system-storage/containers/storage"
runroot = "/run/containers/storage"

[storage.options]
pull_options = {enable_partial_images = "true", use_hard_links = "false"}

[storage.options.overlay]
mountopt = "nodev,metacopy=on"
mount_program = "/usr/bin/fuse-overlayfs"
EOF

###############################################################################
# 4. Per-user storage configuration template
###############################################################################

# NOTE:
# We intentionally do NOT use:
#   /user-containers/$USER/storage
# inside TOML because Podman does not expand shell variables there.
#
# Instead we use %U via systemd-style expansion in generated configs later,
# or simply rely on the system-wide graphroot.

mkdir -p /etc/skel/.config/containers

cat > /etc/skel/.config/containers/storage.conf <<'EOF'
[storage]
driver = "overlay"

[storage.options]
pull_options = {enable_partial_images = "true", use_hard_links = "false"}
EOF

###############################################################################
# 5. Boot-time initialization service
###############################################################################

cat > /etc/systemd/system/data-ssd-init.service <<'EOF'
[Unit]
Description=Initialize data-ssd storage directories
After=local-fs.target zfs-mount.service
Wants=zfs-mount.service
RequiresMountsFor=/var/mnt/data-ssd

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/init-data-ssd-storage.sh

[Install]
WantedBy=multi-user.target
EOF

###############################################################################
# 6. Initialization script
###############################################################################

mkdir -p /usr/local/bin

cat > /usr/local/bin/init-data-ssd-storage.sh <<'EOF'
#!/bin/bash

set -euo pipefail

BASE="/var/mnt/data-ssd/system-storage"

if [ ! -d "/var/mnt/data-ssd" ]; then
    echo "data-ssd not mounted, skipping initialization"
    exit 0
fi

echo "Initializing data-ssd storage directories..."

mkdir -p "${BASE}/tmp"
mkdir -p "${BASE}/containers/storage"
mkdir -p "${BASE}/user-containers"

chmod 1777 "${BASE}/tmp"
chmod 755 "${BASE}/containers"
chmod 755 "${BASE}/user-containers"

# Create per-user directories
for user_home in /home/*; do
    [ -d "${user_home}" ] || continue

    username="$(basename "${user_home}")"
    user_storage="${BASE}/user-containers/${username}"

    mkdir -p "${user_storage}"

    if id "${username}" >/dev/null 2>&1; then
        chown -R "${username}:${username}" "${user_storage}" || true
    fi
done

echo "✓ data-ssd storage initialized"
EOF

chmod +x /usr/local/bin/init-data-ssd-storage.sh

###############################################################################
# 7. Enable initialization service
###############################################################################

systemctl enable data-ssd-init.service

###############################################################################
# 8. Optional DNF cache bind mount
###############################################################################

cat > /etc/systemd/system/var-cache-dnf.mount <<'EOF'
[Unit]
Description=DNF cache on data-ssd
After=data-ssd-init.service
RequiresMountsFor=/var/mnt/data-ssd
ConditionPathExists=/var/mnt/data-ssd/system-storage/cache-dnf

[Mount]
What=/var/mnt/data-ssd/system-storage/cache-dnf
Where=/var/cache/dnf
Type=none
Options=bind

[Install]
WantedBy=multi-user.target
EOF

###############################################################################
# 9. Final verification
###############################################################################

echo "Verifying data-ssd configuration..."

if [ -d "${BASE}/tmp" ]; then
    echo "✓ tmp directory exists"
else
    echo "WARNING: tmp directory missing"
fi

echo "✓ data-ssd storage configuration complete"
