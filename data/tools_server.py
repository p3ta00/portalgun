#!/usr/bin/env python3
"""
Tools Documentation Server with Dotfile Installer
Serves static files and handles dotfile installation via API
"""

from flask import Flask, send_from_directory, request, jsonify, Response, stream_with_context
import os
import shutil
import json
import subprocess
import re
import uuid
import threading
import time
import tempfile
import fcntl
import shlex
from datetime import datetime

ANSI_ESCAPE = re.compile(r'\x1b\[[0-9;]*[mGKHFABCDJn]')

app = Flask(__name__)
app.config['MAX_CONTENT_LENGTH'] = 2 * 1024 * 1024  # 2MB max request body

# Background job tracking — protected by lock
JOBS = {}
JOBS_LOCK = threading.Lock()

DOCS_DIR = '/opt/tools-docs'
DOTFILES_DIR = os.path.join(DOCS_DIR, 'dotfiles')
HOME_DIR = os.path.expanduser('~')

# Janitor: clean up old job logs every hour
def _jobs_janitor():
    while True:
        time.sleep(3600)
        cutoff = time.time() - 3600
        with JOBS_LOCK:
            expired = [jid for jid, j in JOBS.items()
                       if j.get('done') and j.get('started', 0) < cutoff]
            for jid in expired:
                log = JOBS[jid].get('log')
                if log and os.path.exists(log):
                    try:
                        os.unlink(log)
                    except OSError:
                        pass
                del JOBS[jid]

threading.Thread(target=_jobs_janitor, daemon=True).start()

# Input validation helpers
_SAFE_PKG = re.compile(r'^[a-z0-9][a-z0-9+._-]*$')
_SAFE_URL = re.compile(r'^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(\.git)?/?$')
_SAFE_SCRIPT = re.compile(r'^[A-Za-z0-9_.-]+(\.sh|\.py)?$')

def _safe_target(path):
    """Expand ~ and reject path traversal — target must be under HOME_DIR"""
    expanded = os.path.realpath(os.path.expanduser(path))
    # Allow HOME_DIR and /opt/tools-docs/dotfiles
    allowed_roots = [os.path.realpath(HOME_DIR), os.path.realpath(DOTFILES_DIR)]
    if not any(expanded.startswith(r) for r in allowed_roots):
        return None
    return expanded

@app.route('/')
def index():
    return send_from_directory(DOCS_DIR, 'index.html')

@app.route('/<path:path>')
def static_files(path):
    return send_from_directory(DOCS_DIR, path)

@app.route('/api/readme')
def serve_readme():
    """Serve a tool's local README file (offline)."""
    path = request.args.get('path', '')
    if not path:
        return 'No path specified', 400
    real = os.path.realpath(path)
    # Allow paths under /opt/tools/ (github), /usr/share/doc/ (apt fallback),
    # or /var/cache/portalgun/apt-readmes/ (cached GitHub READMEs for apt tools)
    allowed_prefixes = ('/opt/tools/', '/usr/share/doc/', '/var/cache/portalgun/',
                        '/var/log/portalgun/')
    if not any(real.startswith(p) for p in allowed_prefixes):
        return 'Forbidden', 403
    if not os.path.isfile(real):
        return 'README not found', 404
    try:
        if real.endswith('.gz'):
            import gzip
            with gzip.open(real, 'rt', encoding='utf-8', errors='replace') as f:
                content = f.read()
        else:
            with open(real, 'r', encoding='utf-8', errors='replace') as f:
                content = f.read()
        fmt = 'markdown' if real.lower().rstrip('.gz').endswith(('.md', '.markdown')) else 'text'
        return jsonify({'content': content, 'format': fmt, 'path': real})
    except Exception as e:
        return jsonify({'error': str(e)}), 500


_SAFE_PKG_NAME = re.compile(r'^[a-z0-9][a-z0-9+._-]*$')


@app.route('/api/readme/manpage')
def serve_manpage():
    """Render an apt package's man page as text."""
    package = request.args.get('package', '')
    if not _SAFE_PKG_NAME.match(package):
        return jsonify({'error': 'Invalid package name'}), 400
    try:
        env = os.environ.copy()
        env['MANWIDTH'] = '100'
        env['MANPAGER'] = 'cat'
        result = subprocess.run(
            ['man', package],
            capture_output=True, text=True, timeout=10,
            env=env
        )
        if result.returncode == 0 and result.stdout.strip():
            # Strip backspace formatting (man uses _\b_ for underline, etc.)
            content = re.sub(r'.\x08', '', result.stdout)
            return jsonify({'content': content, 'format': 'text', 'path': f'man {package}'})
        return jsonify({'error': 'No man page for ' + package}), 404
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/api/readme/help')
def serve_help_text():
    """Run <package> --help for tools without a README or man page."""
    package = request.args.get('package', '')
    if not _SAFE_PKG_NAME.match(package):
        return jsonify({'error': 'Invalid package name'}), 400
    # Try `<bin> --help` then `<bin> -h`
    for flag in ('--help', '-h'):
        try:
            result = subprocess.run(
                [package, flag],
                capture_output=True, text=True, timeout=5
            )
            text = (result.stdout or '') + (result.stderr or '')
            if text.strip():
                return jsonify({'content': text, 'format': 'text', 'path': f'{package} {flag}'})
        except FileNotFoundError:
            return jsonify({'error': 'Binary not in PATH: ' + package}), 404
        except Exception:
            continue
    return jsonify({'error': 'No help output for ' + package}), 404


@app.route('/api/install-dotfile', methods=['POST'])
def install_dotfile():
    try:
        data = request.json
        dotfile_id = data.get('id')

        # Load manifest
        manifest_path = os.path.join(DOTFILES_DIR, 'manifest.json')
        with open(manifest_path, 'r') as f:
            manifest = json.load(f)

        # Find the dotfile
        dotfile = None
        for df in manifest['dotfiles']:
            if df['id'] == dotfile_id:
                dotfile = df
                break

        if not dotfile:
            return jsonify({'success': False, 'error': 'Dotfile not found'}), 404

        # Source and target paths
        source = os.path.join(DOTFILES_DIR, dotfile['file'])
        target = os.path.expanduser(dotfile['target'])

        # Create target directory if needed
        target_dir = os.path.dirname(target)
        if target_dir and not os.path.exists(target_dir):
            os.makedirs(target_dir, exist_ok=True)

        # Backup existing file if it exists
        if os.path.exists(target):
            backup = target + '.backup'
            shutil.copy2(target, backup)

        # Copy the dotfile
        shutil.copy2(source, target)

        return jsonify({
            'success': True,
            'message': f'Installed {dotfile["name"]} to {dotfile["target"]}',
            'backup': os.path.exists(target + '.backup')
        })

    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 500

