#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────
# portalgun offline toggle
# ─────────────────────────────────────────────────────────────────────────
# Switches pip between online (PyPI) and offline (local wheelhouse only)
# resolution by writing /etc/pip.conf. /etc/pip.conf is the global config and
# applies to both system pip3 and the /opt/pentest-venv pip.
#
# A distributed clone is used offline, so `portalgun offline on` is the
# go-dark step (also invoked automatically by `portalgun sanitize`).

WHEELS_DIR="${PORTALGUN_WHEELS:-/opt/portalgun/wheels}"
APT_MIRROR="${PORTALGUN_APT_MIRROR:-/opt/portalgun/apt-mirror}"
PIP_CONF="/etc/pip.conf"
APT_LOCAL="/etc/apt/sources.list.d/portalgun-local.list"
APT_BACKUP="/opt/portalgun/apt-sources.offline-backup"

# Switch apt to the local mirror only (online repos are unreachable offline).
_apt_offline_on() {
    [ -d "$APT_MIRROR" ] || return 0
    # Enable the local mirror source.
    [ -f "$APT_LOCAL.disabled" ] && mv -f "$APT_LOCAL.disabled" "$APT_LOCAL"
    if [ ! -f "$APT_LOCAL" ]; then
        echo "deb [trusted=yes] file://$APT_MIRROR ./" > "$APT_LOCAL"
    fi
    # Stash online sources so `apt update` doesn't fail on unreachable repos.
    mkdir -p "$APT_BACKUP"
    [ -f /etc/apt/sources.list ] && mv -f /etc/apt/sources.list "$APT_BACKUP/sources.list" 2>/dev/null || true
    local f
    for f in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
        [ -f "$f" ] || continue
        [ "$f" = "$APT_LOCAL" ] && continue
        mv -f "$f" "$APT_BACKUP/$(basename "$f")" 2>/dev/null || true
    done
}

_apt_offline_off() {
    # Disable local mirror, restore online sources.
    [ -f "$APT_LOCAL" ] && mv -f "$APT_LOCAL" "$APT_LOCAL.disabled" 2>/dev/null || true
    if [ -d "$APT_BACKUP" ]; then
        [ -f "$APT_BACKUP/sources.list" ] && mv -f "$APT_BACKUP/sources.list" /etc/apt/sources.list 2>/dev/null || true
        local f
        for f in "$APT_BACKUP"/*; do
            [ -f "$f" ] || continue
            [ "$(basename "$f")" = "sources.list" ] && continue
            mv -f "$f" "/etc/apt/sources.list.d/$(basename "$f")" 2>/dev/null || true
        done
    fi
}

offline_on() {
    mkdir -p "$WHEELS_DIR"
    cat > "$PIP_CONF" <<EOF
# portalgun OFFLINE mode — pip resolves ONLY from the local wheelhouse.
# Switch back with: sudo portalgun offline off
[global]
no-index = true
find-links = $WHEELS_DIR
[install]
find-links = $WHEELS_DIR
EOF
    _apt_offline_on
    echo "[+] pip OFFLINE — installs resolve from $WHEELS_DIR"
    [ -d "$APT_MIRROR" ] && echo "[+] apt OFFLINE — installs resolve from $APT_MIRROR (run: apt update)"
    echo "    (no internet needed; revert with: sudo portalgun offline off)"
}

offline_off() {
    cat > "$PIP_CONF" <<EOF
# portalgun ONLINE mode — PyPI, with the local wheelhouse as a fast supplement.
[global]
find-links = $WHEELS_DIR
prefer-binary = true
EOF
    _apt_offline_off
    echo "[+] pip ONLINE — PyPI + local wheelhouse supplement"
    echo "[+] apt ONLINE — online repos restored"
}

offline_status() {
    if grep -q 'no-index' "$PIP_CONF" 2>/dev/null; then
        echo "offline"
    else
        echo "online"
    fi
}

offline_cmd() {
    case "${1:-status}" in
        on)     offline_on ;;
        off)    offline_off ;;
        status) echo "pip mode: $(offline_status)" ;;
        *)      echo "Usage: portalgun offline <on|off|status>"; return 1 ;;
    esac
}
