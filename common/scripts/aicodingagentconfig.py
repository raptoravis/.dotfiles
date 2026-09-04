#!/usr/bin/env python3
"""Build an AI coding agent's live settings from a shared template and provider.

Normal usage has two positional arguments:

    aicodingagentconfig.py <agent> <provider>

The shared, non-secret settings live in:

    common/scripts/aicodingagentsettings/

The machine-local ~/.aicodingagentconfig.jsonc contains only apikey, baseurl,
models, or {"sub": true}.  It can be imported from CC Switch via --import-only.
"""

from __future__ import annotations

import argparse
import copy
import json
import os
import re
import shutil
import sqlite3
import sys
import tempfile
import tomllib
from datetime import datetime
from pathlib import Path
from typing import Any

if sys.platform == 'win32':
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    sys.stderr.reconfigure(encoding='utf-8', errors='replace')

SCRIPT_DIR = Path(__file__).resolve().parent
SETTINGS_DIR = SCRIPT_DIR / 'aicodingagentsettings'
CONFIG_PATH = Path.home() / '.aicodingagentconfig.jsonc'
CC_SWITCH_DB = Path.home() / '.cc-switch' / 'cc-switch.db'
BACKUP_DIR = Path.home() / '.aicodingagentconfig.backups'
AGENT_ALIASES = {
    'claude-code': 'claude',
    'open-code': 'opencode',
    'grok': 'grokbuild',
    'grok-build': 'grokbuild',
}
SUPPORTED_AGENTS = {'claude', 'codex', 'opencode'}
ALLOWED_PROVIDER_KEYS = {'apikey', 'baseurl', 'models', 'sub'}
PROVIDER_HINTS = {
    'ds': ('deepseek',),
    'glm': ('zhipu', 'glm', 'bigmodel'),
    'sub': ('sub', 'subscription'),
}


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
        '// Re-import with: aicodingagentconfig.py --import-only\n'
    )
    atomic_write(CONFIG_PATH, header + json.dumps(data, ensure_ascii=False, indent=2) + '\n')


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


def slugify(value: str) -> str:
    return re.sub(r'[^a-z0-9]+', '-', value.lower()).strip('-') or 'provider'


def preferred_alias(name: str, category: str | None, agent: str) -> str | None:
    lowered = name.lower()
    for alias, hints in PROVIDER_HINTS.items():
        if any(hint in lowered for hint in hints):
            return alias
    if agent == 'codex' and category == 'official':
        return 'sub'
    return None


def unique_alias(preferred: str | None, name: str, occupied: set[str]) -> str:
    slug = slugify(name)
    candidate = preferred or slug
    if candidate not in occupied:
        return candidate
    candidate = f'{preferred}-{slug}' if preferred else slug
    suffix = 2
    original = candidate
    while candidate in occupied:
        candidate = f'{original}-{suffix}'
        suffix += 1
    return candidate


def ordered_rows(rows: list[sqlite3.Row]) -> list[sqlite3.Row]:
    username = (os.environ.get('USERNAME') or os.environ.get('USER') or '').lower()
    return sorted(
        rows,
        key=lambda row: (
            username not in row['name'].lower() if username else True,
            row['sort_index'] is None,
            row['sort_index'] or 0,
            row['name'].lower(),
        ),
    )


def first_string(values: list[Any]) -> str | None:
    return next((value for value in values if isinstance(value, str) and value), None)


def extract_claude(name: str, settings: dict[str, Any]) -> dict[str, Any]:
    env = settings.get('env', {})
    if not isinstance(env, dict):
        env = {}
    if not env and ('sub' in name.lower() or 'subscription' in name.lower()):
        return {'sub': True}
    provider: dict[str, Any] = {}
    apikey = first_string([env.get('ANTHROPIC_API_KEY'), env.get('ANTHROPIC_AUTH_TOKEN')])
    if apikey:
        provider['apikey'] = apikey
    baseurl = env.get('ANTHROPIC_BASE_URL')
    if isinstance(baseurl, str) and baseurl:
        provider['baseurl'] = baseurl
    model_map = {
        'default': 'ANTHROPIC_MODEL',
        'haiku': 'ANTHROPIC_DEFAULT_HAIKU_MODEL',
        'sonnet': 'ANTHROPIC_DEFAULT_SONNET_MODEL',
        'opus': 'ANTHROPIC_DEFAULT_OPUS_MODEL',
    }
    models = {
        role: env[variable]
        for role, variable in model_map.items()
        if isinstance(env.get(variable), str) and env[variable]
    }
    if models:
        provider['models'] = models
    return provider


