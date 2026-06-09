#!/usr/bin/env python3
"""
Pre-download every Burp BApp's release asset (or a shallow clone for Jython/
Python BApps with no release) into data/bapp-jars/<name>/ so the installed
system can stage them entirely OFFLINE — no per-BApp GitHub API calls at install
time (499 unauthenticated calls blow the 60/hr limit and 403-cascade).

Run on a host with authenticated `gh` (5000/hr). Parallel workers.

Input  : data/bapp-catalog.json (the PortSwigger org repo list)
Output : data/bapp-jars/<name>/<asset>           (release assets)
         data/bapp-jars/<name>/src/              (shallow clone fallback)
"""
import json
import os
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CATALOG = Path(os.environ.get("BAPP_CATALOG", ROOT / "data" / "bapp-catalog.json"))
OUT_DIR = Path(os.environ.get("BAPP_OUT", ROOT / "data" / "bapp-jars"))
ASSET_EXTS = (".jar", ".zip", ".bapp", ".py")


def gh_latest_assets(full_name):
    """Return [(asset_name, download_url)] for the latest release (gh auth)."""
    try:
        r = subprocess.run(
            ["gh", "api", f"repos/{full_name}/releases/latest",
             "--jq", "[.assets[] | {name, url: .browser_download_url}]"],
            capture_output=True, text=True, timeout=30,
        )
        if r.returncode != 0:
            return []
        return [(a["name"], a["url"]) for a in json.loads(r.stdout or "[]")]
    except Exception:
        return []


def download(url, dest):
    if dest.exists() and dest.stat().st_size > 500:
        return True
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = Path(str(dest) + ".tmp")
    try:
        r = subprocess.run(["curl", "-fsSL", "--retry", "3", "--connect-timeout", "20",
                            "-o", str(tmp), url], capture_output=True, timeout=120)
        if r.returncode != 0:
            tmp.unlink(missing_ok=True)
            return False
        os.replace(str(tmp), str(dest))
        return True
    except Exception:
        tmp.unlink(missing_ok=True)
        return False


def handle(entry):
    full = entry["full_name"]
    safe = entry["name"]
    dest_dir = OUT_DIR / safe
    # 1) release asset(s)
    got = False
    for name, url in gh_latest_assets(full):
        if not name.lower().endswith(ASSET_EXTS):
            continue
        if download(url, dest_dir / name):
            got = True
    if got:
        return ("asset", safe)
    # 2) shallow clone for source BApps (Jython/Python, no release)
    src = dest_dir / "src"
    if (src / ".git").is_dir():
        return ("clone", safe)
    src.parent.mkdir(parents=True, exist_ok=True)
    try:
        r = subprocess.run(["git", "clone", "--depth", "1", "--quiet",
                            f"https://github.com/{full}.git", str(src)],
                           capture_output=True, timeout=180)
        if r.returncode == 0:
            # Drop .git — we only need the BApp files, not history (saves ~half).
            gitdir = src / ".git"
            if gitdir.is_dir():
                subprocess.run(["rm", "-rf", str(gitdir)], capture_output=True)
            return ("clone", safe)
    except Exception:
        pass
    return ("fail", safe)


def main():
    catalog = json.load(open(CATALOG))
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    counts = {"asset": 0, "clone": 0, "fail": 0}
    failed = []
    with ThreadPoolExecutor(max_workers=8) as ex:
        futs = {ex.submit(handle, e): e["name"] for e in catalog}
        done = 0
        for f in as_completed(futs):
            kind, name = f.result()
            counts[kind] += 1
            if kind == "fail":
                failed.append(name)
            done += 1
            if done % 25 == 0:
                print(f"  {done}/{len(catalog)} (asset={counts['asset']} "
                      f"clone={counts['clone']} fail={counts['fail']})", flush=True)
    print(f"DONE: {counts['asset']} assets, {counts['clone']} clones, "
          f"{counts['fail']} failed of {len(catalog)} -> {OUT_DIR}")
    if failed:
        print("failed:", ", ".join(sorted(failed)[:30]))
    (OUT_DIR / ".preload-summary.json").write_text(json.dumps(
        {"counts": counts, "failed": failed}, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
