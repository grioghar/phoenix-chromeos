#!/usr/bin/env python3
"""
Monitor ChromeOS recovery versions and automatically build bundles for new versions.

Reads the recovery JSON lists from Google, finds rammus versions newer than what's
in the bundle store, and runs make-bundle.sh for them when the matching reven version exists.

Usage: watch-versions.py [--repo-dir /path] [--bundles-dir /path] [--once]

Logs to syslog and returns 0 if successful, non-zero on error.
"""
import json
import subprocess
import sys
import os
import logging
import argparse
from datetime import datetime
from pathlib import Path
from urllib.request import urlopen, Request
from urllib.error import URLError

# Setup logging to syslog
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s phoenix-watch-versions: %(levelname)s: %(message)s'
)
log = logging.getLogger(__name__)

RECOVERY_JSON_URL = "https://dl.google.com/dl/edgedl/chromeos/recovery/recovery2.json"
FLEX_JSON_URL = "https://dl.google.com/dl/edgedl/chromeos/recovery/cloudready_recovery2.json"

def fetch_json(url, timeout=30):
    """Fetch and parse JSON from a URL."""
    try:
        req = Request(url, headers={'User-Agent': 'phoenix-bundle-watcher'})
        with urlopen(req, timeout=timeout) as response:
            return json.loads(response.read().decode('utf-8'))
    except URLError as e:
        log.error(f"Failed to fetch {url}: {e}")
        return None
    except json.JSONDecodeError as e:
        log.error(f"Invalid JSON from {url}: {e}")
        return None

def get_versions_from_json(data, board):
    """Extract versions for a given board from recovery JSON.

    The JSON is a flat list of releases. Board is extracted from the 'file' field.
    Returns dict: {version: (url, channel)}
    """
    if not data:
        return {}
    # JSON is either a list or a dict with 'releases' key
    releases = data if isinstance(data, list) else data.get('releases', [])

    versions = {}
    for release in releases:
        # Extract board from filename: chromeos_VERSION_BOARD_recovery_...
        filename = release.get('file', '')
        parts = filename.split('_')
        if len(parts) >= 3:
            file_board = parts[2]
            if file_board == board:
                ver = release.get('version')
                url = release.get('url')
                channel = release.get('channel', 'unknown')
                if ver and url:
                    if ver not in versions:  # Keep first occurrence (LTC preferred)
                        versions[ver] = (url, channel)
    return versions

def get_existing_bundles(bundles_dir):
    """Get list of versions that already have bundles."""
    bundles_dir = Path(bundles_dir)
    if not bundles_dir.exists():
        return set()
    return {
        f.stem for f in bundles_dir.glob('*.tar')
        if f.with_suffix('.sha256').exists()
    }

def version_tuple(v):
    """Convert version string to tuple for comparison."""
    try:
        return tuple(int(x) for x in v.split('.'))
    except (ValueError, AttributeError):
        return (0,)

def build_bundle(version, repo_dir, bundles_dir):
    """Run make-bundle.sh for a given version."""
    script = Path(repo_dir) / 'build' / 'make-bundle.sh'
    if not script.exists():
        log.error(f"make-bundle.sh not found at {script}")
        return False

    log.info(f"Building bundle for version {version}")
    try:
        result = subprocess.run(
            [str(script), version, str(bundles_dir)],
            capture_output=True,
            text=True,
            timeout=3600
        )
        if result.returncode == 0:
            log.info(f"Successfully built bundle for {version}")
            return True
        else:
            log.error(f"Failed to build bundle for {version}: {result.stderr}")
            return False
    except subprocess.TimeoutExpired:
        log.error(f"Timeout building bundle for {version}")
        return False
    except Exception as e:
        log.error(f"Error building bundle for {version}: {e}")
        return False

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo-dir', default='/root/phoenix',
                        help='Phoenix repo directory (default: /root/phoenix)')
    parser.add_argument('--bundles-dir', default='/root/phoenix-bundles',
                        help='Bundle output directory (default: /root/phoenix-bundles)')
    parser.add_argument('--once', action='store_true',
                        help='Run once and exit instead of continuous monitoring')
    parser.add_argument('--dry-run', action='store_true',
                        help='Show what would be built without actually building')
    args = parser.parse_args()

    bundles_dir = Path(args.bundles_dir)
    bundles_dir.mkdir(parents=True, exist_ok=True)

    log.info("Fetching recovery metadata")
    rammus_data = fetch_json(RECOVERY_JSON_URL)
    reven_data = fetch_json(FLEX_JSON_URL)

    if not rammus_data or not reven_data:
        log.error("Failed to fetch recovery metadata")
        return 1

    rammus_versions = get_versions_from_json(rammus_data, 'rammus')
    reven_versions = get_versions_from_json(reven_data, 'reven')
    existing_bundles = get_existing_bundles(bundles_dir)

    log.info(f"Found {len(rammus_versions)} rammus versions, {len(reven_versions)} reven versions")
    log.info(f"Existing bundles: {len(existing_bundles)} versions")

    # Log the versions and channels found
    if log.level <= logging.DEBUG or args.dry_run:
        log.info("Rammus versions/channels:")
        for ver in sorted(rammus_versions.keys(), key=version_tuple, reverse=True)[:10]:
            channel = rammus_versions[ver][1] if isinstance(rammus_versions[ver], tuple) else 'unknown'
            log.info(f"  {ver}: {channel}")
        log.info("Reven versions/channels:")
        for ver in sorted(reven_versions.keys(), key=version_tuple, reverse=True)[:10]:
            channel = reven_versions[ver][1] if isinstance(reven_versions[ver], tuple) else 'unknown'
            log.info(f"  {ver}: {channel}")

    if not rammus_versions or not reven_versions:
        log.error("No versions found in recovery metadata")
        return 1

    # Find versions to build: versions in rammus that are not in bundles yet,
    # and have a matching reven version
    to_build = []
    for version in sorted(rammus_versions.keys(), key=version_tuple, reverse=True):
        if version not in existing_bundles and version in reven_versions:
            to_build.append(version)

    if not to_build:
        log.info("No new versions to build")
        return 0

    log.info(f"Found {len(to_build)} new version(s) to build:")
    for v in to_build[:5]:
        channel_r = rammus_versions[v][1] if isinstance(rammus_versions[v], tuple) else 'unknown'
        log.info(f"  {v} (rammus: {channel_r})")

    if args.dry_run:
        log.info("DRY RUN: Would build the following versions:")
        for version in to_build[:5]:
            log.info(f"  - {version}")
        return 0

    # Build bundles (newest first, but limit to avoid overwhelming)
    built = 0
    failed = 0
    max_builds = 5  # Limit per run to avoid overloading
    for version in to_build[:max_builds]:
        if build_bundle(version, args.repo_dir, bundles_dir):
            built += 1
        else:
            failed += 1

    log.info(f"Build complete: {built} successful, {failed} failed")
    return 0 if failed == 0 else 1

if __name__ == '__main__':
    sys.exit(main())