@app.route('/api/dotfiles', methods=['GET'])
def list_dotfiles():
    try:
        manifest_path = os.path.join(DOTFILES_DIR, 'manifest.json')
        with open(manifest_path, 'r') as f:
            manifest = json.load(f)

        tmux_imported = []
        if os.path.exists(IMPORTED_TMUX_INDEX):
            with open(IMPORTED_TMUX_INDEX, 'r') as f:
                tmux_imported = json.load(f)

        return jsonify({
            'dotfiles': manifest.get('dotfiles', []),
            'tmux_imported': tmux_imported
        })
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/api/import-dotfile', methods=['POST'])
def import_dotfile():
    try:
        data = request.json
        import_type = data.get('type')  # 'zshrc' or 'tmux'
        name = data.get('name', '').strip()

        if not name:
            return jsonify({'success': False, 'error': 'Name required'}), 400

        safe_name = ''.join(c for c in name if c.isalnum() or c in '-_').lower()
        if not safe_name:
            return jsonify({'success': False, 'error': 'Invalid name'}), 400

        content = data.get('content')
        if not content:
            return jsonify({'success': False, 'error': 'No file content received'}), 400

        if import_type == 'zshrc':
            file_name = f'zshrc_imported_{safe_name}'
            dest = os.path.join(DOTFILES_DIR, file_name)
            with open(dest, 'w') as f:
                f.write(content)

            entry_id = f'zshrc_imported_{safe_name}'
            entry = {
                'id': entry_id,
                'name': name,
                'file': file_name,
                'target': '~/.zshrc',
                'description': f'Imported on {datetime.now().strftime("%Y-%m-%d")}',
                'category': 'shell',
                'requires': ['zsh']
            }

            manifest_path = os.path.join(DOTFILES_DIR, 'manifest.json')
            with open(manifest_path, 'r') as f:
                manifest = json.load(f)

            manifest['dotfiles'] = [d for d in manifest['dotfiles'] if d['id'] != entry_id]
            manifest['dotfiles'].append(entry)

            with open(manifest_path, 'w') as f:
                json.dump(manifest, f, indent=2)

            return jsonify({'success': True, 'message': f'Imported as "{name}"', 'id': entry_id})

        elif import_type == 'tmux':
            os.makedirs(IMPORTED_TMUX_DIR, exist_ok=True)
            dest = os.path.join(IMPORTED_TMUX_DIR, f'{safe_name}.conf')
            with open(dest, 'w') as f:
                f.write(content)

            entry = {
                'id': safe_name,
                'name': name,
                'imported_at': datetime.now().isoformat()
            }

            index = []
            if os.path.exists(IMPORTED_TMUX_INDEX):
                with open(IMPORTED_TMUX_INDEX, 'r') as f:
                    index = json.load(f)

            index = [e for e in index if e['id'] != safe_name]
            index.append(entry)

            with open(IMPORTED_TMUX_INDEX, 'w') as f:
                json.dump(index, f, indent=2)

            return jsonify({'success': True, 'message': f'Imported as "{name}"', 'id': safe_name})

        else:
            return jsonify({'success': False, 'error': f'Unknown type: {import_type}'}), 400

    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 500

@app.route('/api/edit-dotfile', methods=['POST'])
def edit_dotfile():
    try:
        data = request.json
        dotfile_id = data.get('id')

        # Load manifest
        manifest_path = os.path.join(DOTFILES_DIR, 'manifest.json')
        with open(manifest_path, 'r') as f:
            manifest = json.load(f)

        # Find the dotfile
        dotfile = None
        for df in manifest['dotfiles']:
            if df['id'] == dotfile_id:
                dotfile = df
                break

        if not dotfile:
            return jsonify({'success': False, 'error': 'Dotfile not found'}), 404

        # Target path
        target = os.path.expanduser(dotfile['target'])

        # Set display for GUI apps
        env = os.environ.copy()
        env['DISPLAY'] = ':0'

        # Terminals whose -e takes a single string get a shell-quoted path so
        # filenames with spaces/special chars open correctly (and can't be
        # word-split into extra commands).
        qtarget = shlex.quote(target)
        terminals = [
            ['kitty', '-e', 'nvim', target],
            ['qterminal', '-e', f'nvim {qtarget}'],
            ['gnome-terminal', '--', 'nvim', target],
            ['xfce4-terminal', '-e', f'nvim {qtarget}'],
            ['konsole', '-e', 'nvim', target],
            ['xterm', '-e', f'nvim {qtarget}'],
        ]

        for term_cmd in terminals:
            try:
                subprocess.Popen(term_cmd, start_new_session=True, env=env)
                return jsonify({'success': True, 'message': f'Opened {target} in nvim'})
            except FileNotFoundError:
                continue

        return jsonify({'success': False, 'error': 'No terminal emulator found'}), 500

    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 500

ZELLIJ_DIR = os.path.join(DOTFILES_DIR, 'zellij')
CUSTOM_HOTKEYS_DIR = os.path.join(ZELLIJ_DIR, 'custom')
TMUX_DIR = os.path.join(DOTFILES_DIR, 'tmux')
CUSTOM_TMUX_DIR = os.path.join(TMUX_DIR, 'custom')
IMPORTED_TMUX_DIR = os.path.join(TMUX_DIR, 'imported')
IMPORTED_TMUX_INDEX = os.path.join(IMPORTED_TMUX_DIR, 'index.json')

# Zellij preset configs
ZELLIJ_PRESETS = {
    'p3ta': 'zellij_p3ta.kdl',
    'default': 'zellij_default.kdl'
}

ZELLIJ_HOTKEY_PRESETS = {
    'p3ta': 'hotkeys_p3ta.kdl',
    'default': 'hotkeys_default.kdl'
}

# Tmux theme presets
TMUX_THEMES = {
    'catppuccin-mocha': 'tmux_catppuccin_mocha.conf',
    'dracula': 'tmux_dracula.conf',
    'nord': 'tmux_nord.conf',
    'gruvbox': 'tmux_gruvbox.conf',
    'tokyo-night': 'tmux_tokyo_night.conf'
}

TMUX_HOTKEY_PRESETS = {
    'p3ta': 'tmux_hotkeys_p3ta.conf',
    'default': 'tmux_hotkeys_default.conf'
}

