#!/usr/bin/env bash
# portalgun install log exporter.
# Copies the master install log to a versioned location under
# /var/log/portalgun/install-logs/ and to the web UI's static dir so it can be
# pulled remotely. Generates a per-phase error summary JSON for triage.

set -u

LOG_SRC="${1:-/dev/null}"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
LOG_PERSIST_DIR="/var/log/portalgun/install-logs"
WEB_LOG_DIR="/opt/tools-docs/install-logs"
SUMMARY_PATH="$LOG_PERSIST_DIR/install-$TS.summary.json"
LOG_DEST="$LOG_PERSIST_DIR/install-$TS.log"

mkdir -p "$LOG_PERSIST_DIR" "$WEB_LOG_DIR"

if [ -f "$LOG_SRC" ]; then
    cp -f "$LOG_SRC" "$LOG_DEST"
    cp -f "$LOG_SRC" "$WEB_LOG_DIR/install-$TS.log"
fi

# Per-phase error/warn extraction. Keep tight signal:
#   - apt failures
#   - github clone/build failures
#   - pip resolution conflicts
#   - cargo compile errors
#   - generic ERROR / FAILED / FATAL lines
python3 - "$LOG_DEST" "$SUMMARY_PATH" "$TS" <<'PYEOF'
import json, os, re, sys
log_path, summary_path, ts = sys.argv[1], sys.argv[2], sys.argv[3]
if not os.path.isfile(log_path):
    json.dump({"timestamp": ts, "log": None, "error": "log file missing"}, open(summary_path, "w"), indent=2)
    sys.exit(0)

with open(log_path, "r", errors="replace") as f:
    lines = f.readlines()

# Phase markers from apply.sh: print_status "Phase N: ..."
phase_re = re.compile(r"Phase\s+\d+[a-z]?:", re.I)
# Tight signal-only patterns. Avoid generic "error"/"failed" which match
# package names (node-error-ex), summary counters ("Failed: 0"), and apt's
# "Setting up python3-colored-traceback" lines.
err_patterns = [
    ("apt-broken",     re.compile(r"^E: |^dpkg: error|Sub-process .* returned an error|Could not get lock|broken packages|Hash Sum mismatch|Unable to (locate|fetch)")),
    ("github-fail",    re.compile(r"^fatal: (could not|unable to|repository|Authentication)|^make: \*\*\* |Error response from daemon|\[install_github\].*Status: failed")),
    ("build-fail",     re.compile(r"\bbuild failed\b|compilation terminated|cannot find -l|undefined reference to|configure: error|\bld: cannot\b", re.I)),
    ("pip-conflict",   re.compile(r"^ERROR: Cannot install|conflicting dependencies|ResolutionImpossible|No matching distribution found|ERROR: pip.*conflict")),
    ("cargo-fail",     re.compile(r"error\[E\d+\]|aborting due to .* error|cargo install failed|error: failed to compile|error: package .* not found")),
    # Only the Traceback header is a reliable error signal. A bare
    # '  File "...", line N' line also appears in benign output — notably
    # Python SyntaxWarnings from bundled third-party tools (cupp, commix, ...)
    # and -v/-W output — so matching it alone produced false-positive errors.
    ("python-trace",   re.compile(r"^Traceback \(most recent call last\)")),
    ("permission",     re.compile(r"Permission denied(?!\.)|EACCES|operation not permitted", re.I)),
    ("network",        re.compile(r"Could not resolve host|Connection refused|TLS handshake|Temporary failure in name resolution|curl: \(\d+\)")),
    ("portalgun-err",  re.compile(r"^\x1b\[[\d;]+m\[-\]|^\[!\] .*(?:fail|error|broken)", re.I)),
]
# Match the colored "[!]" warning glyph used by common.sh, and bare WARNING:
warn_re = re.compile(r"^\x1b\[[\d;]+m\[!\]|^\[WARNING\]|^WARNING:")

