#!/usr/bin/env bash
# portalgun Burp Suite Pro installer + license import + BApp preload
# Designed to work fully offline once initial download is complete.

BURP_DIR="${BURP_DIR:-/opt/portalgun/burpsuite}"
BURP_JAR="${BURP_JAR:-$BURP_DIR/BurpSuitePro.jar}"
BURP_LICENSE_DIR="${BURP_LICENSE_DIR:-$BURP_DIR/license-import}"
BURP_LICENSE_TEMPLATE="${BURP_LICENSE_TEMPLATE:-$BURP_LICENSE_DIR/prefs.xml}"
BURP_BAPPS_DIR="${BURP_BAPPS_DIR:-$BURP_DIR/bapps}"
BURP_CDN="https://portswigger-cdn.net/burp/releases/download?product=pro&type=Jar"
# BApps live under PortSwigger's GitHub org (501 repos as of writing).
# Each BApp repo's latest release contains either a packaged JAR/zip or the
# raw .py source for Jython-based BApps. We mirror the whole org.
BAPP_GH_API="https://api.github.com/orgs/PortSwigger/repos?per_page=100"
# Repos that are NOT BApps and should be excluded from the mass-clone.
BAPP_EXCLUDE_REGEX='^(burp-suite-pro|burp-extender-api|extender-(api|library)|labs-.*|web-security-academy|burp-rest-api|jython-burp-api|portswigger-cli|portswigger-shellcode|all-bapps|featured-bapps)$'

_burp_log() { printf '\033[0;34m[*]\033[0m %s\n' "$*"; }
_burp_ok()  { printf '\033[0;32m[+]\033[0m %s\n' "$*"; }
_burp_err() { printf '\033[0;31m[!]\033[0m %s\n' "$*" >&2; }

