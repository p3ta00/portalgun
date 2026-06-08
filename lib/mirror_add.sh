#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────
# portalgun mirror-add — incrementally feed the offline mirrors
# ─────────────────────────────────────────────────────────────────────────
# When a tool is added on the live master (e.g. via the web admin), its offline
# artifacts (wheels / .debs + deps) are appended to the wheelhouse / apt mirror
# so the NEXT clone can install it offline — no full mirror rebuild needed.
# No-op when the corresponding mirror doesn't exist.

WHEELS_DIR="${PORTALGUN_WHEELS:-/opt/portalgun/wheels}"
APT_MIRROR="${PORTALGUN_APT_MIRROR:-/opt/portalgun/apt-mirror}"

mirror_add_pip() {
    local pkg="$1"; [ -z "$pkg" ] && return 1
    [ -d "$WHEELS_DIR" ] || return 0
    local pip; pip="$([ -x /opt/pentest-venv/bin/pip ] && echo /opt/pentest-venv/bin/pip || echo pip3)"
    if PIP_CONFIG_FILE=/dev/null "$pip" download --prefer-binary --dest "$WHEELS_DIR" "$pkg" >/dev/null 2>&1; then
        echo "[mirror] wheelhouse += $pkg (+deps)"
    else
        echo "[mirror] could not add $pkg to wheelhouse (offline or not on PyPI?)"
    fi
}

mirror_add_apt() {
    local pkg="$1"; [ -z "$pkg" ] && return 1
    [ -d "$APT_MIRROR/pool" ] || return 0
    local deps
    deps="$(apt-cache depends --recurse --no-recommends --no-suggests --no-conflicts \
            --no-breaks --no-replaces --no-enhances --no-pre-depends "$pkg" 2>/dev/null \
            | grep '^\w' | sort -u)"
    [ -z "$deps" ] && { echo "[mirror] apt: unknown package $pkg"; return 1; }
    ( cd "$APT_MIRROR/pool" && apt-get download $deps >/dev/null 2>&1 )
    ( cd "$APT_MIRROR" && dpkg-scanpackages -m pool /dev/null 2>/dev/null | tee Packages | gzip -9c > Packages.gz ) >/dev/null 2>&1
    echo "[mirror] apt-mirror += $pkg (+deps)"
}

mirror_add_cmd() {
    case "$1" in
        pip) mirror_add_pip "$2" ;;
        apt) mirror_add_apt "$2" ;;
        *)   echo "Usage: portalgun mirror-add <pip|apt> <package>"; return 1 ;;
    esac
}
