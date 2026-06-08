#!/usr/bin/env python3
"""
Pre-download every Sliver armory package release tarball into a local cache so
that the installed system can stage them entirely offline (no GitHub API calls
at install time).

Run on a host with authenticated `gh` (5000/hr GitHub API limit).

Input  : /tmp/armory.json (from https://github.com/sliverarmory/armory/releases/latest)
Output : /home/p3ta/dev/portalgun/data/sliver-armory/<command_name>/<asset>
         /home/p3ta/dev/portalgun/data/sliver-armory/armory.json
"""
import json
import os
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

ARMORY_JSON = Path(os.environ.get("ARMORY_JSON", "/tmp/armory.json"))
OUT_DIR = Path(os.environ.get("OUT_DIR", "/home/p3ta/dev/portalgun/data/sliver-armory"))


def gh_release(repo_url: str):
    """Return (tag, [(asset_name, download_url, size), ...]) for latest release."""
    # repo_url like https://github.com/sliverarmory/CoffLoader → "sliverarmory/CoffLoader"
    slug = repo_url.replace("https://github.com/", "").rstrip("/")
    try:
        r = subprocess.run(
            ["gh", "api", f"repos/{slug}/releases/latest", "--jq",
             "{tag: .tag_name, assets: [.assets[] | {name, url: .browser_download_url, size}]}"],
            capture_output=True, text=True, timeout=30,
        )
        if r.returncode != 0:
            return None, []
        d = json.loads(r.stdout)
        return d.get("tag"), d.get("assets", [])
    except Exception as e:
        print(f"  [err] {slug}: {e}", file=sys.stderr)
        return None, []


def download(url: str, dest: Path):
    if dest.exists() and dest.stat().st_size > 200:
        return True
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = Path(str(dest) + ".tmp")
    try:
        r = subprocess.run(
            ["curl", "-fL", "--retry", "3", "--connect-timeout", "20",
             "-o", str(tmp), url],
            capture_output=True, timeout=120,
        )
        if r.returncode != 0:
            tmp.unlink(missing_ok=True)  # don't leave partial downloads behind
            return False
        os.replace(str(tmp), str(dest))
        return True
    except Exception:
        tmp.unlink(missing_ok=True)
        return False


def main():
    if not ARMORY_JSON.is_file():
        print(f"missing {ARMORY_JSON}", file=sys.stderr)
        return 1
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    # Ship the index alongside the assets
    import shutil
    shutil.copy(ARMORY_JSON, OUT_DIR / "armory.json")

    catalog = json.loads(ARMORY_JSON.read_text())
    items = (catalog.get("extensions", []) + catalog.get("aliases", []))
    print(f"Total packages: {len(items)}")

    def process_one(entry):
        name = entry.get("command_name") or entry.get("name") or "?"
        repo = entry.get("repo_url", "")
        if not repo:
            return ("skipped", name, "no repo_url")
        # If already cached, skip
        pkg_dir = OUT_DIR / name
        if pkg_dir.exists() and any(pkg_dir.glob("*.tar.gz")):
            return ("ok", name, "cached")
        tag, assets = gh_release(repo)
        if not tag:
            return ("failed", name, "no release")
        pkg_dir.mkdir(parents=True, exist_ok=True)
        any_dl = False
        for a in assets:
            if not a["name"].lower().endswith((".tar.gz", ".tgz", ".minisig")):
                continue
            dest = pkg_dir / a["name"]
            if download(a["url"], dest):
                any_dl = True
        if not any_dl:
            return ("failed", name, "no usable asset")
        (pkg_dir / "tag.txt").write_text(tag)
        return ("ok", name, tag)

    summary = {"ok": [], "skipped": [], "failed": []}
    done = 0
    with ThreadPoolExecutor(max_workers=8) as pool:
        futures = {pool.submit(process_one, e): e for e in items}
        for fut in as_completed(futures):
            try:
                status, name, why = fut.result()
            except Exception as e:
                status, name, why = "failed", "?", str(e)
            done += 1
            if status == "ok":
                summary["ok"].append(name)
            elif status == "skipped":
                summary["skipped"].append((name, why))
            else:
                summary["failed"].append((name, why))
                print(f"  [{done}/{len(items)}] {name}: FAIL ({why})", file=sys.stderr)
            if done % 20 == 0:
                print(f"  progress: {done}/{len(items)} — {len(summary['ok'])} ok, {len(summary['failed'])} fail")

    print(f"\nDONE: {len(summary['ok'])} ok, {len(summary['failed'])} failed, {len(summary['skipped'])} skipped")
    if summary["failed"]:
        print("Failures:")
        for n, why in summary["failed"][:15]:
            print(f"  {n}: {why}")
    (OUT_DIR / "preload-summary.json").write_text(json.dumps(summary, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
