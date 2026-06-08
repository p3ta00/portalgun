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
PIP_CONF="/etc/pip.conf"

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
    echo "[+] pip OFFLINE — installs resolve from $WHEELS_DIR (no internet)"
}

offline_off() {
    cat > "$PIP_CONF" <<EOF
# portalgun ONLINE mode — PyPI, with the local wheelhouse as a fast supplement.
[global]
find-links = $WHEELS_DIR
prefer-binary = true
EOF
    echo "[+] pip ONLINE — PyPI + local wheelhouse supplement"
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
