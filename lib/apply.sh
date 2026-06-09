#!/bin/bash
# portalgun apply — install all tools from a bundle JSON

# Phase time weights (based on observed install times):
#   apt:    35%  (0–35)
#   github: 45%  (35–80)
#   pip:    15%  (80–95)
#   cargo:  5%   (95–100)
_progress() {
    local pct="$1" label="$2"
    echo "PROGRESS:${pct}:${label}"
}

# When apply.sh is sourced standalone (install.sh runs
# `bash -c "source apply.sh && apply_bundle"`), the portalgun environment and
# its helper libs aren't loaded, so print_*/registry_*/register_all/
# sync_web_manifest are all undefined. Bootstrap the env + libs here so the
# bundle replay (registry backfill + web sync) works regardless of how it's run.
if ! declare -F print_status >/dev/null 2>&1 || ! declare -F registry_write >/dev/null 2>&1; then
    _apply_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    : "${PORTALGUN_ROOT:=/opt/portalgun}"
    : "${PORTALGUN_LIB:=$_apply_dir}"
    : "${PORTALGUN_REGISTRY:=/var/lib/portalgun/registry}"
    : "${PORTALGUN_LOG_DIR:=/var/log/portalgun}"
    : "${PORTALGUN_TOOLS_BASE:=/opt/tools}"
    : "${PORTALGUN_WEB_DIR:=/opt/tools-docs}"
    export PORTALGUN_ROOT PORTALGUN_LIB PORTALGUN_REGISTRY PORTALGUN_LOG_DIR \
           PORTALGUN_TOOLS_BASE PORTALGUN_WEB_DIR
    for _l in common.sh registry.sh register.sh sync_web.sh; do
        # shellcheck source=/dev/null
        [ -f "$_apply_dir/$_l" ] && source "$_apply_dir/$_l"
    done
    # Last-resort logging shims if common.sh was missing entirely.
    if ! declare -F print_status >/dev/null 2>&1; then
        print_status()  { echo "[*] $*"; }
        print_success() { echo "[+] $*"; }
        print_warning() { echo "[!] $*"; }
        print_error()   { echo "[-] $*" >&2; }
    fi
fi