@app.route('/api/install-config', methods=['POST'])
def install_config():
    """Install zshrc or zellij config"""
    try:
        data = request.json
        config_type = data.get('type')  # zshrc, zellij-config, zellij-hotkeys
        config_id = data.get('id')

        if config_type == 'zshrc':
            # Use existing dotfile logic
            manifest_path = os.path.join(DOTFILES_DIR, 'manifest.json')
            with open(manifest_path, 'r') as f:
                manifest = json.load(f)

            dotfile = None
            for df in manifest['dotfiles']:
                if df['id'] == config_id:
                    dotfile = df
                    break

            if not dotfile:
                return jsonify({'success': False, 'error': 'Config not found'}), 404

            source = os.path.join(DOTFILES_DIR, dotfile['file'])
            target = os.path.expanduser(dotfile['target'])

        elif config_type == 'zellij-config':
            if config_id not in ZELLIJ_PRESETS:
                return jsonify({'success': False, 'error': 'Unknown preset'}), 404

            zellij_config_dir = os.path.join(HOME_DIR, '.config', 'zellij')

            # For "default", remove custom files to get true vanilla Zellij
            if config_id == 'default':
                for item in ['config.kdl', 'layouts', 'themes.kdl']:
                    item_path = os.path.join(zellij_config_dir, item)
                    if os.path.isfile(item_path):
                        os.remove(item_path)
                    elif os.path.isdir(item_path):
                        shutil.rmtree(item_path)
                # Clear cache
                cache_dir = os.path.join(HOME_DIR, '.cache', 'zellij')
                if os.path.exists(cache_dir):
                    shutil.rmtree(cache_dir)
                return jsonify({
                    'success': True,
                    'message': 'Vanilla Zellij restored (config removed)',
                    'backup': False
                })

            # For "p3ta", copy config AND extra files (layouts, themes, scripts)
            if config_id == 'p3ta':
                p3ta_files_dir = os.path.join(ZELLIJ_DIR, 'p3ta_files')
                # Copy layouts
                src_layouts = os.path.join(p3ta_files_dir, 'layouts')
                dst_layouts = os.path.join(zellij_config_dir, 'layouts')
                if os.path.exists(src_layouts):
                    if os.path.exists(dst_layouts):
                        shutil.rmtree(dst_layouts)
                    shutil.copytree(src_layouts, dst_layouts)
                # Copy themes.kdl
                src_themes = os.path.join(p3ta_files_dir, 'themes.kdl')
                if os.path.exists(src_themes):
                    shutil.copy2(src_themes, os.path.join(zellij_config_dir, 'themes.kdl'))
                # Copy scripts
                src_scripts = os.path.join(p3ta_files_dir, 'scripts')
                dst_scripts = os.path.join(zellij_config_dir, 'scripts')
                if os.path.exists(src_scripts):
                    if os.path.exists(dst_scripts):
                        shutil.rmtree(dst_scripts)
                    shutil.copytree(src_scripts, dst_scripts)
                    # Make scripts executable
                    for script in os.listdir(dst_scripts):
                        os.chmod(os.path.join(dst_scripts, script), 0o755)
                # Copy plugins (zjstatus)
                src_plugins = os.path.join(p3ta_files_dir, 'plugins')
                dst_plugins = os.path.join(zellij_config_dir, 'plugins')
                if os.path.exists(src_plugins):
                    os.makedirs(dst_plugins, exist_ok=True)
                    for plugin in os.listdir(src_plugins):
                        shutil.copy2(os.path.join(src_plugins, plugin), dst_plugins)

            source = os.path.join(ZELLIJ_DIR, ZELLIJ_PRESETS[config_id])
            target = os.path.join(zellij_config_dir, 'config.kdl')

        elif config_type == 'zellij-hotkeys':
            # Check if it's a custom config or preset
            if config_id.startswith('custom_'):
                custom_name = config_id.replace('custom_', '')
                source = os.path.join(CUSTOM_HOTKEYS_DIR, f'{custom_name}.kdl')
            elif config_id in ZELLIJ_HOTKEY_PRESETS:
                source = os.path.join(ZELLIJ_DIR, ZELLIJ_HOTKEY_PRESETS[config_id])
            else:
                return jsonify({'success': False, 'error': 'Unknown hotkey preset'}), 404
            target = os.path.join(HOME_DIR, '.config', 'zellij', 'config.kdl')

        elif config_type == 'tmux-theme':
            if config_id not in TMUX_THEMES:
                return jsonify({'success': False, 'error': 'Unknown tmux theme'}), 404
            source = os.path.join(TMUX_DIR, TMUX_THEMES[config_id])
            target = os.path.join(HOME_DIR, '.tmux.conf')

        elif config_type == 'tmux-hotkeys':
            if config_id.startswith('custom_'):
                custom_name = config_id.replace('custom_', '')
                source = os.path.join(CUSTOM_TMUX_DIR, f'{custom_name}.conf')
            elif config_id in TMUX_HOTKEY_PRESETS:
                source = os.path.join(TMUX_DIR, TMUX_HOTKEY_PRESETS[config_id])
            else:
                return jsonify({'success': False, 'error': 'Unknown tmux hotkey preset'}), 404
            target = os.path.join(HOME_DIR, '.tmux.conf')

        elif config_type == 'tmux-imported':
            source = os.path.join(IMPORTED_TMUX_DIR, f'{config_id}.conf')
            if not os.path.exists(source):
                return jsonify({'success': False, 'error': f'Imported config not found: {config_id}'}), 404
            target = os.path.join(HOME_DIR, '.tmux.conf')

        else:
            return jsonify({'success': False, 'error': 'Invalid config type'}), 400

        # Check source exists
        if not os.path.exists(source):
            return jsonify({'success': False, 'error': f'Source file not found: {source}'}), 404

        # Create target directory
        target_dir = os.path.dirname(target)
        if target_dir and not os.path.exists(target_dir):
            os.makedirs(target_dir, exist_ok=True)

        # Backup existing
        if os.path.exists(target):
            backup = target + '.backup'
            shutil.copy2(target, backup)

        # Copy config
        shutil.copy2(source, target)

        # If tmux config, source it into any running tmux sessions so the
        # change is visible immediately. Themes are standalone (no plugin
        # download needed) so TPM headless install is not required.
        tpm_message = ''
        if config_type in ['tmux-theme', 'tmux-hotkeys', 'tmux-imported']:
            # Reload config in all running tmux sessions
            try:
                # Get list of tmux sessions
                result = subprocess.run(['tmux', 'list-sessions', '-F', '#{session_name}'],
                                       capture_output=True, text=True, timeout=5)
                if result.returncode == 0 and result.stdout.strip():
                    sessions = result.stdout.strip().split('\n')
                    for sess in sessions:
                        subprocess.run(['tmux', 'source-file', '-t', sess, target],
                                     capture_output=True, timeout=5)
                    tpm_message = f' (reloaded in {len(sessions)} tmux session(s))'
                else:
                    tpm_message = ' (will apply on next tmux start)'
            except Exception:
                tpm_message = ' (will apply on next tmux start)'

            # Skip the legacy TPM block below
        return jsonify({
            'success': True,
            'message': f'Installed to {target}{tpm_message}',
            'backup': os.path.exists(target + '.backup')
        })

    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 500