def extract_codex(
    name: str,
    category: str | None,
    settings: dict[str, Any],
) -> dict[str, Any]:
    if category == 'official':
        return {'sub': True}
    config_text = settings.get('config', '')
    try:
        parsed = tomllib.loads(config_text) if isinstance(config_text, str) else {}
    except tomllib.TOMLDecodeError as exc:
        raise ConfigError(f'CC Switch Codex provider {name} 的 TOML 无法解析: {exc}') from exc
    custom = parsed.get('model_providers', {}).get('custom', {})
    provider: dict[str, Any] = {}
    auth = settings.get('auth', {})
    if isinstance(auth, str):
        try:
            auth = json.loads(auth)
        except json.JSONDecodeError:
            auth = {}
    if isinstance(auth, dict):
        apikey = auth.get('OPENAI_API_KEY')
        if isinstance(apikey, str) and apikey:
            provider['apikey'] = apikey
    baseurl = custom.get('base_url') if isinstance(custom, dict) else None
    if isinstance(baseurl, str) and baseurl:
        provider['baseurl'] = baseurl
    default_model = parsed.get('model')
    available = [
        model.get('model')
        for model in settings.get('modelCatalog', {}).get('models', [])
        if isinstance(model, dict) and isinstance(model.get('model'), str)
    ]
    models: dict[str, Any] = {}
    if isinstance(default_model, str) and default_model:
        models['default'] = default_model
    if available:
        models['available'] = list(dict.fromkeys(available))
    if models:
        provider['models'] = models
    return provider


def extract_opencode(settings: dict[str, Any]) -> dict[str, Any]:
    options = settings.get('options', {})
    provider: dict[str, Any] = {}
    if isinstance(options, dict):
        apikey = options.get('apiKey')
        baseurl = options.get('baseURL')
        if isinstance(apikey, str) and apikey:
            provider['apikey'] = apikey
        if isinstance(baseurl, str) and baseurl:
            provider['baseurl'] = baseurl
    raw_models = settings.get('models', {})
    if isinstance(raw_models, dict) and raw_models:
        provider['models'] = {
            'default': next(iter(raw_models)),
            'available': copy.deepcopy(raw_models),
        }
    return provider


def extract_provider(
    agent: str,
    name: str,
    category: str | None,
    settings: dict[str, Any],
) -> dict[str, Any]:
    if agent == 'claude':
        return extract_claude(name, settings)
    if agent == 'codex':
        return extract_codex(name, category, settings)
    if agent == 'opencode':
        return extract_opencode(settings)
    return {}


def read_cc_switch() -> dict[str, Any]:
    if not CC_SWITCH_DB.exists():
        raise ConfigError(f'找不到 CC Switch 数据库: {CC_SWITCH_DB}')
    uri = f'file:{CC_SWITCH_DB.resolve().as_posix()}?mode=ro'
    try:
        connection = sqlite3.connect(uri, uri=True)
        connection.row_factory = sqlite3.Row
        rows = connection.execute(
            """
            SELECT app_type, name, settings_config, category, sort_index
            FROM providers
            ORDER BY app_type, sort_index, name
            """
        ).fetchall()
        common_opencode_row = connection.execute(
            "SELECT value FROM settings WHERE key = 'common_config_opencode'"
        ).fetchone()
    except sqlite3.Error as exc:
        raise ConfigError(f'读取 CC Switch 数据库失败: {exc}') from exc
    finally:
        if 'connection' in locals():
            connection.close()

    grouped: dict[str, list[sqlite3.Row]] = {}
    for row in rows:
        grouped.setdefault(row['app_type'], []).append(row)

    result: dict[str, Any] = {}
    for agent, agent_rows in grouped.items():
        providers: dict[str, Any] = {}
        occupied: set[str] = set()
        for row in ordered_rows(agent_rows):
            try:
                settings = json.loads(row['settings_config'])
            except json.JSONDecodeError as exc:
                raise ConfigError(f"CC Switch provider {agent}/{row['name']} 不是合法 JSON") from exc
            provider = extract_provider(agent, row['name'], row['category'], settings)
            if not provider:
                continue
            preferred = preferred_alias(row['name'], row['category'], agent)
            alias = unique_alias(preferred, row['name'], occupied)
            occupied.add(alias)
            providers[alias] = provider
        if providers:
            result[agent] = providers

    # CC Switch may keep additive OpenCode providers in its common config.
    if common_opencode_row:
        try:
            common_opencode = json.loads(common_opencode_row['value'])
        except json.JSONDecodeError:
            common_opencode = {}
        embedded = common_opencode.get('provider', {}) if isinstance(common_opencode, dict) else {}
        if isinstance(embedded, dict):
            opencode = result.setdefault('opencode', {})
            for alias, settings in embedded.items():
                if alias not in opencode and isinstance(settings, dict):
                    provider = extract_opencode(settings)
                    if provider:
                        opencode[alias] = provider

    validate_config(result)
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
    parser.add_argument('--import-only', action='store_true', help='从 CC Switch 导入到 HOME JSONC，不切换')
    parser.add_argument('--dry-run', action='store_true', help='显示将变更的文件，但不写入')
    parser.add_argument('--list', action='store_true', help='列出 agent/provider')
    return parser


def print_available(config: dict[str, Any]) -> None:
    for agent, providers in config.items():
        if isinstance(providers, dict):
            print(f'{agent}: {", ".join(providers) or "无"}')


def main() -> int:
    args = build_parser().parse_args()
    try:
        if args.import_only:
            config = read_cc_switch()
            if not args.dry_run:
                save_config(config)
            action = '将从' if args.dry_run else '已从'
            print(f'{action} CC Switch 抽取最小配置到 {CONFIG_PATH}')
            validate_config(config)
            if args.list:
                print_available(config)
            return 0

        config = load_jsonc(CONFIG_PATH)
        if not config:
            raise ConfigError(
                f'{CONFIG_PATH} 为空或不存在；'
                '请先运行 --import-only 从 CC Switch 导入，或手动创建该文件'
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