# Hoisted out of apply_bundle — bash nested functions pollute global scope
_apply_dotfiles_for_user() {
    local user="$1" CONFIGS_DIR="$2"
    local home
    home=$(getent passwd "$user" | cut -d: -f6)
    [ -z "$home" ] || [ ! -d "$home" ] && return

    print_status "  Configuring $user ($home)..."

    [ -f "$CONFIGS_DIR/zshrc" ] && cp "$CONFIGS_DIR/zshrc" "$home/.zshrc" && chown "$user:$user" "$home/.zshrc" 2>/dev/null || true
    [ -f "$CONFIGS_DIR/tmux.conf" ] && cp "$CONFIGS_DIR/tmux.conf" "$home/.tmux.conf" && chown "$user:$user" "$home/.tmux.conf" 2>/dev/null || true
    mkdir -p "$home/.config"
    [ -f "$CONFIGS_DIR/starship.toml" ] && cp "$CONFIGS_DIR/starship.toml" "$home/.config/starship.toml" && chown "$user:$user" "$home/.config/starship.toml" 2>/dev/null || true
    mkdir -p "$home/.config/kitty"
    [ -f "$CONFIGS_DIR/kitty.conf" ] && cp "$CONFIGS_DIR/kitty.conf" "$home/.config/kitty/kitty.conf" && chown -R "$user:$user" "$home/.config/kitty" 2>/dev/null || true

    # zellij
    local ZELLIJ_CONFIGS="$CONFIGS_DIR/zellij"
    if [ -d "$ZELLIJ_CONFIGS" ]; then
        mkdir -p "$home/.config/zellij/layouts" "$home/.config/zellij/plugins"
        cp -r "$ZELLIJ_CONFIGS/"* "$home/.config/zellij/" 2>/dev/null || true
        chown -R "$user:$user" "$home/.config/zellij" 2>/dev/null || true
    fi

    # oh-my-zsh
    if [ ! -d "$home/.oh-my-zsh" ]; then
        print_status "    Installing oh-my-zsh for $user..."
        if [ "$user" = "root" ]; then
            sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended 2>/dev/null || true
        else
            sudo -u "$user" sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended 2>/dev/null || true
        fi
        # oh-my-zsh overwrites .zshrc — restore our config
        [ -f "$CONFIGS_DIR/zshrc" ] && cp "$CONFIGS_DIR/zshrc" "$home/.zshrc" && chown "$user:$user" "$home/.zshrc" 2>/dev/null || true
    fi

    # zsh plugins
    local ZSH_CUSTOM="$home/.oh-my-zsh/custom"
    for plugin_url in "https://github.com/zsh-users/zsh-syntax-highlighting.git" "https://github.com/zsh-users/zsh-autosuggestions"; do
        local plugin_name
        plugin_name=$(basename "$plugin_url" .git)
        if [ ! -d "$ZSH_CUSTOM/plugins/$plugin_name" ]; then
            [ "$user" = "root" ] && git clone -q "$plugin_url" "$ZSH_CUSTOM/plugins/$plugin_name" 2>/dev/null || true
            [ "$user" != "root" ] && sudo -u "$user" git clone -q "$plugin_url" "$ZSH_CUSTOM/plugins/$plugin_name" 2>/dev/null || true
        fi
    done

    # TPM + tmux plugins — pre-clone (TPM headless install doesn't work outside tmux session)
    mkdir -p "$home/.tmux/plugins"
    if [ ! -d "$home/.tmux/plugins/tpm" ]; then
        [ "$user" = "root" ] && git clone -q https://github.com/tmux-plugins/tpm "$home/.tmux/plugins/tpm" 2>/dev/null || true
        [ "$user" != "root" ] && sudo -u "$user" git clone -q https://github.com/tmux-plugins/tpm "$home/.tmux/plugins/tpm" 2>/dev/null || true
    fi
    for plugin_url in "https://github.com/tmux-plugins/tmux-sensible" "https://github.com/tmux-plugins/tmux-resurrect" "https://github.com/tmux-plugins/tmux-yank"; do
        local plugin_name
        plugin_name=$(basename "$plugin_url")
        if [ ! -d "$home/.tmux/plugins/$plugin_name" ]; then
            [ "$user" = "root" ] && git clone -q "$plugin_url" "$home/.tmux/plugins/$plugin_name" 2>/dev/null || true
            [ "$user" != "root" ] && sudo -u "$user" git clone -q "$plugin_url" "$home/.tmux/plugins/$plugin_name" 2>/dev/null || true
        fi
    done

    # Only chsh if not already zsh — don't force it unconditionally
    local current_shell
    current_shell=$(getent passwd "$user" | cut -d: -f7)
    [ "$current_shell" != "/usr/bin/zsh" ] && chsh -s /usr/bin/zsh "$user" 2>/dev/null || true
    print_success "    $user: shell + tmux + zellij configured"
}

