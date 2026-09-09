#!/usr/bin/env python3
"""Build an AI coding agent's live settings from a shared template and provider.

Normal usage has two positional arguments:

    aicodingagentconfig.py <agent> <provider>

The shared, non-secret settings live in:

    common/scripts/aicodingagentsettings/

The machine-local ~/.aicodingagentconfig.jsonc contains only apikey, baseurl,
models, or {"sub": true}.
"""

from __future__ import annotations

import argparse
import base64
import copy
import json
import os
import re
import shutil
import sys
import tempfile
import tomllib
import urllib.error
import urllib.request
from datetime import datetime
from pathlib import Path
from typing import Any

if sys.platform == 'win32':
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    sys.stderr.reconfigure(encoding='utf-8', errors='replace')

SCRIPT_DIR = Path(__file__).resolve().parent
SETTINGS_DIR = SCRIPT_DIR / 'aicodingagentsettings'
CONFIG_PATH = Path.home() / '.aicodingagentconfig.jsonc'
ENV_PATH = Path.home() / '.env'
BACKUP_DIR = Path.home() / '.aicodingagentconfig.backups'
AGENT_ALIASES = {
    'claude-code': 'claude',
    'open-code': 'opencode',
    'grok': 'grokbuild',
    'grok-build': 'grokbuild',
}
SUPPORTED_AGENTS = {'claude', 'codex', 'opencode'}
ALLOWED_PROVIDER_KEYS = {'apikey', 'baseurl', 'models', 'sub'}
WEBDAV_BASE_URL = 'https://dav.jianguoyun.com/dav/'
WEBDAV_REMOTE_DIR = 'aicodingagentconfig'


class ConfigError(RuntimeError):
    """A user-facing configuration error."""


def strip_jsonc(text: str) -> str:
    """Remove JSONC comments and trailing commas without touching strings."""
    output: list[str] = []
    index = 0
    in_string = False
    escaped = False
    while index < len(text):
        char = text[index]
        next_char = text[index + 1] if index + 1 < len(text) else ''
        if in_string:
            output.append(char)
            if escaped:
                escaped = False
            elif char == '\\':
                escaped = True
            elif char == '"':
                in_string = False
            index += 1
            continue
        if char == '"':
            in_string = True
            output.append(char)
            index += 1
            continue
        if char == '/' and next_char == '/':
            index += 2
            while index < len(text) and text[index] not in '\r\n':
                index += 1
            continue
        if char == '/' and next_char == '*':
            index += 2
            while index + 1 < len(text) and text[index : index + 2] != '*/':
                index += 1
            index += 2
            continue
        output.append(char)
        index += 1
    return re.sub(r',(\s*[}\]])', r'\1', ''.join(output))


def load_jsonc(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    try:
        data = json.loads(strip_jsonc(path.read_text(encoding='utf-8')))
    except (OSError, json.JSONDecodeError) as exc:
        raise ConfigError(f'无法读取 {path}: {exc}') from exc
    if not isinstance(data, dict):
        raise ConfigError(f'{path} 的顶层必须是对象')
    return data


def atomic_write(path: Path, content: str, *, secret: bool = True) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f'.{path.name}.', dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, 'w', encoding='utf-8', newline='\n') as handle:
            handle.write(content)
        if secret:
            os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def save_config(data: dict[str, Any]) -> None:
    header = (
        '// Machine-local provider data. This file contains API keys; do not commit it.\n'
        '// Provider fields are restricted to: apikey, baseurl, models, sub.\n'
        '// Edit manually, then switch with: aicodingagentconfig.py <agent> <provider>.\n'
    )
    atomic_write(CONFIG_PATH, header + json.dumps(data, ensure_ascii=False, indent=2) + '\n')


def webdav_request(url: str, user: str, password: str, method: str = 'GET', data: bytes | None = None):
    request = urllib.request.Request(url, data=data, method=method)
    token = base64.b64encode(f'{user}:{password}'.encode('utf-8')).decode('ascii')
    request.add_header('Authorization', f'Basic {token}')
    return urllib.request.urlopen(request, timeout=60)