_burp_users() {
    # Print every account that should get a Burp config: root + every /home/*
    echo "root:/root"
    for h in /home/*; do
        [ -d "$h" ] || continue
        printf '%s:%s\n' "$(basename "$h")" "$h"
    done
}

ensure_java_21() {
    if command -v java >/dev/null 2>&1; then
        local ver
        ver=$(java -version 2>&1 | head -1 | grep -oE '[0-9]+' | head -1)
        [ "${ver:-0}" -ge 21 ] && return 0
    fi
    _burp_log "Installing openjdk-21-jre-headless"
    DEBIAN_FRONTEND=noninteractive apt-get install -y openjdk-21-jre-headless \
        || { _burp_err "Failed to install Java 21"; return 1; }
}

download_burp_pro() {
    mkdir -p "$BURP_DIR"
    _burp_log "Downloading Burp Suite Pro JAR (this is ~700MB)"
    if curl -fL --retry 3 --connect-timeout 30 -o "$BURP_JAR.new" "$BURP_CDN"; then
        # Guard against a truncated download or a CDN error page served as 200:
        # the real JAR is ~700MB, so anything under 100MB is corrupt.
        local sz
        sz=$(stat -c %s "$BURP_JAR.new" 2>/dev/null || echo 0)
        if [ "$sz" -lt 104857600 ]; then
            _burp_err "Downloaded JAR is only $((sz / 1024 / 1024))MB — corrupt/incomplete, discarding"
            rm -f "$BURP_JAR.new"
            return 1
        fi
        mv "$BURP_JAR.new" "$BURP_JAR"
        _burp_ok "Burp JAR: $BURP_JAR ($(du -h "$BURP_JAR" | cut -f1))"
    else
        _burp_err "Download failed"
        rm -f "$BURP_JAR.new"
        return 1
    fi
}

install_burp_launcher() {
    cat > /usr/local/bin/burpsuite-pro <<EOF
#!/usr/bin/env bash
# portalgun-managed Burp Suite Pro launcher
exec java -Djava.awt.headless=false -jar "$BURP_JAR" "\$@"
EOF
    chmod 755 /usr/local/bin/burpsuite-pro
    _burp_ok "Launcher → /usr/local/bin/burpsuite-pro"
}

apply_burp_license() {
    if [ ! -f "$BURP_LICENSE_TEMPLATE" ]; then
        _burp_log "No license file at $BURP_LICENSE_TEMPLATE — Burp will run unactivated."
        _burp_log "Drop a registered prefs.xml there (or run: portalgun import burp-license <path>)"
        return 0
    fi
    while IFS=: read -r user home; do
        local target="$home/.java/.userPrefs/burp"
        mkdir -p "$target/pro" "$target/community"
        cp "$BURP_LICENSE_TEMPLATE" "$target/prefs.xml"
        # The prefs.xml carries the activated license blob — keep it private to
        # the owning user so it isn't world-readable to other local accounts.
        chmod 600 "$target/prefs.xml"
        # Pro subdir gets an empty prefs.xml so Burp doesn't crash on first load
        if [ ! -f "$target/pro/prefs.xml" ]; then
            cat > "$target/pro/prefs.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8" standalone="no"?>
<!DOCTYPE map SYSTEM "http://java.sun.com/dtd/preferences.dtd">
<map MAP_XML_VERSION="1.0"/>
EOF
        fi
        chown -R "$user:$user" "$home/.java" 2>/dev/null || true
        _burp_ok "License applied for $user ($target)"
    done < <(_burp_users)
}

fetch_bapp_catalog() {
    mkdir -p "$BURP_BAPPS_DIR"
    # If a fresh bundled catalog ships with the install, use it (offline-friendly).
    for bundled in /opt/portalgun/data/bapp-catalog.json \
                   "$(dirname "${BASH_SOURCE[0]}")/../data/bapp-catalog.json"; do
        if [ -f "$bundled" ]; then
            cp -f "$bundled" "$BURP_BAPPS_DIR/catalog.json"
            local count
            count=$(python3 -c "import json;print(len(json.load(open('$BURP_BAPPS_DIR/catalog.json'))))" 2>/dev/null || echo 0)
            _burp_ok "Loaded bundled BApp catalog: $count entries"
            return 0
        fi
    done

    _burp_log "Enumerating BApps under github.com/PortSwigger (live)"
    # GH token (5000/hr) strongly recommended for ~500 repos. Falls back to:
    #   1) GITHUB_TOKEN env  →  2) `gh auth token`  →  3) unauthenticated
    # Unauth is hard-capped at 60/hr → only ~6 pages, so we cache and persist.
    local token=""
    [ -n "${GITHUB_TOKEN:-}" ] && token="$GITHUB_TOKEN"
    [ -z "$token" ] && command -v gh >/dev/null 2>&1 && token=$(gh auth token 2>/dev/null || true)
    [ -z "$token" ] && _burp_log "No GITHUB_TOKEN; will paginate unauth (slower, may hit rate limit)"

    # If we already have a recent catalog (≤7 days), reuse it instead of re-hitting API
    if [ -f "$BURP_BAPPS_DIR/catalog.json" ]; then
        local age_days
        age_days=$(( ($(date +%s) - $(stat -c %Y "$BURP_BAPPS_DIR/catalog.json")) / 86400 ))
        if [ "$age_days" -lt 7 ]; then
            local count
            count=$(python3 -c "import json;print(len(json.load(open('$BURP_BAPPS_DIR/catalog.json'))))" 2>/dev/null || echo 0)
            if [ "$count" -gt 50 ]; then
                _burp_ok "Reusing cached BApp catalog ($count repos, $age_days days old)"
                return 0
            fi
        fi
    fi

    GITHUB_TOKEN="$token" python3 - "$BURP_BAPPS_DIR" "$BAPP_EXCLUDE_REGEX" <<'PYEOF' || return 1
import json, os, re, sys, time, urllib.request, urllib.error

out_dir, exclude_re = sys.argv[1], re.compile(sys.argv[2])
api = "https://api.github.com/orgs/PortSwigger/repos?per_page=100"
token = os.environ.get("GITHUB_TOKEN", "").strip()
headers = {"User-Agent": "portalgun/1.0", "Accept": "application/vnd.github+json"}
if token: headers["Authorization"] = f"Bearer {token}"

repos = []
url = api
while url:
    for attempt in range(3):
        req = urllib.request.Request(url, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=20) as r:
                page = json.loads(r.read())
                repos.extend(page)
                link = r.headers.get("Link", "")
            break
        except urllib.error.HTTPError as e:
            if e.code == 403 and attempt < 2:
                wait = 30 * (attempt + 1)
                print(f"[!] {url} → 403 (rate-limited?); waiting {wait}s", file=sys.stderr)
                time.sleep(wait)
                continue
            print(f"[!] Failed to fetch {url}: HTTP {e.code}", file=sys.stderr)
            link = ""
            break
        except Exception as e:
            print(f"[!] Failed to fetch {url}: {e}", file=sys.stderr)
            link = ""
            break
    else:
        link = ""
    nxt = ""
    for part in link.split(","):
        if 'rel="next"' in part:
            nxt = part.split(";")[0].strip().lstrip("<").rstrip(">")
    url = nxt

filtered = [r for r in repos
            if not exclude_re.match(r["name"])
            and not r.get("archived") and not r.get("disabled")]
json.dump(filtered, open(os.path.join(out_dir, "catalog.json"), "w"), indent=2)
print(f"BApp catalog: {len(filtered)} repos (of {len(repos)} total under PortSwigger)")
if len(filtered) < 50:
    print(f"[!] Catalog suspiciously small — possible rate-limit. Pass GITHUB_TOKEN env to retry.", file=sys.stderr)
    sys.exit(2)
PYEOF
}

download_all_bapps() {
    [ -f "$BURP_BAPPS_DIR/catalog.json" ] || return 0
    _burp_log "Downloading every BApp (may take 10+ minutes for first install)"
    python3 - "$BURP_BAPPS_DIR" <<'PYEOF'
"""For each PortSwigger repo: download latest release JAR/zip if any, else
clone the repo (shallow) so Jython/Python BApps still work."""
import json, os, subprocess, sys, urllib.request, urllib.error

bapps_dir = sys.argv[1]
catalog = json.load(open(os.path.join(bapps_dir, "catalog.json")))
token = os.environ.get("GITHUB_TOKEN") or ""
headers = {"User-Agent": "portalgun/1.0", "Accept": "application/vnd.github+json"}
if token: headers["Authorization"] = f"Bearer {token}"

ok = fail = cloned = 0
for entry in catalog:
    full = entry["full_name"]  # e.g. PortSwigger/turbo-intruder
    safe = entry["name"]
    dest_dir = os.path.join(bapps_dir, safe)
    os.makedirs(dest_dir, exist_ok=True)

    # 1) Try latest release with downloadable asset
    rel_url = f"https://api.github.com/repos/{full}/releases/latest"
    got_asset = False
    try:
        req = urllib.request.Request(rel_url, headers=headers)
        with urllib.request.urlopen(req, timeout=15) as r:
            rel = json.loads(r.read())
        for asset in rel.get("assets", []):
            name = asset["name"]
            if not name.lower().endswith((".jar", ".zip", ".bapp", ".py")):
                continue
            dl = asset["browser_download_url"]
            dest = os.path.join(dest_dir, name)
            if os.path.exists(dest) and os.path.getsize(dest) > 500:
                got_asset = True
                continue
            try:
                arq = urllib.request.Request(dl, headers={"User-Agent": "portalgun/1.0"})
                with urllib.request.urlopen(arq, timeout=60) as ar, open(dest + ".tmp", "wb") as out:
                    out.write(ar.read())
                os.replace(dest + ".tmp", dest)
                got_asset = True
            except Exception as e:
                print(f"  [asset-fail] {safe}/{name}: {e}", file=sys.stderr)
    except urllib.error.HTTPError as e:
        if e.code != 404:
            print(f"  [release-fetch-fail] {safe}: HTTP {e.code}", file=sys.stderr)
    except Exception as e:
        print(f"  [release-fetch-fail] {safe}: {e}", file=sys.stderr)

    if got_asset:
        ok += 1
        continue

    # 2) Fall back to shallow git clone for Jython/Python BApps (no release)
    clone_dir = os.path.join(dest_dir, "src")
    if os.path.isdir(os.path.join(clone_dir, ".git")):
        cloned += 1
        continue
    try:
        subprocess.run(
            ["git", "clone", "--depth", "1", "--quiet",
             f"https://github.com/{full}.git", clone_dir],
            check=True, timeout=120,
        )
        cloned += 1
    except Exception as e:
        print(f"  [clone-fail] {safe}: {e}", file=sys.stderr)
        fail += 1

print(f"DONE: {ok} via release asset, {cloned} cloned, {fail} failed")
PYEOF
}

stage_bapps_for_users() {
    [ -d "$BURP_BAPPS_DIR" ] || return 0
    while IFS=: read -r user home; do
        local target="$home/.BurpSuite/bapps"
        mkdir -p "$target"
        # Copy/sync the BApps shared store into each user's Burp dir
        cp -ru "$BURP_BAPPS_DIR"/*/ "$target/" 2>/dev/null || true
        chown -R "$user:$user" "$home/.BurpSuite" 2>/dev/null || true
    done < <(_burp_users)
    _burp_ok "BApps staged into every user's ~/.BurpSuite/bapps/"
}

