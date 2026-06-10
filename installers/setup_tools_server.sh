#!/bin/bash
# ═══════════════════════════════════════════════════════════════════
# Tools Documentation Server Setup
# Deploys the Flask server, web UI, dotfiles, and zellij configs
# ═══════════════════════════════════════════════════════════════════

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status() { echo -e "${BLUE}[*]${NC} $1"; }
print_success() { echo -e "${GREEN}[+]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
print_error() { echo -e "${RED}[-]${NC} $1"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOC_DIR="/opt/tools-docs"
DOTFILES_DIR="$DOC_DIR/dotfiles"
ZELLIJ_DIR="$DOTFILES_DIR/zellij"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "           Tools Documentation Server Setup"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# ───────────────────────────────────────────────────────────────────
# Create directory structure
# ───────────────────────────────────────────────────────────────────
print_status "Creating directory structure..."
sudo mkdir -p "$DOC_DIR"
sudo mkdir -p "$DOTFILES_DIR"
sudo mkdir -p "$ZELLIJ_DIR/custom"
sudo chown -R "$USER:$USER" "$DOC_DIR"
print_success "Directories created"

# ───────────────────────────────────────────────────────────────────
# Install Flask if needed
# ───────────────────────────────────────────────────────────────────
if ! python3 -c "import flask" 2>/dev/null; then
    print_status "Installing Flask..."
    pip3 install flask --quiet --break-system-packages 2>/dev/null || pip3 install flask --quiet
    print_success "Flask installed"
else
    print_warning "Flask already installed"
fi

# ───────────────────────────────────────────────────────────────────
# Copy server files
# ───────────────────────────────────────────────────────────────────
print_status "Copying server files..."

# Main HTML page
cp "$SCRIPT_DIR/../data/tools_readme.html" "$DOC_DIR/index.html"

# Logo (the title bar references <img src="portalgun.png">)
[ -f "$SCRIPT_DIR/../data/portalgun.png" ] && cp "$SCRIPT_DIR/../data/portalgun.png" "$DOC_DIR/portalgun.png"

# Flask server
cp "$SCRIPT_DIR/../data/tools_server.py" "$DOC_DIR/tools_server.py"

# GitHub tools installer (if exists)
if [ -f "$SCRIPT_DIR/install_github_tools.sh" ]; then
    cp "$SCRIPT_DIR/install_github_tools.sh" "$DOC_DIR/install_github_tools.sh"
    chmod +x "$DOC_DIR/install_github_tools.sh"
fi

print_success "Server files copied"

# ───────────────────────────────────────────────────────────────────
# Copy dotfiles
# ───────────────────────────────────────────────────────────────────
print_status "Setting up dotfiles..."

# Copy zshrc configs
if [ -f "$SCRIPT_DIR/../configs/zshrc" ]; then
    cp "$SCRIPT_DIR/../configs/zshrc" "$DOTFILES_DIR/zshrc"
fi

# Copy JP's zshrc if it exists
if [ -f "$SCRIPT_DIR/../configs/zshrc_nerd" ]; then
    cp "$SCRIPT_DIR/../configs/zshrc_nerd" "$DOTFILES_DIR/zshrc_nerd"
fi

# Create manifest if it doesn't exist
if [ ! -f "$DOTFILES_DIR/manifest.json" ]; then
    cat > "$DOTFILES_DIR/manifest.json" << 'EOF'
{
  "dotfiles": [
    {
      "id": "zshrc_p3ta",
      "name": "p3ta",
      "file": "zshrc",
      "target": "~/.zshrc",
      "description": "Oh-My-Zsh with Starship, FZF, Zoxide, modern aliases",
      "category": "shell",
      "requires": ["zsh", "starship", "fzf", "zoxide", "eza", "bat"]
    },
    {
      "id": "zshrc_jp",
      "name": "JP",
      "file": "zshrc_nerd",
      "target": "~/.zshrc",
      "description": "Kali-style zshrc with NerdFonts glyphs, completion, history",
      "category": "shell",
      "requires": ["zsh", "nerdfonts"]
    }
  ]
}
EOF
fi

print_success "Dotfiles configured"

# ───────────────────────────────────────────────────────────────────
# Copy Zellij configs
# ───────────────────────────────────────────────────────────────────
print_status "Setting up Zellij configs..."

# Copy zellij preset configs
if [ -d "$SCRIPT_DIR/../zellij" ]; then
    cp "$SCRIPT_DIR/../zellij/"*.kdl "$ZELLIJ_DIR/" 2>/dev/null || true
fi

print_success "Zellij configs installed"

# ───────────────────────────────────────────────────────────────────
# Set permissions
# ───────────────────────────────────────────────────────────────────
print_status "Setting permissions..."
chmod -R 755 "$DOC_DIR"
chmod 644 "$DOC_DIR"/*.html "$DOC_DIR"/*.py 2>/dev/null || true
chmod 644 "$DOTFILES_DIR"/* 2>/dev/null || true
chmod 644 "$ZELLIJ_DIR"/*.kdl 2>/dev/null || true
print_success "Permissions set"

# ───────────────────────────────────────────────────────────────────
# Create systemd service (optional)
# ───────────────────────────────────────────────────────────────────
print_status "Creating systemd service..."

sudo tee /etc/systemd/system/tools-server.service > /dev/null << EOF
[Unit]
Description=Kali Tools Documentation Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$DOC_DIR
# Prefer the pentest-venv so Flask + Jinja2 are guaranteed available.
ExecStart=/bin/sh -c 'if [ -x /opt/pentest-venv/bin/python3 ]; then exec /opt/pentest-venv/bin/python3 $DOC_DIR/tools_server.py; else exec /usr/bin/python3 $DOC_DIR/tools_server.py; fi'
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable tools-server.service >/dev/null 2>&1 || true
sudo systemctl start  tools-server.service >/dev/null 2>&1 || true
if systemctl is-active tools-server.service >/dev/null 2>&1; then
    print_success "Systemd service created, enabled, and running (tools-server.service)"
else
    print_warning "Systemd service created but failed to start — check: journalctl -u tools-server"
fi

# ───────────────────────────────────────────────────────────────────
# Done
# ───────────────────────────────────────────────────────────────────
IP=$(hostname -I | awk '{print $1}')

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo -e "                    ${GREEN}Setup Complete!${NC}"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Directory structure:"
echo "  $DOC_DIR/"
echo "  ├── index.html         (Web UI)"
echo "  ├── tools_server.py    (Flask server)"
echo "  └── dotfiles/"
echo "      ├── manifest.json  (Dotfile registry)"
echo "      ├── zshrc          (p3ta config)"
echo "      ├── zshrc_nerd     (JP config)"
echo "      └── zellij/        (Zellij presets)"
echo ""
echo "To start the server:"
echo "  ./start_tools_server.sh"
echo "  OR"
echo "  sudo systemctl start tools-server"
echo "  sudo systemctl enable tools-server  # Auto-start on boot"
echo ""
echo "Access at: http://$IP:1337"
echo ""
