#!/usr/bin/env bash
# portalgun Sliver C2 installer + full armory preload
# Source: https://github.com/BishopFox/sliver

SLIVER_DIR="/opt/portalgun/sliver"
SLIVER_SERVER_BIN="/usr/local/bin/sliver-server"
SLIVER_CLIENT_BIN="/usr/local/bin/sliver-client"
SLIVER_INSTALL_URL="https://sliver.sh/install"
ARMORY_INDEX_URL="https://armory.sliver.sh/index.json"

_sl_log() { printf '\033[0;34m[*]\033[0m %s\n' "$*"; }
_sl_ok()  { printf '\033[0;32m[+]\033[0m %s\n' "$*"; }
_sl_err() { printf '\033[0;31m[!]\033[0m %s\n' "$*" >&2; }

_sl_users() {
    echo "root:/root"
    for h in /home/*; do
        [ -d "$h" ] || continue
        printf '%s:%s\n' "$(basename "$h")" "$h"
    done
}

ensure_sliver_installed() {
    if command -v sliver-server >/dev/null 2>&1 && command -v sliver-client >/dev/null 2>&1; then
        _sl_log "Sliver already installed: $(sliver-server version 2>&1 | head -1)"
        return 0
    fi
    _sl_log "Installing Sliver via official installer"
    curl -fL --retry 3 "$SLIVER_INSTALL_URL" | bash || {
        _sl_err "Installer failed; falling back to direct release download"
        sliver_direct_install || return 1
    }
}

sliver_direct_install() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64) arch=amd64 ;;
        aarch64|arm64) arch=arm64 ;;
        *) _sl_err "Unsupported arch: $arch"; return 1 ;;
    esac
    local server_url client_url
    server_url="https://github.com/BishopFox/sliver/releases/latest/download/sliver-server_linux"
    client_url="https://github.com/BishopFox/sliver/releases/latest/download/sliver-client_linux"
    [ "$arch" = "arm64" ] && {
        server_url="https://github.com/BishopFox/sliver/releases/latest/download/sliver-server_linux-arm64"
        client_url="https://github.com/BishopFox/sliver/releases/latest/download/sliver-client_linux-arm64"
    }
    curl -fL -o "$SLIVER_SERVER_BIN" "$server_url" && chmod +x "$SLIVER_SERVER_BIN"
    curl -fL -o "$SLIVER_CLIENT_BIN" "$client_url" && chmod +x "$SLIVER_CLIENT_BIN"
}

# Bundled offline path: if /opt/portalgun/data/sliver-armory/ exists (with
# armory.json + per-package tarballs), skip GitHub entirely. Otherwise fall
# back to the slow on-line `armory install <pkg>` loop (rate-limited).
stage_bundled_armory() {
    local bundle=""
    for candidate in /opt/portalgun/data/sliver-armory \
                     "$(dirname "${BASH_SOURCE[0]}")/../data/sliver-armory"; do
        [ -d "$candidate" ] && [ -f "$candidate/armory.json" ] && { bundle="$candidate"; break; }
    done
    [ -z "$bundle" ] && return 1

    _sl_log "Bundled armory cache found: $bundle"
    local ext_root=/root/.sliver-client/extensions
    local alias_root=/root/.sliver-client/aliases
    mkdir -p "$ext_root" "$alias_root"

    local ext_count=0 alias_count=0
    for pkg_dir in "$bundle"/*/; do
        [ -d "$pkg_dir" ] || continue
        local name
        name=$(basename "$pkg_dir")
        [ "$name" = "armory.json" ] && continue
        local tarball
        tarball=$(find "$pkg_dir" -maxdepth 1 -name "*.tar.gz" -o -name "*.tgz" | head -1)
        [ -z "$tarball" ] && continue
        # Aliases ship an alias.json; extensions ship an extension.json. Route
        # each package to the correct dir so sliver picks it up. Tar entries
        # may be prefixed with ./ — accept both.
        local kind="extensions"
        if tar tzf "$tarball" 2>/dev/null | grep -qE '(^|/)alias\.json$'; then
            kind="aliases"
        fi
        local dest
        if [ "$kind" = "aliases" ]; then
            dest="$alias_root/$name"
        else
            dest="$ext_root/$name"
        fi
        mkdir -p "$dest"
        # Reject tarballs with absolute or parent-traversal members before
        # extracting (a corrupt/hostile armory tarball could otherwise write
        # outside $dest as root). --no-same-owner keeps ownership sane.
        if tar tzf "$tarball" 2>/dev/null | grep -qE '(^|/)\.\.(/|$)|^/'; then
            _sl_log "Skipping $name — tarball contains unsafe paths"
            continue
        fi
        if tar xzf "$tarball" -C "$dest" --no-same-owner 2>/dev/null; then
            [ "$kind" = "aliases" ] && alias_count=$((alias_count + 1)) || ext_count=$((ext_count + 1))
        fi
    done
    _sl_ok "Staged $ext_count extensions + $alias_count aliases from bundle"
    return 0
}