def webdav_put(url: str, user: str, password: str, content: bytes) -> None:
    try:
        with webdav_request(url, user, password, 'PUT', content) as response:
            response.read()
    except urllib.error.HTTPError as exc:
        raise ConfigError(f'WebDAV 上传失败: HTTP {exc.code} {exc.reason} ({url})') from exc
    except urllib.error.URLError as exc:
        raise ConfigError(f'WebDAV 上传失败: {exc.reason} ({url})') from exc


def webdav_get(url: str, user: str, password: str) -> bytes:
    try:
        with webdav_request(url, user, password, 'GET') as response:
            return response.read()
    except urllib.error.HTTPError as exc:
        raise ConfigError(f'WebDAV 下载失败: HTTP {exc.code} {exc.reason} ({url})') from exc
    except urllib.error.URLError as exc:
        raise ConfigError(f'WebDAV 下载失败: {exc.reason} ({url})') from exc


def remote_url(name: str) -> str:
    return f'{WEBDAV_BASE_URL.rstrip("/")}/{WEBDAV_REMOTE_DIR}/{name}'


def webdav_mkcol(url: str, user: str, password: str) -> None:
    try:
        with webdav_request(url, user, password, 'MKCOL') as response:
            response.read()
    except urllib.error.HTTPError as exc:
        if exc.code == 405:
            return
        raise ConfigError(f'WebDAV 创建目录失败: HTTP {exc.code} {exc.reason} ({url})') from exc
    except urllib.error.URLError as exc:
        raise ConfigError(f'WebDAV 创建目录失败: {exc.reason} ({url})') from exc


def remote_dir_url() -> str:
    return f'{WEBDAV_BASE_URL.rstrip("/")}/{WEBDAV_REMOTE_DIR}/'


def load_dotenv(path: Path) -> dict[str, str]:
    if not path.exists():
        return {}
    values: dict[str, str] = {}
    for line in path.read_text(encoding='utf-8').splitlines():
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        if line.startswith('export '):
            line = line[len('export '):].lstrip()
        if '=' not in line:
            continue
        key, _, value = line.partition('=')
        key = key.strip()
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in ('"', "'"):
            value = value[1:-1]
        if key:
            values[key] = value
    return values


def resolve_webdav_credentials(user: str | None, password: str | None) -> tuple[str, str]:
    if not (user and password):
        env_values = load_dotenv(ENV_PATH)
        user = user or env_values.get('WEBDAV_USER')
        password = password or env_values.get('WEBDAV_PASSWORD')
    if not user or not password:
        raise ConfigError(
            '--push/--pull 需要 --user 和 --password，'
            '或 ~/.env 中的 WEBDAV_USER / WEBDAV_PASSWORD'
        )
    return user, password


def push_remote(user: str, password: str) -> list[Path]:
    local_paths = [path for path in (CONFIG_PATH, ENV_PATH) if path.exists()]
    if not local_paths:
        raise ConfigError(f'没有可上传的文件: {CONFIG_PATH}、{ENV_PATH} 均不存在')
    uploaded: list[Path] = []
    webdav_mkcol(remote_dir_url(), user, password)
    for path in local_paths:
        webdav_put(remote_url(path.name), user, password, path.read_bytes())
        uploaded.append(path)
    return uploaded


def pull_remote(user: str, password: str) -> list[Path]:
    downloaded: list[Path] = []
    for path in (CONFIG_PATH, ENV_PATH):
        content = webdav_get(remote_url(path.name), user, password)
        atomic_write(path, content.decode('utf-8'))
        downloaded.append(path)
    return downloaded