register_burp() {
    local reg_dir="/var/lib/portalgun/registry/burp"
    mkdir -p "$reg_dir"
    cat > "$reg_dir/burp-pro.json" <<EOF
{
  "name": "burp-pro",
  "type": "burp",
  "jar": "$BURP_JAR",
  "launcher": "/usr/local/bin/burpsuite-pro",
  "license_applied": $([ -f "$BURP_LICENSE_TEMPLATE" ] && echo true || echo false),
  "bapps_dir": "$BURP_BAPPS_DIR",
  "installed_at": "$(date -Iseconds)"
}
EOF
    _burp_ok "Registered → $reg_dir/burp-pro.json"
}

install_burp_pro() {
    mkdir -p "$BURP_DIR" "$BURP_LICENSE_DIR" "$BURP_BAPPS_DIR"
    # The license-import staging dir holds the operator's activated prefs.xml —
    # lock it down so the secret isn't listable/readable by other local users.
    chmod 700 "$BURP_LICENSE_DIR"
    ensure_java_21 || return 1
    download_burp_pro || return 1
    install_burp_launcher
    apply_burp_license
    fetch_bapp_catalog && download_all_bapps && stage_bapps_for_users
    register_burp
    _burp_ok "Burp Suite Pro install complete. Launch: burpsuite-pro"
}

update_burp_pro() {
    _burp_log "Updating Burp Suite Pro"
    download_burp_pro || return 1
    install_burp_launcher
    # Re-apply license + re-stage BApps in case new users were added
    apply_burp_license
    stage_bapps_for_users
    _burp_ok "Burp Suite Pro updated"
}

import_burp_license() {
    local src="$1"
    if [ -z "$src" ] || [ ! -f "$src" ]; then
        _burp_err "Usage: portalgun import burp-license <path-to-prefs.xml>"
        return 1
    fi
    # Sanity-check the input is a Java preferences XML (a Burp prefs.xml), so a
    # wrong file doesn't get silently staged and reported as a valid license.
    if ! head -c 512 "$src" | grep -qiE 'preferences\.dtd|<map'; then
        _burp_err "Not a Burp prefs.xml (expected a Java preferences XML with a <map> root)"
        return 1
    fi
    mkdir -p "$BURP_LICENSE_DIR"
    chmod 700 "$BURP_LICENSE_DIR"
    cp "$src" "$BURP_LICENSE_TEMPLATE"
    chmod 600 "$BURP_LICENSE_TEMPLATE"
    _burp_ok "License blob staged at $BURP_LICENSE_TEMPLATE"
    apply_burp_license
}
