#!/usr/bin/env python3
"""Launch a package in a private configuration and fail on crashes or missing resources."""
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

package = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix='sdbui-package-smoke-') as directory:
    root = Path(directory)
    env = {key: value for key, value in os.environ.items() if key not in ('SDBUI_PROFILE', 'SDBUI_SQL', 'ADBC_PROFILE_PATH')}
    (root / 'home').mkdir()
    env.update(HOME=str(root / 'home'), CFFIXED_USER_HOME=str(root / 'home'), XDG_CONFIG_HOME=str(root / 'config'), XDG_DATA_HOME=str(root / 'data'),
               SDBUI_APP_ID='dev.sdbui.PackageSmoke', GSK_RENDERER='cairo', G_DEBUG='fatal-criticals')
    if package.suffix == '.AppImage':
        subprocess.run([str(package), '--appimage-extract'], cwd=root, stdout=subprocess.DEVNULL, check=True)
        appdir = root / 'squashfs-root'
        assert list((appdir / 'usr/bin').glob('sdbui_ADBCKit.*/transfer.py')), 'Transfer resources missing'
        assert (appdir / 'usr/lib/libgtk-4.so.1').exists(), 'GTK not bundled'
        assert (appdir / 'usr/lib/libsqlite3.so.0').exists(), 'SQLite not bundled'
        env.update(APPDIR=str(appdir), GDK_BACKEND='x11', GTK_USE_PORTAL='0')
        command = ['xvfb-run', '-a', str(appdir / 'AppRun')]
    elif package.suffix == '.app':
        # A macOS .bundle keeps resources under Contents/Resources; Linux bundles are flat.
        assert list((package / 'Contents/Resources').glob('sdbui_ADBCKit.*/**/transfer.py')), 'Transfer resources missing'
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(package)], check=True)
        command = [str(package / 'Contents/MacOS/sdbui')]
    else:
        raise SystemExit('Pass an AppImage or macOS .app directory.')
    with (root / 'app.log').open('w+') as log:
        process = subprocess.Popen(command, cwd=root, env=env, stdout=log, stderr=log, start_new_session=True)
        try:
            time.sleep(6)
            if process.poll() is not None:
                log.seek(0); raise RuntimeError('Packaged app exited early:\n' + log.read())
        finally:
            try: os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError: pass
            try: process.wait(timeout=10)
            except subprocess.TimeoutExpired: os.killpg(process.pid, signal.SIGKILL); process.wait()
        log.seek(0); output = log.read()
        for failure in ['Gtk-CRITICAL', 'GLib-CRITICAL', 'Fatal error:', 'unable to find bundle', 'error while loading shared libraries']:
            if failure in output: raise RuntimeError(output)
    print('Packaged application started successfully with a private configuration.')
