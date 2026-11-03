#!/usr/bin/env python3
"""Install the isolated transfer runtime (no system pip or package changes)."""
import argparse
import ctypes.util
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import subprocess
import sys
import sysconfig
import tempfile
import urllib.request
import urllib.error
import venv
import zipfile

VERSION = '21.0.0'
def main():
    parser = argparse.ArgumentParser(description=__doc__)
    base = Path(os.environ.get('XDG_DATA_HOME', str(Path.home() / '.local/share')))
    parser.add_argument('--directory', type=Path, default=base / 'sdbui/transfer-python')
    args = parser.parse_args()
    target = args.directory.resolve()
    if target.exists() and any(target.iterdir()) and not (target / 'pyvenv.cfg').exists():
        parser.error('Choose an empty directory or an existing dedicated virtual environment.')
    python = target / 'bin/python3'
    if (target / 'pyvenv.cfg').is_file() and python.is_file():
        check = subprocess.run([str(python), '-I', '-c', 'import pyarrow; print(pyarrow.__version__)'], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        if check.returncode == 0 and check.stdout.strip() == VERSION:
            print(f'Transfer runtime already ready: {python}')
            raise SystemExit(0)
    library = Path(sysconfig.get_config_var('LIBDIR') or '') / (sysconfig.get_config_var('LDLIBRARY') or '')
    if not library.is_file() and not ctypes.util.find_library('python' + sysconfig.get_python_version()):
        parser.error('Python shared library missing. Install the matching OS libpython package, then retry.')
    abi = f'cp{sys.version_info.major}{sys.version_info.minor}'
    machine = platform.machine().lower()
    with urllib.request.urlopen(f'https://pypi.org/pypi/pyarrow/{VERSION}/json', timeout=30) as response:
        metadata = json.load(response)

    def compatible(name):
        if f'-{abi}-{abi}-' not in name:
            return False
        if sys.platform == 'linux':
            return f'manylinux_2_28_{machine}.whl' in name
        if sys.platform == 'darwin':
            return 'macosx' in name and (machine in name or 'universal2' in name)
        return False

    wheels = [item for item in metadata['urls'] if compatible(item['filename'])]
    if not wheels:
        parser.error(f'No PyArrow {VERSION} wheel for this Python/platform. Use Python 3.9–3.13 on Linux or macOS.')
    wheel = wheels[0]
    venv.EnvBuilder(with_pip=False).create(target)
    python = target / 'bin/python3'
    site = Path(subprocess.check_output([str(python), '-I', '-c', "import sysconfig;print(sysconfig.get_path('purelib'))"], text=True).strip())
    site.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='transfer-install-') as temporary:
        archive = Path(temporary) / wheel['filename']
        digest = hashlib.sha256()
        with urllib.request.urlopen(wheel['url'], timeout=60) as response, archive.open('wb') as output:
            while chunk := response.read(1024 * 1024):
                digest.update(chunk)
                output.write(chunk)
        if digest.hexdigest() != wheel['digests']['sha256']:
            raise SystemExit('Wheel checksum mismatch; installation aborted.')
        with zipfile.ZipFile(archive) as package:
            for entry in package.infolist():
                path = PurePosixPath(entry.filename)
                if path.is_absolute() or '..' in path.parts or (entry.external_attr >> 16) & 0o170000 == 0o120000:
                    raise SystemExit('Unsafe path in wheel; installation aborted.')
            package.extractall(site)
    subprocess.run([str(python), '-I', '-c', 'import pyarrow; print("PyArrow", pyarrow.__version__)'], check=True)
    print(f'Transfer runtime ready: {python}')

if __name__ == '__main__':
    try:
        main()
    except (OSError, urllib.error.URLError, subprocess.CalledProcessError, zipfile.BadZipFile) as error:
        raise SystemExit(f'Transfer runtime setup failed: {error}') from None
