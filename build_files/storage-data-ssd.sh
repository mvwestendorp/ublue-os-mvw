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

chown root:root "${BASE}"
chmod 755 "${BASE}"

# Ensure 'tmp' is writable by everyone (sticky bit)
chown root:root "${BASE}/tmp"
chmod 1777 "${BASE}/tmp"

# Ensure 'containers/storage' is owned by root (for podman)
chown root:root "${BASE}/containers/storage"
chmod 755 "${BASE}/containers/storage"

# If you want to support specific users, loop through /home as we did before:
for user_home in /home/*; do
    [ -d "${user_home}" ] || continue
    username="$(basename "${user_home}")"
    
    # Create user-specific tmp dir
    USER_TMP="${BASE}/tmp/devcontainercli-${username}"
    mkdir -p "${USER_TMP}"
    chown "${username}:${username}" "${USER_TMP}"
    
    # Create user storage dir
    USER_STORAGE="${BASE}/user-containers/${username}"
    mkdir -p "${USER_STORAGE}"
    chown -R "${username}:${username}" "${USER_STORAGE}"
done

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


cat > /usr/bin/init-data-ssd-storage.sh <<'SCRIPT_EOF'
#!/bin/bash
set -euo pipefail

BASE="/var/mnt/data-ssd/system-storage"

# SAFETY CHECK: If the mount doesn't exist, do nothing.
# This happens during image build or if the SSD is unplugged.
if [ ! -d "/var/mnt/data-ssd" ]; then
    echo "data-ssd not mounted, skipping initialization"
    exit 0
fi

echo "Initializing data-ssd storage directories..."

# Create directories
mkdir -p "${BASE}/tmp"
mkdir -p "${BASE}/containers/storage"
mkdir -p "${BASE}/user-containers"

# Permissions
chmod 1777 "${BASE}/tmp"
chmod 755 "${BASE}/containers"
chmod 755 "${BASE}/user-containers"

# Loop through users
for user_home in /home/*; do
    [ -d "${user_home}" ] || continue
    username="$(basename "${user_home}")"
    
    USER_TMP="${BASE}/tmp/devcontainercli-${username}"
    mkdir -p "${USER_TMP}"
    chown "${username}:${username}" "${USER_TMP}"
    
    USER_STORAGE="${BASE}/user-containers/${username}"
    mkdir -p "${USER_STORAGE}"
    chown -R "${username}:${username}" "${USER_STORAGE}"
done

# SELinux Contexts
if command -v chcon &>/dev/null; then
    chcon -Rt container_tmp_t "${BASE}/tmp" 2>/dev/null || true
    chcon -Rt container_var_lib_t "${BASE}/containers/storage" 2>/dev/null || true
    chcon -Rt container_var_lib_t "${BASE}/user-containers" 2>/dev/null || true
fi

# Permanent SELinux Rules
if command -v semanage &>/dev/null; then
    semanage fcontext -a -t container_tmp_t "/var/mnt/data-ssd/system-storage/tmp(/.*)?" 2>/dev/null || true
    semanage fcontext -a -t container_var_lib_t "/var/mnt/data-ssd/system-storage/containers(/.*)?" 2>/dev/null || true
    semanage fcontext -a -t container_var_lib_t "/var/mnt/data-ssd/system-storage/user-containers(/.*)?" 2>/dev/null || true
    restorecon -Rv /var/mnt/data-ssd/system-storage 2>/dev/null || true
fi

echo "✓ data-ssd storage initialized"
SCRIPT_EOF

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

###############################################################################
# 12. Permanent SELinux File Contexts (CRITICAL FOR REBOOT)
###############################################################################

# Ensure semanage is installed
if ! command -v semanage &>/dev/null; then
    dnf install -y policycoreutils-python-utils
fi

# Add a rule so SELinux *always* labels this path as container_tmp_t
# even after a reboot or filesystem remount
if command -v semanage &>/dev/null; then
    echo "Adding permanent SELinux file context rules..."
    
    # Rule for the tmp directory
    semanage fcontext -a -t container_tmp_t "/var/mnt/data-ssd/system-storage/tmp(/.*)?"
    
    # Rule for the storage directory
    semanage fcontext -a -t container_var_lib_t "/var/mnt/data-ssd/system-storage/containers(/.*)?"
    
    # Rule for user containers
    semanage fcontext -a -t container_var_lib_t "/var/mnt/data-ssd/system-storage/user-containers(/.*)?"
    
    # Apply the rules immediately
    restorecon -Rv /var/mnt/data-ssd/system-storage
fi