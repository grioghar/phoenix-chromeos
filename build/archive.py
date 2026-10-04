#!/usr/bin/env python3
"""Phoenix archive: keep local, verified copies of everything a Phoenix install depends on, so
installs keep working when an image is pulled from Google or GitHub. Nothing is ever deleted.

Archived (default ARCHIVE=/root/phoenix-archive):
  google/<board>/<version>/<file>.bin.zip + entry.json   ChromeOS recovery images (rammus = Phoenix's
                                                         base, reven = ChromeOS Flex), the channels
                                                         Phoenix can use (LTC, LTR; stable too)
  brunch/<tag>/<asset>                                    Brunch releases (GitHub sebanc/brunch)
  index.json                                              everything archived, with checksums

Verification: Google publishes the SHA-1 of the unzipped image and the zip size; Brunch assets
are checked against GitHub's size. A file only enters the archive after it verifies.
These are personal/local copies for your own installs, not for redistribution.

  archive.py [--dry-run] [--boards rammus,reven] [--channels LTC,LTR,STABLE] [--brunch N]
"""
import argparse, hashlib, json, os, shutil, subprocess, sys, time, urllib.request, zipfile

ARCHIVE = os.environ.get("PHOENIX_ARCHIVE", "/root/phoenix-archive")
LISTS = {"rammus": "https://dl.google.com/dl/edgedl/chromeos/recovery/recovery2.json",
         "reven": "https://dl.google.com/dl/edgedl/chromeos/recovery/cloudready_recovery2.json"}
UA = {"User-Agent": "phoenix-archive"}
SEED = os.environ.get("PHOENIX_ARCHIVE_SEED", "/root/brunch-build")   # existing downloads to reuse

def log(*a): print(time.strftime("%H:%M:%S"), *a, flush=True)

def get_json(url):
    with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=60) as r:
        return json.load(r)

def download(url, dest, size=None):
    """curl with resume + progress; returns True when the file has the expected size."""
    tmp = dest + ".part"
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    subprocess.run(["curl", "-fL", "-C", "-", "--retry", "5", "-#", "-o", tmp, url], check=False)
    if size and os.path.getsize(tmp) != size:
        log(f"  size mismatch {os.path.getsize(tmp)} != {size}; keeping .part to resume next run")
        return False
    os.replace(tmp, dest)
    return True

def sha1_of_zip_member(path):
    h = hashlib.sha1()
    with zipfile.ZipFile(path) as z:
        name = [n for n in z.namelist() if n.endswith(".bin")][0]
        with z.open(name) as f:
            for b in iter(lambda: f.read(1 << 22), b""):
                h.update(b)
    return h.hexdigest()

def board_of(entry):
    parts = entry.get("file", "").split("_")
    return parts[2] if len(parts) > 2 else "?"

def archive_google(boards, channels, dry):
    out = []
    for list_board, url in LISTS.items():
        if list_board not in boards: continue
        seen = set()
        for e in get_json(url):
            if board_of(e) != list_board or e.get("channel", "").upper() not in channels: continue
            key = (e["version"], e["file"])
            if key in seen: continue
            seen.add(key)
            d = os.path.join(ARCHIVE, "google", list_board, e["version"])
            dest = os.path.join(d, os.path.basename(e["url"]))
            meta = os.path.join(d, "entry.json")
            if os.path.isfile(meta):
                out.append(json.load(open(meta))); continue
            log(f"{list_board} {e['version']} ({e['channel']}): {e['file']}  {e['zipfilesize'] / 1e9:.1f} GB")
            if dry: continue
            seed = os.path.join(SEED, os.path.basename(e["url"]))   # already downloaded on this server?
            if os.path.isfile(seed) and os.path.getsize(seed) == e.get("zipfilesize"):
                os.makedirs(d, exist_ok=True); shutil.copyfile(seed, dest); log("  copied from " + SEED)
            elif not download(e["url"], dest, e.get("zipfilesize")): continue
            log("  verifying SHA-1 of the image ...")
            got = sha1_of_zip_member(dest)
            if got != e["sha1"]:
                log(f"  SHA-1 MISMATCH ({got}); not archived"); os.rename(dest, dest + ".bad"); continue
            e = dict(e, archived=time.strftime("%Y-%m-%d"), verified_sha1=got, path=os.path.relpath(dest, ARCHIVE))
            json.dump(e, open(meta, "w"), indent=1)
            log("  archived and verified")
            out.append(e)
    return out

def archive_brunch(n, dry):
    out = []
    rels = [r for r in get_json("https://api.github.com/repos/sebanc/brunch/releases?per_page=20")
            if not r.get("draft") and "stable" in r.get("tag_name", "")][:n]
    for r in rels:
        for a in r.get("assets", []):
            d = os.path.join(ARCHIVE, "brunch", r["tag_name"]); dest = os.path.join(d, a["name"])
            meta = dest + ".json"
            if os.path.isfile(meta):
                out.append(json.load(open(meta))); continue
            log(f"brunch {r['tag_name']}: {a['name']}  {a['size'] / 1e6:.0f} MB")
            if dry: continue
            if not download(a["browser_download_url"], dest, a["size"]): continue
            h = hashlib.sha256(open(dest, "rb").read()).hexdigest()
            m = {"tag": r["tag_name"], "name": a["name"], "size": a["size"], "sha256": h,
                 "archived": time.strftime("%Y-%m-%d"), "path": os.path.relpath(dest, ARCHIVE)}
            json.dump(m, open(meta, "w"), indent=1); out.append(m)
            log("  archived")
    return out

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--boards", default="rammus,reven")
    ap.add_argument("--channels", default="LTC,LTR,STABLE")
    ap.add_argument("--brunch", type=int, default=4, help="latest N stable Brunch releases")
    a = ap.parse_args()
    os.makedirs(ARCHIVE, exist_ok=True)
    free = shutil.disk_usage(ARCHIVE).free / 1e9
    log(f"archive {ARCHIVE}: {free:.0f} GB free")
    if free < 15 and not a.dry_run:
        log("less than 15 GB free: not downloading"); sys.exit(1)
    g = archive_google(set(a.boards.split(",")), {c.upper() for c in a.channels.split(",")}, a.dry_run)
    b = archive_brunch(a.brunch, a.dry_run)
    if not a.dry_run:
        json.dump({"updated": time.strftime("%Y-%m-%d %H:%M"), "google": g, "brunch": b},
                  open(os.path.join(ARCHIVE, "index.json"), "w"), indent=1)
    log(f"{len(g)} Google images, {len(b)} Brunch files in the archive")

if __name__ == "__main__":
    main()
