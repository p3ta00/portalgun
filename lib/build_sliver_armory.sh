#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────
# portalgun local Sliver armory (offline)
# ─────────────────────────────────────────────────────────────────────────
# Stands up a LOCAL Sliver armory so the `armory` command (browse + install)
# works with NO internet. Uses sliverarmory/private-armory's `armory-server`
# to sign the bundled packages and serve them over http://127.0.0.1:8888, with
# each user's ~/.sliver[-client]/armories.json pointed at it (no GitHub default).
#
# Sliver requires http(s) (file:// is rejected) and verifies minisign signatures,
# so a plain file drop can't work — armory-server generates a key, signs the
# index + packages, and serves the endpoints the client expects.
#
# Built once on the master (online to fetch armory-server the first time); the
# signed armory-data is baked into the image so every clone serves it offline.

ARMORY_DIR="${PORTALGUN_SLIVER_ARMORY:-/opt/portalgun/sliver-armory}"
ARMORY_ROOT="$ARMORY_DIR/armory-data"
ARMORY_BIN="$ARMORY_DIR/bin/armory-server"
ARMORY_SRC="${PORTALGUN_SLIVER_BUNDLE:-/opt/portalgun/data/sliver-armory}"
ARMORY_PORT="${PORTALGUN_SLIVER_ARMORY_PORT:-8888}"

_sa_log() { printf '\033[0;34m[*]\033[0m %s\n' "$*"; }
_sa_ok()  { printf '\033[0;32m[+]\033[0m %s\n' "$*"; }
_sa_err() { printf '\033[0;31m[!]\033[0m %s\n' "$*" >&2; }

# Get the armory-server binary: bundled copy first (offline), else download.
ensure_armory_server() {
    [ -x "$ARMORY_BIN" ] && return 0
    mkdir -p "$(dirname "$ARMORY_BIN")"
    if [ -f "$ARMORY_DIR/armory-server.bundled" ]; then
        cp "$ARMORY_DIR/armory-server.bundled" "$ARMORY_BIN" && chmod +x "$ARMORY_BIN" && return 0
    fi
    local url
    url=$(curl -s --max-time 20 https://api.github.com/repos/sliverarmory/private-armory/releases/latest \
          | python3 -c "import json,sys;print([a['browser_download_url'] for a in json.load(sys.stdin)['assets'] if a['name']=='armory-server_linux-amd64'][0])" 2>/dev/null)
    [ -z "$url" ] && { _sa_err "could not resolve armory-server download URL"; return 1; }
    curl -fsSL --max-time 180 -o "$ARMORY_BIN" "$url" && chmod +x "$ARMORY_BIN"
}

# Stage bundled package tarballs, named by their INTERNAL manifest command_name
# (some bundle tarballs are misnamed). armory-server v0.0.1 indexes only the v1
# single-command format; v2 multi-command packages (package_name + commands[])
# are skipped here but remain pre-installed in ~/.sliver-client/extensions and
# usable in-session.
stage_armory_packages() {
    rm -rf "$ARMORY_ROOT/extensions" "$ARMORY_ROOT/aliases" \
           "$ARMORY_ROOT/.armory-index.json" "$ARMORY_ROOT/.armory-index.minisig" \
           "$ARMORY_ROOT/.armory-minisigs"
    mkdir -p "$ARMORY_ROOT/extensions" "$ARMORY_ROOT/aliases"
    python3 - "$ARMORY_SRC" "$ARMORY_ROOT" <<'PY'
import os, sys, glob, tarfile, json, shutil
src, root = sys.argv[1], sys.argv[2]
seen = set(); ext = ali = 0
for tb in glob.glob(os.path.join(src, "**", "*.tar.gz"), recursive=True):
    try:
        with tarfile.open(tb) as t:
            mf = kind = None
            for n in t.getnames():
                b = os.path.basename(n)
                if b == "extension.json": mf, kind = n, "extensions"; break
                if b == "alias.json":     mf, kind = n, "aliases"; break
            if not mf:
                continue
            m = json.load(t.extractfile(mf))
    except Exception:
        continue
    cn = (m.get("command_name") or "").strip()
    if not cn or cn in seen:
        continue
    seen.add(cn)
    shutil.copy(tb, os.path.join(root, kind, cn + ".tar.gz"))
    ext += (kind == "extensions"); ali += (kind == "aliases")
print("%d %d" % (ext, ali))
PY
}

