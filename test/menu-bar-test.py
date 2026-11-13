#!/usr/bin/env python3
"""Exercise the installed two-file SwiftBar plugin without touching real services."""
import base64
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent


class MenuBarTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='bridge menu ')
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.bin = self.home / 'bin'
        self.bin.mkdir()
        self.plugin = self.home / 'plugins' / 'muse-bridge.10s.sh'
        self.plugin.parent.mkdir()
        for name in ('muse-bridge.10s.sh', 'muse-bridge-toggle.sh'):
            shutil.copyfile(ROOT / 'mac-menu-bar' / name, self.plugin.parent / name)
        fixtures = {
            'curl': '''#!/bin/sh
case "$*" in
  */health) [ "$FAKE_BRIDGE_UP" = 1 ] && printf '{"ok":true,"version":"0.1.0","mode":"auto-review"}' ;;
  *) echo "Unexpected request" >&2; exit 99 ;;
esac
''',
            'tailscale': '''#!/bin/sh
[ "$*" = 'ip -4' ] || { echo "Unexpected Tailscale action" >&2; exit 99; }
[ "$FAKE_TS_UP" = 1 ] && echo '100.64.0.2'
''',
            'muse-bridge': '#!/bin/sh\necho "Unexpected bridge action" >&2\nexit 99\n',
        }
        for name, text in fixtures.items():
            path = self.bin / name
            path.write_text(text)
            path.chmod(0o755)

    def run_plugin(self, bridge, tailscale, appearance='Light'):
        env = dict(os.environ, HOME=str(self.home), PATH=f'{self.bin}:{os.environ["PATH"]}',
                   FAKE_BRIDGE_UP=str(bridge), FAKE_TS_UP=str(tailscale), OS_APPEARANCE=appearance)
        result = subprocess.run(['/bin/bash', str(self.plugin)], env=env, text=True,
                                capture_output=True, check=True, timeout=10)
        self.assertEqual(result.stderr, '')
        lines = result.stdout.splitlines()
        header = lines[0]
        self.assertTrue(header.startswith(' | templateImage='))
        self.assertIn('dropdown=false', header)
        self.assertEqual(lines[1], '---')
        self.assertTrue(lines[2].startswith('Muse Bridge: '))
        encoded = header.split('templateImage=', 1)[1].split()[0]
        pdf = base64.b64decode(encoded, validate=True)
        self.assertTrue(pdf.startswith(b'%PDF-1.4'))
        self.assertIn(b'/MediaBox [0 0 18 18]', pdf)
        self.assertIn('Open bridge logs |', result.stdout)
        self.assertIn('Restart bridge |', result.stdout)
        self.assertIn('Refresh | refresh=true', result.stdout)
        return result.stdout, pdf

    def test_states_and_theme_independence(self):
        icons = []
        for bridge, tailscale, status, switch in (
            (1, 1, 'connected', 'off'),
            (1, 0, 'running, Tailscale disconnected', 'off'),
            (0, 0, 'stopped', 'on'),
            (0, 1, 'stopped', 'off'),
        ):
            with self.subTest(bridge=bridge, tailscale=tailscale):
                light, pdf = self.run_plugin(bridge, tailscale)
                dark, dark_pdf = self.run_plugin(bridge, tailscale, 'Dark')
                self.assertEqual(light, dark)
                self.assertEqual(pdf, dark_pdf)
                self.assertIn(f'Muse Bridge: {status}\n', light)
                self.assertIn(f'param0={switch} terminal=false refresh=true', light)
                self.assertIn('Bridge: running' if bridge else 'Bridge: stopped', light)
                self.assertIn('Tailscale: connected' if tailscale else 'Tailscale: disconnected', light)
                icons.append(pdf)
        self.assertEqual(len(set(icons)), 3, 'Three distinct state silhouettes')
        self.assertEqual(icons[2], icons[3], 'Stopped takes priority over Tailscale')

    def test_generated_assets_are_current(self):
        paths = [ROOT / 'mac-menu-bar' / 'muse-bridge.10s.sh',
                 *sorted((ROOT / 'mac-menu-bar' / 'icons').glob('*.svg'))]
        before = [path.read_bytes() for path in paths]
        subprocess.run(['python3', str(ROOT / 'scripts' / 'generate-menu-bar-icons.py')], check=True)
        self.assertEqual(before, [path.read_bytes() for path in paths])


if __name__ == '__main__':
    unittest.main()