@app.route('/api/edit-file', methods=['POST'])
def edit_file():
    """Open a file in nvim"""
    try:
        data = request.json
        target = os.path.expanduser(data.get('target', ''))

        if not target:
            return jsonify({'success': False, 'error': 'No target specified'}), 400

        # Set display for GUI apps
        env = os.environ.copy()
        env['DISPLAY'] = ':0'

        # Terminals whose -e takes a single string get a shell-quoted path so
        # filenames with spaces/special chars open correctly (and can't be
        # word-split into extra commands).
        qtarget = shlex.quote(target)
        terminals = [
            ['kitty', '-e', 'nvim', target],
            ['qterminal', '-e', f'nvim {qtarget}'],
            ['gnome-terminal', '--', 'nvim', target],
            ['xfce4-terminal', '-e', f'nvim {qtarget}'],
            ['konsole', '-e', 'nvim', target],
            ['xterm', '-e', f'nvim {qtarget}'],
        ]

        for term_cmd in terminals:
            try:
                subprocess.Popen(term_cmd, start_new_session=True, env=env)
                return jsonify({'success': True, 'message': f'Opened {target} in nvim'})
            except FileNotFoundError:
                continue

        return jsonify({'success': False, 'error': 'No terminal emulator found'}), 500

    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 500

@app.route('/api/save-hotkeys', methods=['POST'])
def save_hotkeys():
    """Save custom hotkeys and generate zellij config"""
    try:
        data = request.json
        name = data.get('name', '').strip()
        hotkeys = data.get('hotkeys', {})

        if not name:
            return jsonify({'success': False, 'error': 'Name required'}), 400

        # Sanitize name
        safe_name = ''.join(c for c in name if c.isalnum() or c in '-_').lower()

        # Ensure custom dir exists
        os.makedirs(CUSTOM_HOTKEYS_DIR, exist_ok=True)

        # Generate zellij KDL config
        kdl_config = generate_zellij_kdl(hotkeys)

        # Save to custom dir
        config_path = os.path.join(CUSTOM_HOTKEYS_DIR, f'{safe_name}.kdl')
        with open(config_path, 'w') as f:
            f.write(kdl_config)

        # Also install to user's config
        target_dir = os.path.join(HOME_DIR, '.config', 'zellij')
        os.makedirs(target_dir, exist_ok=True)
        target = os.path.join(target_dir, 'config.kdl')

        # Backup existing
        if os.path.exists(target):
            shutil.copy2(target, target + '.backup')

        shutil.copy2(config_path, target)

        return jsonify({
            'success': True,
            'message': f'Saved as {safe_name} and installed',
            'config_name': safe_name
        })

    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 500

def generate_zellij_kdl(hotkeys):
    """Generate zellij config KDL from hotkey mapping"""
    # Default values if not specified
    defaults = {
        'split-right': 'n',
        'split-down': 'm',
        'close-pane': 'x',
        'fullscreen': 'z',
        'float': '!',
        'new-tab': 'c',
        'close-tab': '&',
        'next-tab': 'N',
        'prev-tab': 'p',
        'rename-tab': ',',
        'move-left': 'h',
        'move-down': 'j',
        'move-up': 'k',
        'move-right': 'l',
        'resize-mode': 'r',
        'scroll-mode': '[',
        'session': 's',
        'detach': 'd'
    }

    # Merge with provided hotkeys
    keys = {**defaults, **hotkeys}

    kdl = '''// Zellij Config - Custom Hotkeys
// Generated by Config Manager

keybinds clear-defaults=true {
    normal {
        // Pane operations
        bind "Ctrl ''' + keys['split-right'] + '''" { NewPane "Right"; }
        bind "Ctrl ''' + keys['split-down'] + '''" { NewPane "Down"; }
        bind "Ctrl ''' + keys['close-pane'] + '''" { CloseFocus; }
        bind "Ctrl ''' + keys['fullscreen'] + '''" { ToggleFocusFullscreen; }
        bind "Ctrl ''' + keys['float'] + '''" { ToggleFloatingPanes; }

        // Tab operations
        bind "Ctrl ''' + keys['new-tab'] + '''" { NewTab; }
        bind "Ctrl ''' + keys['close-tab'] + '''" { CloseTab; }
        bind "Ctrl ''' + keys['next-tab'] + '''" { GoToNextTab; }
        bind "Ctrl ''' + keys['prev-tab'] + '''" { GoToPreviousTab; }
        bind "Ctrl ''' + keys['rename-tab'] + '''" { SwitchToMode "RenameTab"; }

        // Navigation
        bind "Alt ''' + keys['move-left'] + '''" { MoveFocus "Left"; }
        bind "Alt ''' + keys['move-down'] + '''" { MoveFocus "Down"; }
        bind "Alt ''' + keys['move-up'] + '''" { MoveFocus "Up"; }
        bind "Alt ''' + keys['move-right'] + '''" { MoveFocus "Right"; }

        // Mode switching
        bind "Ctrl ''' + keys['resize-mode'] + '''" { SwitchToMode "Resize"; }
        bind "Ctrl ''' + keys['scroll-mode'] + '''" { SwitchToMode "Scroll"; }
        bind "Ctrl ''' + keys['session'] + '''" { SwitchToMode "Session"; }
        bind "Ctrl ''' + keys['detach'] + '''" { Detach; }

        // Tab numbers
        bind "Ctrl 1" { GoToTab 1; }
        bind "Ctrl 2" { GoToTab 2; }
        bind "Ctrl 3" { GoToTab 3; }
        bind "Ctrl 4" { GoToTab 4; }
        bind "Ctrl 5" { GoToTab 5; }
        bind "Ctrl 6" { GoToTab 6; }
        bind "Ctrl 7" { GoToTab 7; }
        bind "Ctrl 8" { GoToTab 8; }
        bind "Ctrl 9" { GoToTab 9; }
    }

    resize {
        bind "h" "Left" { Resize "Increase Left"; }
        bind "j" "Down" { Resize "Increase Down"; }
        bind "k" "Up" { Resize "Increase Up"; }
        bind "l" "Right" { Resize "Increase Right"; }
        bind "Esc" { SwitchToMode "Normal"; }
    }

    scroll {
        bind "j" "Down" { ScrollDown; }
        bind "k" "Up" { ScrollUp; }
        bind "d" { HalfPageScrollDown; }
        bind "u" { HalfPageScrollUp; }
        bind "Esc" { SwitchToMode "Normal"; }
    }

    session {
        bind "d" { Detach; }
        bind "Esc" { SwitchToMode "Normal"; }
    }

    renametab {
        bind "Enter" { SwitchToMode "Normal"; }
        bind "Esc" { SwitchToMode "Normal"; }
    }
}

// Theme
theme "catppuccin-mocha"

// UI Options
pane_frames true
'''
    return kdl

