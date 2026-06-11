# Data-SSD Storage Configuration

This OS image is configured to automatically use `/var/mnt/data-ssd` for heavy storage operations when available.

## What Gets Redirected

- **Container storage** (system & user): `/var/mnt/data-ssd/system-storage/containers/`
- **Build temporary files**: `/var/mnt/data-ssd/system-storage/tmp/`
- **User container storage**: `/var/mnt/data-ssd/system-storage/user-containers/$USER/`

## Prerequisites

Your data-ssd disk must be mounted at `/var/mnt/data-ssd`. This can be configured via:

### Option 1: Automatic mount via fstab

Add to `/etc/fstab`:
```
UUID=<your-uuid>  /var/mnt/data-ssd  auto  defaults,nofail  0  2
```

Find your UUID with:
```bash
lsblk -f
# or
blkid /dev/sdX1
```

### Option 2: Systemd mount unit

Create `/etc/systemd/system/var-mnt-data\x2dssd.mount`:
```ini
[Unit]
Description=Data SSD Mount

[Mount]
What=/dev/disk/by-uuid/<your-uuid>
Where=/var/mnt/data-ssd
Type=auto
Options=defaults

[Install]
WantedBy=multi-user.target
```

Then enable it:
```bash
sudo systemctl enable var-mnt-data\x2dssd.mount
```

## How It Works

1. **On boot**: The `data-ssd-init.service` systemd service runs after local filesystems are mounted
2. **If data-ssd exists**: Creates the directory structure with proper permissions
3. **Container operations**: Podman/Buildah automatically use the data-ssd for storage
4. **Build operations**: TMPDIR and related variables point to data-ssd

## Verification

After rebooting into the new OS image:

```bash
# Check if service ran successfully
systemctl status data-ssd-init.service

# Verify directory structure
ls -la /var/mnt/data-ssd/system-storage/

# Test Podman storage location
podman info --format '{{.Store.GraphRoot}}'
# Should output: /var/mnt/data-ssd/system-storage/containers/storage

# Check environment variables
echo $TMPDIR
# Should output: /var/mnt/data-ssd/system-storage/tmp
```

## Fallback Behavior

If `/var/mnt/data-ssd` is not mounted:
- The init service silently exits (no error)
- Environment variables are not set
- Containers use default storage locations
- Everything continues to work normally (using system disk)

## Manual User Setup

For existing users on the system, their container storage will automatically use the data-ssd on next container operation. The configuration is already in place via `/etc/skel/.config/containers/storage.conf`.

If you need to migrate existing user container storage:

```bash
# Stop all containers
podman stop --all

# Reset storage (WARNING: removes existing containers/images)
podman system reset

# Storage will now use data-ssd automatically
podman info --format '{{.Store.GraphRoot}}'
```

## Space Savings

Expected space freed on main system disk:
- Container images/layers: 10-50GB (varies by usage)
- Build artifacts: 1-5GB per build
- User containers: 5-20GB per user

## Troubleshooting

### Issue: Podman still uses old storage location

```bash
# Check current config
podman info --format '{{.Store.ConfigFile}}'

# Verify config file exists
cat ~/.config/containers/storage.conf

# Reset if needed (removes containers!)
podman system reset
```

### Issue: Permission denied on container operations

```bash
# Verify ownership
ls -la /var/mnt/data-ssd/system-storage/user-containers/$USER/

# Fix if needed
sudo chown -R $USER:$USER /var/mnt/data-ssd/system-storage/user-containers/$USER/
```

### Issue: Build fails with "no space left on device"

```bash
# Check data-ssd space
df -h /var/mnt/data-ssd

# Verify TMPDIR is set
echo $TMPDIR

# Clean up if needed
podman system prune -a --volumes
```
