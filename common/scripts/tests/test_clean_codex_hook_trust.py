"""Regression tests for Codex hook trust cleanup."""

from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path


SCRIPT_PATH = Path(__file__).resolve().parents[1] / 'clean-codex-hook-trust.mjs'


class CleanCodexHookTrustTest(unittest.TestCase):
    def test_removes_foreign_and_legacy_native_entries(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            codex_home = Path(directory) / '.codex'
            codex_home.mkdir()
            native_backslash = str(codex_home / 'hooks.json')
            native_forward = (codex_home / 'hooks.json').as_posix()
            config_path = codex_home / 'config.toml'
            config_path.write_text(
                '\n'.join(
                    [
                        '[hooks.state]',
                        '',
                        f"[hooks.state.'{native_backslash}:session_start:1:0']",
                        'enabled = true',
                        'trusted_hash = "sha256:legacy"',
                        '',
                        f'[hooks.state."{native_forward}:stop:0:0"]',
                        'trusted_hash = "sha256:valid"',
                        '',
                        '[hooks.state."/tmp/foreign/hooks.json:stop:0:0"]',
                        'trusted_hash = "sha256:foreign"',
                        '',
                        '[tui]',
                        'screen_reader_detection_done = true',
                        '',
                    ]
                ),
                encoding='utf-8',
            )
            env = {**os.environ, 'CODEX_HOME': str(codex_home)}

            result = subprocess.run(
                ['node', str(SCRIPT_PATH)],
                check=True,
                capture_output=True,
                text=True,
                env=env,
            )

            cleaned = config_path.read_text(encoding='utf-8')
            self.assertIn('removed 2 conflicting [hooks.state] entries', result.stdout)
            self.assertNotIn('session_start:1:0', cleaned)
            self.assertNotIn('/tmp/foreign/hooks.json', cleaned)
            self.assertIn(f'{native_forward}:stop:0:0', cleaned)
            self.assertIn('screen_reader_detection_done = true', cleaned)
            self.assertEqual(1, len(list(codex_home.glob('config.toml.bak-*'))))

            second = subprocess.run(
                ['node', str(SCRIPT_PATH)],
                check=True,
                capture_output=True,
                text=True,
                env=env,
            )
            self.assertEqual('', second.stdout)
            self.assertEqual(1, len(list(codex_home.glob('config.toml.bak-*'))))


if __name__ == '__main__':
    unittest.main()