@app.route('/api/save-tmux-hotkeys', methods=['POST'])
def save_tmux_hotkeys():
    """Save custom tmux hotkeys and generate config"""
    try:
        data = request.json
        name = data.get('name', '').strip()
        hotkeys = data.get('hotkeys', {})
        theme = data.get('theme', 'catppuccin-mocha')

        if not name:
            return jsonify({'success': False, 'error': 'Name required'}), 400

        # Sanitize name
        safe_name = ''.join(c for c in name if c.isalnum() or c in '-_').lower()

        # Ensure custom dir exists
        os.makedirs(CUSTOM_TMUX_DIR, exist_ok=True)

        # Generate tmux config
        tmux_config = generate_tmux_conf(hotkeys, theme)

        # Save to custom dir
        config_path = os.path.join(CUSTOM_TMUX_DIR, f'{safe_name}.conf')
        with open(config_path, 'w') as f:
            f.write(tmux_config)

        # Also install to user's config
        target = os.path.join(HOME_DIR, '.tmux.conf')

        # Backup existing
        if os.path.exists(target):
            shutil.copy2(target, target + '.backup')

        shutil.copy2(config_path, target)

        return jsonify({
            'success': True,
            'message': f'Saved as {safe_name} and installed',
            'config_name': safe_name
        })

    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 500

def generate_tmux_conf(hotkeys, theme='catppuccin-mocha'):
    """Generate tmux config from hotkey mapping and theme"""
    # Default hotkeys
    defaults = {
        'split-v': '|',
        'split-h': '-',
        'kill-pane': 'x',
        'fullscreen': 'z',
        'new-window': 'c',
        'kill-window': '&',
        'next-window': 'n',
        'prev-window': 'p',
        'rename-window': ',',
        'select-left': 'h',
        'select-down': 'j',
        'select-up': 'k',
        'select-right': 'l',
        'reload': 'r',
        'copy-mode': '[',
        'list-sessions': 's',
        'detach': 'd'
    }

    keys = {**defaults, **hotkeys}

    # Theme colors
    themes = {
        'catppuccin-mocha': {
            'bg': '#1e1e2e', 'fg': '#cdd6f4', 'black': '#181825', 'gray': '#313244',
            'blue': '#89b4fa', 'magenta': '#cba6f7', 'cyan': '#89dceb',
            'green': '#a6e3a1', 'yellow': '#f9e2af', 'red': '#f38ba8'
        },
        'catppuccin-macchiato': {
            'bg': '#24273a', 'fg': '#cad3f5', 'black': '#1e2030', 'gray': '#363a4f',
            'blue': '#8aadf4', 'magenta': '#c6a0f6', 'cyan': '#91d7e3',
            'green': '#a6da95', 'yellow': '#eed49f', 'red': '#ed8796'
        },
        'dracula': {
            'bg': '#282a36', 'fg': '#f8f8f2', 'black': '#21222c', 'gray': '#44475a',
            'blue': '#8be9fd', 'magenta': '#bd93f9', 'cyan': '#8be9fd',
            'green': '#50fa7b', 'yellow': '#f1fa8c', 'red': '#ff5555'
        },
        'nord': {
            'bg': '#2e3440', 'fg': '#eceff4', 'black': '#3b4252', 'gray': '#4c566a',
            'blue': '#88c0d0', 'magenta': '#b48ead', 'cyan': '#8fbcbb',
            'green': '#a3be8c', 'yellow': '#ebcb8b', 'red': '#bf616a'
        },
        'gruvbox': {
            'bg': '#282828', 'fg': '#ebdbb2', 'black': '#1d2021', 'gray': '#3c3836',
            'blue': '#83a598', 'magenta': '#d3869b', 'cyan': '#8ec07c',
            'green': '#b8bb26', 'yellow': '#fabd2f', 'red': '#fb4934'
        },
        'tokyo-night': {
            'bg': '#1a1b26', 'fg': '#c0caf5', 'black': '#15161e', 'gray': '#414868',
            'blue': '#7aa2f7', 'magenta': '#bb9af7', 'cyan': '#7dcfff',
            'green': '#9ece6a', 'yellow': '#e0af68', 'red': '#f7768e'
        }
    }

    t = themes.get(theme, themes['catppuccin-mocha'])

    conf = f'''# ═══════════════════════════════════════════════════════════════════
# Tmux Configuration - Custom Hotkeys
# Theme: {theme}
# Generated by Config Manager
# ═══════════════════════════════════════════════════════════════════

# General Settings
set -g default-terminal "tmux-256color"
set -ag terminal-overrides ",xterm-256color:RGB"
set -g mouse on
set -g history-limit 50000
set -g base-index 1
setw -g pane-base-index 1
set -g renumber-windows on
set -sg escape-time 0
set -g focus-events on
set -g set-clipboard on

# ───────────────────────────────────────────────────────────────────
# Key Bindings
# ───────────────────────────────────────────────────────────────────
# Reload config
bind {keys['reload']} source-file ~/.tmux.conf \\; display "Config reloaded!"

# Split panes
bind {keys['split-v']} split-window -h -c "#{{pane_current_path}}"
bind {keys['split-h']} split-window -v -c "#{{pane_current_path}}"

# Pane navigation (vim-style)
bind {keys['select-left']} select-pane -L
bind {keys['select-down']} select-pane -D
bind {keys['select-up']} select-pane -U
bind {keys['select-right']} select-pane -R

# Alt + h/j/k/l to switch panes (no prefix)
bind -n M-h select-pane -L
bind -n M-l select-pane -R
bind -n M-k select-pane -U
bind -n M-j select-pane -D

# Pane management
bind {keys['kill-pane']} kill-pane
bind {keys['fullscreen']} resize-pane -Z

# Window management
bind {keys['new-window']} new-window -c "#{{pane_current_path}}"
bind {keys['kill-window']} kill-window
bind {keys['next-window']} next-window
bind {keys['prev-window']} previous-window
bind {keys['rename-window']} command-prompt -I "#W" "rename-window '%%'"

# Other
bind {keys['copy-mode']} copy-mode
bind {keys['list-sessions']} choose-tree -Zs
bind {keys['detach']} detach-client

# Shift + arrow to switch windows
bind -n S-Left previous-window
bind -n S-Right next-window

# Resize panes with Prefix + H/J/K/L
bind -r H resize-pane -L 5
bind -r J resize-pane -D 5
bind -r K resize-pane -U 5
bind -r L resize-pane -R 5

# ───────────────────────────────────────────────────────────────────
# Copy Mode (vi keys)
# ───────────────────────────────────────────────────────────────────
setw -g mode-keys vi
bind -T copy-mode-vi v send -X begin-selection
bind -T copy-mode-vi y send -X copy-pipe-and-cancel "xclip -selection clipboard"

# ───────────────────────────────────────────────────────────────────
# Theme: {theme}
# ───────────────────────────────────────────────────────────────────
set -g status on
set -g status-interval 1
set -g status-position bottom
set -g status-justify left
set -g status-style "bg={t['bg']},fg={t['fg']}"

# Left side
set -g status-left-length 100
set -g status-left "#[fg={t['black']},bg={t['blue']},bold]  #S #[fg={t['blue']},bg={t['bg']},nobold]#[default] "

# Right side
set -g status-right-length 100
set -g status-right "#[fg={t['gray']},bg={t['bg']}]#[fg={t['fg']},bg={t['gray']}]  %H:%M #[fg={t['blue']}]#[fg={t['black']},bg={t['blue']},bold]  %d-%b "

# Window status
set -g window-status-format "#[fg={t['gray']},bg={t['bg']}]#[fg={t['fg']},bg={t['gray']}] #I: #W #[fg={t['gray']},bg={t['bg']}]"
set -g window-status-current-format "#[fg={t['magenta']},bg={t['bg']}]#[fg={t['black']},bg={t['magenta']},bold] #I: #W #[fg={t['magenta']},bg={t['bg']}]"
set -g window-status-separator ""

# Pane borders
set -g pane-border-style "fg={t['gray']}"
set -g pane-active-border-style "fg={t['blue']}"

# Messages
set -g message-style "fg={t['cyan']},bg={t['gray']},bold"

# Mode style
setw -g mode-style "fg={t['magenta']},bg={t['gray']},bold"

# Clock
setw -g clock-mode-colour "{t['blue']}"

# ═══════════════════════════════════════════════════════════════════
# TPM - Tmux Plugin Manager
# ═══════════════════════════════════════════════════════════════════
set -g @plugin 'tmux-plugins/tpm'
set -g @plugin 'tmux-plugins/tmux-sensible'
set -g @plugin 'tmux-plugins/tmux-resurrect'
set -g @plugin 'tmux-plugins/tmux-continuum'
set -g @plugin 'tmux-plugins/tmux-yank'

set -g @resurrect-capture-pane-contents 'on'
set -g @continuum-restore 'on'
set -g @continuum-save-interval '10'

# Initialize TPM
run '~/.tmux/plugins/tpm/tpm'
'''
    return conf

