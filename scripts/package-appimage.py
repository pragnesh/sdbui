#!/usr/bin/env python3
"""Build an AppImage from package-linux.sh's portable stage, using verified tools."""
import argparse
import hashlib
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile
import urllib.request

TOOLS = {
    'linuxdeploy': ('linuxdeploy/linuxdeploy', '1-alpha-20251107-1', {
        'x86_64': 'c20cd71e3a4e3b80c3483cef793cda3f4e990aca14014d23c544ca3ce1270b4d',
        'aarch64': '620095110d693282b8ebeb244a95b5e911cf8f65f76c88b4b47d16ae6346fcff'}),
    'appimagetool': ('AppImage/appimagetool', '1.9.1', {
        'x86_64': 'ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0',
        'aarch64': 'f0837e7448a0c1e4e650a93bb3e85802546e60654ef287576f46c71c126a9158'})}
RUNTIME_HASHES = {
    'x86_64': '617aa77314d57c8b8e4fae9c3f0b35af7b30d5529cb69e98f64f92510ed98a46',
    'aarch64': '9a72a744d221576c9347ec074243acc5c3c7568896b12714e0e82e9f0bf47900'}

ROOT = Path(__file__).resolve().parents[1]


def tool(name, arch):
    repo, version, hashes = TOOLS[name]
    cache = ROOT / '.build/appimage-tools' / version
    cache.mkdir(parents=True, exist_ok=True)
    binary = cache / f'{name}-{arch}.AppImage'
    def valid():
        if not binary.is_file(): return False
        with binary.open('rb') as source:
            return hashlib.file_digest(source, 'sha256').hexdigest() == hashes[arch]
    if not valid():
        url = f'https://github.com/{repo}/releases/download/{version}/{binary.name}'
        with tempfile.NamedTemporaryFile(dir=cache, delete=False) as pending:
            temporary = Path(pending.name)
            try:
                with urllib.request.urlopen(url, timeout=60) as source:
                    shutil.copyfileobj(source, pending)
                pending.flush()
                if hashlib.sha256(temporary.read_bytes()).hexdigest() != hashes[arch]:
                    raise RuntimeError(f'{name} checksum mismatch; refusing to execute it.')
                os.replace(temporary, binary)
            finally:
                temporary.unlink(missing_ok=True)
    binary.chmod(0o755)
    # Extract tools once: packaging never requires FUSE or root.
    extracted = cache / name
    if not (extracted / 'AppRun').is_file():
        with tempfile.TemporaryDirectory(dir=cache) as directory:
            subprocess.run([str(binary), '--appimage-extract'], cwd=directory, check=True, stdout=subprocess.DEVNULL)
            shutil.move(str(Path(directory) / 'squashfs-root'), extracted)
    return extracted / 'AppRun'


def runtime_file(arch):
    cache = ROOT / '.build/appimage-tools/runtime'
    cache.mkdir(parents=True, exist_ok=True)
    binary = cache / ('runtime-' + arch)
    if binary.exists() and hashlib.sha256(binary.read_bytes()).hexdigest() == RUNTIME_HASHES[arch]:
        return binary
    url = 'https://github.com/AppImage/type2-runtime/releases/download/continuous/runtime-' + arch
    with urllib.request.urlopen(url, timeout=60) as response:
        data = response.read()
    if hashlib.sha256(data).hexdigest() != RUNTIME_HASHES[arch]:
        raise RuntimeError('AppImage runtime checksum mismatch. Update the reviewed runtime pin before rebuilding.')
    with tempfile.NamedTemporaryFile(dir=cache, delete=False) as pending:
        pending.write(data)
        temporary = Path(pending.name)
    os.replace(temporary, binary)
    return binary

