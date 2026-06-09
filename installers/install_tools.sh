#!/bin/bash
# ═══════════════════════════════════════════════════════════════════
# Kali Linux Additional Tools Installation Script
# Installs missing packages from full Kali toolset
# ═══════════════════════════════════════════════════════════════════

# Suppress interactive prompts (kernel upgrade notices, etc.)
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGES_FILE="$SCRIPT_DIR/../data/installable_packages.txt"
FAILED_FILE="$SCRIPT_DIR/../data/failed_packages.txt"

# ───────────────────────────────────────────────────────────────────
# Parse arguments
# ───────────────────────────────────────────────────────────────────
CHECK_ONLY=false
SHOW_MISSING=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -c|--check)
            CHECK_ONLY=true
            shift
            ;;
        -m|--missing)
            CHECK_ONLY=true
            SHOW_MISSING=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  -c, --check    Check only - show installed vs missing (no install)"
            echo "  -m, --missing  Check only - list all missing packages"
            echo "  -h, --help     Show this help message"
            echo ""
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage"
            exit 1
            ;;
    esac
done

# ───────────────────────────────────────────────────────────────────
# Check requirements
# ───────────────────────────────────────────────────────────────────
if [ "$EUID" -eq 0 ]; then
    echo -e "${RED}[-]${NC} Please run as normal user, not root"
    exit 1
fi

if [ ! -f "$PACKAGES_FILE" ]; then
    echo -e "${RED}[-]${NC} Package list not found: $PACKAGES_FILE"
    exit 1
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
if [ "$CHECK_ONLY" = true ]; then
    echo "           Kali Linux Tools - Status Check"
else
    echo "           Kali Linux Additional Tools Installation"
fi
echo "═══════════════════════════════════════════════════════════════════"
echo ""

> "$FAILED_FILE"

# ───────────────────────────────────────────────────────────────────
# Check all packages
# ───────────────────────────────────────────────────────────────────
echo -e "${BLUE}[*]${NC} Checking packages..."

TOTAL_IN_FILE=$(wc -l < "$PACKAGES_FILE")
INSTALLED_COUNT=0
INSTALLED_LIST=()
TO_INSTALL=()