REGISTRY_BASE = '/var/lib/portalgun/registry'


@app.route('/api/admin/export', methods=['GET'])
def admin_export():
    apt_tools    = []
    github_tools = []
    pip_tools    = []
    cargo_tools  = []

    def read_registry_dir(subdir, collect):
        d = os.path.join(REGISTRY_BASE, subdir)
        if not os.path.isdir(d):
            return
        for fname in sorted(os.listdir(d)):
            if not fname.endswith('.json'):
                continue
            try:
                with open(os.path.join(d, fname)) as f:
                    data = json.load(f)
                collect(data)
            except Exception:
                continue

    def collect_apt(data):
        pkg = data.get('package') or data.get('name')
        if pkg:
            apt_tools.append(pkg)

    def collect_github(data):
        url = data.get('url', '')
        target = data.get('target', '')
        if url:
            github_tools.append({'url': url, 'target': target})

    def collect_pip(data):
        pkg = data.get('package') or data.get('name')
        if pkg:
            pip_tools.append(pkg)

    def collect_cargo(data):
        pkg = data.get('package') or data.get('name')
        if pkg:
            cargo_tools.append(pkg)

    read_registry_dir('apt',    collect_apt)
    read_registry_dir('github', collect_github)
    read_registry_dir('pip',    collect_pip)
    read_registry_dir('cargo',  collect_cargo)

    bundle = {
        'version': '2',
        'exported_at': datetime.now().isoformat(),
        'tools': {
            'apt':    apt_tools,
            'github': github_tools,
            'pip':    pip_tools,
            'cargo':  cargo_tools,
        }
    }

    from flask import Response as FlaskResponse
    return FlaskResponse(
        json.dumps(bundle, indent=2),
        mimetype='application/json',
        headers={'Content-Disposition': 'attachment; filename="portalgun_bundle.json"'}
    )


@app.route('/api/admin/recent', methods=['GET'])
def admin_recent():
    entries = []
    for tool_type in ['apt', 'github']:
        type_dir = os.path.join(REGISTRY_BASE, tool_type)
        if not os.path.isdir(type_dir):
            continue
        for fname in os.listdir(type_dir):
            if not fname.endswith('.json'):
                continue
            try:
                with open(os.path.join(type_dir, fname)) as f:
                    data = json.load(f)
                entries.append({
                    'name': data.get('name', fname[:-5]),
                    'type': tool_type,
                    'added': data.get('added', ''),
                    'status': data.get('status', 'ok'),
                    'url': data.get('url', ''),
                })
            except Exception:
                continue
    entries.sort(key=lambda x: x.get('added', ''), reverse=True)
    return jsonify(entries[:20])


