#!/usr/bin/env bash
# portalgun verify
# Audits the installed system against the bundle and reports what's actually
# present, partially present, or missing. Designed to be run after `install all`
# to confirm the environment is complete.

verify_install() {
    local bundle="${1:-$PORTALGUN_ROOT/portalgun_bundle.json}"
    [ -f "$bundle" ] || bundle="/opt/portalgun/portalgun_bundle.json"
    if [ ! -f "$bundle" ]; then
        print_error "No bundle found at $bundle"
        return 1
    fi

    print_status "Verifying install against: $bundle"
    echo

    local pass=0 warn=0 fail=0
    local PASS_MARK="\033[0;32m✓\033[0m"
    local WARN_MARK="\033[1;33m!\033[0m"
    local FAIL_MARK="\033[0;31m✗\033[0m"
    _row() { printf '  %b %-32s %s\n' "$1" "$2" "$3"; }

    # ── APT packages ────────────────────────────────────────────────
    echo "── APT packages ──────────────────────────"
    local apt_list
    apt_list=$(python3 -c "import json;d=json.load(open('$bundle'));print('\n'.join(d['tools']['apt']))")
    local apt_total apt_installed apt_missing
    apt_total=$(echo "$apt_list" | wc -l)
    apt_installed=0; apt_missing=0
    # Some bundle entries (zoxide, starship, lazygit, atuin, etc.) are
    # technically apt-installable but install.sh stages them via direct
    # binary download. Treat "binary present in /usr/local/bin or ~/.local/bin"
    # as installed even if dpkg doesn't know about it.
    while IFS= read -r pkg; do
        if dpkg -s "$pkg" >/dev/null 2>&1 \
           || command -v "$pkg" >/dev/null 2>&1 \
           || [ -x "/usr/local/bin/$pkg" ] \
           || [ -x "/root/.local/bin/$pkg" ]; then
            apt_installed=$((apt_installed + 1))
        else
            apt_missing=$((apt_missing + 1))
        fi
    done <<< "$apt_list"
    if [ "$apt_missing" -eq 0 ]; then
        _row "$PASS_MARK" "apt packages" "$apt_installed/$apt_total installed"
        pass=$((pass + 1))
    else
        _row "$WARN_MARK" "apt packages" "$apt_installed/$apt_total installed ($apt_missing missing)"
        warn=$((warn + 1))
    fi

    # ── GitHub tools ────────────────────────────────────────────────
    echo "── GitHub tools ──────────────────────────"
    local gh_total gh_present=0 gh_missing=0
    gh_total=$(python3 -c "import json;d=json.load(open('$bundle'));print(len(d['tools']['github']))")
    while IFS=$'\t' read -r target raw_name; do
        # Different installers normalize dots/underscores differently. Try every
        # plausible variant and consider the tool present if ANY exists.
        local found=0 candidate
        for candidate in "$raw_name" \
                         "${raw_name//./-}" \
                         "${raw_name//./_}" \
                         "${raw_name//./}" \
                         "${raw_name//_/-}"; do
            if [ -d "$target/$candidate" ] && [ -n "$(ls -A "$target/$candidate" 2>/dev/null)" ]; then
                found=1
                break
            fi
        done
        if [ "$found" -eq 1 ]; then
            gh_present=$((gh_present + 1))
        else
            gh_missing=$((gh_missing + 1))
        fi
    done < <(python3 -c "
import json
d = json.load(open('$bundle'))
for g in d['tools']['github']:
    url = g['url']
    name = url.rstrip('/').replace('.git','').split('/')[-1].lower()
    print(g['target'] + '\t' + name)
")
    if [ "$gh_missing" -eq 0 ]; then
        _row "$PASS_MARK" "github tools" "$gh_present/$gh_total present"
        pass=$((pass + 1))
    else
        _row "$WARN_MARK" "github tools" "$gh_present/$gh_total present ($gh_missing missing)"
        warn=$((warn + 1))
    fi

    # ── README coverage ─────────────────────────────────────────────
    # Asserts every tool resolves to SOME offline README source. The frontend
    # fallback chain is file → apt man page → --help → metadata stub, so the
    # load-bearing checks are: (a) every github readme_path that is set points
    # at a real file on disk, and (b) every embedded static tool has a
    # static_readmes entry. Stubs guarantee the static side reaches 100%.
    echo "── README coverage ───────────────────────"
    local readme_report
    readme_report=$(python3 - "$PORTALGUN_WEB_DIR/portalgun_tools.json" "$PORTALGUN_WEB_DIR/index.html" "$PORTALGUN_LIB/extract_static_tools.py" <<'PY' 2>/dev/null
import json, os, sys, subprocess
manifest, html, extractor = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    d = json.load(open(manifest))
except Exception as e:
    print("ERR manifest %s" % e); sys.exit(0)

gh = d.get("tools", {}).get("github", [])
gh_with = [t for t in gh if t.get("readme_path")]
gh_bad = [t for t in gh_with if not os.path.isfile(t["readme_path"])]

static_map = d.get("static_readmes", {}) or {}
# Determine the embedded static-tool universe from the served HTML.
static_names = set()
try:
    subprocess.run(["python3", extractor, html], check=False,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for t in json.load(open("/tmp/static_tools.json")):
        static_names.add(t["name"])
except Exception:
    static_names = set(static_map)  # fall back to whatever is mapped
unmapped = [n for n in static_names if n not in static_map]

ok = (len(gh_bad) == 0) and (len(unmapped) == 0)
print("%s\t%d\t%d\t%d\t%d\t%d" % (
    "OK" if ok else "BAD",
    len(gh_with) - len(gh_bad), len(gh_with),
    len(static_names) - len(unmapped), len(static_names),
    len(static_map)))
PY
)
    if [ -z "$readme_report" ] || [ "${readme_report:0:3}" = "ERR" ]; then
        _row "$WARN_MARK" "README coverage" "manifest not present (skipped)"
        warn=$((warn + 1))
    else
        local r_status r_ghok r_ghtot r_stok r_sttot r_maptot
        IFS=$'\t' read -r r_status r_ghok r_ghtot r_stok r_sttot r_maptot <<< "$readme_report"
        if [ "$r_status" = "OK" ]; then
            _row "$PASS_MARK" "README coverage" "github $r_ghok/$r_ghtot on disk, static $r_stok/$r_sttot mapped ($r_maptot total)"
            pass=$((pass + 1))
        else
            _row "$WARN_MARK" "README coverage" "github $r_ghok/$r_ghtot on disk, static $r_stok/$r_sttot mapped — gaps fall back to stub/man/help"
            warn=$((warn + 1))
        fi
    fi

    # ── pip packages ────────────────────────────────────────────────
    echo "── pip packages ──────────────────────────"
    local pip_total pip_installed=0 pip_missing=0
    pip_total=$(python3 -c "import json;d=json.load(open('$bundle'));print(len(d['tools']['pip']))")
    if [ -x /opt/pentest-venv/bin/pip ]; then
        local installed_set
        # Normalize the same way pip does: lowercase + collapse _ → -
        installed_set=$(/opt/pentest-venv/bin/pip list --format=freeze 2>/dev/null | cut -d= -f1 | tr '[:upper:]' '[:lower:]' | tr '_' '-' | sort -u)
        while IFS= read -r spec; do
            local pkg
            pkg=$(echo "$spec" | sed 's/[<>=!~].*//' | tr '[:upper:]' '[:lower:]' | tr '_' '-' | tr -d ' ')
            if echo "$installed_set" | grep -qx "$pkg"; then
                pip_installed=$((pip_installed + 1))
            else
                pip_missing=$((pip_missing + 1))
            fi
        done < <(python3 -c "import json;d=json.load(open('$bundle'));print('\n'.join(d['tools']['pip']))")
        if [ "$pip_missing" -eq 0 ]; then
            _row "$PASS_MARK" "pip (pentest-venv)" "$pip_installed/$pip_total installed"
            pass=$((pass + 1))
        else
            _row "$WARN_MARK" "pip (pentest-venv)" "$pip_installed/$pip_total installed ($pip_missing missing)"
            warn=$((warn + 1))
        fi
    else
        _row "$FAIL_MARK" "pip (pentest-venv)" "/opt/pentest-venv missing"
        fail=$((fail + 1))
    fi

    # ── cargo crates ────────────────────────────────────────────────
    echo "── cargo crates ──────────────────────────"
    local cargo_total cargo_installed=0 cargo_missing=0
    cargo_total=$(python3 -c "import json;d=json.load(open('$bundle'));print(len(d['tools'].get('cargo',[])))")
    # Crate name ≠ binary name (e.g. cargo-update ships cargo-install-update).
    # Use `cargo install --list` for the source of truth.
    local cargo_list
    cargo_list=$(cargo install --list 2>/dev/null | grep -E '^[a-z]' | awk -F: '{print $1}' | awk '{print $1}' | sort -u)
    while IFS= read -r crate; do
        [ -z "$crate" ] && continue
        if echo "$cargo_list" | grep -qx "$crate" || \
           [ -x "/root/.cargo/bin/$crate" ] || \
           command -v "$crate" >/dev/null 2>&1 || \
           ls /root/.cargo/bin/$crate* >/dev/null 2>&1; then
            cargo_installed=$((cargo_installed + 1))
        else
            cargo_missing=$((cargo_missing + 1))
        fi
    done < <(python3 -c "import json;d=json.load(open('$bundle'));print('\n'.join(d['tools'].get('cargo',[])))")
    if [ "$cargo_missing" -eq 0 ]; then
        _row "$PASS_MARK" "cargo crates" "$cargo_installed/$cargo_total installed"
        pass=$((pass + 1))
    else
        _row "$WARN_MARK" "cargo crates" "$cargo_installed/$cargo_total installed ($cargo_missing missing)"
        warn=$((warn + 1))
    fi

    # ── Offline wheelhouse ──────────────────────────────────────────
    echo "── Offline pip wheelhouse ────────────────"
    local wheels_dir="${PORTALGUN_WHEELS:-/opt/portalgun/wheels}"
    local wh_count=0 wh_size="0"
    if [ -d "$wheels_dir" ]; then
        wh_count=$(find "$wheels_dir" -maxdepth 1 -type f \( -name '*.whl' -o -name '*.tar.gz' -o -name '*.zip' \) 2>/dev/null | wc -l)
        wh_size=$(du -sh "$wheels_dir" 2>/dev/null | cut -f1)
    fi
    local pip_mode="online"
    grep -q 'no-index' /etc/pip.conf 2>/dev/null && pip_mode="offline"
    if [ "$wh_count" -ge 200 ]; then
        _row "$PASS_MARK" "pip wheelhouse" "$wh_count wheels ($wh_size), pip=$pip_mode"
        pass=$((pass + 1))
    elif [ "$wh_count" -gt 0 ]; then
        _row "$WARN_MARK" "pip wheelhouse" "$wh_count wheels ($wh_size) — partial; run: portalgun build-wheelhouse"
        warn=$((warn + 1))
    else
        _row "$WARN_MARK" "pip wheelhouse" "empty — run (online): portalgun build-wheelhouse"
        warn=$((warn + 1))
    fi
    local apt_mirror_dir="${PORTALGUN_APT_MIRROR:-/opt/portalgun/apt-mirror}"
    local am_count=0 am_size="0"
    if [ -d "$apt_mirror_dir/pool" ]; then
        am_count=$(find "$apt_mirror_dir/pool" -name '*.deb' 2>/dev/null | wc -l)
        am_size=$(du -sh "$apt_mirror_dir" 2>/dev/null | cut -f1)
    fi
    if [ "$am_count" -ge 100 ]; then
        _row "$PASS_MARK" "apt mirror" "$am_count .debs ($am_size)"
        pass=$((pass + 1))
    elif [ "$am_count" -gt 0 ]; then
        _row "$WARN_MARK" "apt mirror" "$am_count .debs ($am_size) — partial; run: portalgun build-apt-mirror"
        warn=$((warn + 1))
    else
        _row "$WARN_MARK" "apt mirror" "empty — run (online): portalgun build-apt-mirror"
        warn=$((warn + 1))
    fi

    # ── Burp Suite Pro ───────────────────────────────────────────────
    echo "── Burp Suite Pro ────────────────────────"
    if [ -f /opt/portalgun/burpsuite/BurpSuitePro.jar ]; then
        local jar_size
        jar_size=$(stat -c %s /opt/portalgun/burpsuite/BurpSuitePro.jar 2>/dev/null || echo 0)
        if [ "$jar_size" -gt 100000000 ]; then
            _row "$PASS_MARK" "Burp Pro JAR" "$((jar_size / 1024 / 1024))MB"
            pass=$((pass + 1))
        else
            _row "$FAIL_MARK" "Burp Pro JAR" "too small ($jar_size bytes)"
            fail=$((fail + 1))
        fi
    else
        _row "$FAIL_MARK" "Burp Pro JAR" "missing"
        fail=$((fail + 1))
    fi
    if [ -x /usr/local/bin/burpsuite-pro ]; then
        _row "$PASS_MARK" "Burp launcher" "/usr/local/bin/burpsuite-pro"
        pass=$((pass + 1))
    else
        _row "$FAIL_MARK" "Burp launcher" "missing"
        fail=$((fail + 1))
    fi
    local bapp_count=0
    [ -d /opt/portalgun/burpsuite/bapps ] && \
        bapp_count=$(find /opt/portalgun/burpsuite/bapps -maxdepth 1 -mindepth 1 -type d | wc -l)
    if [ "$bapp_count" -ge 450 ]; then
        _row "$PASS_MARK" "BApps cached" "$bapp_count entries"
        pass=$((pass + 1))
    elif [ "$bapp_count" -gt 0 ]; then
        _row "$WARN_MARK" "BApps cached" "$bapp_count entries (expected ~499)"
        warn=$((warn + 1))
    else
        _row "$FAIL_MARK" "BApps cached" "0 — bundle preload failed"
        fail=$((fail + 1))
    fi
    # Honest check (exegol-style symlink model): the persistent store must hold
    # a prefs.xml with an actual license key, and at least one user's burp dir
    # must be SYMLINKED to that store (so a one-time activation persists).
    local store_prefs="/opt/portalgun/burpsuite/burp-config/.java/.userPrefs/burp/prefs.xml"
    local has_key=0 symlinked=0
    [ -s "$store_prefs" ] && grep -q 'key="license1"' "$store_prefs" 2>/dev/null && has_key=1
    local up
    for up in /root/.java/.userPrefs/burp /home/*/.java/.userPrefs/burp; do
        if [ -L "$up" ]; then symlinked=1; break; fi
    done
    if [ "$has_key" -eq 1 ] && [ "$symlinked" -eq 1 ]; then
        _row "$PASS_MARK" "Burp license" "license key in store, users symlinked (activates once, persists)"
        pass=$((pass + 1))
    elif [ "$has_key" -eq 1 ]; then
        _row "$WARN_MARK" "Burp license" "key staged but users not symlinked — run: portalgun import burp-license <file>"
        warn=$((warn + 1))
    else
        _row "$WARN_MARK" "Burp license" "no license — upload prefs.xml (Admin → Burp License) or: portalgun import burp-license <file>"
        warn=$((warn + 1))
    fi

    # ── Sliver ───────────────────────────────────────────────────────
    echo "── Sliver C2 ─────────────────────────────"
    command -v sliver-server >/dev/null 2>&1 && \
        { _row "$PASS_MARK" "sliver-server" "$(command -v sliver-server)"; pass=$((pass+1)); } || \
        { _row "$FAIL_MARK" "sliver-server" "missing"; fail=$((fail+1)); }
    command -v sliver-client >/dev/null 2>&1 && \
        { _row "$PASS_MARK" "sliver-client" "$(command -v sliver-client)"; pass=$((pass+1)); } || \
        { _row "$FAIL_MARK" "sliver-client" "missing"; fail=$((fail+1)); }
    local ext_count=0 alias_count=0
    [ -d /root/.sliver-client/extensions ] && \
        ext_count=$(find /root/.sliver-client/extensions -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)
    [ -d /root/.sliver-client/aliases ] && \
        alias_count=$(find /root/.sliver-client/aliases -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)
    if [ "$ext_count" -ge 140 ]; then
        _row "$PASS_MARK" "Sliver extensions" "$ext_count staged"
        pass=$((pass + 1))
    elif [ "$ext_count" -gt 0 ]; then
        _row "$WARN_MARK" "Sliver extensions" "$ext_count staged (expected ~152)"
        warn=$((warn + 1))
    else
        _row "$FAIL_MARK" "Sliver extensions" "0 — bundled armory missing"
        fail=$((fail + 1))
    fi
    if [ "$alias_count" -ge 20 ]; then
        _row "$PASS_MARK" "Sliver aliases" "$alias_count staged"
        pass=$((pass + 1))
    else
        _row "$WARN_MARK" "Sliver aliases" "$alias_count staged (expected ~22)"
        warn=$((warn + 1))
    fi

    # ── Burp smoke test ─────────────────────────────────────────────
    echo "── Burp smoke test ───────────────────────"
    if [ -f /opt/portalgun/burpsuite/BurpSuitePro.jar ]; then
        # Lightweight: --help exits fast, proves Java can load the JAR
        local burp_ver
        burp_ver=$(timeout 30 java -jar /opt/portalgun/burpsuite/BurpSuitePro.jar --version 2>/dev/null | head -1)
        if echo "$burp_ver" | grep -q "Burp Suite"; then
            _row "$PASS_MARK" "Burp JAR loads" "$(echo $burp_ver | head -c 80)"
            pass=$((pass + 1))
        else
            _row "$WARN_MARK" "Burp JAR loads" "version probe returned: $burp_ver"
            warn=$((warn + 1))
        fi
    fi

    # ── Sliver extension validity ───────────────────────────────────
    # Honest measure: how many staged extensions have a VALID manifest
    # (a command_name, or a v2 commands[] array) with all referenced binaries
    # present. NOT the online `armory` ✅ count, which only reflects how many of
    # the ~58-entry remote catalog match locally and needs internet.
    echo "── Sliver extension validity ─────────────"
    local sl_valid sl_total
    read -r sl_valid sl_total < <(python3 - <<'PY' 2>/dev/null
import json, os, glob
base = "/root/.sliver-client/extensions"
dirs = [d for d in glob.glob(base + "/*") if os.path.isdir(d)]
valid = 0
for d in dirs:
    mf = os.path.join(d, "extension.json")
    if not os.path.isfile(mf):
        continue
    try:
        m = json.load(open(mf))
    except Exception:
        continue
    cmds = m.get("commands") or ([m] if m.get("command_name") else [])
    if not cmds:
        continue
    ok = True
    for c in cmds:
        for f in c.get("files", []):
            p = f.get("path")
            if p and not os.path.isfile(os.path.join(d, p)):
                ok = False
    if ok:
        valid += 1
print(valid, len(dirs))
PY
)
    sl_valid=${sl_valid:-0}; sl_total=${sl_total:-0}
    if [ "$sl_total" -gt 0 ] && [ "$sl_valid" -eq "$sl_total" ]; then
        _row "$PASS_MARK" "Sliver extensions valid" "$sl_valid/$sl_total manifests valid (v1+v2), binaries present"
        pass=$((pass + 1))
    elif [ "$sl_valid" -gt 0 ]; then
        _row "$WARN_MARK" "Sliver extensions valid" "$sl_valid/$sl_total valid — $((sl_total - sl_valid)) bad manifest/missing files"
        warn=$((warn + 1))
    else
        _row "$FAIL_MARK" "Sliver extensions valid" "0 valid manifests"
        fail=$((fail + 1))
    fi

    # ── Offline armory ──────────────────────────────────────────────
    # The local armory server lets `armory` browse + install work with no
    # internet. Check the service is up, the signed index exists, and a user
    # is pointed at it (no GitHub Default).
    local armory_root="/opt/portalgun/sliver-armory/armory-data"
    local armory_pkgs=0 armory_up=0 armory_cfg=0
    if [ -s "$armory_root/.armory-index.json" ] && [ -s "$armory_root/.armory-index.minisig" ]; then
        armory_pkgs=$(python3 -c "import json;d=json.load(open('$armory_root/.armory-index.json'));print(len(d.get('extensions',[]))+len(d.get('aliases',[])))" 2>/dev/null || echo 0)
    fi
    curl -s -o /dev/null -w "%{http_code}" --max-time 5 http://127.0.0.1:8888/health 2>/dev/null | grep -q 200 && armory_up=1
    grep -rqs '127.0.0.1:8888' /root/.sliver/armories.json /root/.sliver-client/armories.json /home/*/.sliver/armories.json /home/*/.sliver-client/armories.json 2>/dev/null && armory_cfg=1
    if [ "$armory_pkgs" -ge 100 ] && [ "$armory_up" -eq 1 ] && [ "$armory_cfg" -eq 1 ]; then
        _row "$PASS_MARK" "Offline armory" "$armory_pkgs pkgs, server up, clients pointed local"
        pass=$((pass + 1))
    elif [ "$armory_pkgs" -gt 0 ]; then
        _row "$WARN_MARK" "Offline armory" "$armory_pkgs pkgs indexed but server down/unconfigured — run: portalgun build-sliver-armory"
        warn=$((warn + 1))
    else
        _row "$WARN_MARK" "Offline armory" "not built — run (online): portalgun build-sliver-armory"
        warn=$((warn + 1))
    fi

    # ── Web UI ───────────────────────────────────────────────────────
    echo "── Web UI ────────────────────────────────"
    if curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:1337/ 2>/dev/null | grep -q 200; then
        _row "$PASS_MARK" "tools_server :1337" "HTTP 200"
        pass=$((pass + 1))
    else
        _row "$WARN_MARK" "tools_server :1337" "not responding (start with: systemctl start tools-server)"
        warn=$((warn + 1))
    fi
    if [ -f /opt/tools-docs/portalgun_tools.json ]; then
        local manifest_total
        manifest_total=$(python3 -c "import json;d=json.load(open('/opt/tools-docs/portalgun_tools.json'));print(d.get('totals',{}).get('total','?'))" 2>/dev/null)
        _row "$PASS_MARK" "web manifest" "$manifest_total tools listed"
        pass=$((pass + 1))
    else
        _row "$FAIL_MARK" "web manifest" "missing"
        fail=$((fail + 1))
    fi

    # ── Registry ─────────────────────────────────────────────────────
    echo "── Registry ──────────────────────────────"
    local reg_apt reg_gh reg_pip reg_cargo
    reg_apt=$(find /var/lib/portalgun/registry/apt -name '*.json' 2>/dev/null | wc -l)
    reg_gh=$(find /var/lib/portalgun/registry/github -name '*.json' 2>/dev/null | wc -l)
    reg_pip=$(find /var/lib/portalgun/registry/pip -name '*.json' 2>/dev/null | wc -l)
    reg_cargo=$(find /var/lib/portalgun/registry/cargo -name '*.json' 2>/dev/null | wc -l)
    _row "$PASS_MARK" "registry" "apt=$reg_apt github=$reg_gh pip=$reg_pip cargo=$reg_cargo"

    # ── Summary ──────────────────────────────────────────────────────
    echo
    echo "════════════════════════════════════════"
    printf '  Passed:  %d\n  Warnings: %d\n  Failed:  %d\n' "$pass" "$warn" "$fail"
    echo "════════════════════════════════════════"
    if [ "$fail" -gt 0 ]; then
        return 2
    elif [ "$warn" -gt 0 ]; then
        return 1
    fi
    return 0
}
