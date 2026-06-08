#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────
# portalgun apt mirror builder
# ─────────────────────────────────────────────────────────────────────────
# Downloads the FULL recursive dependency closure of a curated apt package set
# (plus the already-cached .debs of installed packages) into a local apt repo
# at /opt/portalgun/apt-mirror, so a 100%-offline clone can `apt install` those
# packages and their deps with no internet.
#
# Run ONLINE at master-build time. Idempotent (apt-get download skips existing)
# and disk-guarded.
#
# Env:
#   PORTALGUN_APT_MIRROR          mirror dir (default /opt/portalgun/apt-mirror)
#   PORTALGUN_APT_MIRROR_MIN_FREE_GB  stop below this many GB free (default 5)

APT_MIRROR="${PORTALGUN_APT_MIRROR:-/opt/portalgun/apt-mirror}"
APT_MIN_FREE_GB="${PORTALGUN_APT_MIRROR_MIN_FREE_GB:-5}"
APT_SOURCE_LIST="/etc/apt/sources.list.d/portalgun-local.list"

_am_free_gb() { df -BG --output=avail "$1" 2>/dev/null | tail -1 | tr -dc '0-9'; }

build_apt_mirror() {
    local pkg_list="${1:-$(dirname "${BASH_SOURCE[0]}")/../data/apt-mirror-packages.txt}"
    local log_dir="${PORTALGUN_LOG_DIR:-/var/log/portalgun}"
    local log="$log_dir/apt-mirror.log"
    local pool="$APT_MIRROR/pool"

    mkdir -p "$pool" "$log_dir"
    : > "$log"

    if [ ! -f "$pkg_list" ]; then
        echo "[apt-mirror] package list not found: $pkg_list" | tee -a "$log"
        return 1
    fi
    if ! command -v dpkg-scanpackages >/dev/null 2>&1; then
        echo "[apt-mirror] installing dpkg-dev (for dpkg-scanpackages)..." | tee -a "$log"
        apt-get install -y -q dpkg-dev >>"$log" 2>&1
    fi

    # Seed the pool with the .debs already downloaded for installed packages,
    # so anything on the image is reinstallable/repairable offline.
    cp -n /var/cache/apt/archives/*.deb "$pool/" 2>/dev/null || true

    apt-get update >>"$log" 2>&1 || true

    local pkgs i=0 total ok=0 fail=0 pkg
    pkgs="$(grep -vE '^\s*#|^\s*$' "$pkg_list")"
    total="$(echo "$pkgs" | wc -l)"
    echo "[apt-mirror] $total top-level packages → $APT_MIRROR" | tee -a "$log"
    echo "[apt-mirror] free now: $(_am_free_gb "$APT_MIRROR")GB (floor: ${APT_MIN_FREE_GB}GB)" | tee -a "$log"

    while IFS= read -r pkg; do
        [ -z "$pkg" ] && continue
        i=$((i + 1))
        local free; free="$(_am_free_gb "$APT_MIRROR")"
        if [ "${free:-0}" -lt "$APT_MIN_FREE_GB" ]; then
            echo "[apt-mirror] STOP at $i/$total — only ${free}GB free (< ${APT_MIN_FREE_GB}GB)." | tee -a "$log"
            echo "[apt-mirror] Expand disk + re-run 'portalgun build-apt-mirror' to finish." | tee -a "$log"
            break
        fi
        # Full recursive dependency closure (so deps resolve offline even when
        # they were already installed on the build host). Download into the pool.
        local deps
        deps="$(apt-cache depends --recurse --no-recommends --no-suggests \
                    --no-conflicts --no-breaks --no-replaces --no-enhances \
                    --no-pre-depends "$pkg" 2>/dev/null \
                | grep '^\w' | sort -u)"
        if [ -z "$deps" ]; then
            echo "[apt-mirror] UNKNOWN: $pkg" | tee -a "$log"
            fail=$((fail + 1)); continue
        fi
        ( cd "$pool" && apt-get download $deps >>"$log" 2>&1 ) && ok=$((ok + 1)) || {
            # fall back to downloading the single package if closure download partially fails
            ( cd "$pool" && apt-get download "$pkg" >>"$log" 2>&1 ) && ok=$((ok + 1)) || {
                echo "[apt-mirror] FAILED: $pkg" | tee -a "$log"; fail=$((fail + 1)); }
        }
        [ $((i % 10)) -eq 0 ] && echo "[apt-mirror] $i/$total (ok=$ok fail=$fail, $(_am_free_gb "$APT_MIRROR")GB free)"
    done <<< "$pkgs"

    # Build the repo index.
    echo "[apt-mirror] scanning pool → Packages.gz ..." | tee -a "$log"
    ( cd "$APT_MIRROR" && dpkg-scanpackages -m pool /dev/null 2>>"$log" | tee Packages | gzip -9c > Packages.gz )

    # Write the (offline-only) local source. It is created disabled — portalgun
    # offline on/off enables/disables it so it doesn't shadow PyPI/Kali online.
    if [ ! -f "$APT_SOURCE_LIST" ]; then
        echo "# Enabled by 'portalgun offline on'. Local mirror at $APT_MIRROR" > "$APT_SOURCE_LIST.disabled"
        echo "deb [trusted=yes] file://$APT_MIRROR ./" >> "$APT_SOURCE_LIST.disabled"
    fi

    local count size
    count="$(find "$pool" -name '*.deb' 2>/dev/null | wc -l)"
    size="$(du -sh "$APT_MIRROR" 2>/dev/null | cut -f1)"
    echo "[apt-mirror] done: ${ok} ok / ${fail} failed; ${count} .debs, ${size} on disk" | tee -a "$log"
    return 0
}