@app.route('/api/admin/install', methods=['POST'])
def admin_install():
    data = request.json
    install_type = data.get('type', '')

    def _stream_proc(cmd, cwd=None):
        proc = subprocess.Popen(
            cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, bufsize=1, cwd=cwd
        )
        for line in iter(proc.stdout.readline, ''):
            clean = ANSI_ESCAPE.sub('', line).rstrip()
            if clean:
                yield clean
        proc.stdout.close()
        proc.wait()
        return proc.returncode

    # Long-running types: background job + log tail (survives connection drops)
    if install_type in ('all', 'update'):
        if install_type == 'update':
            cmd = ['sudo', '-n', 'portalgun', 'update']
        else:
            bundle = data.get('bundle', '').strip()
            phases = data.get('phases', [])
            cmd = ['sudo', '-n', 'portalgun', 'install', 'all']
            # Always pass bundle path explicitly so it works regardless of $HOME
            if not bundle:
                for candidate in [
                    '/opt/portalgun/portalgun_bundle.json',
                    '/home/kali/portalgun/portalgun_bundle.json',
                ]:
                    if os.path.exists(candidate):
                        bundle = candidate
                        break
            if bundle:
                cmd.append(bundle)
            if phases and len(phases) < 4:
                cmd.append(f"--phases={','.join(phases)}")

        job_id = str(uuid.uuid4())[:8]
        # Use secure temp file — not world-readable fixed path
        fd, log_path = tempfile.mkstemp(dir='/var/log/portalgun', prefix=f'pg_job_{job_id}_', suffix='.log')
        os.chmod(log_path, 0o600)
        log_file = os.fdopen(fd, 'w')
        proc = subprocess.Popen(cmd, stdout=log_file, stderr=subprocess.STDOUT)
        with JOBS_LOCK:
            JOBS[job_id] = {'log': log_path, 'proc': proc, 'done': False, 'rc': None, 'started': time.time()}

        def _monitor(jid, p, lf):
            p.wait()
            lf.close()
            with JOBS_LOCK:
                if jid in JOBS:
                    JOBS[jid]['done'] = True
                    JOBS[jid]['rc'] = p.returncode
        threading.Thread(target=_monitor, args=(job_id, proc, log_file), daemon=True).start()

        return jsonify({'job_id': job_id})

    def generate():
        try:
            if False:
                pass  # placeholder to keep structure

            elif install_type == 'apt':
                pkg = data.get('package', '').strip()
                if not pkg:
                    yield json.dumps({'line': '[!] No package name specified'}) + '\n'
                    yield json.dumps({'done': True, 'success': False}) + '\n'
                    return
                if not _SAFE_PKG.match(pkg):
                    yield json.dumps({'line': f'[!] Invalid package name: {pkg}'}) + '\n'
                    yield json.dumps({'done': True, 'success': False}) + '\n'
                    return
                cmd = ['sudo', '-n', 'portalgun', 'install', 'apt', pkg]

            elif install_type == 'github':
                url = data.get('url', '').strip()
                os_cat = data.get('os_cat', 'linux')
                sub_cat = data.get('sub_cat', 'misc')
                run_requirements = data.get('requirements', False)
                run_script = data.get('run_script', '').strip()
                if not url:
                    yield json.dumps({'line': '[!] No URL specified'}) + '\n'
                    yield json.dumps({'done': True, 'success': False}) + '\n'
                    return
                # Validate inputs so a malformed URL/category can't build a
                # nonsense target path or a non-github clone target.
                if not _SAFE_URL.match(url):
                    yield json.dumps({'line': f'[!] Not a valid github URL: {url}'}) + '\n'
                    yield json.dumps({'done': True, 'success': False}) + '\n'
                    return
                if not re.fullmatch(r'[a-z0-9_-]+', os_cat) or not re.fullmatch(r'[a-z0-9_-]+', sub_cat):
                    yield json.dumps({'line': '[!] Invalid category (use [a-z0-9_-])'}) + '\n'
                    yield json.dumps({'done': True, 'success': False}) + '\n'
                    return
                if run_script and not _SAFE_SCRIPT.match(run_script):
                    yield json.dumps({'line': f'[!] Invalid run_script: {run_script}'}) + '\n'
                    yield json.dumps({'done': True, 'success': False}) + '\n'
                    return
                target_dir = f'/opt/tools/{os_cat}/{sub_cat}'
                cmd = ['sudo', '-n', 'portalgun', 'install', 'github', url, target_dir]

            elif install_type == 'pip':
                pkg = data.get('package', '').strip()
                if not pkg:
                    yield json.dumps({'line': '[!] No package name specified'}) + '\n'
                    yield json.dumps({'done': True, 'success': False}) + '\n'
                    return
                if not _SAFE_PKG.match(pkg):
                    yield json.dumps({'line': f'[!] Invalid package name: {pkg}'}) + '\n'
                    yield json.dumps({'done': True, 'success': False}) + '\n'
                    return
                cmd = ['pip', 'install', '--break-system-packages', pkg]

            elif install_type == 'cargo':
                pkg = data.get('package', '').strip()
                if not pkg:
                    yield json.dumps({'line': '[!] No package name specified'}) + '\n'
                    yield json.dumps({'done': True, 'success': False}) + '\n'
                    return
                if not _SAFE_PKG.match(pkg):
                    yield json.dumps({'line': f'[!] Invalid package name: {pkg}'}) + '\n'
                    yield json.dumps({'done': True, 'success': False}) + '\n'
                    return
                cmd = ['cargo', 'install', pkg]

            else:
                yield json.dumps({'line': f'[!] Unknown install type: {install_type}'}) + '\n'
                yield json.dumps({'done': True, 'success': False}) + '\n'
                return

            # Run main install command, stream output with heartbeats
            # so the browser connection stays alive during silent phases (e.g. apt)
            import select
            proc = subprocess.Popen(
                cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True, bufsize=1
            )
            while True:
                ready = select.select([proc.stdout], [], [], 10.0)[0]
                if ready:
                    line = proc.stdout.readline()
                    if not line:
                        break
                    clean = ANSI_ESCAPE.sub('', line).rstrip()
                    if not clean:
                        continue
                    if clean.startswith('PROGRESS:'):
                        parts = clean.split(':', 2)
                        if len(parts) == 3:
                            try:
                                yield json.dumps({'progress': int(parts[1]), 'label': parts[2]}) + '\n'
                            except ValueError:
                                pass
                        continue
                    yield json.dumps({'line': clean}) + '\n'
                else:
                    # No output for 10s — send heartbeat to keep connection alive
                    if proc.poll() is not None:
                        break
                    yield json.dumps({'heartbeat': True}) + '\n'
            proc.stdout.close()
            proc.wait()
            rc = proc.returncode

            if rc != 0:
                yield json.dumps({'line': f'[!] Command exited with code {rc}'}) + '\n'
                yield json.dumps({'done': True, 'success': False}) + '\n'
                return

            # GitHub post-install: requirements.txt + custom script
            if install_type == 'github':
                repo_name = url.rstrip('/').split('/')[-1].lower()
                source_dir = os.path.join(target_dir, repo_name, 'source')

                if run_requirements:
                    req_file = os.path.join(source_dir, 'requirements.txt')
                    if os.path.exists(req_file):
                        yield json.dumps({'line': f'[+] Installing requirements.txt...'}) + '\n'
                        pip_proc = subprocess.Popen(
                            ['pip', 'install', '-r', req_file, '--break-system-packages'],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, bufsize=1
                        )
                        for line in iter(pip_proc.stdout.readline, ''):
                            clean = ANSI_ESCAPE.sub('', line).rstrip()
                            if clean:
                                yield json.dumps({'line': clean}) + '\n'
                        pip_proc.stdout.close()
                        pip_proc.wait()
                    else:
                        yield json.dumps({'line': f'[-] No requirements.txt in {source_dir}'}) + '\n'

                if run_script:
                    script_path = os.path.join(source_dir, run_script)
                    if os.path.exists(script_path):
                        yield json.dumps({'line': f'[+] Running {run_script}...'}) + '\n'
                        s_proc = subprocess.Popen(
                            ['bash', script_path],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, bufsize=1, cwd=source_dir
                        )
                        for line in iter(s_proc.stdout.readline, ''):
                            clean = ANSI_ESCAPE.sub('', line).rstrip()
                            if clean:
                                yield json.dumps({'line': clean}) + '\n'
                        s_proc.stdout.close()
                        s_proc.wait()
                    else:
                        yield json.dumps({'line': f'[!] Script not found: {script_path}'}) + '\n'

            # Feed the offline mirrors so this newly-added tool is installable
            # offline on the next clone (no full mirror rebuild needed).
            if install_type in ('pip', 'apt'):
                ma_pkg = data.get('package', '').strip()
                if ma_pkg and _SAFE_PKG.match(ma_pkg) and os.path.exists('/usr/local/bin/portalgun'):
                    yield json.dumps({'line': f'[+] Feeding offline mirror ({install_type})...'}) + '\n'
                    try:
                        mp = subprocess.run(
                            ['sudo', '-n', 'portalgun', 'mirror-add', install_type, ma_pkg],
                            capture_output=True, text=True, timeout=300
                        )
                        for ln in (mp.stdout or '').splitlines():
                            if ln.strip():
                                yield json.dumps({'line': ln.rstrip()}) + '\n'
                    except Exception as me:
                        yield json.dumps({'line': f'[!] mirror-add skipped: {me}'}) + '\n'

            yield json.dumps({'done': True, 'success': True}) + '\n'

        except Exception as e:
            yield json.dumps({'line': f'[!] Internal error: {str(e)}'}) + '\n'
            yield json.dumps({'done': True, 'success': False}) + '\n'

    return Response(
        stream_with_context(generate()),
        mimetype='application/x-ndjson',
        headers={'Cache-Control': 'no-cache', 'X-Accel-Buffering': 'no'}
    )


