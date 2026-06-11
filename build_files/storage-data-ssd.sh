#!/bin/bash
set -oue pipefail

BASE="/var/mnt/data-ssd/system-storage"

if [ ! -d "/var/mnt/data-ssd" ]; then
    echo "INFO: /var/mnt/data-ssd not found. Skipping configuration (will run on boot)."
else
    mkdir -p "${BASE}/tmp" "${BASE}/containers/storage" "${BASE}/user-containers"
    chmod 1777 "${BASE}/tmp"
    chmod 755 "${BASE}" "${BASE}/containers" "${BASE}/user-containers"
    
    chown root:root "${BASE}" "${BASE}/tmp" "${BASE}/containers/storage"
    
    for user_home in /home/*; do
        [ -d "${user_home}" ] || continue
        username="$(basename "${user_home}")"
        USER_TMP="${BASE}/tmp/devcontainercli-${username}"
        USER_STORAGE="${BASE}/user-containers/${username}"
        mkdir -p "${USER_TMP}" "${USER_STORAGE}"
        chown "${username}:${username}" "${USER_TMP}" "${USER_STORAGE}"
    done

    if command -v chcon &>/dev/null; then
        chcon -Rt container_tmp_t "${BASE}/tmp" 2>/dev/null || true
        chcon -Rt container_var_lib_t "${BASE}/containers/storage" 2>/dev/null || true
        chcon -Rt container_var_lib_t "${BASE}/user-containers" 2>/dev/null || true
    fi
fi

cat > /etc/profile.d/data-ssd-storage.sh <<'EOF'
DATA_SSD_BASE="/var/mnt/data-ssd/system-storage"
DATA_SSD_TMP="${DATA_SSD_BASE}/tmp"
if [ -d "/var/mnt/data-ssd" ]; then
    export TMPDIR="${DATA_SSD_TMP}" TEMP="${TMPDIR}" TMP="${TMPDIR}"
    export BUILDAH_TMPDIR="${TMPDIR}" CONTAINERS_STORAGE_TMPDIR="${TMPDIR}"
fi
EOF

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

mkdir -p /etc/skel/.config/containers
cat > /etc/skel/.config/containers/storage.conf <<'EOF'
[storage]
driver = "overlay"
[storage.options]
pull_options = {enable_partial_images = "true", use_hard_links = "false"}
EOF

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

mkdir -p /usr/bin
cat > /usr/bin/init-data-ssd-storage.sh <<'SCRIPT_EOF'
#!/bin/bash
set -euo pipefail
BASE="/var/mnt/data-ssd/system-storage"
if [ ! -d "/var/mnt/data-ssd" ]; then exit 0; fi
echo "Initializing data-ssd..."
mkdir -p "${BASE}/tmp" "${BASE}/containers/storage" "${BASE}/user-containers"
chmod 1777 "${BASE}/tmp"
chmod 755 "${BASE}/containers" "${BASE}/user-containers"
for user_home in /home/*; do
    [ -d "${user_home}" ] || continue
    username="$(basename "${user_home}")"
    USER_TMP="${BASE}/tmp/devcontainercli-${username}"
    USER_STORAGE="${BASE}/user-containers/${username}"
    mkdir -p "${USER_TMP}" "${USER_STORAGE}"
    chown "${username}:${username}" "${USER_TMP}" "${USER_STORAGE}"
done
if command -v chcon &>/dev/null; then
    chcon -Rt container_tmp_t "${BASE}/tmp" 2>/dev/null || true
    chcon -Rt container_var_lib_t "${BASE}/containers/storage" 2>/dev/null || true
    chcon -Rt container_var_lib_t "${BASE}/user-containers" 2>/dev/null || true
fi
if command -v semanage &>/dev/null; then
    semanage fcontext -a -t container_tmp_t "/var/mnt/data-ssd/system-storage/tmp(/.*)?" 2>/dev/null || true
    semanage fcontext -a -t container_var_lib_t "/var/mnt/data-ssd/system-storage/containers(/.*)?" 2>/dev/null || true
    semanage fcontext -a -t container_var_lib_t "/var/mnt/data-ssd/system-storage/user-containers(/.*)?" 2>/dev/null || true
    restorecon -Rv /var/mnt/data-ssd/system-storage 2>/dev/null || true
fi
echo "✓ Done"
SCRIPT_EOF
chmod +x /usr/bin/init-data-ssd-storage.sh

systemctl enable data-ssd-init.service

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

echo "Storage configuration complete."