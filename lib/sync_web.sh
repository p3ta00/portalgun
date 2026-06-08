#!/bin/bash
# portalgun → web UI sync
# Walks the registry and writes a single JSON manifest the web UI consumes.

# Generate the static-tool README cache (real upstream READMEs where reachable,
# metadata stubs for the rest) so every tool in the embedded toolsData catalog
# resolves to an offline README. sync_web.py then merges the resulting map into
# the manifest's static_readmes. Idempotent: skips when already current; the
# fetch step is skipped entirely when PORTALGUN_OFFLINE=1 (stubs still cover 100%).
gen_static_readmes() {
    local html="$PORTALGUN_WEB_DIR/index.html"
    [ -f "$html" ] || html="$PORTALGUN_WEB_DIR/tools_readme.html"
    [ -f "$html" ] || return 0

    local map="/var/cache/portalgun/static-tools-map.json"
    # Already generated and the catalog hasn't changed since → nothing to do.
    if [ -f "$map" ] && [ ! "$html" -nt "$map" ]; then
        return 0
    fi

    python3 "$PORTALGUN_LIB/extract_static_tools.py" "$html" >/dev/null 2>&1 || return 0
    if [ "${PORTALGUN_OFFLINE:-0}" != "1" ]; then
        # Resume-aware; raw.githubusercontent fetches for curated repos, best-effort.
        python3 "$PORTALGUN_LIB/fetch_static_readmes.py" >/dev/null 2>&1 || true
    fi
    # Always fill remaining gaps with metadata stubs → guarantees 100% coverage.
    python3 "$PORTALGUN_LIB/synth_stub_readmes.py" >/dev/null 2>&1 || true
}

sync_web_manifest() {
    local out_dir="$PORTALGUN_WEB_DIR"
    local out_file="$out_dir/portalgun_tools.json"

    if [ ! -d "$out_dir" ]; then
        print_warning "Web dir not present: $out_dir (web sync skipped)"
        return 0
    fi

    # Ensure the static-tool README map exists before the manifest is written,
    # so sync_web.py can merge it into static_readmes.
    gen_static_readmes

    if ! python3 "$PORTALGUN_LIB/sync_web.py" "$PORTALGUN_REGISTRY" "$out_file"; then
        print_warning "Failed to write web manifest"
        return 1
    fi
    print_success "Updated web manifest → $out_file"
}
