#!/bin/bash
# ═══════════════════════════════════════════════════════════════════
# portalgun installer — copies the tool to /opt/portalgun and sets it up
# ═══════════════════════════════════════════════════════════════════
set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'

print_status()  { echo -e "${BLUE}[*]${NC} $1"; }
print_success() { echo -e "${GREEN}[+]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
print_error()   { echo -e "${RED}[-]${NC} $1" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# When called from the merged repo, this script lives in portalgun/installers/.
# The portalgun source assets (bin, lib, web, completion) live one level up.
SRC_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL_ROOT="/opt/portalgun"
BIN_LINK="/usr/local/bin/portalgun"
REGISTRY_DIR="/var/lib/portalgun/registry"
LOG_DIR="/var/log/portalgun"
WEB_DIR="/opt/tools-docs"
ZSH_COMP_DIR="/usr/share/zsh/site-functions"

# ─── Pre-flight ──────────────────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
    print_error "Please run as root (sudo $0)"
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
    print_status "Installing prerequisites (python3, jq, git)..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q python3 jq git >/dev/null
fi

# ─── Copy files ──────────────────────────────────────────────────────
print_status "Installing portalgun to $INSTALL_ROOT..."
mkdir -p "$INSTALL_ROOT"
rsync -a --delete "$SRC_ROOT/bin/"        "$INSTALL_ROOT/bin/"
rsync -a --delete "$SRC_ROOT/lib/"        "$INSTALL_ROOT/lib/"
rsync -a --delete "$SRC_ROOT/completion/" "$INSTALL_ROOT/completion/"
rsync -a --delete "$SRC_ROOT/web/"        "$INSTALL_ROOT/web/"
mkdir -p "$INSTALL_ROOT/data"
[ -f "$SRC_ROOT/data/bapp-catalog.json" ] && \
    cp "$SRC_ROOT/data/bapp-catalog.json" "$INSTALL_ROOT/data/bapp-catalog.json"
[ -f "$SRC_ROOT/data/wheelhouse-packages.txt" ] && \
    cp "$SRC_ROOT/data/wheelhouse-packages.txt" "$INSTALL_ROOT/data/wheelhouse-packages.txt"
[ -f "$SRC_ROOT/data/apt-mirror-packages.txt" ] && \
    cp "$SRC_ROOT/data/apt-mirror-packages.txt" "$INSTALL_ROOT/data/apt-mirror-packages.txt"
if [ -d "$SRC_ROOT/data/sliver-armory" ]; then
    rsync -a "$SRC_ROOT/data/sliver-armory/" "$INSTALL_ROOT/data/sliver-armory/"
fi
if [ -d "$SRC_ROOT/data/bapp-jars" ]; then
    rsync -a "$SRC_ROOT/data/bapp-jars/" "$INSTALL_ROOT/data/bapp-jars/"
fi
if [ -d "$SRC_ROOT/data/sliver-armory-bin" ]; then
    rsync -a "$SRC_ROOT/data/sliver-armory-bin/" "$INSTALL_ROOT/data/sliver-armory-bin/"
fi

chmod +x "$INSTALL_ROOT/bin/portalgun" "$INSTALL_ROOT/bin/portalgun-firstboot.sh"
chmod +x "$INSTALL_ROOT/lib/"*.py 2>/dev/null || true

print_success "Files copied"

# ─── First-boot hygiene service (runs once on a cloned VM) ──────────
cp "$INSTALL_ROOT/web/portalgun-firstboot.service" /etc/systemd/system/portalgun-firstboot.service
systemctl daemon-reload
systemctl enable portalgun-firstboot.service >/dev/null 2>&1
print_success "First-boot service enabled (regenerates machine-id + SSH keys on clones)"

# ─── Symlink to /usr/local/bin ──────────────────────────────────────
ln -sf "$INSTALL_ROOT/bin/portalgun" "$BIN_LINK"
print_success "Linked $BIN_LINK → $INSTALL_ROOT/bin/portalgun"

# ─── Registry + log dirs ────────────────────────────────────────────
mkdir -p "$REGISTRY_DIR/apt" "$REGISTRY_DIR/github" \
         "$REGISTRY_DIR/pip" "$REGISTRY_DIR/cargo" "$LOG_DIR"
chmod 755 "$REGISTRY_DIR" "$LOG_DIR"
print_success "Registry dir: $REGISTRY_DIR"
print_success "Log dir:      $LOG_DIR"

# Copy bundle to /opt/portalgun so it's always findable regardless of $HOME
if [ -f "$SRC_ROOT/portalgun_bundle.json" ]; then
    cp "$SRC_ROOT/portalgun_bundle.json" "$INSTALL_ROOT/portalgun_bundle.json"
    print_success "Bundle → $INSTALL_ROOT/portalgun_bundle.json"
fi

# ─── Pentest venv PATH — add /opt/pentest-venv/bin system-wide ───────
cat > /etc/profile.d/pentest-venv.sh << 'PROFILE'
# portalgun: pentest python venv
export PENTEST_VENV=/opt/pentest-venv
if [ -d "$PENTEST_VENV/bin" ]; then
    export PATH="$PENTEST_VENV/bin:$PATH"
fi
PROFILE
chmod 644 /etc/profile.d/pentest-venv.sh

# Also add to /etc/bash.bashrc for non-login interactive shells
if ! grep -q "pentest-venv" /etc/bash.bashrc 2>/dev/null; then
    echo 'source /etc/profile.d/pentest-venv.sh 2>/dev/null' >> /etc/bash.bashrc
fi
# And /etc/zsh/zshenv for zsh users
if ! grep -q "pentest-venv" /etc/zsh/zshenv 2>/dev/null; then
    echo 'source /etc/profile.d/pentest-venv.sh 2>/dev/null' >> /etc/zsh/zshenv 2>/dev/null || true
fi

# Allow sudo to find venv binaries
if ! grep -q "pentest-venv" /etc/sudoers 2>/dev/null; then
    echo 'Defaults secure_path="/opt/pentest-venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"' \
        >> /etc/sudoers
fi
print_success "Pentest venv PATH → /etc/profile.d/pentest-venv.sh"

# ─── Zsh completion ─────────────────────────────────────────────────
if [ -d "$ZSH_COMP_DIR" ]; then
    cp "$INSTALL_ROOT/completion/_portalgun" "$ZSH_COMP_DIR/_portalgun"
    print_success "Zsh completion → $ZSH_COMP_DIR/_portalgun"
    print_status  "  (run 'rm -f ~/.zcompdump*' and start a new shell to load it)"
else
    print_warning "$ZSH_COMP_DIR not found; skipping zsh completion"
fi

# ─── Dotfiles directory + manifest ──────────────────────────────────
DOTFILES_DIR="$WEB_DIR/dotfiles"
mkdir -p "$DOTFILES_DIR"/{zellij/{custom,p3ta_files/{layouts,plugins,scripts}},tmux/custom}

# Copy ALL dotfiles from repo
if [ -d "$SRC_ROOT/configs" ]; then
    for f in zshrc zshrc_nerd zshrc_kali_default kitty.conf starship.toml tmux.conf; do
        src="$SRC_ROOT/configs/$f"
        [ -f "$src" ] && cp "$src" "$DOTFILES_DIR/$f" && print_status "  copied $f" || true
    done
fi

# Copy tmux themes + hotkeys
if [ -d "$SRC_ROOT/tmux" ]; then
    mkdir -p "$DOTFILES_DIR/tmux/custom" "$DOTFILES_DIR/tmux/imported"
    cp "$SRC_ROOT/tmux/"*.conf "$DOTFILES_DIR/tmux/" 2>/dev/null || true
    print_status "  copied tmux themes"
fi

# Copy zellij configs + plugins
if [ -d "$SRC_ROOT/configs/zellij" ]; then
    mkdir -p "$DOTFILES_DIR/zellij/p3ta_files/layouts" \
              "$DOTFILES_DIR/zellij/p3ta_files/plugins" \
              "$DOTFILES_DIR/zellij/p3ta_files/scripts" \
              "$DOTFILES_DIR/zellij/custom"
    [ -f "$SRC_ROOT/configs/zellij/config.kdl" ] && cp "$SRC_ROOT/configs/zellij/config.kdl" "$DOTFILES_DIR/zellij/"
    [ -f "$SRC_ROOT/configs/zellij/themes.kdl" ] && cp "$SRC_ROOT/configs/zellij/themes.kdl" "$DOTFILES_DIR/zellij/"
    cp "$SRC_ROOT/configs/zellij/layouts/"* "$DOTFILES_DIR/zellij/p3ta_files/layouts/" 2>/dev/null || true
    cp "$SRC_ROOT/configs/zellij/plugins/"* "$DOTFILES_DIR/zellij/p3ta_files/plugins/" 2>/dev/null || true
    cp "$SRC_ROOT/configs/zellij/scripts/"* "$DOTFILES_DIR/zellij/p3ta_files/scripts/" 2>/dev/null || true
    print_status "  copied zellij configs + zjstatus plugin"
fi

# Create manifest.json if it doesn't exist
if [ ! -f "$DOTFILES_DIR/manifest.json" ]; then
    # Write manifest — use python3 to avoid heredoc quote-stripping issues
    python3 -c "
import json
manifest = {
    'dotfiles': [
        {'id':'zshrc_kali_default','name':'Kali Default','file':'zshrc_kali_default',
         'target':'~/.zshrc','description':'Stock Kali Linux zshrc - unmodified default',
         'category':'shell','requires':['zsh']},
        {'id':'zshrc_p3ta','name':'p3ta','file':'zshrc',
         'target':'~/.zshrc','description':'Oh-My-Zsh with Starship, FZF, Zoxide, modern aliases',
         'category':'shell','requires':['zsh','starship','fzf','zoxide','eza','bat']},
        {'id':'zshrc_jp','name':'JP','file':'zshrc_nerd',
         'target':'~/.zshrc','description':'Kali-style zshrc with NerdFonts glyphs, completion, history',
         'category':'shell','requires':['zsh','nerdfonts']}
    ]
}
print(json.dumps(manifest, indent=2))
" > "$DOTFILES_DIR/manifest.json"
    print_success "Dotfiles manifest created"
fi

# ─── Web UI integration ─────────────────────────────────────────────
if [ -d "$WEB_DIR" ]; then
    cp "$INSTALL_ROOT/web/portalgun_tools.html" "$WEB_DIR/portalgun_tools.html"
    cp "$INSTALL_ROOT/web/portalgun_wiki.html"  "$WEB_DIR/portalgun_wiki.html"
    print_success "Web pages → $WEB_DIR/portalgun_{tools,wiki}.html"

    # Initialize an empty manifest so the page loads cleanly before the first install
    if [ ! -f "$WEB_DIR/portalgun_tools.json" ]; then
        python3 "$INSTALL_ROOT/lib/sync_web.py" "$REGISTRY_DIR" "$WEB_DIR/portalgun_tools.json"
    fi

    # Patch index.html to link to the portalgun pages (idempotent — only if marker absent)
    INDEX="$WEB_DIR/index.html"
    if [ -f "$INDEX" ] && ! grep -q "portalgun_tools.html" "$INDEX"; then
        python3 - "$INDEX" <<'PYEOF'
import sys, re
p = sys.argv[1]
html = open(p).read()
banner = (
    '<div style="background:#cba6f7;color:#1e1e2e;padding:10px;text-align:center;'
    'font-family:monospace;font-weight:bold">'
    '<a href="portalgun_tools.html" style="color:#1e1e2e;text-decoration:none;margin:0 16px">'
    '▸ portalgun tools</a>'
    '<a href="portalgun_wiki.html" style="color:#1e1e2e;text-decoration:none;margin:0 16px">'
    '▸ portalgun wiki</a>'
    '</div>'
)
new = re.sub(r'(<body[^>]*>)', r'\1\n' + banner, html, count=1, flags=re.IGNORECASE)
open(p, 'w').write(new)
PYEOF
        print_success "Linked tools + wiki from $INDEX"
    elif [ -f "$INDEX" ] && ! grep -q "portalgun_wiki.html" "$INDEX"; then
        # tools banner already there from earlier install — extend with wiki link
        python3 - "$INDEX" <<'PYEOF'
import sys, re
p = sys.argv[1]
html = open(p).read()
# Replace the existing tools-only banner with the combined banner
combined = (
    '<div style="background:#cba6f7;color:#1e1e2e;padding:10px;text-align:center;'
    'font-family:monospace;font-weight:bold">'
    '<a href="portalgun_tools.html" style="color:#1e1e2e;text-decoration:none;margin:0 16px">'
    '▸ portalgun tools</a>'
    '<a href="portalgun_wiki.html" style="color:#1e1e2e;text-decoration:none;margin:0 16px">'
    '▸ portalgun wiki</a>'
    '</div>'
)
new = re.sub(r'<div[^>]*background:#cba6f7[^>]*>.*?</div>', combined, html, count=1, flags=re.DOTALL)
open(p, 'w').write(new)
PYEOF
        print_success "Extended banner with wiki link"
    fi
else
    print_warning "$WEB_DIR not found; web UI integration skipped"
    print_status  "  (Re-run install.sh after setting up tools-docs server)"
fi

# ─── Done ──────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo -e "                ${GREEN}portalgun installed${NC}"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Try:"
echo "  portalgun help"
echo "  portalgun status"
echo "  sudo portalgun install apt nmap"
echo "  sudo portalgun install github https://github.com/akamai/BadSuccessor /opt/tools/windows/exploit"
echo ""
echo "Web UI: open http://localhost:1337/portalgun_tools.html"
echo "Registry: $REGISTRY_DIR"
echo "Logs:    $LOG_DIR"
echo ""