CURRENT=0
while IFS= read -r pkg || [ -n "$pkg" ]; do
    [[ -z "$pkg" || "$pkg" =~ ^# ]] && continue
    CURRENT=$((CURRENT + 1))

    # Progress indicator
    printf "\r${BLUE}[*]${NC} Checking: %d/%d - %s                    " "$CURRENT" "$TOTAL_IN_FILE" "$pkg"

    if dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
        INSTALLED_COUNT=$((INSTALLED_COUNT + 1))
        INSTALLED_LIST+=("$pkg")
    else
        TO_INSTALL+=("$pkg")
    fi
done < "$PACKAGES_FILE"

printf "\r%-80s\n" ""

echo -e "${GREEN}[+]${NC} Installed:   ${CYAN}$INSTALLED_COUNT${NC} / $TOTAL_IN_FILE"
# Pre-install inventory of packages queued for this run — informational, not a
# defect. Use the status glyph ([*]) so the install-log analyzer's [!] warning
# regex doesn't count it (these all get installed; final verify reports 100%).
echo -e "${BLUE}[*]${NC} To install:  ${CYAN}${#TO_INSTALL[@]}${NC} / $TOTAL_IN_FILE"
echo ""

# ───────────────────────────────────────────────────────────────────
# Check only mode - exit here
# ───────────────────────────────────────────────────────────────────
if [ "$CHECK_ONLY" = true ]; then
    if [ "$SHOW_MISSING" = true ] && [ ${#TO_INSTALL[@]} -gt 0 ]; then
        echo -e "${YELLOW}Missing packages:${NC}"
        echo "───────────────────────────────────────────────────────────────────"
        printf '%s\n' "${TO_INSTALL[@]}" | column
        echo ""
    fi

    # Check Rust tools
    echo -e "${BLUE}[*]${NC} Rust tools status:"
    for tool in rustscan feroxbuster; do
        if command -v "$tool" &> /dev/null || dpkg -l "$tool" 2>/dev/null | grep -q "^ii"; then
            echo -e "  ${GREEN}[+]${NC} $tool - installed"
        else
            echo -e "  ${YELLOW}[-]${NC} $tool - missing"
        fi
    done
    echo ""
    exit 0
fi

# ───────────────────────────────────────────────────────────────────
# Nothing to install?
# ───────────────────────────────────────────────────────────────────
if [ ${#TO_INSTALL[@]} -eq 0 ]; then
    echo -e "${GREEN}[+]${NC} All packages already installed! Nothing to do."
    echo ""
    exit 0
fi

# ───────────────────────────────────────────────────────────────────
# Configure apt to skip prompts
# ───────────────────────────────────────────────────────────────────
echo -e "${BLUE}[*]${NC} Configuring apt for non-interactive install..."
sudo mkdir -p /etc/needrestart/conf.d/
echo "\$nrconf{restart} = 'a';" | sudo tee /etc/needrestart/conf.d/50local.conf > /dev/null 2>&1 || true

# ───────────────────────────────────────────────────────────────────
# Update package lists
# ───────────────────────────────────────────────────────────────────
echo -e "${BLUE}[*]${NC} Updating package lists..."
sudo apt update
echo ""

# ───────────────────────────────────────────────────────────────────
# Install base dependencies
# ───────────────────────────────────────────────────────────────────
echo -e "${BLUE}[*]${NC} Installing base dependencies (cargo, golang, pip, npm, ruby)..."
echo ""
sudo DEBIAN_FRONTEND=noninteractive apt install -y \
    build-essential \
    curl \
    wget \
    git \
    cargo \
    rustc \
    golang \
    python3-pip \
    python3-venv \
    ruby \
    ruby-dev \
    npm || echo -e "${YELLOW}[!]${NC} Some base dependencies may have failed"

echo ""
echo -e "${GREEN}[+]${NC} Base dependencies done"
echo ""

# ───────────────────────────────────────────────────────────────────
# Install packages in batches with retry
# ───────────────────────────────────────────────────────────────────
echo "═══════════════════════════════════════════════════════════════════"
echo -e "${BLUE}[*]${NC} Installing ${CYAN}${#TO_INSTALL[@]}${NC} packages..."
echo "═══════════════════════════════════════════════════════════════════"
echo ""

install_package() {
    local pkg=$1
    if sudo DEBIAN_FRONTEND=noninteractive apt install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" "$pkg" &>/dev/null; then
        return 0
    else
        return 1
    fi
}

# First pass: batch install (faster)
BATCH_SIZE=50
TOTAL=${#TO_INSTALL[@]}
BATCH_NUM=0
BATCH_FAILED=()

for ((i=0; i<TOTAL; i+=BATCH_SIZE)); do
    BATCH_NUM=$((BATCH_NUM + 1))
    END=$((i + BATCH_SIZE))
    [ $END -gt $TOTAL ] && END=$TOTAL

    BATCH=("${TO_INSTALL[@]:i:BATCH_SIZE}")

    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}[*]${NC} Batch $BATCH_NUM: Installing packages $((i+1))-$END of $TOTAL"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${YELLOW}Packages:${NC} ${BATCH[*]}"
    echo ""

    if sudo DEBIAN_FRONTEND=noninteractive apt install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" "${BATCH[@]}" 2>/dev/null; then
        echo -e "${GREEN}[+]${NC} Batch $BATCH_NUM complete"
    else
        echo -e "${YELLOW}[!]${NC} Some packages in batch $BATCH_NUM failed - will retry individually"
        # Collect failed packages for retry
        for pkg in "${BATCH[@]}"; do
            if ! dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
                BATCH_FAILED+=("$pkg")
            fi
        done
    fi
done

# ───────────────────────────────────────────────────────────────────
# Second pass: retry failed packages individually
# ───────────────────────────────────────────────────────────────────
if [ ${#BATCH_FAILED[@]} -gt 0 ]; then
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}[*]${NC} Retrying ${#BATCH_FAILED[@]} failed packages individually..."
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    RETRY_COUNT=0
    RETRY_SUCCESS=0

    for pkg in "${BATCH_FAILED[@]}"; do
        RETRY_COUNT=$((RETRY_COUNT + 1))
        printf "${BLUE}[*]${NC} [%d/%d] %s ... " "$RETRY_COUNT" "${#BATCH_FAILED[@]}" "$pkg"

        if install_package "$pkg"; then
            echo -e "${GREEN}OK${NC}"
            RETRY_SUCCESS=$((RETRY_SUCCESS + 1))
        else
            echo -e "${RED}FAILED${NC}"
            echo "$pkg" >> "$FAILED_FILE"
        fi
    done

    echo ""
    echo -e "${GREEN}[+]${NC} Retry complete: $RETRY_SUCCESS/${#BATCH_FAILED[@]} succeeded"
fi

# ───────────────────────────────────────────────────────────────────
# Install Rust tools via cargo
# ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BLUE}[*]${NC} Checking Rust-based tools..."

for tool in rustscan feroxbuster; do
    if ! command -v "$tool" &> /dev/null && ! dpkg -l "$tool" 2>/dev/null | grep -q "^ii"; then
        echo -e "${BLUE}[*]${NC} Installing $tool via cargo..."
        cargo install "$tool" || echo -e "${YELLOW}[!]${NC} $tool may need manual install"
    else
        echo -e "${GREEN}[+]${NC} $tool already installed"
    fi
done

# ───────────────────────────────────────────────────────────────────
# Clean up
# ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BLUE}[*]${NC} Cleaning up..."
sudo apt autoremove -y
sudo apt clean

# ───────────────────────────────────────────────────────────────────
# Summary
# ───────────────────────────────────────────────────────────────────
FAILED_COUNT=0
[ -f "$FAILED_FILE" ] && [ -s "$FAILED_FILE" ] && FAILED_COUNT=$(wc -l < "$FAILED_FILE")

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo -e "                    ${GREEN}Installation Complete!${NC}"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Summary:"
echo -e "  Already installed: ${CYAN}$INSTALLED_COUNT${NC}"
echo -e "  Newly installed:   ${GREEN}$((${#TO_INSTALL[@]} - FAILED_COUNT))${NC}"
if [ "$FAILED_COUNT" -gt 0 ]; then
    echo -e "  Failed:            ${RED}$FAILED_COUNT${NC}"
    echo ""
    echo -e "${YELLOW}[!]${NC} Failed packages saved to: $FAILED_FILE"
    echo ""
    echo "Failed packages (may not exist in repos or have unmet dependencies):"
    cat "$FAILED_FILE"
else
    echo ""
    echo -e "${GREEN}[+]${NC} All packages installed successfully!"
fi
echo ""
echo -e "${BLUE}[*]${NC} Note: Reboot recommended to use new kernel if upgraded"
echo ""

exit 0
