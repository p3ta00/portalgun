#!/usr/bin/env bash
# portalgun Burp Suite Pro installer + license import + BApp preload
# Designed to work fully offline once initial download is complete.

BURP_DIR="${BURP_DIR:-/opt/portalgun/burpsuite}"
BURP_JAR="${BURP_JAR:-$BURP_DIR/BurpSuitePro.jar}"
BURP_LICENSE_DIR="${BURP_LICENSE_DIR:-$BURP_DIR/license-import}"
BURP_LICENSE_TEMPLATE="${BURP_LICENSE_TEMPLATE:-$BURP_LICENSE_DIR/prefs.xml}"
# Persistent Burp config store. Each user's ~/.java/.userPrefs/burp and
# ~/.BurpSuite are SYMLINKED here (exegol-style), so a one-time activation
# writes back through the symlink and persists — Burp never re-registers.
BURP_CONFIG_STORE="${BURP_CONFIG_STORE:-$BURP_DIR/burp-config}"
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

# Symlink every user's Burp config dirs to the shared persistent store, the way
# exegol's burp-persist.sh does. A one-time online activation (one of the 25
# license seats, on first GUI launch) is written back through the symlink into
# the store and reused forever after — so Burp does NOT re-register on every
# launch (which is what gets a license flagged).
apply_burp_license() {
    local store_prefs="$BURP_CONFIG_STORE/.java/.userPrefs/burp"
    local store_bsuite="$BURP_CONFIG_STORE/.BurpSuite"

    if [ ! -d "$store_prefs" ]; then
        _burp_log "No Burp config store at $store_prefs — Burp will run unactivated."
        _burp_log "Provide one with: portalgun import burp-license <prefs.xml | burp-config dir | tarball>"
        return 0
    fi

    # The store must be writable by whoever launches Burp so the activation can
    # persist. Use a shared 'burp' group rather than world-writable.
    groupadd -f burp 2>/dev/null || true

    while IFS=: read -r user home; do
        id -nG "$user" 2>/dev/null | grep -qw burp || usermod -aG burp "$user" 2>/dev/null || true

        # ~/.java/.userPrefs/burp  ->  store
        mkdir -p "$home/.java/.userPrefs"
        rm -rf "$home/.java/.userPrefs/burp"
        ln -sfn "$store_prefs" "$home/.java/.userPrefs/burp"
        chown -h "$user:$user" "$home/.java/.userPrefs/burp" 2>/dev/null || true
        chown "$user:$user" "$home/.java" "$home/.java/.userPrefs" 2>/dev/null || true

        # ~/.BurpSuite -> store (extensions, sessions, themes, bapps)
        if [ -d "$store_bsuite" ]; then
            rm -rf "$home/.BurpSuite"
            ln -sfn "$store_bsuite" "$home/.BurpSuite"
            chown -h "$user:$user" "$home/.BurpSuite" 2>/dev/null || true
        fi
        _burp_ok "Burp config linked for $user → $BURP_CONFIG_STORE"
    done < <(_burp_users)

    # Group-writable so activation persists regardless of which user runs Burp.
    chgrp -R burp "$BURP_CONFIG_STORE" 2>/dev/null || true
    chmod -R g+rwX "$BURP_CONFIG_STORE" 2>/dev/null || true
    find "$BURP_CONFIG_STORE" -type d -exec chmod g+s {} + 2>/dev/null || true
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

# Stage the pre-bundled BApp assets/clones (shipped in the image at
# /opt/portalgun/data/bapp-jars) into the BApp dir, so download_all_bapps finds
# them already present and makes ZERO GitHub API calls — fully offline, no
# rate-limit 403 cascade. Built at master-build time via lib/preload_bapps.py.
stage_bundled_bapps() {
    local src
    for src in /opt/portalgun/data/bapp-jars \
               "$(dirname "${BASH_SOURCE[0]}")/../data/bapp-jars"; do
        if [ -d "$src" ] && [ -n "$(ls -A "$src" 2>/dev/null)" ]; then
            mkdir -p "$BURP_BAPPS_DIR"
            cp -rn "$src"/. "$BURP_BAPPS_DIR"/ 2>/dev/null || true
            local n; n=$(ls -A "$src" 2>/dev/null | wc -l)
            _burp_ok "Staged $n bundled BApps (offline)"
            return 0
        fi
    done
    _burp_log "No bundled BApps found — download_all_bapps will fetch online (rate-limit-prone)"
}

download_all_bapps() {
    [ -f "$BURP_BAPPS_DIR/catalog.json" ] || return 0
    _burp_log "Resolving BApps (bundled ones skip the GitHub API)..."
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

    # Already present (bundled offline, or a prior run) → skip with NO GitHub
    # API call. This is what keeps a fresh install from 499 unauthenticated API
    # calls (which 403-cascade past the 60/hr limit).
    have_asset = any(
        f.lower().endswith((".jar", ".zip", ".bapp", ".py")) and
        os.path.isfile(os.path.join(dest_dir, f)) and
        os.path.getsize(os.path.join(dest_dir, f)) > 500
        for f in os.listdir(dest_dir)
    )
    # A bundled source BApp is present as a non-empty src/ dir (the preloader
    # strips .git, so don't require src/.git — that caused redundant re-clones
    # to fail with "destination already exists").
    _src = os.path.join(dest_dir, "src")
    src_present = os.path.isdir(_src) and bool(os.listdir(_src))
    if have_asset or src_present:
        ok += 1
        continue

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

    # 2) Fall back to shallow git clone for Jython/Python BApps (no release).
    clone_dir = os.path.join(dest_dir, "src")
    # Already present (bundled, .git stripped, or a prior clone) → don't re-clone
    # into a non-empty dir (git exits 128 "destination already exists").
    if os.path.isdir(clone_dir) and os.listdir(clone_dir):
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
    fetch_bapp_catalog && stage_bundled_bapps && download_all_bapps && stage_bapps_for_users
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

# Accepts any of:
#   - prefs.xml                  (the Java userPrefs file holding the license)
#   - a burp-config directory    (exegol-style: contains .java/.userPrefs/burp[/.BurpSuite])
#   - a .tar.gz/.tgz/.tar        (a tarball of that burp-config directory)
# Populates the persistent store, then symlinks every user to it.
import_burp_license() {
    local src="$1"
    if [ -z "$src" ] || [ ! -e "$src" ]; then
        _burp_err "Usage: portalgun import burp-license <prefs.xml | burp-config dir | tarball>"
        return 1
    fi
    local store_prefs="$BURP_CONFIG_STORE/.java/.userPrefs/burp"
    mkdir -p "$store_prefs"

    if [ -d "$src" ]; then
        local found
        found=$(find "$src" -type d -path '*/.java/.userPrefs/burp' 2>/dev/null | head -1)
        if [ -n "$found" ]; then
            cp -a "$found/." "$store_prefs/"
        elif [ -f "$src/prefs.xml" ]; then
            cp -a "$src/prefs.xml" "$store_prefs/prefs.xml"
        else
            _burp_err "No .java/.userPrefs/burp or prefs.xml found under $src"
            return 1
        fi
        local bs
        bs=$(find "$src" -type d -name '.BurpSuite' 2>/dev/null | head -1)
        [ -n "$bs" ] && { mkdir -p "$BURP_CONFIG_STORE/.BurpSuite"; cp -a "$bs/." "$BURP_CONFIG_STORE/.BurpSuite/" 2>/dev/null || true; }
    elif printf '%s' "$src" | grep -qiE '\.(tar\.gz|tgz|tar)$'; then
        local tmp; tmp=$(mktemp -d)
        if tar xf "$src" -C "$tmp" 2>/dev/null; then
            import_burp_license "$tmp"; local rc=$?
            rm -rf "$tmp"; return $rc
        fi
        rm -rf "$tmp"; _burp_err "Could not extract $src"; return 1
    else
        if ! head -c 512 "$src" | grep -qiE 'preferences\.dtd|<map'; then
            _burp_err "Not a Burp prefs.xml (expected a Java preferences XML with a <map> root)"
            return 1
        fi
        cp "$src" "$store_prefs/prefs.xml"
    fi

    if [ ! -s "$store_prefs/prefs.xml" ]; then
        _burp_err "No prefs.xml ended up in the store — nothing imported"
        return 1
    fi
    # Back-compat copy for tooling that still looks at the legacy template path.
    mkdir -p "$BURP_LICENSE_DIR" && chmod 700 "$BURP_LICENSE_DIR"
    cp "$store_prefs/prefs.xml" "$BURP_LICENSE_TEMPLATE" 2>/dev/null || true
    _burp_ok "Burp config staged → $BURP_CONFIG_STORE"
    apply_burp_license
}
