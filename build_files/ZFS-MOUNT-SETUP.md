# ZFS Mount Setup for data-ssd

Your `data-ssd` is a ZFS dataset, which is already configured to mount automatically at `/var/mnt/data-ssd`.

## Current Setup

```bash
# Check ZFS dataset
zfs list data-ssd

# Verify mount properties
zfs get mountpoint,canmount data-ssd
```

## ZFS is Already Persistent!

ZFS stores mount configuration in the dataset properties, so **no additional setup is needed**. The mount will persist across reboots automatically when:
1. ZFS services are enabled (they are by default)
2. The dataset `canmount` property is set to `on` (it is)
3. The `mountpoint` property is set (it's `/var/mnt/data-ssd`)

## Verification After Reboot

After deploying the new OS image and rebooting:

```bash
# 1. Check if ZFS dataset is mounted
zfs list data-ssd
findmnt /var/mnt/data-ssd

# 2. Verify storage initialization service ran
systemctl status data-ssd-init.service

# 3. Check directory structure
ls -la /var/mnt/data-ssd/system-storage/

# 4. Verify Podman is using data-ssd
podman info --format '{{.Store.GraphRoot}}'
# Expected: /var/mnt/data-ssd/system-storage/containers/storage

# 5. Check environment variables
source /etc/profile.d/data-ssd-storage.sh
echo $TMPDIR
# Expected: /var/mnt/data-ssd/system-storage/tmp
```

## ZFS Service Dependencies

The systemd services are configured to wait for ZFS:
- `data-ssd-init.service` has `After=zfs-mount.service`
- This ensures directories are only created after ZFS mounts

## Troubleshooting

### Issue: Dataset not mounting on boot

```bash
# Check if ZFS services are enabled
systemctl status zfs-mount.service
systemctl status zfs.target

# Enable if needed
sudo systemctl enable zfs-mount.service

# Check dataset properties
zfs get mountpoint,canmount,mounted data-ssd

# Manually mount if needed
sudo zfs mount data-ssd
```

### Issue: Dataset is unmounted

```bash
# Mount it
sudo zfs mount data-ssd

# Check what's preventing auto-mount
zfs get all data-ssd | grep -E 'mount|canmount'
```

### Issue: Want to change the mountpoint

```bash
# Stop using the dataset
sudo systemctl stop data-ssd-init.service

# Unmount
sudo zfs unmount data-ssd

# Change mountpoint
sudo zfs set mountpoint=/new/path data-ssd

# Mount at new location
sudo zfs mount data-ssd

# Update OS configuration and rebuild image with new path
```

## ZFS Benefits for This Use Case

- **Compression**: ZFS can compress container layers (potential space savings)
- **Snapshots**: Easy to snapshot before major operations
- **Self-healing**: Automatic data integrity checking
- **No fstab needed**: Mount configuration stored in dataset

## Optional: Enable ZFS Compression

To save even more space:

```bash
# Enable lz4 compression (fast, good ratio for most data)
sudo zfs set compression=lz4 data-ssd

# Check compression ratio over time
zfs get compressratio data-ssd
```

This is especially effective for container images which often contain redundant data.
