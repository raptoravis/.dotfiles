"""Regression tests for generated coding-agent configuration."""

from __future__ import annotations

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock


SCRIPT_PATH = Path(__file__).resolve().parents[1] / 'aicodingagentconfig.py'
SPEC = importlib.util.spec_from_file_location('aicodingagentconfig', SCRIPT_PATH)
assert SPEC is not None
assert SPEC.loader is not None
aicodingagentconfig = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(aicodingagentconfig)


class ApplyOpenCodeTest(unittest.TestCase):
    """Verify OpenCode settings updates preserve externally managed keys."""

    def test_preserves_plugin_and_mcp_configuration(self) -> None:
        """Keep plugin and MCP entries while switching model providers."""
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            config_path = home / '.config' / 'opencode' / 'opencode.json'
            config_path.parent.mkdir(parents=True)
            config_path.write_text(
                json.dumps(
                    {
                        '$schema': 'https://opencode.ai/config.json',
                        'plugin': ['yunxing@git+https://github.com/raptoravis/yunxing.git'],
                        'mcp': {'context7': {'type': 'local'}},
                    }
                ),
                encoding='utf-8',
            )

            provider = {
                'apikey': 'test-key',
                'baseurl': 'https://example.invalid/v1',
                'models': {'default': 'test-model', 'available': {'test-model': {}}},
            }
            backup_dir = home / '.aicodingagentconfig.backups'
            with (
                mock.patch.object(aicodingagentconfig.Path, 'home', return_value=home),
                mock.patch.object(aicodingagentconfig, 'BACKUP_DIR', backup_dir),
            ):
                aicodingagentconfig.apply_opencode('test', provider, 'test-stamp', False)

            result = json.loads(config_path.read_text(encoding='utf-8'))
            assert result['plugin'] == ['yunxing@git+https://github.com/raptoravis/yunxing.git']
            assert result['mcp'] == {'context7': {'type': 'local'}}
            assert result['model'] == 'test/test-model'


if __name__ == '__main__':
    unittest.main()