@app.route('/api/admin/job/<job_id>/stop', methods=['POST'])
def job_stop(job_id):
    with JOBS_LOCK:
        job = JOBS.get(job_id)
        if not job:
            return jsonify({'error': 'job not found'}), 404
        proc = job.get('proc')
        if proc and proc.poll() is None:
            proc.terminate()
            time.sleep(1)
            if proc.poll() is None:
                proc.kill()
        job['done'] = True
        job['rc'] = -1
    return jsonify({'stopped': True})


@app.route('/api/admin/job/<job_id>/stream')
def job_stream(job_id):
    with JOBS_LOCK:
        job = JOBS.get(job_id)
    if not job:
        return jsonify({'error': 'job not found'}), 404

    try:
        offset = max(0, int(request.args.get('offset', 0)))
    except (TypeError, ValueError):
        offset = 0

    def generate():
        pos = offset
        log_path = job['log']
        # Wall-clock guard: never let a single stream pin a worker forever if
        # the job's monitor thread dies and 'done' never flips.
        deadline = time.time() + 7200
        missing_tries = 0
        while True:
            if time.time() > deadline:
                yield json.dumps({'line': '[!] Stream timed out (still running? reconnect)', 'pos': pos}) + '\n'
                break
            try:
                with open(log_path, 'r', errors='replace') as f:
                    f.seek(pos)
                    chunk = f.read(8192)
                    if chunk:
                        for line in chunk.splitlines():
                            clean = ANSI_ESCAPE.sub('', line).rstrip()
                            if not clean:
                                continue
                            if clean == 'REFRESH_MANIFEST':
                                yield json.dumps({'refresh': True}) + '\n'
                                continue
                            if clean.startswith('PROGRESS:'):
                                parts = clean.split(':', 2)
                                if len(parts) == 3:
                                    try:
                                        yield json.dumps({'progress': int(parts[1]), 'label': parts[2], 'pos': pos}) + '\n'
                                    except ValueError:
                                        pass
                                continue
                            yield json.dumps({'line': clean, 'pos': pos}) + '\n'
                        pos = f.tell()
                    elif job['done']:
                        rc = job.get('rc', 0)
                        if rc and rc != 0:
                            yield json.dumps({'line': f'[!] Command exited with code {rc}'}) + '\n'
                            yield json.dumps({'done': True, 'success': False}) + '\n'
                        else:
                            yield json.dumps({'done': True, 'success': True}) + '\n'
                        break
                    else:
                        yield json.dumps({'heartbeat': True}) + '\n'
                        time.sleep(1)
            except FileNotFoundError:
                missing_tries += 1
                if missing_tries > 120:  # ~60s of the log never appearing
                    yield json.dumps({'line': '[!] Log file never appeared', 'done': True, 'success': False}) + '\n'
                    break
                time.sleep(0.5)

    return Response(
        stream_with_context(generate()),
        mimetype='application/x-ndjson',
        headers={'Cache-Control': 'no-cache', 'X-Accel-Buffering': 'no'}
    )


if __name__ == '__main__':
    # Ensure directories exist
    os.makedirs(ZELLIJ_DIR, exist_ok=True)
    os.makedirs(CUSTOM_HOTKEYS_DIR, exist_ok=True)
    os.makedirs(TMUX_DIR, exist_ok=True)
    os.makedirs(CUSTOM_TMUX_DIR, exist_ok=True)
    os.makedirs(IMPORTED_TMUX_DIR, exist_ok=True)

    print(f"Serving tools documentation from {DOCS_DIR}")
    print(f"Dotfiles directory: {DOTFILES_DIR}")
    print(f"Zellij configs: {ZELLIJ_DIR}")
    print(f"Tmux configs: {TMUX_DIR}")
    app.run(host='0.0.0.0', port=1337, debug=False)