def validate_config(config: dict[str, Any]) -> None:
    for agent, providers in config.items():
        if not isinstance(providers, dict):
            raise ConfigError(f'{agent} 必须映射到 provider 对象')
        for alias, provider in providers.items():
            if not isinstance(provider, dict):
                raise ConfigError(f'{agent}/{alias} 必须是对象')
            unexpected = set(provider) - ALLOWED_PROVIDER_KEYS
            if unexpected:
                raise ConfigError(
                    f'{agent}/{alias} 包含不允许的字段: {", ".join(sorted(unexpected))}'
                )
            if provider.get('sub') is True:
                extra = set(provider) - {'sub'}
                if extra:
                    raise ConfigError(f'{agent}/{alias} 为 sub 时不能保存 credentials/models')
            elif not any(key in provider for key in ('apikey', 'baseurl', 'models')):
                raise ConfigError(f'{agent}/{alias} 没有 apikey/baseurl/models/sub')


def deep_merge(base: dict[str, Any], overlay: dict[str, Any]) -> dict[str, Any]:
    result = copy.deepcopy(base)
    for key, value in overlay.items():
        if isinstance(value, dict) and isinstance(result.get(key), dict):
            result[key] = deep_merge(result[key], value)
        else:
            result[key] = copy.deepcopy(value)
    return result


def backup_file(path: Path, stamp: str) -> None:
    if not path.exists():
        return
    relative = str(path).replace(':', '').lstrip('/\\').replace('\\', '/')
    destination = BACKUP_DIR / stamp / relative
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(path, destination)


def write_if_changed(path: Path, content: str, stamp: str, dry_run: bool) -> bool:
    old_content = path.read_text(encoding='utf-8') if path.exists() else None
    if old_content == content:
        return False
    if not dry_run:
        backup_file(path, stamp)
        atomic_write(path, content)
    return True


def load_json_template(agent: str) -> dict[str, Any]:
    path = SETTINGS_DIR / f'{agent}.json'
    if not path.exists():
        raise ConfigError(f'缺少 {agent} setting 模板: {path}')
    return load_jsonc(path)


def apply_claude(provider: dict[str, Any], stamp: str, dry_run: bool) -> list[Path]:
    result = load_json_template('claude')
    if provider.get('sub') is not True:
        env = result.setdefault('env', {})
        if not isinstance(env, dict):
            raise ConfigError('Claude setting 模板的 env 必须是对象')
        permissions = result.setdefault('permissions', {})
        if not isinstance(permissions, dict):
            raise ConfigError('Claude setting 模板的 permissions 必须是对象')
        denied_tools = permissions.setdefault('deny', [])
        if not isinstance(denied_tools, list):
            raise ConfigError('Claude setting 模板的 permissions.deny 必须是数组')
        # Artifact requires a claude.ai session. Some Anthropic-compatible API
        # providers reject its Unicode regex schema before processing a prompt.
        if 'Artifact' not in denied_tools:
            denied_tools.insert(0, 'Artifact')
        if provider.get('apikey'):
            env['ANTHROPIC_AUTH_TOKEN'] = provider['apikey']
        if provider.get('baseurl'):
            env['ANTHROPIC_BASE_URL'] = provider['baseurl']
        model_variables = {
            'default': 'ANTHROPIC_MODEL',
            'haiku': 'ANTHROPIC_DEFAULT_HAIKU_MODEL',
            'sonnet': 'ANTHROPIC_DEFAULT_SONNET_MODEL',
            'opus': 'ANTHROPIC_DEFAULT_OPUS_MODEL',
        }
        models = provider.get('models', {})
        if isinstance(models, dict):
            for role, variable in model_variables.items():
                if isinstance(models.get(role), str):
                    env[variable] = models[role]
    path = Path.home() / '.claude' / 'settings.json'
    content = json.dumps(result, ensure_ascii=False, indent=2) + '\n'
    return [path] if write_if_changed(path, content, stamp, dry_run) else []


def toml_string(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)


def extract_toml_table_family(text: str, family: str) -> str:
    """Return a TOML table and its descendants without changing their text."""
    header_pattern = re.compile(r'^\s*\[\[?([^\]]+?)\]?\]\s*(?:#.*)?$')
    output: list[str] = []
    keep = False
    for line in text.splitlines():
        match = header_pattern.match(line)
        if match:
            table = match.group(1).strip()
            keep = table == family or table.startswith(f'{family}.')
        if keep:
            output.append(line)
    return '\n'.join(output).strip()


