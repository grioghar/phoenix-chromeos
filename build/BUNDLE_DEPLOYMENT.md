# Phoenix Bundle Pipeline Deployment

This document describes how to deploy the automated bundle building pipeline on the build server (dockervm).

## Overview

The pipeline consists of three components:

1. **`make-bundle.sh`**: Builds a single bundle for a ChromeOS version
2. **`watch-versions.py`**: Monitors for new versions and triggers builds
3. **Phoenix server route**: Serves built bundles to devices

## Deployment Steps

### 1. Prepare the Build Server (dockervm)

Ensure you have:
- Docker installed and running
- Tools: `curl`, `python3`, `losetup`, `tar` (with xattrs support)
- At least 200 GB free disk space in `/root/brunch-build` (for recovery images)
- Sufficient space in `/root/phoenix-bundles` (bundles are ~1-2 GB each)

### 2. Copy Scripts to Build Server

```bash
ssh dockervm mkdir -p /root/phoenix-bundles /root/brunch-build/recovery
rsync -av /path/to/phoenix-chromeos/ /root/phoenix/
```

The repo should be mirrored with rsync (as already configured).

### 3. Install systemd Units

On dockervm:

```bash
sudo install -m 644 /root/phoenix/server/systemd/phoenix-bundles.service \
  /etc/systemd/system/phoenix-bundles.service

sudo install -m 644 /root/phoenix/server/systemd/phoenix-bundles.timer \
  /etc/systemd/system/phoenix-bundles.timer

sudo systemctl daemon-reload
sudo systemctl enable phoenix-bundles.timer
sudo systemctl start phoenix-bundles.timer
```

### 4. Update Phoenix Server

Restart the phoenix-server to enable the new bundle serving route:

```bash
ssh dockervm systemctl restart phoenix-server
```

The server will now serve bundles at:
- `GET /bundle/<version>.tar`
- `GET /bundle/<version>.sha256`

## Operation

### Manual Build

To manually build a bundle for a specific version:

```bash
ssh dockervm bash /root/phoenix/build/make-bundle.sh 16700.65.0 /root/phoenix-bundles
```

Output files:
- `/root/phoenix-bundles/16700.65.0.tar` - the bundle (1-2 GB)
- `/root/phoenix-bundles/16700.65.0.sha256` - SHA256 checksum
- `/root/phoenix-bundles/16700.65.0.manifest` - file list with hashes

### Check Build Status

```bash
ssh dockervm systemctl status phoenix-bundles.timer
ssh dockervm journalctl -u phoenix-bundles -f
```

### Monitor Disk Usage

```bash
ssh dockervm du -sh /root/brunch-build/recovery /root/phoenix-bundles
```

### Force a Check

To run the version watcher immediately (instead of waiting for the daily timer):

```bash
ssh dockervm /root/phoenix/build/watch-versions.py --repo-dir /root/phoenix --bundles-dir /root/phoenix-bundles --once
```

## Verification

### Test a Built Bundle

```bash
ssh dockervm bash /root/phoenix/build/verify-bundle.sh /root/phoenix-bundles/16700.65.0.tar
```

This compares against the known-good fixed image (if available).

### Manual Verification Steps

1. **Extract and inspect the tar**:
   ```bash
   tar -tf /root/phoenix-bundles/16700.65.0.tar | head -20
   ```

2. **Verify checksums**:
   ```bash
   ssh dockervm "cd /root/phoenix-bundles && sha256sum -c 16700.65.0.sha256"
   ```

3. **Check manifest**:
   ```bash
   ssh dockervm head -20 /root/phoenix-bundles/16700.65.0.manifest
   ```

## Troubleshooting

### "No rammus image for version X"

The version does not exist in Google's recovery list, or the JSON is stale. Check:
- `https://dl.google.com/dl/edgedl/chromeos/recovery/recovery2.json` in a browser
- Local cache: `ls /root/brunch-build/recovery/*.json`

### "Docker patch-android.sh failed"

The Docker build inside the container failed. Check logs:
```bash
ssh dockervm "VERBOSE=1 bash /root/phoenix/build/make-bundle.sh 16700.65.0 /root/phoenix-bundles 2>&1 | tail -50"
```

Ensure Docker has access to `/dev` and `/root/phoenix`.

### Bundle too large / small

Expected bundle sizes vary but are typically:
- 700-900 MB for rammus + reven of the same version
- Check with: `ls -lh /root/phoenix-bundles/*.tar`

### Systemd timer not running

Check:
```bash
ssh dockervm systemctl status phoenix-bundles.timer
ssh dockervm journalctl -u phoenix-bundles.timer
```

If the timer file is missing, reinstall it and reload:
```bash
sudo install -m 644 /root/phoenix/server/systemd/phoenix-bundles.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable phoenix-bundles.timer
sudo systemctl start phoenix-bundles.timer
```

## Monitoring Checklist

Daily checks (or via monitoring):

- [ ] Timer is active: `systemctl is-active phoenix-bundles.timer`
- [ ] Recent logs have no errors: `journalctl -u phoenix-bundles -n 50`
- [ ] Disk space is available: `df /root/brunch-build /root/phoenix-bundles`
- [ ] Phoenix server is running: `systemctl is-active phoenix-server`
- [ ] Bundles are being created: `ls -lt /root/phoenix-bundles/*.tar | head -5`

## Future Enhancements

- Parallel builds (limit to 1 per run to avoid overwhelming the build server)
- Cleanup of old recovery images (keep only last 2 versions)
- Build notifications (Slack/email on success/failure)
- Automated rollback of bad bundles
- Metrics collection (build time, bundle size, failure reasons)