apply_bundle() {
    # Separate bundle file from flags — first non-flag arg is the bundle path
    local bundle_file=""
    local run_apt=1 run_github=1 run_pip=1 run_cargo=1
    for arg in "$@"; do
        if [[ "$arg" != --* ]] && [ -z "$bundle_file" ]; then
            bundle_file="$arg"
            continue
        fi
        case "$arg" in
            --only-apt)    run_github=0; run_pip=0; run_cargo=0 ;;
            --only-github) run_apt=0;    run_pip=0; run_cargo=0 ;;
            --only-pip)    run_apt=0;    run_github=0; run_cargo=0 ;;
            --only-cargo)  run_apt=0;    run_github=0; run_pip=0 ;;
            --skip-apt)    run_apt=0 ;;
            --skip-github) run_github=0 ;;
            --skip-pip)    run_pip=0 ;;
            --skip-cargo)  run_cargo=0 ;;
            --phases=*)
                local phases="${arg#--phases=}"
                run_apt=0; run_github=0; run_pip=0; run_cargo=0
                echo "$phases" | grep -q "apt"    && run_apt=1
                echo "$phases" | grep -q "github" && run_github=1
                echo "$phases" | grep -q "pip"    && run_pip=1
                echo "$phases" | grep -q "cargo"  && run_cargo=1
                ;;
        esac
    done

    if [ -z "$bundle_file" ]; then
        for candidate in \
            "$PORTALGUN_REPO_DIR/portalgun_bundle.json" \
            "$PORTALGUN_REPO_DIR/data/portalgun_bundle.json" \
            "/opt/portalgun/portalgun_bundle.json" \
            "/home/kali/portalgun/portalgun_bundle.json" \
            "./portalgun_bundle.json"; do
            if [ -f "$candidate" ]; then
                bundle_file="$candidate"
                break
            fi
        done
    fi

    if [ -z "$bundle_file" ] || [ ! -f "$bundle_file" ]; then
        print_error "No portalgun_bundle.json found. Run: portalgun export"
        exit 1
    fi

    require_root install all "$bundle_file"

    if ! jq empty "$bundle_file" 2>/dev/null; then
        print_error "Invalid JSON: $bundle_file"
        exit 1
    fi

    local version
    version=$(jq -r '.version // "?"' "$bundle_file")
    local apt_count github_count pip_count cargo_count
    apt_count=$(jq '.tools.apt | length'             "$bundle_file")
    github_count=$(jq '.tools.github | length'       "$bundle_file")
    pip_count=$(jq '(.tools.pip // []) | length'     "$bundle_file")
    cargo_count=$(jq '(.tools.cargo // []) | length' "$bundle_file")

    _progress 0 "Starting install..."
    print_status "Applying bundle (v${version}): $apt_count apt, $github_count github, $pip_count pip, $cargo_count cargo"
    echo ""

    # ── APT (0–35%) ──────────────────────────────────────────────────
    if [ "$apt_count" -gt 0 ] && [ "$run_apt" -eq 1 ]; then
        _progress 1 "Phase 1: Resolving apt packages..."
        print_status "Phase 1: apt packages ($apt_count)"

        local apt_needed=()
        while IFS= read -r pkg; do
            [ -z "$pkg" ] && continue
            # Skip if either the registry knows about it OR dpkg shows it
            # installed system-wide. Falling back to dpkg keeps idempotency
            # honest when apt was driven by install.sh's legacy path (which
            # doesn't touch the registry) or by manual sysadmin work.
            if registry_exists apt "$pkg" || dpkg -s "$pkg" >/dev/null 2>&1; then
                continue
            fi
            apt_needed+=("$pkg")
        done < <(jq -r '.tools.apt[]' "$bundle_file")

        local apt_skip=$(( apt_count - ${#apt_needed[@]} ))
        local apt_total=${#apt_needed[@]}
        print_status "  $apt_skip already installed, $apt_total to install"

        if [ "$apt_total" -gt 0 ]; then
            _progress 2 "Phase 1: Downloading apt packages ($apt_total)..."
            local apt_done=0
            # Use process substitution (not pipe) to avoid subshell variable loss
            while IFS= read -r line; do
                if echo "$line" | grep -qE "^Setting up|^Unpacking"; then
                    local pkg_name
                    pkg_name=$(echo "$line" | sed 's/^Setting up //;s/^Unpacking //' | grep -oE '^[a-z][a-z0-9.+_-]+')
                    (( apt_done++ )) || true
                    local display_done=$(( apt_done > apt_total ? apt_total : apt_done ))
                    local pct=$(( 2 + ( display_done * 32 / apt_total ) ))
                    [ "$pct" -gt 34 ] && pct=34
                    _progress "$pct" "Phase 1: apt [$display_done/$apt_total] $pkg_name"
                    printf "  ${BLUE}[apt]${NC} [%d/%d] %s\n" "$display_done" "$apt_total" "$pkg_name"
                fi
            done < <(DEBIAN_FRONTEND=noninteractive apt-get install -y "${apt_needed[@]}" 2>&1)

            for pkg in "${apt_needed[@]}"; do
                if dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
                    local version_str
                    version_str=$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null || echo "unknown")
                    local json
                    json=$(jq -n \
                        --arg name    "$pkg" \
                        --arg package "$pkg" \
                        --arg version "$version_str" \
                        --arg added   "$(date -Iseconds)" \
                        '{name:$name,type:"apt",package:$package,version:$version,status:"ok",added:$added}')
                    registry_write apt "$pkg" "$json"
                fi
            done
        fi

        _progress 35 "Phase 1: apt complete"
        print_status "apt phase complete"
        echo ""
    fi

    # ── GitHub (35–80%) ──────────────────────────────────────────────
    if [ "$github_count" -gt 0 ] && [ "$run_github" -eq 1 ]; then
        _progress 36 "Phase 2: Cloning GitHub tools..."
        print_status "Phase 2: github tools ($github_count)"
        local gh_ok=0 gh_skip=0 gh_fail=0 gh_done=0

        while IFS= read -r entry; do
            local url target name
            url=$(echo "$entry" | jq -r '.url')
            target=$(echo "$entry" | jq -r '.target // "/opt/tools/misc"')
            name=$(basename "$url" .git | tr '[:upper:]' '[:lower:]')
            gh_done=$(( gh_done + 1 ))

            # github occupies 36–79%
            local pct=$(( 36 + ( gh_done * 43 / github_count ) ))
            _progress "$pct" "Phase 2: GitHub [$gh_done/$github_count] $name"

            # Idempotency: registry knows about it OR the tool_dir exists on
            # disk with content (handles legacy install_github_tools.sh which
            # doesn't write the registry).
            local tool_dir="$target/$name"
            if registry_exists github "${name}_" || \
               { [ -d "$tool_dir" ] && [ -n "$(ls -A "$tool_dir" 2>/dev/null)" ]; }; then
                printf "  ${CYAN}[skip]${NC} %s\n" "$name"
                (( gh_skip++ )) || true
            else
                printf "  ${BLUE}[git]${NC}  %s ... " "$name"
                if portalgun install github "$url" "$target" >/dev/null 2>&1; then
                    printf "${GREEN}ok${NC}\n"
                    (( gh_ok++ )) || true
                else
                    printf "${RED}FAILED${NC}\n"
                    (( gh_fail++ )) || true
                fi
            fi
        done < <(jq -c '.tools.github[]' "$bundle_file")

        _progress 80 "Phase 2: GitHub complete"
        echo ""
        print_status "github: $gh_ok installed, $gh_skip skipped, $gh_fail failed"
        echo ""
    fi

    # ── pip (80–95%) — installed into shared venv /opt/pentest-venv ──
    local VENV="/opt/pentest-venv"
    local VENV_PIP="$VENV/bin/pip"

    if [ "$pip_count" -gt 0 ] && [ "$run_pip" -eq 1 ]; then
        _progress 81 "Phase 3: Setting up /opt/pentest-venv..."
        print_status "Phase 3: pip packages ($pip_count) → $VENV"

        # install.sh invokes apply_bundle via `sudo -E`, so $HOME stays the
        # invoking user's (e.g. /home/kali). Root can't write ~/.cache/pip there,
        # so pip prints "cache disabled" and rebuilds/refetches everything. Point
        # the cache at a root-owned dir so caching works (and the warning stops).
        export PIP_CACHE_DIR="${PIP_CACHE_DIR:-/var/cache/portalgun/pip}"
        mkdir -p "$PIP_CACHE_DIR" 2>/dev/null || true

        # Create venv if needed
        if [ ! -f "$VENV_PIP" ]; then
            print_status "  Creating venv at $VENV..."
            python3 -m venv "$VENV"
            "$VENV_PIP" install --quiet --upgrade pip setuptools wheel
        fi

        # System build-deps for native pip packages (dbus-python, pycairo, etc.)
        # Without these, single-package builds abort the entire batch.
        local pip_build_deps="libdbus-1-dev libgirepository1.0-dev libcairo2-dev pkg-config python3-dev libffi-dev libssl-dev libxml2-dev libxslt1-dev libpcap-dev libkrb5-dev libldap2-dev libsasl2-dev"
        DEBIAN_FRONTEND=noninteractive apt-get install -y -q $pip_build_deps >/dev/null 2>&1 || \
            print_warning "Some pip build-deps could not be installed"

        # Write requirements.txt
        local req_file
        req_file=$(mktemp /tmp/portalgun_req_XXXXXX.txt)
        jq -r '(.tools.pip // [])[]' "$bundle_file" > "$req_file"
        local pip_total
        pip_total=$(wc -l < "$req_file")

        print_status "  Installing $pip_total packages via requirements.txt..."
        _progress 82 "Phase 3: pip — resolving and installing $pip_total packages..."

        # Phase A: bulk install — fast path, gets ~95% of packages in ~3min.
        # --no-deps because the bundle is a COMPLETE pip freeze (every transitive
        # dep is already an explicit pin), so pip needs no dependency resolution.
        # This avoids pip's strict resolver throwing ResolutionImpossible on
        # mutually-incompatible pins (e.g. tabulate / pyasn1) — which would abort
        # the entire bulk install and force a slow 820-package per-package retry.
        # Phase B below (with deps) is the safety net for any genuinely-missing dep.
        local pip_tmp pip_fail_log
        pip_tmp=$(mktemp /tmp/pg_pip_XXXXXX.tmp)
        chmod 600 "$pip_tmp"
        pip_fail_log="$PORTALGUN_LOG_DIR/pip_failures.log"
        : > "$pip_fail_log"
        "$VENV_PIP" install --prefer-binary --no-deps -r "$req_file" 2>&1 | tee "$pip_tmp" | \
            grep -E "^(ERROR|Successfully installed)" | tail -20 || true

        # Phase B: discover what didn't make it and retry per-package so one
        # build failure doesn't abort the rest.
        local installed_set
        installed_set=$("$VENV_PIP" list --format=freeze 2>/dev/null | cut -d= -f1 | tr '[:upper:]' '[:lower:]' | tr '_' '-' | sort -u)
        local missing_pip=() pkg_name_only
        while IFS= read -r spec; do
            [ -z "$spec" ] && continue
            pkg_name_only=$(echo "$spec" | sed 's/[<>=!~].*//' | tr '[:upper:]' '[:lower:]' | tr '_' '-' | tr -d ' ')
            echo "$installed_set" | grep -qx "$pkg_name_only" || missing_pip+=("$spec")
        done < "$req_file"

        if [ "${#missing_pip[@]}" -gt 0 ]; then
            print_status "  Retrying ${#missing_pip[@]} stragglers individually..."
            local retry_done=0 retry_ok=0 retry_fail=0
            for spec in "${missing_pip[@]}"; do
                retry_done=$((retry_done + 1))
                # Try --no-deps first: the bundle is a COMPLETE freeze, so every
                # transitive dep is already its own line. Installing with deps
                # makes pip's resolver emit "requires X but you have Y" notices
                # for the bundle's deliberately-pinned (and mutually under-
                # constrained) versions — noise that pollutes pip_failures.log
                # without changing the installed set. Only if --no-deps fails
                # (a genuinely-missing dep not in the freeze) do we fall back to
                # a full resolve.
                if "$VENV_PIP" install --quiet --prefer-binary --no-deps "$spec" >/dev/null 2>>"$pip_fail_log" \
                   || "$VENV_PIP" install --quiet --prefer-binary "$spec" >/dev/null 2>>"$pip_fail_log"; then
                    retry_ok=$((retry_ok + 1))
                else
                    echo "  $spec" >> "$pip_fail_log"
                    retry_fail=$((retry_fail + 1))
                fi
            done
            print_status "  Stragglers: $retry_ok installed, $retry_fail failed (log: $pip_fail_log)"
        fi
        rm -f "$pip_tmp" "$req_file"

        # Register only pip packages that ACTUALLY installed. Avoids the
        # earlier bug where 822 registry entries existed but only 3 packages
        # were truly in the venv.
        local final_installed
        final_installed=$("$VENV_PIP" list --format=freeze 2>/dev/null | cut -d= -f1 | tr '[:upper:]' '[:lower:]' | tr '_' '-' | sort -u)
        while IFS= read -r pkg_spec; do
            [ -z "$pkg_spec" ] && continue
            local pkg_name pkg_ver safe_id
            pkg_name=$(echo "$pkg_spec" | cut -d= -f1 | tr '[:upper:]' '[:lower:]' | tr '_' '-')
            pkg_ver=$(echo "$pkg_spec" | cut -d= -f3)
            safe_id=$(echo "$pkg_name" | tr -cs 'a-z0-9._-' '_')
            # Only register if pip list shows it installed
            if echo "$final_installed" | grep -qx "$pkg_name" && ! registry_exists pip "$safe_id"; then
                local json
                json=$(jq -n \
                    --arg name    "$pkg_name" \
                    --arg package "$pkg_spec" \
                    --arg version "$pkg_ver" \
                    --arg added   "$(date -Iseconds)" \
                    '{name:$name,type:"pip",package:$package,version:$version,status:"ok",added:$added}')
                registry_write pip "$safe_id" "$json"
            fi
        done < <(jq -r '(.tools.pip // [])[]' "$bundle_file")

        _progress 95 "Phase 3: pip complete"
        print_status "pip phase complete"
        echo ""
    fi

    # ── cargo (95–100%) ──────────────────────────────────────────────
    if [ "$cargo_count" -gt 0 ] && [ "$run_cargo" -eq 1 ]; then
        _progress 96 "Phase 4: Installing cargo tools..."
        print_status "Phase 4: cargo packages ($cargo_count)"

        # apply_bundle runs as `sudo bash -c "..."` where root's PATH usually
        # omits the cargo bin dirs, so a bare `command -v cargo` reports it
        # missing and the whole phase is skipped (cargo crates → 0 installed).
        # Add the standard rustup/apt cargo locations to PATH before probing.
        local _cargo_home="${CARGO_HOME:-$HOME/.cargo}" _cdir
        for _cdir in "$_cargo_home/bin" /root/.cargo/bin /usr/local/cargo/bin; do
            [ -x "$_cdir/cargo" ] && case ":$PATH:" in *":$_cdir:"*) ;; *) PATH="$_cdir:$PATH" ;; esac
        done
        export PATH

        if ! command -v cargo >/dev/null 2>&1; then
            print_warning "cargo not found — skipping cargo phase"
        else
            local cargo_ok=0 cargo_skip=0 cargo_fail=0 cargo_done=0

            while IFS= read -r pkg_name; do
                [ -z "$pkg_name" ] && continue
                cargo_done=$(( cargo_done + 1 ))
                local safe_id
                safe_id=$(echo "$pkg_name" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9._-' '_')
                local pct=$(( 96 + ( cargo_done * 3 / cargo_count ) ))
                _progress "$pct" "Phase 4: cargo [$cargo_done/$cargo_count] $pkg_name"

                if registry_exists cargo "$safe_id"; then
                    printf "  ${CYAN}[skip]${NC} %s\n" "$pkg_name"
                    (( cargo_skip++ )) || true
                    continue
                fi

                printf "  ${BLUE}[cargo]${NC} %s ... " "$pkg_name"
                if cargo install "$pkg_name" --quiet 2>/dev/null; then
                    local ver
                    ver=$(cargo install --list 2>/dev/null | grep "^${pkg_name} " | head -1 | sed 's/.* v//;s/:.*//')
                    local json
                    json=$(jq -n \
                        --arg name    "$pkg_name" \
                        --arg package "$pkg_name" \
                        --arg version "$ver" \
                        --arg added   "$(date -Iseconds)" \
                        '{name:$name,type:"cargo",package:$package,version:$version,status:"ok",added:$added}')
                    registry_write cargo "$safe_id" "$json"
                    printf "${GREEN}ok${NC}\n"
                    (( cargo_ok++ )) || true
                else
                    printf "${RED}FAILED${NC}\n"
                    (( cargo_fail++ )) || true
                fi
            done < <(jq -r '(.tools.cargo // [])[]' "$bundle_file")

            echo ""
            print_status "cargo: $cargo_ok installed, $cargo_skip skipped, $cargo_fail failed"
        fi
        echo ""
    fi

    # ── Phase 5: dotfiles — apply p3ta config for root + first user ──
    _progress 96 "Phase 5: Applying p3ta dotfiles..."
    print_status "Phase 5: dotfiles (p3ta default config)"

    local CONFIGS_DIR="$PORTALGUN_REPO_DIR/configs"

    # Apply to both root and the sudo user (kali or whoever invoked sudo)
    local FIRST_USER="${SUDO_USER:-kali}"
    local USERS_TO_CONFIGURE=("root" "$FIRST_USER")

    # Install Rust terminal tools via direct binary download (most reliable)
    # cargo-binstall is unreliable in this environment, so download from GitHub releases directly

    # Zellij
    if ! command -v zellij >/dev/null 2>&1; then
        _progress 96 "Phase 5: Installing zellij..."
        local ZELLIJ_VER
        ZELLIJ_VER=$(curl -s https://api.github.com/repos/zellij-org/zellij/releases/latest | grep tag_name | cut -d'"' -f4 2>/dev/null || echo "v0.44.3")
        if curl -sL "https://github.com/zellij-org/zellij/releases/download/${ZELLIJ_VER}/zellij-x86_64-unknown-linux-musl.tar.gz" | tar xz -C /usr/local/bin/ 2>/dev/null; then
            print_success "  zellij $ZELLIJ_VER installed"
        else
            print_warning "  zellij download failed"
        fi
    fi

    # Yazi + ya
    if ! command -v yazi >/dev/null 2>&1; then
        _progress 97 "Phase 5: Installing yazi..."
        local YAZI_VER
        YAZI_VER=$(curl -s https://api.github.com/repos/sxyazi/yazi/releases/latest | grep tag_name | cut -d'"' -f4 2>/dev/null)
        if [ -n "$YAZI_VER" ]; then
            curl -sL "https://github.com/sxyazi/yazi/releases/download/${YAZI_VER}/yazi-x86_64-unknown-linux-gnu.zip" -o /tmp/yazi.zip 2>/dev/null
            if (cd /tmp && unzip -oq yazi.zip && mv yazi-x86_64-unknown-linux-gnu/yazi /usr/local/bin/ && mv yazi-x86_64-unknown-linux-gnu/ya /usr/local/bin/) 2>/dev/null; then
                print_success "  yazi $YAZI_VER installed"
            else
                print_warning "  yazi install failed"
            fi
            rm -rf /tmp/yazi.zip /tmp/yazi-x86_64-unknown-linux-gnu
        fi
    fi

    # Lazydocker
    if ! command -v lazydocker >/dev/null 2>&1; then
        _progress 98 "Phase 5: Installing lazydocker..."
        if curl -sL https://raw.githubusercontent.com/jesseduffield/lazydocker/master/scripts/install_update_linux.sh | bash 2>/dev/null; then
            # The script installs to ~/.local/bin — copy to /usr/local/bin
            [ -f "$HOME/.local/bin/lazydocker" ] && cp "$HOME/.local/bin/lazydocker" /usr/local/bin/ 2>/dev/null
            command -v lazydocker >/dev/null 2>&1 && print_success "  lazydocker installed" || print_warning "  lazydocker not in PATH"
        else
            print_warning "  lazydocker download failed"
        fi
    fi

    if [ -d "$CONFIGS_DIR" ]; then
        for user in "${USERS_TO_CONFIGURE[@]}"; do
            _apply_dotfiles_for_user "$user" "$CONFIGS_DIR"
        done

        # Copy configs to dotfiles dir for web UI Config Manager
        local DOTFILES_DIR="/opt/tools-docs/dotfiles"
        mkdir -p "$DOTFILES_DIR"
        for f in zshrc zshrc_nerd zshrc_kali_default kitty.conf starship.toml; do
            [ -f "$CONFIGS_DIR/$f" ] && cp "$CONFIGS_DIR/$f" "$DOTFILES_DIR/$f"
        done
        chown -R "$FIRST_USER:$FIRST_USER" "$DOTFILES_DIR"
        print_success "Dotfiles applied for: ${USERS_TO_CONFIGURE[*]}"
    else
        print_warning "Configs dir not found — skipping dotfiles phase"
    fi
    echo ""

    # ── Phase 6: Burp Pro + Sliver (heavy specialty installs) ──
    if [ "${PORTALGUN_SKIP_BURP:-0}" != "1" ]; then
        _progress 97 "Phase 6a: Burp Suite Pro + BApps..."
        print_status "Phase 6a: Burp Suite Pro"
        if source "$PORTALGUN_LIB/install_burp.sh" 2>/dev/null && install_burp_pro; then
            print_success "Burp Suite Pro installed"
        else
            print_warning "Burp Suite Pro install skipped/failed (non-fatal)"
        fi
    fi
    if [ "${PORTALGUN_SKIP_SLIVER:-0}" != "1" ]; then
        _progress 98 "Phase 6b: Sliver C2 + armory..."
        print_status "Phase 6b: Sliver C2"
        if source "$PORTALGUN_LIB/install_sliver.sh" 2>/dev/null && install_sliver; then
            print_success "Sliver installed"
        else
            print_warning "Sliver install skipped/failed (non-fatal)"
        fi
    fi

    # Auto-register all installed tools so web UI search is populated
    _progress 99 "Registering tools in registry..."
    print_status "Running portalgun register to populate search..."
    source "$PORTALGUN_LIB/register.sh"
    register_all 2>/dev/null | grep -E "registered|summary" || true

    source "$PORTALGUN_LIB/sync_web.sh"
    sync_web_manifest

    _progress 100 "Installation complete!"
    print_success "Done. Run 'portalgun status' to verify."
    # Emit refresh signal so web UI reloads tool list
    echo "REFRESH_MANIFEST"
}