def apply_codex(provider: dict[str, Any], stamp: str, dry_run: bool) -> list[Path]:
    template_path = SETTINGS_DIR / 'codex.toml'
    path = Path.home() / '.codex' / 'config.toml'
    try:
        template = template_path.read_text(encoding='utf-8').strip()
        tomllib.loads(template)
    except (OSError, tomllib.TOMLDecodeError) as exc:
        raise ConfigError(f'无法读取 Codex setting 模板 {template_path}: {exc}') from exc

    template = template.replace('$(home)', Path.home().as_posix())
    if provider.get('sub') is True:
        content = template + '\n'
    else:
        models = provider.get('models', {})
        model = models.get('default') if isinstance(models, dict) else None
        if not isinstance(model, str) or not model:
            raise ConfigError('Codex API provider 缺少 models.default')
        if not isinstance(provider.get('baseurl'), str):
            raise ConfigError('Codex API provider 缺少 baseurl')
        if not isinstance(provider.get('apikey'), str):
            raise ConfigError('Codex API provider 缺少 apikey')

        lines = template.splitlines()
        first_table = next(
            (index for index, line in enumerate(lines) if line.lstrip().startswith('[')),
            len(lines),
        )
        root = lines[:first_table]
        tables = lines[first_table:]
        root.extend(
            [
                f'model = {toml_string(model)}',
                'model_provider = "aicodingagentconfig"',
            ]
        )
        provider_table = [
            '',
            '[model_providers.aicodingagentconfig]',
            'name = "aicodingagentconfig"',
            f'base_url = {toml_string(provider["baseurl"])}',
            'wire_api = "responses"',
            'requires_openai_auth = false',
            f'experimental_bearer_token = {toml_string(provider["apikey"])}',
        ]
        content = '\n'.join(root + tables + provider_table).strip() + '\n'

    # Project trust is machine-local and managed by Codex itself. Preserve it
    # verbatim instead of keeping or updating it in the shared template.
    current = path.read_text(encoding='utf-8') if path.exists() else ''
    projects = extract_toml_table_family(current, 'projects')
    if projects:
        content = content.rstrip() + '\n\n' + projects + '\n'
    try:
        tomllib.loads(content)
    except tomllib.TOMLDecodeError as exc:
        raise ConfigError(f'合并后的 Codex TOML 无法解析: {exc}') from exc

    return [path] if write_if_changed(path, content, stamp, dry_run) else []


def apply_opencode(
    alias: str,
    provider: dict[str, Any],
    stamp: str,
    dry_run: bool,
) -> list[Path]:
    result = load_json_template('opencode')
    if provider.get('sub') is not True:
        models = provider.get('models', {})
        default_model = models.get('default') if isinstance(models, dict) else None
        available = models.get('available', {}) if isinstance(models, dict) else {}
        if not isinstance(default_model, str) or not default_model:
            raise ConfigError('OpenCode API provider 缺少 models.default')
        if isinstance(available, list):
            available = {model: {} for model in available if isinstance(model, str)}
        if not isinstance(available, dict):
            raise ConfigError('OpenCode models.available 必须是对象或数组')
        options: dict[str, Any] = {}
        if isinstance(provider.get('apikey'), str):
            options['apiKey'] = provider['apikey']
        if isinstance(provider.get('baseurl'), str):
            options['baseURL'] = provider['baseurl']
        live_provider = {
            'npm': '@ai-sdk/openai-compatible',
            'options': options,
            'models': available,
        }
        result.setdefault('provider', {})[alias] = live_provider
        result['model'] = f'{alias}/{default_model}'

    candidates = [
        Path.home() / '.config' / 'opencode' / 'opencode.json',
        Path.home() / '.opencode' / 'config.json',
    ]
    path = next((candidate for candidate in candidates if candidate.exists()), candidates[0])
    content = json.dumps(result, ensure_ascii=False, indent=2) + '\n'
    return [path] if write_if_changed(path, content, stamp, dry_run) else []


