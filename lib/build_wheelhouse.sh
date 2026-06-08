#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────
# portalgun wheelhouse builder
# ─────────────────────────────────────────────────────────────────────────
# Downloads pip wheels (+ sdists where no wheel exists) for the installed
# package closure AND a curated "future-proof" superset into a local
# wheelhouse, so a 100%-offline clone can `pip install` future/self-written
# tools' dependencies with no internet.
#
# Run ONLINE at master-build time. Idempotent (skips files already present)
# and disk-safe (stops before filling the partition).
#
# Env:
#   PORTALGUN_WHEELS              wheelhouse dir (default /opt/portalgun/wheels)
#   PORTALGUN_WHEELS_MIN_FREE_GB  stop when free space drops below this (default 5)
#   PORTALGUN_LOG_DIR             log dir (default /var/log/portalgun)

WHEELS_DIR="${PORTALGUN_WHEELS:-/opt/portalgun/wheels}"
MIN_FREE_GB="${PORTALGUN_WHEELS_MIN_FREE_GB:-5}"
_WH_VENV_PIP="/opt/pentest-venv/bin/pip"

_wh_pip() { if [ -x "$_WH_VENV_PIP" ]; then echo "$_WH_VENV_PIP"; else echo "pip3"; fi; }
_wh_free_gb() { df -BG --output=avail "$1" 2>/dev/null | tail -1 | tr -dc '0-9'; }

build_wheelhouse() {
    local pkg_list="${1:-$(dirname "${BASH_SOURCE[0]}")/../data/wheelhouse-packages.txt}"
    local pip; pip="$(_wh_pip)"
    local log_dir="${PORTALGUN_LOG_DIR:-/var/log/portalgun}"
    local log="$log_dir/wheelhouse.log"

    mkdir -p "$WHEELS_DIR" "$log_dir"
    : > "$log"

    if [ ! -f "$pkg_list" ]; then
        echo "[wheelhouse] package list not found: $pkg_list" | tee -a "$log"
        return 1
    fi

    # Build the target set: installed closure (names only) + curated future list.
    # Set PORTALGUN_WHEELHOUSE_NO_CLOSURE=1 to download only the curated list
    # (skip the reinstallable closure of what's already installed).
    local tmp_list; tmp_list="$(mktemp)"
    if [ "${PORTALGUN_WHEELHOUSE_NO_CLOSURE:-0}" != "1" ]; then
        "$pip" freeze 2>/dev/null \
            | grep -vE '^-e |@ |^#' \
            | sed 's/[=<>!~ ].*//' \
            | grep -vE '^$' >> "$tmp_list"
    fi
    grep -vE '^\s*#|^\s*$' "$pkg_list" >> "$tmp_list"
    sort -u "$tmp_list" -o "$tmp_list"

    local total ok=0 fail=0 i=0 pkg
    total="$(wc -l < "$tmp_list")"
    echo "[wheelhouse] $total packages → $WHEELS_DIR" | tee -a "$log"
    echo "[wheelhouse] target: $($pip --version 2>&1)" | tee -a "$log"
    echo "[wheelhouse] free now: $(_wh_free_gb "$WHEELS_DIR")GB (floor: ${MIN_FREE_GB}GB)" | tee -a "$log"

    while IFS= read -r pkg; do
        [ -z "$pkg" ] && continue
        i=$((i + 1))
        local free; free="$(_wh_free_gb "$WHEELS_DIR")"
        if [ "${free:-0}" -lt "$MIN_FREE_GB" ]; then
            echo "[wheelhouse] STOP at $i/$total — only ${free}GB free (< ${MIN_FREE_GB}GB)." | tee -a "$log"
            echo "[wheelhouse] Expand the disk and re-run 'portalgun build-wheelhouse' to finish." | tee -a "$log"
            rm -f "$tmp_list"
            return 2
        fi
        # PIP_CONFIG_FILE=/dev/null so this download ignores any offline pip.conf
        # (no-index) that may already be set on the box. --prefer-binary grabs
        # wheels first; sdists only when no wheel (they build offline because the
        # image ships the C build-deps). Per-package so one bad resolve doesn't
        # abort the whole run, and so the wheelhouse can hold multiple versions.
        if PIP_CONFIG_FILE=/dev/null "$pip" download --prefer-binary \
                --dest "$WHEELS_DIR" "$pkg" >>"$log" 2>&1; then
            ok=$((ok + 1))
        else
            fail=$((fail + 1))
            echo "[wheelhouse] FAILED: $pkg" | tee -a "$log"
        fi
        if [ $((i % 25)) -eq 0 ]; then
            echo "[wheelhouse] $i/$total (ok=$ok fail=$fail, $(_wh_free_gb "$WHEELS_DIR")GB free)"
        fi
    done < "$tmp_list"
    rm -f "$tmp_list"

    local count size
    count="$(find "$WHEELS_DIR" -maxdepth 1 -type f \( -name '*.whl' -o -name '*.tar.gz' -o -name '*.zip' \) 2>/dev/null | wc -l)"
    size="$(du -sh "$WHEELS_DIR" 2>/dev/null | cut -f1)"
    echo "[wheelhouse] done: ${ok} ok / ${fail} failed (top-level); ${count} files, ${size} on disk" | tee -a "$log"
    return 0
}