def pkg(variable, package):
    return subprocess.check_output(['pkg-config', '--variable=' + variable, package], text=True).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--stage', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    arch = {'arm64': 'aarch64'}.get(platform.machine(), platform.machine())
    if platform.system() != 'Linux' or arch not in ('x86_64', 'aarch64'):
        parser.error('Build natively on Linux x86_64 or ARM64.')
    stage, output = args.stage.resolve(), args.output.resolve()
    if not (stage / 'bin/sdbui').is_file():
        parser.error('Stage the portable Linux release first.')
    deploy, image_tool = tool('linuxdeploy', arch), tool('appimagetool', arch)
    app_id = 'dev.sdbui.QueryBrowser'
    with tempfile.TemporaryDirectory(prefix='sdbui-appimage-', dir=ROOT / '.build') as directory:
        appdir = Path(directory) / 'sdbui.AppDir'
        shutil.copytree(stage / 'bin', appdir / 'usr/bin')
        shutil.copytree(stage / 'share', appdir / 'usr/share')
        modules = []
        # GIO and GdkPixbuf load these with dlopen; DT_NEEDED alone misses them.
        for source, destination in [(pkg('giomoduledir', 'gio-2.0'), 'usr/lib/gio/modules'),
                                    (pkg('gdk_pixbuf_moduledir', 'gdk-pixbuf-2.0'), 'usr/lib/gdk-pixbuf/loaders')]:
            if source and Path(source).is_dir():
                shutil.copytree(source, appdir / destination)
                modules += list((appdir / destination).glob('*.so'))
        loader_query = pkg('gdk_pixbuf_query_loaders', 'gdk-pixbuf-2.0')
        if loader_query and Path(loader_query).is_file():
            shutil.copy2(loader_query, appdir / 'usr/bin/gdk-pixbuf-query-loaders')
        for source, destination in [('/usr/share/glib-2.0/schemas', 'usr/share/glib-2.0/schemas'),
                                    ('/usr/share/icons/Adwaita', 'usr/share/icons/Adwaita')]:
            if Path(source).is_dir():
                shutil.copytree(source, appdir / destination, dirs_exist_ok=True, symlinks=True)
        # Data-only GTK packages are not discovered by ELF dependency scanning.
        for package in ['adwaita-icon-theme', 'gsettings-desktop-schemas', 'libglib2.0-data']:
            copyright_file = Path('/usr/share/doc') / package / 'copyright'
            if copyright_file.is_file():
                destination = appdir / 'usr/share/doc' / package
                destination.mkdir(parents=True, exist_ok=True)
                shutil.copy2(copyright_file, destination / 'copyright')
        command = [str(deploy), '--appdir', str(appdir), '--executable', str(appdir / 'usr/bin/sdbui'),
                   '--desktop-file', str(appdir / f'usr/share/applications/{app_id}.desktop'),
                   '--icon-file', str(appdir / f'usr/share/icons/hicolor/scalable/apps/{app_id}.svg')]
        if (appdir / 'usr/bin/gdk-pixbuf-query-loaders').exists():
            command += ['--executable', str(appdir / 'usr/bin/gdk-pixbuf-query-loaders')]
        for module in modules:
            command += ['--library', str(module)]
        subprocess.run(command, check=True)
        # linuxdeploy provides a default launcher; use one that also relocates GTK's data.
        launcher = appdir / 'AppRun'
        if launcher.exists() or launcher.is_symlink(): launcher.unlink()
        shutil.copy2(ROOT / 'packaging/linux/AppRun', launcher); launcher.chmod(0o755)
        env = {**os.environ, 'ARCH': arch, 'VERSION': (stage / 'VERSION').read_text().strip(), 'SOURCE_DATE_EPOCH': os.environ.get('SOURCE_DATE_EPOCH', '0')}
        # Use the runtime shipped with the pinned tool; do not fetch a mutable runtime.
        runtime = runtime_file(arch)
        command = [str(image_tool), '--no-appstream', '--runtime-file', str(runtime)]
        command += [str(appdir), str(output)]
        subprocess.run(command, check=True, env=env)
        output.chmod(0o755)
    print(f'AppImage ready: {output.name}')

if __name__ == '__main__':
    main()