def resolve_agent(value: str) -> str:
    normalized = value.lower().strip()
    return AGENT_ALIASES.get(normalized, normalized)


def resolve_provider(providers: dict[str, Any], requested: str) -> tuple[str, dict[str, Any]]:
    normalized = requested.lower().strip()
    if normalized in providers and isinstance(providers[normalized], dict):
        return normalized, providers[normalized]
    matches = [(alias, value) for alias, value in providers.items() if normalized in alias]
    if len(matches) == 1:
        return matches[0]
    available = ', '.join(providers) or '无'
    raise ConfigError(f'找不到 provider {requested!r}；可用 provider: {available}')


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description='用仓库 settings + HOME provider 生成 AI coding agent 配置',
    )
    parser.add_argument('agent', nargs='?', help='claude、codex、opencode、grok 等')
    parser.add_argument('provider', nargs='?', help='ds、glm、sub，或 JSONC 中的完整别名')
    parser.add_argument('--dry-run', action='store_true', help='显示将变更的文件，但不写入')
    parser.add_argument('--list', action='store_true', help='列出 agent/provider')
    parser.add_argument('--push', action='store_true', help='将 ~/.aicodingagentconfig.jsonc 与 ~/.env 上传到坚果云 WebDAV')
    parser.add_argument('--pull', action='store_true', help='从坚果云 WebDAV 下载 ~/.aicodingagentconfig.jsonc 与 ~/.env')
    parser.add_argument('--user', help='WebDAV 账号')
    parser.add_argument('--password', help='WebDAV 密码')
    return parser


def print_available(config: dict[str, Any]) -> None:
    for agent, providers in config.items():
        if isinstance(providers, dict):
            print(f'{agent}: {", ".join(providers) or "无"}')


def main() -> int:
    args = build_parser().parse_args()
    try:
        if args.push or args.pull:
            user, password = resolve_webdav_credentials(args.user, args.password)
            if args.push:
                changed = push_remote(user, password)
                print('已上传:')
            else:
                changed = pull_remote(user, password)
                print('已下载:')
            for path in changed:
                print(f'  {path}')
            return 0

        config = load_jsonc(CONFIG_PATH)
        if not config:
            raise ConfigError(
                f'{CONFIG_PATH} 为空或不存在；'
                '请手动创建该文件（字段仅限 apikey/baseurl/models/sub）'
            )
        validate_config(config)

        if args.list:
            print_available(config)
            return 0
        if not args.agent or not args.provider:
            raise ConfigError('正常切换需要两个参数: <agent> <provider>')

        agent = resolve_agent(args.agent)
        if agent not in SUPPORTED_AGENTS:
            raise ConfigError(f'尚未实现 {args.agent!r} 的 setting 合并适配器')
        providers = config.get(agent)
        if not isinstance(providers, dict):
            raise ConfigError(f'HOME JSONC 中没有 agent {agent!r}')
        alias, provider = resolve_provider(providers, args.provider)
        stamp = datetime.now().strftime('%Y%m%d-%H%M%S')
        if agent == 'claude':
            changed = apply_claude(provider, stamp, args.dry_run)
        elif agent == 'codex':
            changed = apply_codex(provider, stamp, args.dry_run)
        else:
            changed = apply_opencode(alias, provider, stamp, args.dry_run)

        action = '将修改' if args.dry_run else '已修改'
        if changed:
            print(f'{action}:')
            for path in changed:
                print(f'  {path}')
        else:
            print('配置已经是目标状态，无需修改')
        print(f'当前选择: {agent}/{alias}')
        return 0
    except ConfigError as exc:
        print(f'错误: {exc}', file=sys.stderr)
        return 2
    except OSError as exc:
        print(f'文件操作失败: {exc}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
