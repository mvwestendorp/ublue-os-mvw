#!/bin/bash
# Configure system to use data-ssd for heavy storage operations

set -ouex pipefail

echo "Configuring data-ssd storage for containers and caches..."

# Note: This configuration assumes data-ssd is a ZFS dataset mounted at /var/mnt/data-ssd
# ZFS automatically handles mounting via zfs-mount.service

# 1. System-wide environment variables for build/temp directories
cat > /etc/profile.d/data-ssd-storage.sh <<'EOF'
# Use data-ssd for temporary build files (if available)
if [ -d "/var/mnt/data-ssd" ]; then
    export TMPDIR="/var/mnt/data-ssd/system-storage/tmp"
    export TEMP="$TMPDIR"
    export TMP="$TMPDIR"
    export BUILDAH_TMPDIR="$TMPDIR"
    export CONTAINERS_STORAGE_TMPDIR="$TMPDIR"
fi
EOF

# 2. System containers storage configuration
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

# 3. User containers storage template for ~/.config/containers/storage.conf
mkdir -p /etc/skel/.config/containers
cat > /etc/skel/.config/containers/storage.conf <<'EOF'
[storage]
driver = "overlay"
graphroot = "/var/mnt/data-ssd/system-storage/user-containers/$USER/storage"

[storage.options]
pull_options = {enable_partial_images = "true", use_hard_links = "false"}
EOF

# 4. Create systemd service to initialize data-ssd directories on boot
cat > /etc/systemd/system/data-ssd-init.service <<'EOF'
[Unit]
Description=Initialize data-ssd storage directories
After=local-fs.target zfs-mount.service
ConditionPathExists=/var/mnt/data-ssd
RequiresMountsFor=/var/mnt/data-ssd

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/init-data-ssd-storage.sh

[Install]
WantedBy=multi-user.target
EOF

# 5. Create the initialization script
mkdir -p /usr/local/bin
cat > /usr/local/bin/init-data-ssd-storage.sh <<'EOF'
#!/bin/bash
# Initialize data-ssd storage structure

set -e

BASE="/var/mnt/data-ssd/system-storage"

if [ ! -d "/var/mnt/data-ssd" ]; then
    echo "data-ssd not mounted, skipping initialization"
    exit 0
fi

echo "Initializing data-ssd storage directories..."

# Create base directory structure
mkdir -p "$BASE"/{tmp,containers/storage,user-containers}

# Set proper permissions
chmod 1777 "$BASE/tmp"
chmod 755 "$BASE/containers"
chmod 755 "$BASE/user-containers"

# Create per-user directories for existing users
for user_home in /home/*; do
    if [ -d "$user_home" ]; then
        username=$(basename "$user_home")
        user_storage="$BASE/user-containers/$username"

        if [ ! -d "$user_storage" ]; then
            mkdir -p "$user_storage"
            chown -R "$username:$username" "$user_storage" 2>/dev/null || true
        fi
    fi
done

echo "✓ data-ssd storage initialized"
EOF

chmod +x /usr/local/bin/init-data-ssd-storage.sh

# 6. Enable the service (will only run if /var/mnt/data-ssd exists)
systemctl enable data-ssd-init.service

# 7. Create bind mount units for package caches (optional but helpful)
cat > /etc/systemd/system/var-cache-dnf.mount <<'EOF'
[Unit]
Description=DNF cache on data-ssd
After=data-ssd-init.service
ConditionPathExists=/var/mnt/data-ssd/system-storage/cache-dnf
RequiresMountsFor=/var/mnt/data-ssd

[Mount]
What=/var/mnt/data-ssd/system-storage/cache-dnf
Where=/var/cache/dnf
Type=none
Options=bind

[Install]
WantedBy=multi-user.target
EOF

# Note: We don't enable the mount units by default since they require the cache
# directories to exist. Users can enable them manually if desired.

echo "✓ data-ssd storage configuration complete"