# Sliver's `armory` CLI does NOT support `install all`. Need to:
#   1. Run `armory list` to enumerate every package (~200+)
#   2. Generate an rc file with one `armory install <pkg>` per line
#   3. Execute that rc against sliver-server
preinstall_sliver_armory() {
    # Try bundled cache first (offline-safe, fast)
    if stage_bundled_armory; then
        _sl_ok "Armory installed offline from bundle"
        return 0
    fi
    if ! command -v sliver-server >/dev/null 2>&1; then
        _sl_err "sliver-server not on PATH; skipping armory preload"
        return 1
    fi
    _sl_log "Unpacking sliver assets first"
    sliver-server unpack --force >> /var/log/portalgun/sliver-armory.log 2>&1 || true

    mkdir -p /root/.sliver-client/armories /root/.sliver-client/configs

    # Step 1: enumerate available packages
    _sl_log "Enumerating armory packages"
    local list_rc=/tmp/portalgun-sliver-list.rc
    local list_out=/tmp/portalgun-sliver-list.txt
    printf 'armory refresh\narmory list\nexit\n' > "$list_rc"
    timeout 180 sliver-server --rc "$list_rc" 2>&1 | \
        sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' > "$list_out"
    rm -f "$list_rc"

    # Parse: rows look like " Default   <name>   v0.0.X   Extension|Alias   ..."
    # Filter requires col 3 to be a vX.Y.Z and col 4 to be Extension or Alias —
    # this excludes the Bundles table (which has comma lists in col 3).
    mapfile -t pkgs < <(awk '
        /^ +Default[[:space:]]+[A-Za-z0-9_.-]+[[:space:]]+v[0-9]+\.[0-9]+/ {
            if ($4 == "Extension" || $4 == "Alias") print $2
        }
    ' "$list_out" | sort -u | grep -v '^$')
    rm -f "$list_out"

    if [ "${#pkgs[@]}" -eq 0 ]; then
        _sl_err "No armory packages enumerated (rc invocation may have failed)"
        return 1
    fi
    _sl_ok "Found ${#pkgs[@]} armory packages — installing each"

    # Step 2: write rc file with one install per package
    local install_rc=/tmp/portalgun-sliver-install.rc
    {
        echo 'armory refresh'
        for p in "${pkgs[@]}"; do
            echo "armory install $p"
        done
        echo 'exit'
    } > "$install_rc"

    # Step 3: execute install (one big timeout — 60min for ~200 packages)
    _sl_log "Installing ${#pkgs[@]} armory packages (this may take 30-60 min)"
    timeout 3600 sliver-server --rc "$install_rc" \
        >> /var/log/portalgun/sliver-armory.log 2>&1 \
        || _sl_err "armory install batch exited non-zero (continuing — partial cache is fine)"
    rm -f "$install_rc"

    # Sliver caches installed extensions under ~/.sliver-client/extensions/
    local n=0 ext_dir=/root/.sliver-client/extensions
    [ -d "$ext_dir" ] && n=$(find "$ext_dir" -maxdepth 1 -mindepth 1 -type d | wc -l)
    _sl_ok "Armory install finished — $n extensions cached under $ext_dir"
}

# Copy root's sliver-client state (configs, extensions, armory cache) out to
# every user's home so non-root sliver-client users get the same offline-ready
# set without re-downloading.
stage_armory_for_users() {
    [ -d /root/.sliver-client ] || return 0
    while IFS=: read -r user home; do
        [ "$user" = "root" ] && continue
        mkdir -p "$home/.sliver-client"
        for sub in extensions aliases armories configs; do
            [ -d "/root/.sliver-client/$sub" ] || continue
            mkdir -p "$home/.sliver-client/$sub"
            cp -ru "/root/.sliver-client/$sub/." "$home/.sliver-client/$sub/" 2>/dev/null || true
        done
        chown -R "$user:$user" "$home/.sliver-client" 2>/dev/null || true
    done < <(_sl_users)
    _sl_ok "Armory + extensions staged for every user"
}

register_sliver() {
    local reg_dir="/var/lib/portalgun/registry/sliver"
    mkdir -p "$reg_dir"
    cat > "$reg_dir/sliver.json" <<EOF
{
  "name": "sliver",
  "type": "sliver",
  "server": "$SLIVER_SERVER_BIN",
  "client": "$SLIVER_CLIENT_BIN",
  "armory_dir": "/root/.sliver-client/armories",
  "installed_at": "$(date -Iseconds)"
}
EOF
    _sl_ok "Registered → $reg_dir/sliver.json"
}

install_sliver() {
    mkdir -p "$SLIVER_DIR" /var/log/portalgun
    ensure_sliver_installed || return 1
    preinstall_sliver_armory
    stage_armory_for_users
    register_sliver
    _sl_ok "Sliver install complete. Server: sliver-server | Client: sliver-client"
}

update_sliver() {
    _sl_log "Updating Sliver and re-running armory install"
    sliver_direct_install || return 1
    preinstall_sliver_armory
    stage_armory_for_users
    _sl_ok "Sliver updated"
}