_armory_disable_autorefresh() {
    python3 - "$ARMORY_ROOT/config.json" <<'PY' 2>/dev/null
import json, sys
p = sys.argv[1]
c = json.load(open(p))
def walk(o):
    if isinstance(o, dict):
        for k in list(o):
            if k == "auto_refresh_enabled":
                o[k] = False
            walk(o[k])
walk(c)
json.dump(c, open(p, "w"), indent=2)
PY
}

install_armory_service() {
    cat > /etc/systemd/system/portalgun-sliver-armory.service <<UNIT
[Unit]
Description=portalgun local Sliver armory (offline)
After=network.target
[Service]
Type=simple
ExecStart=$ARMORY_BIN -d $ARMORY_ROOT -g local -A -m 127.0.0.1 -p $ARMORY_PORT -a $ARMORY_DIR/pass.txt
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable --now portalgun-sliver-armory.service >/dev/null 2>&1 || true
}

# Point every user's server console (~/.sliver) and client (~/.sliver-client) at
# the local armory. No "Default" entry → the GitHub armory is never contacted.
configure_armories_json() {
    local pk
    pk=$(python3 -c "import json;print(json.load(open('$ARMORY_ROOT/config.json'))['public_key'])" 2>/dev/null)
    [ -z "$pk" ] && { _sa_err "no public_key in armory config"; return 1; }
    local cfg="[{\"name\":\"Offline\",\"enabled\":true,\"repo_url\":\"http://127.0.0.1:$ARMORY_PORT/armory/index\",\"public_key\":\"$pk\",\"authorization\":\"\"}]"
    local home u g
    for home in /root /home/*; do
        [ -d "$home" ] || continue
        u=$(stat -c %U "$home" 2>/dev/null); g=$(stat -c %G "$home" 2>/dev/null)
        local d
        for d in "$home/.sliver" "$home/.sliver-client"; do
            mkdir -p "$d"
            echo "$cfg" > "$d/armories.json"
            [ -n "$u" ] && chown "$u:$g" "$d/armories.json" 2>/dev/null || true
        done
    done
}

build_sliver_armory() {
    if [ ! -d "$ARMORY_SRC" ]; then
        _sa_log "No bundled armory at $ARMORY_SRC — skipping local armory"
        return 0
    fi
    mkdir -p "$ARMORY_ROOT"
    ensure_armory_server || { _sa_err "armory-server unavailable — local armory skipped"; return 1; }

    _sa_log "Staging armory packages (by internal manifest name)..."
    local counts; counts=$(stage_armory_packages)
    _sa_ok "Staged $counts extensions/aliases (v2 multi-command pkgs stay pre-installed)"

    printf '' > "$ARMORY_DIR/pass.txt"
    _sa_log "Signing packages + building local armory index (takes ~1-2 min)..."
    # -r refreshes (build+sign) then serves; run detached, wait for the index +
    # signatures to finish, then stop it so the managed service can serve.
    timeout 240 "$ARMORY_BIN" -d "$ARMORY_ROOT" -g local -A -m 127.0.0.1 -p "$ARMORY_PORT" \
        -a "$ARMORY_DIR/pass.txt" -r </dev/null >"$ARMORY_DIR/refresh.log" 2>&1 &
    local rp=$! i
    # Done when the index AND its signature are written (per-package signatures
    # are produced on-demand at install time, not here).
    for i in $(seq 1 120); do
        [ -s "$ARMORY_ROOT/.armory-index.json" ] && [ -s "$ARMORY_ROOT/.armory-index.minisig" ] && break
        sleep 2
    done
    sleep 2
    kill "$rp" 2>/dev/null
    pkill -f "armory-server .*$ARMORY_ROOT" 2>/dev/null

    if [ ! -f "$ARMORY_ROOT/.armory-index.json" ]; then
        _sa_err "index build failed (see $ARMORY_DIR/refresh.log + $ARMORY_ROOT/logs/app.log)"
        return 1
    fi
    _armory_disable_autorefresh
    install_armory_service
    configure_armories_json
    _sa_ok "Local Sliver armory ready — 'armory' works offline (127.0.0.1:$ARMORY_PORT)"
}
