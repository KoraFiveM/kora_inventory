#!/usr/bin/env python3
"""Run actual exchange SQL/qbsql transactions in an isolated socket-only MariaDB."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time


def main():
    for command in ('mariadb-install-db', 'mariadbd', 'mysql', 'lua', 'node'):
        if not shutil.which(command):
            raise SystemExit(f'Missing {command}; this optional test requires MariaDB, Lua and Node.')
    resource = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix='qbinventory-exchange-') as directory:
        root = Path(directory)
        subprocess.run(['mariadb-install-db', '--no-defaults', f'--datadir={root}',
                        '--auth-root-authentication-method=normal', '--skip-test-db'],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        options = ['mariadbd', '--no-defaults', f'--datadir={root}', f'--socket={root}/mysql.sock',
                   f'--pid-file={root}/mysql.pid', f'--log-error={root}/server.log', '--skip-networking']
        if os.geteuid() == 0:
            options.append('--user=root')
        server = subprocess.Popen(options, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        mysql = ['mysql', '--no-defaults', f'--socket={root}/mysql.sock', '-uroot', '--batch', '--skip-column-names']
        try:
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                if server.poll() is not None:
                    raise RuntimeError((root / 'server.log').read_text())
                if subprocess.run(mysql, input='SELECT 1', text=True, capture_output=True).returncode == 0:
                    break
                time.sleep(0.05)
            else:
                raise RuntimeError('Disposable MariaDB did not become ready.')
            version = subprocess.run(mysql, input='SELECT VERSION()', text=True, capture_output=True, check=True).stdout.strip()
            subprocess.run(mysql, input='CREATE DATABASE exchange_test CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;', text=True, check=True)
            env = dict(os.environ, QBINVENTORY_TEST_SOCKET=str(root / 'mysql.sock'))
            subprocess.run(['node', '--test', 'test/integration/player_exchange.test.js'], cwd=resource,
                           env=env, check=True, timeout=120)
            print(f'Exchange database: PASS ({version}); socket-only scratch database; no existing server accessed.')
        finally:
            server.terminate()
            try:
                server.wait(timeout=10)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait()


if __name__ == '__main__':
    main()
