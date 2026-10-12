"""Parse deployment configuration and exercise scripts with command fixtures only."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class PiDeployTest(unittest.TestCase):
    def test_compose_parse_no_daemon_or_devices(self):
        result = subprocess.run(['docker', 'compose', '-f', 'docker-compose.pi.yml', 'config', '--format', 'json'],
                                capture_output=True, text=True, check=True, env={**os.environ,
                                    'CAMERA_PREVIEW_MODE': 'server', 'ANALYSIS_BASE_URL': 'http://192.168.1.10:9000'})
        config = json.loads(result.stdout)
        server = config['services']['server']
        self.assertNotIn('privileged', server)
        self.assertEqual(len(server['devices']), 2)
        self.assertFalse(any(v.get('target') == '/dev' for v in server['volumes']))
        self.assertEqual(server['environment']['ANALYSIS_BASE_URL'], 'http://192.168.1.10:9000')
        self.assertEqual(server['environment']['CAMERA_PREVIEW_MODE'], 'server')
        self.assertEqual(config['services']['app']['build']['dockerfile'], 'Dockerfile.pi')
        self.assertNotIn('build/', Path('app/Dockerfile.pi.dockerignore').read_text().splitlines())

    def test_scripts_dry_run_cannot_open_hardware_or_call_network(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            device = root / 'fixture-device'
            device.touch()
            for name in ('docker', 'curl', 'chromium', 'ssh', 'ollama'):
                script = root / name
                script.write_text('#!/bin/sh\necho "UNEXPECTED COMMAND" >&2\nexit 99\n')
                script.chmod(0o755)
            env = {**os.environ, 'PATH': f'{temp}:/usr/bin:/bin', 'SERIAL_DEVICE': str(device),
                   'CAMERA_DEVICE': str(root / 'missing'), 'PI_ENV_FILE': str(root / 'missing.env')}
            for script in ('run_pi.sh', 'run_notebook_ai.sh', 'kiosk.sh'):
                subprocess.run(['bash', '-n', 'scripts/' + script], check=True)
                result = subprocess.run(['bash', 'scripts/' + script, '--dry-run'], env=env,
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn('UNEXPECTED COMMAND', result.stderr)
            self.assertFalse((root / 'missing').exists())
