#!/bin/bash
# portalgun sanitize — strip credentials + identity before VM cloning.
# This is destructive. Always confirm.

sanitize_run() {
    require_root sanitize

    local force=0
    [ "$1" = "--yes" ] && force=1

    cat <<'EOF'

╔═══════════════════════════════════════════════════════════════════╗
║                  portalgun sanitize                                ║
╠═══════════════════════════════════════════════════════════════════╣
║  Prepares this VM for cloning + distribution. This is             ║
║  DESTRUCTIVE and intended to run on the master image right        ║
║  before shutdown.                                                  ║
║                                                                    ║
║  It will:                                                          ║
║    1. Stop BloodHound containers (clean shutdown)                 ║
║    2. Clear bash/zsh history (root + all /home/* users)           ║
║    3. Clear /var/log/* + journal                                  ║
║    4. apt clean (remove cached .debs)                             ║
║    5. Remove /etc/sudoers.d/temp_install if present               ║
║    6. Remove Burp Pro license (recipients import their own)       ║
║    7. Clear DHCP leases + NetworkManager connection state         ║
║    8. Clear /tmp + /var/tmp                                       ║
║    9. fstrim + zero free space (for qcow2 compression)            ║
║                                                                    ║
║  After sanitize, run:                                              ║
║    sudo shutdown -h now                                            ║
║  ...then clone the qcow2 from your hypervisor host.               ║
║                                                                    ║
║  First boot of each clone regenerates machine-id + SSH keys       ║
║  via portalgun-firstboot.service.                                  ║
║                                                                    ║
║  WHAT IT DOES NOT REMOVE:                                          ║
║    - BloodHound admin password (persists in the postgres volume)  ║
║    - Firefox saved passwords (persists in the profile)            ║
║    - portalgun registry                                            ║
║    - /opt/tools/                                                   ║
║    - /opt/portalgun/wheels  (offline pip wheelhouse — kept)       ║
║    - /opt/portalgun/apt-mirror (offline apt mirror — kept)        ║
║  These are the things you WANT to ship in the master image.       ║
║  If you don't want them shipped, edit them out before sanitize.   ║
╚═══════════════════════════════════════════════════════════════════╝

EOF

    if [ "$force" -ne 1 ]; then
        printf "Continue? [y/N] "
        read -r ans
        [[ "$ans" =~ ^[Yy]$ ]] || { print_warning "Aborted."; return 1; }
    fi

    print_status "Stopping BloodHound CE..."
    bloodhound-ce stop 2>/dev/null || true

    print_status "Clearing shell history..."
    : > /root/.bash_history 2>/dev/null || true
    : > /root/.zsh_history  2>/dev/null || true
    for u in /home/*; do
        [ -d "$u" ] || continue
        : > "$u/.bash_history" 2>/dev/null || true
        : > "$u/.zsh_history"  2>/dev/null || true
    done

    print_status "Clearing logs + journal..."
    find /var/log -type f \( -name "*.log" -o -name "*.log.*" -o -name "*.gz" \) -exec truncate -s 0 {} \; 2>/dev/null
    journalctl --rotate --vacuum-time=1s >/dev/null 2>&1 || true

    print_status "Folding apt .deb cache into the offline mirror (then clean)..."
    # Keep the downloaded .debs for offline reinstall/repair: fold them into the
    # local apt mirror pool and re-index before clearing the apt cache.
    if [ -d /opt/portalgun/apt-mirror ] && ls /var/cache/apt/archives/*.deb >/dev/null 2>&1; then
        mkdir -p /opt/portalgun/apt-mirror/pool
        cp -n /var/cache/apt/archives/*.deb /opt/portalgun/apt-mirror/pool/ 2>/dev/null || true
        if command -v dpkg-scanpackages >/dev/null 2>&1; then
            ( cd /opt/portalgun/apt-mirror && dpkg-scanpackages -m pool /dev/null 2>/dev/null \
                | tee Packages | gzip -9c > Packages.gz ) 2>/dev/null || true
        fi
    fi
    apt-get clean 2>/dev/null || true

    print_status "Removing temp_install sudoers..."
    rm -f /etc/sudoers.d/temp_install

    print_status "Removing Burp Pro license (recipients import their own)..."
    # The license is operator-specific and must never ship in a distributed
    # clone — strip the staging copy and every user's activated prefs.xml.
    rm -f /opt/portalgun/burpsuite/license-import/prefs.xml 2>/dev/null || true
    rm -f /root/.java/.userPrefs/burp/prefs.xml 2>/dev/null || true
    for u in /home/*; do
        [ -d "$u" ] || continue
        rm -f "$u/.java/.userPrefs/burp/prefs.xml" 2>/dev/null || true
    done

    print_status "Clearing NetworkManager state + DHCP leases..."
    rm -rf /var/lib/dhcp/* /var/lib/NetworkManager/* 2>/dev/null || true

    print_status "Clearing /tmp and /var/tmp..."
    rm -rf /tmp/* /tmp/.[!.]* /var/tmp/* 2>/dev/null || true

    print_status "Switching pip to OFFLINE (local wheelhouse)..."
    # Clones are used offline — point pip at the bundled wheelhouse so future
    # `pip install` resolves locally with no internet.
    if [ -f "$PORTALGUN_LIB/offline.sh" ]; then
        source "$PORTALGUN_LIB/offline.sh"
        offline_on 2>/dev/null || print_warning "Could not set pip offline mode"
    fi

    print_status "fstrim..."
    fstrim -av 2>/dev/null || true

    print_status "Zeroing free space (helps qcow2 compress small)..."
    dd if=/dev/zero of=/var/zero bs=1M status=progress 2>/dev/null || true
    sync
    rm -f /var/zero
    sync

    print_success "Sanitize complete. Now: sudo shutdown -h now"
}

sanitize_run "$@"