# Benign / cosmetic warnings emitted by third-party tooling (apt, dpkg, grub,
# cargo, docker-compose, openmpi, ca-certificates, python upstream code) that
# are NOT portalgun defects and reflect reality (no kernel headers in a VM,
# apt's standard CLI-stability notice, idempotent re-run volume notices, etc.).
# These are excluded from the warning count so a healthy install reports zero.
# Keep this list specific so a genuine new warning is never masked.
benign_warn_res = [
    re.compile(r"apt does not have a stable CLI interface"),
    re.compile(r"No kernel headers were found, skipping module build"),
    re.compile(r"be sure to add .*\.cargo/bin to your PATH"),
    re.compile(r"os-prober will not be executed"),
    re.compile(r"You appear to have cloned an empty repository"),
    re.compile(r"unable to delete old directory .*: Directory not empty"),
    re.compile(r"invalid escape sequence"),                      # SyntaxWarning
    re.compile(r"volume .* already exists but was not created by Docker Compose"),
    re.compile(r"update-alternatives: warning: skip creation of"),
    re.compile(r"rehash: warning: skipping .*does not contain exactly one certificate"),
    # pip's post-install resolver inconsistency notices (non-fatal; the bundle
    # is a deliberately under-constrained complete freeze). Header + each
    # "requires X but you have Y" line.
    re.compile(r"pip's dependency resolver does not currently take into account"),
    re.compile(r"^\S+ \S+ requires .*, but you have \S+ \S+\.$"),
]
def _is_benign_warn(s):
    return any(rx.search(s) for rx in benign_warn_res)

cur_phase = "preamble"
by_phase = {}
counts = {k: 0 for k, _ in err_patterns}
counts["warning"] = 0
samples = {k: [] for k, _ in err_patterns}

# This analyzer prints matched samples to stdout (e.g. "[install-log] ..." and
# "  L123: ERROR: Cannot install ...") which can be tee'd back into a later
# master log. Skip our own echoed output so a previous run's reported errors are
# not re-counted as new errors on the next run (the observed errors=7 vs 4 drift
# where 3 were the analyzer's own appended lines).
self_echo_re = re.compile(r"^\[install-log\]|^\s+L\d+:\s")

for i, raw in enumerate(lines):
    line = raw.rstrip("\n")
    if self_echo_re.search(line):
        continue
    if phase_re.search(line):
        cur_phase = phase_re.search(line).group(0).strip(":") + " " + line[phase_re.search(line).end():].strip()
        cur_phase = cur_phase[:80]
    pinfo = by_phase.setdefault(cur_phase, {"errors": 0, "warnings": 0, "lines": 0, "first_error": None})
    pinfo["lines"] += 1
    if warn_re.search(line) and not _is_benign_warn(line):
        counts["warning"] += 1
        pinfo["warnings"] += 1
    for key, rx in err_patterns:
        if rx.search(line):
            counts[key] += 1
            pinfo["errors"] += 1
            if not pinfo["first_error"]:
                pinfo["first_error"] = line.strip()[:200]
            if len(samples[key]) < 8:
                samples[key].append({"line": i + 1, "text": line.strip()[:240]})
            break

summary = {
    "timestamp": ts,
    "log_path": log_path,
    "log_url": f"/install-logs/install-{ts}.log",
    "size_bytes": os.path.getsize(log_path),
    "line_count": len(lines),
    "counts": counts,
    "by_phase": by_phase,
    "samples": samples,
}
json.dump(summary, open(summary_path, "w"), indent=2)

# Also drop a copy of summary in the web dir
web_summary = os.path.join("/opt/tools-docs/install-logs", f"install-{ts}.summary.json")
try:
    os.makedirs(os.path.dirname(web_summary), exist_ok=True)
    json.dump(summary, open(web_summary, "w"), indent=2)
except Exception:
    pass

# Update an index.json listing all logs (newest first)
idx_path = "/opt/tools-docs/install-logs/index.json"
existing = []
if os.path.isfile(idx_path):
    try:
        existing = json.load(open(idx_path))
    except Exception:
        existing = []
existing.insert(0, {
    "timestamp": ts,
    "log": f"install-{ts}.log",
    "summary": f"install-{ts}.summary.json",
    "errors": sum(counts[k] for k in counts if k != "warning"),
    "warnings": counts["warning"],
    "size_bytes": os.path.getsize(log_path),
})
existing = existing[:50]
try:
    json.dump(existing, open(idx_path, "w"), indent=2)
except Exception:
    pass

# Print short summary to stdout
total_err = sum(counts[k] for k in counts if k != "warning")
print(f"[install-log] saved -> {log_path}")
print(f"[install-log] errors={total_err}  warnings={counts['warning']}  lines={len(lines)}")
if total_err:
    print(f"[install-log] breakdown: " + " ".join(f"{k}={v}" for k,v in counts.items() if v))
    for key, hits in samples.items():
        if hits:
            print(f"[install-log] first {key} examples:")
            for h in hits[:3]:
                print(f"  L{h['line']}: {h['text']}")
print(f"[install-log] summary -> {summary_path}")
print(f"[install-log] web URL  -> http://<host>:1337/install-logs/install-{ts}.log")
PYEOF
