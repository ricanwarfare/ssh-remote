"""Opt-in loopback OpenSSH tests with disposable keys, server, and remote home."""
import os
from pathlib import Path
import pwd
import shutil
import socket
import subprocess
import tempfile
import time
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'ssh-remote.sh'


@unittest.skipUnless(os.environ.get('SSH_REMOTE_REAL_TESTS') == '1',
                     'set SSH_REMOTE_REAL_TESTS=1 to start an isolated loopback sshd')
class RealSSHTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='ssh-remote-integration-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.remote = self.root / 'remote'
        self.remote.mkdir()
        self.server = None
        self.server_log = (self.root / 'sshd.log').open('w+')
        self.addCleanup(self.server_log.close)
        self.addCleanup(self.stop_server)
        self.sshd = shutil.which('sshd') or '/usr/sbin/sshd'
        self.assertTrue(Path(self.sshd).is_file(), 'openssh-server must be installed')
        for name in ('host', 'client'):
            subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(self.root / name)], check=True)
        self.username = pwd.getpwuid(os.getuid()).pw_name
        # ForceCommand confines remote cwd/HOME to the fixture, including audit logs.
        self.force = self.root / 'remote-shell'
        self.force.write_text('#!/bin/sh\nexport HOME=' + str(self.remote) + '\ncd "$HOME" || exit\nexec /bin/sh -c "$SSH_ORIGINAL_COMMAND"\n')
        self.force.chmod(0o700)
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            self.port = sock.getsockname()[1]
        self.config = self.root / 'sshd_config'
        self.client_config = self.root / 'ssh_config'
        self.client_config.write_text(f'''Host 127.0.0.1
    Port {self.port}
    IdentityFile {self.root / 'client'}
    IdentitiesOnly yes
    StrictHostKeyChecking yes
    UserKnownHostsFile {self.root / 'known_hosts'}
    GlobalKnownHostsFile /dev/null
''')
        # Pin the disposable server's key; never disable host verification.
        (self.root / 'known_hosts').write_text(f'[127.0.0.1]:{self.port} ' + (self.root / 'host.pub').read_text())
        (self.root / 'hosts.conf').write_text(f'local 127.0.0.1 {self.username}\n')
        self.env = dict(os.environ, SSH_HOSTS_CONF=str(self.root / 'hosts.conf'),
                        SSH_AUDIT_LOG_DIR=str(self.root / 'audit'), SSH_REMOTE_SSH_CONFIG=str(self.client_config))
        self.start_server(sftp=True)

    def stop_server(self):
        if self.server is not None:
            self.server.terminate()
            try:
                self.server.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.server.kill()
                self.server.wait(timeout=5)
            self.server = None

    def start_server(self, sftp):
        self.stop_server()
        sftp_server = next((p for p in ('/usr/lib/openssh/sftp-server', '/usr/libexec/openssh/sftp-server') if Path(p).exists()), None)
        self.assertTrue(sftp_server, 'OpenSSH SFTP server must be installed')
        self.config.write_text(f'''ListenAddress 127.0.0.1
Port {self.port}
HostKey {self.root / 'host'}
PidFile {self.root / 'sshd.pid'}
AuthorizedKeysFile {self.root / 'client.pub'}
StrictModes no
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
PermitRootLogin prohibit-password
AllowUsers {self.username}
ForceCommand {self.force}
''' + (f'Subsystem sftp {sftp_server}\n' if sftp else ''))
        self.server = subprocess.Popen([self.sshd, '-D', '-e', '-f', str(self.config)], stdout=self.server_log, stderr=self.server_log)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if self.server.poll() is not None:
                self.server_log.flush()
                self.fail('sshd failed: ' + (self.root / 'sshd.log').read_text())
            try:
                with socket.create_connection(('127.0.0.1', self.port), timeout=0.2):
                    return
            except OSError:
                time.sleep(0.05)
        self.fail('sshd did not become ready')

    def run_script(self, *args, stdin=''):
        return subprocess.run(['bash', str(SCRIPT), *args], input=stdin, text=True, cwd=self.root,
                              env=self.env, capture_output=True, timeout=20)

    def test_command_stdin_status_and_diagnostics(self):
        result = self.run_script('local', 'bash -s', stdin='echo actual-ssh\nexit 17\n')
        self.assertEqual(result.returncode, 17, result.stderr)
        self.assertEqual(result.stdout, 'actual-ssh\n')
        logs = ''.join(p.read_text() for p in (self.remote / '.ssh-audit').glob('*.log'))
        self.assertIn('FAILED (exit 17)', logs)
        result = self.run_script('doctor', 'local')
        self.assertEqual(result.returncode, 0, result.stderr)

    def transfer_roundtrip(self, fallback):
        payload = bytes(range(256)) * 4096
        (self.root / 'source file').write_bytes(payload)
        destination = self.remote / "file ' literal"
        result = self.run_script('scp', 'source file', f'local:{destination}')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual('trying base64' in result.stderr, fallback)
        self.assertEqual(destination.read_bytes(), payload)
        result = self.run_script('scp', f'local:{destination}', 'download')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / 'download').read_bytes(), payload)

    def test_sftp_transfers(self):
        self.transfer_roundtrip(fallback=False)

    def test_missing_sftp_base64_fallback(self):
        self.start_server(sftp=False)
        self.transfer_roundtrip(fallback=True)
