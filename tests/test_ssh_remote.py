"""Offline integration tests: fake SSH executes the actual quoted remote command."""
import os
import json
import stat
import signal
import time
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'ssh-remote.sh'


class SSHRemoteTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.remote = self.root / 'remote'
        self.remote.mkdir()
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.conf = self.root / 'hosts.conf'
        self.conf.write_text('web 127.0.0.1 admin\ndb ::1 admin\n')
        self.env = dict(os.environ, PATH=f'{self.bin}:{os.environ["PATH"]}',
                        SSH_HOSTS_CONF=str(self.conf), SSH_AUDIT_USER='tester',
                        SSH_AUDIT_LOG_DIR=str(self.root / 'logs'),
                        TEST_REMOTE=str(self.remote), TEST_CALLS=str(self.root / 'calls'))
        self.executable('ssh', '''#!/usr/bin/env bash
printf 'ssh\\n' >> "$TEST_CALLS"
[[ "$1" == -o && "$2" == BatchMode=yes ]] || exit 90
printf '%s\\n' "$@" > "$TEST_REMOTE/ssh-args"
while [[ "${1:-}" == -o || "${1:-}" == -F ]]; do shift 2; done
shift # destination
export HOME="$TEST_REMOTE"
cd "$HOME" || exit
if [[ "${TEST_TRUNCATE_UPLOAD:-}" == 1 && "$*" == *'Incomplete upload'* ]]; then
  head -c 4 | bash -c "$*"
  exit $?
fi
exec bash -c "$*"
''')
        self.executable('scp', '''#!/usr/bin/env bash
printf 'scp\\n' >> "$TEST_CALLS"
printf '%s\\n' "$@" > "$TEST_REMOTE/scp-args"
echo "${TEST_SCP_ERROR:-subsystem request failed on channel 0}" >&2
exit "${TEST_SCP_STATUS:-1}"
''')

    def executable(self, name, content):
        path = self.bin / name
        path.write_text(content)
        path.chmod(0o755)

    def run_script(self, *args, stdin='', **env):
        return subprocess.run(['bash', str(SCRIPT), *args], input=stdin, text=True,
                              cwd=self.root, env=dict(self.env, **env), capture_output=True)

    def logs(self, remote=False):
        folder = self.remote / '.ssh-audit' if remote else self.root / 'logs'
        return ''.join(p.read_text() for p in folder.rglob('*.log'))

    def test_command_stdin_and_exit_code(self):
        result = self.run_script('web', 'bash -s', stdin='echo from-stdin\nexit 17\n')
        self.assertEqual(result.returncode, 17, result.stderr)
        self.assertEqual(result.stdout, 'from-stdin\n')
        self.assertIn('FAILED (exit 17)', self.logs())

    def test_audit_user_is_literal_and_logs_are_single_line(self):
        user = "someone'; touch INJECTED; #\nforged\rentry"
        command = "printf '%s' \"quoted ' value\"\n# multiline\rcomment"
        result = self.run_script('web', command, SSH_AUDIT_USER=user)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "quoted ' value")
        self.assertFalse((self.remote / 'INJECTED').exists())
        for content in (self.logs(), self.logs(remote=True)):
            self.assertEqual(len(content.splitlines()), 2)
            self.assertIn('\\n', content)
            self.assertIn('\\r', content)

    def test_remote_audit_failure_prevents_execution(self):
        (self.remote / '.ssh-audit').write_text('not a directory')
        result = self.run_script('web', 'touch SHOULD_NOT_RUN')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.remote / 'SHOULD_NOT_RUN').exists())

    def test_local_audit_failure_prevents_connection(self):
        blocked = self.root / 'blocked'
        blocked.write_text('not a directory')
        result = self.run_script('web', 'true', SSH_AUDIT_LOG_DIR=str(blocked))
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / 'calls').exists())

    def test_binary_upload_and_download_with_quoted_paths(self):
        payload = bytes(range(256)) * 8192  # Larger than an OS command argument.
        source = self.root / '-source file'
        source.write_bytes(payload)
        remote_path = "file ' $(touch INJECTED)"
        result = self.run_script('scp', source.name, f'web:{remote_path}')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.remote / remote_path).read_bytes(), payload)
        result = self.run_script('scp', f'web:{remote_path}', 'download')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / 'download').read_bytes(), payload)
        self.assertFalse((self.remote / 'INJECTED').exists())

    def test_missing_download_preserves_existing_destination(self):
        destination = self.root / 'existing'
        destination.write_text('keep me')
        result = self.run_script('scp', 'web:missing', str(destination))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(destination.read_text(), 'keep me')
        self.assertFalse(list(self.root.glob('*.ssh-remote.*')))
        self.assertIn('FAILED', self.logs(remote=True))

    def test_missing_upload_does_not_create_remote_file(self):
        result = self.run_script('scp', 'missing', 'web:target')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.remote / 'target').exists())

    def test_truncated_upload_preserves_existing_destination(self):
        (self.root / 'source').write_text('more than three bytes')
        (self.remote / 'target').write_text('keep me')
        result = self.run_script('scp', 'source', 'web:target', TEST_TRUNCATE_UPLOAD='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Incomplete upload', result.stderr)
        self.assertEqual((self.remote / 'target').read_text(), 'keep me')
        self.assertFalse(list(self.remote.glob('*.ssh-remote.*')))

    def test_transfer_audit_failure_warns_without_changing_status(self):
        (self.remote / '.ssh-audit').write_text('not a directory')
        result = self.run_script('scp', 'source', 'web:target', TEST_SCP_STATUS='0')
        self.assertEqual(result.returncode, 0)
        self.assertIn('Warning: Could not write remote transfer audit', result.stderr)

    def test_directory_destinations(self):
        (self.root / 'file').write_text('contents')
        (self.remote / 'folder').mkdir()
        result = self.run_script('scp', 'file', 'web:folder')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.remote / 'folder/file').read_text(), 'contents')
        (self.root / 'folder').mkdir()
        result = self.run_script('scp', 'web:folder/file', 'folder')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / 'folder/file').read_text(), 'contents')

    def test_generic_scp_failure_is_reported_without_fallback(self):
        result = self.run_script('scp', 'source', 'web:target',
                                 TEST_SCP_ERROR='Connection closed', TEST_SCP_STATUS='23')
        self.assertEqual(result.returncode, 23)
        self.assertIn('Connection closed', result.stderr)
        self.assertNotIn('trying base64', result.stderr)

    def test_bad_endpoints_rejected_before_connection(self):
        for args in [('unknown:path', 'local'), ('web:path', 'db:path'),
                     ('local', 'another'), ('local', ':path'), ('local', 'web:')]:
            with self.subTest(args=args):
                result = self.run_script('scp', *args)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((self.root / 'calls').exists())

    def test_ipv6_scp_address_is_bracketed(self):
        result = self.run_script('scp', 'file', 'db:target', TEST_SCP_STATUS='0', TEST_SCP_ERROR='')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('admin@[::1]:target', (self.remote / 'scp-args').read_text())

    def test_invalid_config_rejected(self):
        for content in ['', '# comment\n', 'web host\n', '../escape host admin\n',
                        'web host admin extra\n', 'all host admin\n',
                        'web host admin\nweb other admin\n', 'web -host admin\n']:
            with self.subTest(content=content):
                self.conf.write_text(content)
                result = self.run_script('hosts')
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('Error:', result.stderr)

    def test_all_continues_after_failure(self):
        result = self.run_script('all', 'echo reached; exit 7')
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout.count('reached'), 2)

    def test_config_without_final_newline(self):
        self.conf.write_text('# comment\n\nweb host admin')
        result = self.run_script('hosts')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('web', result.stdout)

    def test_audit_permissions_and_existing_file_repair(self):
        for remote in (False, True):
            base = self.remote / '.ssh-audit' if remote else self.root / 'logs' / 'web-127.0.0.1'
            base.mkdir(parents=True)
            base.chmod(0o755)
            log = base / (time.strftime('%Y-%m-%d') + '.log')
            log.write_text('existing record\n')
            log.chmod(0o644)
        result = self.run_script('web', 'true')
        self.assertEqual(result.returncode, 0, result.stderr)
        for base in (self.root / 'logs', self.remote / '.ssh-audit'):
            for path in [base, *base.rglob('*')]:
                self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o700 if path.is_dir() else 0o600)

    def test_directory_collisions_are_failures(self):
        (self.root / 'file').write_text('upload')
        (self.remote / 'folder' / 'file').mkdir(parents=True)
        result = self.run_script('scp', 'file', 'web:folder')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(list((self.remote / 'folder' / 'file').iterdir()), [])
        (self.remote / 'file').write_text('download')
        (self.root / 'folder' / 'file').mkdir(parents=True)
        result = self.run_script('scp', 'web:file', 'folder')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(list((self.root / 'folder' / 'file').iterdir()), [])
        self.assertFalse(list(self.root.rglob('*.ssh-remote.*')))

    def test_json_roundtrip_and_command_results(self):
        user = 'operator "name"\\value\n\t雪'
        result = self.run_script('--audit-format', 'json', 'web', 'echo "hello"; exit 19', SSH_AUDIT_USER=user)
        self.assertEqual(result.returncode, 19, result.stderr)
        ids = set()
        for base in (self.root / 'logs', self.remote / '.ssh-audit'):
            records = [json.loads(line) for path in base.rglob('*.jsonl') for line in path.read_text().splitlines()]
            self.assertEqual([r['event'] for r in records], ['start', 'finish'])
            self.assertEqual(records[0]['operator'], user)
            self.assertIsNone(records[0]['exit_status'])
            self.assertIsNone(records[0]['finished_at'])
            self.assertEqual(records[1]['exit_status'], 19)
            self.assertGreaterEqual(records[1]['duration_seconds'], 0)
            ids.update(r['run_id'] for r in records)
        self.assertEqual(len(ids), 1)

    def test_groups_deduplicate_sort_and_validate(self):
        groups = self.root / 'groups.conf'
        groups.write_text('production web db web\n')
        result = self.run_script('@production', 'echo reached', SSH_HOST_GROUPS_CONF=str(groups))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.count('reached'), 2)
        self.assertLess(result.stdout.index('=== db'), result.stdout.index('=== web'))
        self.assertIn('Host summary', result.stdout)
        for content in ['bad unknown\n', 'bad web\nbad db\n', 'empty\n']:
            groups.write_text(content)
            result = self.run_script('groups', SSH_HOST_GROUPS_CONF=str(groups))
            self.assertNotEqual(result.returncode, 0)
        result = self.run_script('@', 'true')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('bad array subscript', result.stderr)

    def test_help_without_config_and_invalid_options(self):
        self.conf.unlink()
        result = self.run_script('--help')
        self.assertEqual(result.returncode, 0)
        self.assertIn('doctor', result.stdout)
        for options in [('--jobs', '0'), ('--jobs', 'abc'), ('--audit-format', 'xml'), ('--unknown',)]:
            result = self.run_script(*options)
            self.assertNotEqual(result.returncode, 0)

    def test_connection_options_and_doctor(self):
        result = self.run_script('doctor', 'web', SSH_CONNECT_TIMEOUT='7', SSH_KEEPALIVE_INTERVAL='9', SSH_KEEPALIVE_COUNT='2')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('OK web', result.stdout)
        args = (self.remote / 'ssh-args').read_text()
        for option in ['ConnectTimeout=7', 'ServerAliveInterval=9', 'ServerAliveCountMax=2']:
            self.assertIn(option, args)
        self.assertFalse(list(self.remote.rglob('.doctor.*')))
        (self.remote / '.ssh-audit').rmdir()
        (self.remote / '.ssh-audit').write_text('blocked')
        result = self.run_script('doctor', 'web')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('FAILED web', result.stdout)

    def test_parallel_limit_separate_output_status_and_no_stdin(self):
        # Each command holds a directory lock: exceeding two concurrent jobs fails.
        self.conf.write_text('a host admin\nb host admin\nc host admin\nd host admin\n')
        command = "slot=; for n in 1 2; do if mkdir slot$n 2>/dev/null; then slot=slot$n; break; fi; done; " \
                  "[ -n \"$slot\" ] || exit 91; trap 'rmdir \"$slot\"' EXIT; " \
                  "sleep 0.2; if read -r input; then exit 92; fi; echo output; echo error >&2; exit 7"
        result = self.run_script('--jobs', '2', 'all', command, stdin='not forwarded\n')
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(result.stdout.count('output'), 4)
        self.assertEqual(result.stderr.count('error'), 4)
        self.assertEqual(result.stdout.count('exit 7'), 4)
        headers = [line for line in result.stdout.splitlines() if line.startswith('===')]
        self.assertEqual(headers, [f'=== {alias} (host) ===' for alias in 'abcd'])
        self.assertFalse(list(self.remote.glob('slot*')))

    def test_signal_download_cleanup(self):
        self.executable('ssh', '''#!/usr/bin/env bash
while [[ "${1:-}" == -o || "${1:-}" == -F ]]; do shift 2; done
shift
if [[ "$*" == "base64 <"* ]]; then printf cGFydGlhbA==; sleep 30; else exit 0; fi
''')
        destination = self.root / 'existing'
        destination.write_text('keep')
        process = subprocess.Popen(['bash', str(SCRIPT), 'scp', 'web:file', 'existing'], cwd=self.root,
                                   env=self.env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        try:
            deadline = time.monotonic() + 5
            while not list(self.root.glob('*.ssh-remote.*')) and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(list(self.root.glob('*.ssh-remote.*')))
            os.killpg(process.pid, signal.SIGTERM)
            process.wait(timeout=5)
            self.assertNotEqual(process.returncode, 0)
            self.assertEqual(destination.read_text(), 'keep')
            self.assertFalse(list(self.root.glob('*.ssh-remote.*')))
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()

    def test_parallel_cancellation_reaps_connections(self):
        self.executable('ssh', '''#!/usr/bin/env bash
printf '%s\\n' "$$" >> "$TEST_REMOTE/connection-pids"
exec sleep 30
''')
        process = subprocess.Popen(['bash', str(SCRIPT), '--jobs', '2', 'all', 'true'], cwd=self.root,
                                   env=dict(self.env, TMPDIR=str(self.root)), stdout=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL)
        try:
            path = self.remote / 'connection-pids'
            deadline = time.monotonic() + 5
            while (not path.exists() or len(path.read_text().splitlines()) < 2) and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(path.exists())
            self.assertEqual(len(path.read_text().splitlines()), 2)
            process.terminate()
            process.wait(timeout=5)
            self.assertEqual(process.returncode, 143)
            for pid in path.read_text().splitlines():
                with self.assertRaises(ProcessLookupError):
                    os.kill(int(pid), 0)
            self.assertFalse(list(self.root.glob('tmp.*')))
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            path = self.remote / 'connection-pids'
            if path.exists():
                for pid in path.read_text().splitlines():
                    try:
                        os.kill(int(pid), signal.SIGKILL)
                    except ProcessLookupError:
                        pass

    def test_audit_creation_preserves_command_umask(self):
        result = self.run_script('web', 'umask')
        expected = subprocess.run(['bash', '-c', 'umask'], capture_output=True, text=True).stdout
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, expected)

    def test_transfer_json_and_temporary_audit_connection_cleanup(self):
        (self.root / 'source').write_text('data')
        result = self.run_script('--audit-format', 'json', 'scp', 'source', 'web:target', TMPDIR=str(self.root))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(list(self.root.glob('tmp.*')))
        local = [json.loads(line) for p in (self.root / 'logs').rglob('*.jsonl') for line in p.read_text().splitlines()]
        remote = [json.loads(line) for p in (self.remote / '.ssh-audit').rglob('*.jsonl') for line in p.read_text().splitlines()]
        self.assertEqual([r['event'] for r in local], ['start', 'finish'])
        self.assertEqual([r['event'] for r in remote], ['finish'])
        self.assertEqual(local[-1]['exit_status'], 0)
        self.assertEqual(remote[-1]['run_id'], local[-1]['run_id'])


if __name__ == '__main__':
    unittest.main()
