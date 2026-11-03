#!/usr/bin/env python3
"""Use an isolated MySQL server executable; never contact an existing database."""
import argparse
import os
import sys
from pathlib import Path
import socket
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--all', action='store_true', help='Also start the PostgreSQL/SSH fixture and run the complete suite')
args = parser.parse_args()
executable = Path(os.environ['SDBUI_MYSQLD']).resolve()
with tempfile.TemporaryDirectory(prefix='sdbui-mysql-test-') as directory:
    root = Path(directory)
    with socket.socket() as sock:
        sock.bind(('127.0.0.1',0)); port = sock.getsockname()[1]
    env = dict(os.environ)
    subprocess.run([str(executable),'--no-defaults','--initialize-insecure','--basedir='+str(executable.parent.parent),'--datadir='+str(root/'data'),'--log-error='+str(root/'init.log')],env=env,check=True)
    bootstrap = root / 'bootstrap.sql'
    bootstrap.write_text("CREATE DATABASE sdbui_test;\nCREATE USER 'sdbui_test'@'127.0.0.1' IDENTIFIED BY '';\nGRANT ALL ON sdbui_test.* TO 'sdbui_test'@'127.0.0.1';\n")
    bootstrap.chmod(0o600)
    process = subprocess.Popen([str(executable),'--no-defaults','--basedir='+str(executable.parent.parent),'--datadir='+str(root/'data'),
        '--socket='+str(root/'mysql.sock'),'--pid-file='+str(root/'mysql.pid'),'--log-error='+str(root/'mysql.log'),
        '--init-file='+str(bootstrap),'--secure-file-priv='+str(root),'--bind-address=127.0.0.1','--port='+str(port),'--mysqlx=OFF','--skip-log-bin','--skip-name-resolve'],env=env)
    try:
        deadline = time.monotonic()+30
        while time.monotonic()<deadline:
            if process.poll() is not None: raise RuntimeError((root/'mysql.log').read_text())
            try:
                with socket.create_connection(('127.0.0.1',port),timeout=.3): break
            except OSError: time.sleep(.2)
        else: raise RuntimeError('MySQL did not start')
        env['SDBUI_TEST_MYSQL_URI']=f'mysql://sdbui_test@127.0.0.1:{port}/sdbui_test?tls=false'
        # Only this temporary database is granted to the test account.
        if args.all:
            env['SDBUI_REQUIRE_NETWORK_DRIVERS']='1'
            env['SDBUI_TEST_EMBEDDED']='1'
            command=[sys.executable,'scripts/test-ssh-integration.py']
        else:
            command=['swift','test','--filter','NetworkDriverTests.testMySQLDriver']
        subprocess.run(command,env=env,check=True)
    finally:
        process.terminate()
        try: process.wait(timeout=15)
        except subprocess.TimeoutExpired: process.kill();process.wait()
