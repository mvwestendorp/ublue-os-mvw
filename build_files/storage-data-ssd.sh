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
ExecStart=/usr/bin/init-data-ssd-storage.sh

[Install]
WantedBy=multi-user.target
EOF

###############################################################################
# 6. Initialization script
###############################################################################

mkdir -p /usr/bin

cat > /usr/bin/init-data-ssd-storage.sh <<'EOF'
#!/bin/bash

set -euo pipefail

BASE="/var/mnt/data-ssd/system-storage"
TMP_DIR="${BASE}/tmp"

if [ ! -d "/var/mnt/data-ssd" ]; then
    echo "data-ssd not mounted, skipping initialization"
    exit 0
fi

echo "Initializing data-ssd storage directories..."

# Ensure base directories exist
mkdir -p "${TMP_DIR}"
mkdir -p "${BASE}/containers/storage"
mkdir -p "${BASE}/user-containers"

# Set base permissions
chmod 1777 "${TMP_DIR}"
chmod 755 "${BASE}/containers"
chmod 755 "${BASE}/user-containers"

# CRITICAL FIX: Create user-specific temp directories for all existing users
# and set ownership so VS Code/DevContainers can write there.
for user_home in /home/*; do
    [ -d "${user_home}" ] || continue

    username="$(basename "${user_home}")"
    
    # Create the specific devcontainer temp dir for this user
    USER_TMP="${TMP_DIR}/devcontainercli-${username}"
    mkdir -p "${USER_TMP}"
    
    # Set ownership to the user
    chown -R "${username}:${username}" "${USER_TMP}"
    
    # Also ensure the parent tmp dir allows user access (sticky bit handles deletion)
    # But ensure the user can traverse
    chmod 755 "${TMP_DIR}" 
    
    # Create user storage dir if needed
    USER_STORAGE="${BASE}/user-containers/${username}"
    mkdir -p "${USER_STORAGE}"
    chown -R "${username}:${username}" "${USER_STORAGE}"
done

# Handle the current user if running interactively (optional safety net)
if [ -n "${USER:-}" ] && [ -d "/home/${USER}" ]; then
    USER_TMP="${TMP_DIR}/devcontainercli-${USER}"
    mkdir -p "${USER_TMP}"
    chown -R "${USER}:${USER}" "${USER_TMP}"
fi

echo "✓ data-ssd storage initialized"
EOF

chmod +x /usr/bin/init-data-ssd-storage.sh

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

###############################################################################
# 10. SELinux Context Fix
###############################################################################

# Ensure the tmp directory has a context allowing user writes
# container_tmp_t is usually safe for container-related temp files
if command -v chcon &>/dev/null; then
    echo "Setting SELinux contexts..."
    chcon -Rt container_tmp_t "${BASE}/tmp" 2>/dev/null || true
    chcon -Rt container_var_lib_t "${BASE}/containers/storage" 2>/dev/null || true
    chcon -Rt container_var_lib_t "${BASE}/user-containers" 2>/dev/null || true
fi
###############################################################################
# 11. Run Directory Setup
###############################################################################

mkdir -p /run/containers/storage
chmod 700 /run/containers/storage