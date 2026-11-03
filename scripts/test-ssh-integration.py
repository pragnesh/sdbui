#!/usr/bin/env python3
"""Isolated OpenSSH -> temporary SSH server -> PostgreSQL integration tests.
Requires Python paramiko, OpenSSH, and PostgreSQL server tools. No user SSH files
or existing databases are modified. Run from the repository root.
"""
import glob
import os
from pathlib import Path
import select
import shlex
import socket
import subprocess
import tempfile
import threading

import paramiko


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def pump(channel, destination):
    try:
        with socket.create_connection(destination, timeout=5) as remote:
            while True:
                ready, _, _ = select.select([channel, remote], [], [], 1)
                for source in ready:
                    data = source.recv(65536)
                    if not data:
                        return
                    (remote if source is channel else channel).sendall(data)
    except (OSError, EOFError):
        pass
    finally:
        channel.close()


class Server(paramiko.ServerInterface):
    def __init__(self, key):
        self.key = key
        self.destinations = {}

    def check_auth_publickey(self, username, key):
        return paramiko.AUTH_SUCCESSFUL if username == "test" and key == self.key else paramiko.AUTH_FAILED

    def get_allowed_auths(self, username):
        return "publickey"

    def check_channel_direct_tcpip_request(self, chanid, origin, destination):
        self.destinations[chanid] = destination
        return paramiko.OPEN_SUCCEEDED


def serve_connection(client, host_key, client_key, stop):
    transport = paramiko.Transport(client)
    try:
        transport.add_server_key(host_key)
        server = Server(client_key)
        transport.start_server(server=server)
        while not stop.is_set() and transport.is_active():
            channel = transport.accept(timeout=0.2)
            if channel:
                threading.Thread(target=pump, args=(channel, server.destinations[channel.chanid]), daemon=True).start()
    except (EOFError, OSError, paramiko.SSHException):
        pass
    finally:
        transport.close()


def main():
    pg_candidates = sorted(glob.glob("/usr/lib/postgresql/*/bin/pg_ctl"))
    if not pg_candidates:
        raise SystemExit("PostgreSQL server tools not found")
    pg = Path(pg_candidates[-1]).parent
    with tempfile.TemporaryDirectory(prefix="sdbui-ssh-test-") as directory:
        root = Path(directory)
        host_key, client_key = paramiko.RSAKey.generate(2048), paramiko.RSAKey.generate(2048)
        key_file = root / "key"
        client_key.write_private_key_file(str(key_file))
        key_file.chmod(0o600)
        listener = socket.socket()
        listener.bind(("127.0.0.1", 0))
        listener.listen()
        listener.settimeout(0.2)
        ssh_port, pg_port = listener.getsockname()[1], free_port()
        (root / "known_hosts").write_text(f"[127.0.0.1]:{ssh_port} {host_key.get_name()} {host_key.get_base64()}\n")
        (root / "ssh_config").write_text(
            f'Host *\n  IdentityFile "{key_file}"\n  IdentitiesOnly yes\n'
            f'  UserKnownHostsFile "{root / "known_hosts"}"\n  GlobalKnownHostsFile /dev/null\n  LogLevel ERROR\n'
        )
        wrapper = root / "ssh"
        wrapper.write_text(f'#!/bin/sh\nexec /usr/bin/ssh -F {shlex.quote(str(root / "ssh_config"))} "$@"\n')
        wrapper.chmod(0o700)
        stop = threading.Event()

        def accept():
            while not stop.is_set():
                try:
                    client, _ = listener.accept()
                except socket.timeout:
                    continue
                except OSError:
                    break
                threading.Thread(target=serve_connection, args=(client, host_key, client_key, stop), daemon=True).start()

        thread = threading.Thread(target=accept, daemon=True)
        thread.start()
        subprocess.run([str(pg / "initdb"), "-D", str(root / "data"), "-A", "trust", "-U", "sdbui_test", "--no-locale"], check=True, stdout=subprocess.DEVNULL)
        subprocess.run([str(pg / "pg_ctl"), "-D", str(root / "data"), "-l", str(root / "pg.log"), "-o", f"-h 127.0.0.1 -p {pg_port} -k {directory}", "-w", "start"], check=True, stdout=subprocess.DEVNULL)
        try:
            # Match CI: a dedicated application database, not the default postgres catalog.
            subprocess.run([str(pg / "createdb"), "-h", "127.0.0.1", "-p", str(pg_port), "-U", "sdbui_test", "sdbui_test"], check=True)
            env = {**os.environ, "SDBUI_TEST_SSH_EXECUTABLE": str(wrapper), "SDBUI_TEST_SSH_PORT": str(ssh_port),
                   "SDBUI_TEST_POSTGRES_URI": f"postgresql://sdbui_test@127.0.0.1:{pg_port}/sdbui_test?sslmode=disable"}
            subprocess.run(["swift", "test"], env=env, check=True)
        finally:
            subprocess.run([str(pg / "pg_ctl"), "-D", str(root / "data"), "-m", "immediate", "-w", "stop"], check=True, stdout=subprocess.DEVNULL)
            stop.set()
            listener.close()
            thread.join(timeout=2)


if __name__ == "__main__":
    main()
