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
import hashlib
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
SYNC_DIR = Path.home() / '.aicodingagentconfig.sync'
SYNC_STATE_PATH = SYNC_DIR / 'state.json'
MANIFEST_NAME = 'manifest.json'
# 同步的两个文件（basename），顺序固定以便状态/清单一致。
SYNC_NAMES = (CONFIG_PATH.name, ENV_PATH.name)
CONFIG_HEADER = (
    '// Machine-local provider data. This file contains API keys; do not commit it.\n'
    '// Provider fields are restricted to: apikey, baseurl, models, sub.\n'
    '// Edit manually, then switch with: aicodingagentconfig.py <agent> <provider>.\n'
)
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
    atomic_write(CONFIG_PATH, CONFIG_HEADER + json.dumps(data, ensure_ascii=False, indent=2) + '\n')


def webdav_request(url: str, user: str, password: str, method: str = 'GET', data: bytes | None = None):
    request = urllib.request.Request(url, data=data, method=method)
    token = base64.b64encode(f'{user}:{password}'.encode()).decode('ascii')
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


def parse_dotenv(text: str) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in text.splitlines():
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


def load_dotenv(path: Path) -> dict[str, str]:
    if not path.exists():
        return {}
    return parse_dotenv(path.read_text(encoding='utf-8'))


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


def hash_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def short_hash(value: str) -> str:
    return value[:12]


def atomic_write_bytes(path: Path, content: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f'.{path.name}.', dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, 'wb') as handle:
            handle.write(content)
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def load_sync_state() -> dict[str, Any]:
    return load_jsonc(SYNC_STATE_PATH)


def save_sync_state(state: dict[str, Any]) -> None:
    atomic_write(SYNC_STATE_PATH, json.dumps(state, ensure_ascii=False, indent=2) + '\n')


def remote_get(name: str, user: str, password: str) -> bytes | None:
    """下载远端文件；404 返回 None，其余错误抛 ConfigError。"""
    try:
        return webdav_get(remote_url(name), user, password)
    except ConfigError as exc:
        if 'HTTP 404' in str(exc):
            return None
        raise


def load_remote_manifest(user: str, password: str) -> dict[str, Any]:
    content = remote_get(MANIFEST_NAME, user, password)
    if content is None:
        return {}
    try:
        data = json.loads(content.decode('utf-8'))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ConfigError(f'远端 manifest 解析失败: {exc}') from exc
    if not isinstance(data, dict):
        raise ConfigError('远端 manifest 顶层必须是对象')
    return data


def save_remote_manifest(user: str, password: str, manifest: dict[str, Any]) -> None:
    payload = json.dumps(manifest, ensure_ascii=False, indent=2).encode('utf-8')
    webdav_put(remote_url(MANIFEST_NAME), user, password, payload)


def base_path(name: str) -> Path:
    return SYNC_DIR / f'{name}.base'


def read_base(name: str) -> bytes | None:
    path = base_path(name)
    if not path.exists():
        return None
    return path.read_bytes()


def write_base(name: str, content: bytes) -> None:
    atomic_write_bytes(base_path(name), content)


def backup_bytes(name: str, content: bytes, suffix: str, stamp: str) -> Path:
    destination = BACKUP_DIR / stamp / suffix / name
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(content)
    return destination


def sidecar_path(name: str) -> Path:
    return Path.home() / f'{name}.remote'


def merge3(base: Any, ours: Any, theirs: Any) -> tuple[Any, list[str]]:
    """三路合并，返回 (merged, conflicts)；conflicts 为冲突键的 dot 路径列表。"""
    conflicts: list[str] = []
    if ours == theirs:
        return copy.deepcopy(theirs), conflicts
    if ours == base:
        return copy.deepcopy(theirs), conflicts
    if theirs == base:
        return copy.deepcopy(ours), conflicts
    if isinstance(base, dict) and isinstance(ours, dict) and isinstance(theirs, dict):
        merged: dict[str, Any] = {}
        for key in sorted(set(base) | set(ours) | set(theirs)):
            in_base = key in base
            in_ours = key in ours
            in_theirs = key in theirs
            if in_ours and in_theirs:
                if not in_base:
                    if ours[key] == theirs[key]:
                        merged[key] = copy.deepcopy(ours[key])
                    else:
                        conflicts.append(key)
                    continue
                value, sub_conflicts = merge3(base[key], ours[key], theirs[key])
                merged[key] = value
                conflicts.extend(f'{key}.{path}' if path else key for path in sub_conflicts)
            elif in_ours:
                if not in_base:
                    merged[key] = copy.deepcopy(ours[key])
                elif base[key] == ours[key]:
                    continue  # 我方未动、对方删除 → 保持删除
                else:
                    merged[key] = copy.deepcopy(ours[key])
                    conflicts.append(key)  # 我方改、对方删 → 冲突，保留我方
            elif not in_base:
                merged[key] = copy.deepcopy(theirs[key])  # 对方新增
            elif base[key] == theirs[key]:
                continue  # 对方未动、我方删除 → 保持删除
            else:
                conflicts.append(key)  # 对方改、我方删 → 冲突，保留删除
        return merged, conflicts
    conflicts.append('')
    return copy.deepcopy(ours), conflicts


def merge3_jsonc(base: bytes, ours: bytes, theirs: bytes) -> tuple[bytes | None, list[str]]:
    try:
        base_obj = json.loads(strip_jsonc(base.decode('utf-8')))
        ours_obj = json.loads(strip_jsonc(ours.decode('utf-8')))
        theirs_obj = json.loads(strip_jsonc(theirs.decode('utf-8')))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        return None, [f'JSON 解析失败: {exc}']
    if not all(isinstance(obj, dict) for obj in (base_obj, ours_obj, theirs_obj)):
        return None, ['顶层必须是对象，无法结构化合并']
    merged, conflicts = merge3(base_obj, ours_obj, theirs_obj)
    content = CONFIG_HEADER + json.dumps(merged, ensure_ascii=False, indent=2) + '\n'
    return content.encode('utf-8'), conflicts


def merge3_env(base: bytes, ours: bytes, theirs: bytes) -> tuple[bytes | None, list[str]]:
    try:
        base_obj = parse_dotenv(base.decode('utf-8'))
        ours_obj = parse_dotenv(ours.decode('utf-8'))
        theirs_obj = parse_dotenv(theirs.decode('utf-8'))
    except UnicodeDecodeError as exc:
        return None, [f'.env 解析失败: {exc}']
    merged, conflicts = merge3(base_obj, ours_obj, theirs_obj)
    lines = [f'{key}={value}' for key, value in sorted(merged.items())]
    content = '\n'.join(lines) + ('\n' if lines else '')
    return content.encode('utf-8'), conflicts


def merge_by_name(name: str, base: bytes, ours: bytes, theirs: bytes) -> tuple[bytes | None, list[str]]:
    if name == ENV_PATH.name:
        return merge3_env(base, ours, theirs)
    return merge3_jsonc(base, ours, theirs)


def resolve_conflict(
    name: str,
    ours: bytes,
    theirs: bytes | None,
    conflicts: list[str],
    stamp: str,
    direction: str,
) -> str:
    """交互式解决冲突，返回 'remote' / 'local' / 'manual'。"""
    local_backup = backup_bytes(name, ours, 'local', stamp)
    remote_backup = None
    if theirs is not None:
        remote_backup = backup_bytes(name, theirs, 'remote', stamp)
        atomic_write_bytes(sidecar_path(name), theirs)
    print(f'\n检测到冲突: {name}（{direction}）')
    print(f'  本地 (ours):   {short_hash(hash_bytes(ours))}')
    print(f'  远端 (theirs): {short_hash(hash_bytes(theirs)) if theirs is not None else "无(已被删除)"}')
    if conflicts:
        print(f'  无法自动合并的字段: {", ".join(conflicts)}')
    print(f'  已备份 本地 → {local_backup}')
    if remote_backup is not None:
        print(f'  已备份 远端 → {remote_backup}')
        print(f'  远端内容已拉取到: {sidecar_path(name)}')
    if not sys.stdin.isatty():
        raise ConfigError(
            f'{name} 存在冲突但当前不是交互终端，无法自动解决'
            f'（远端内容见 {sidecar_path(name)}）'
        )
    while True:
        try:
            choice = input('  [r] 采用远端  [l] 采用本地  [m] 手动合并  请选择 [r/l/m]: ').strip().lower()
        except EOFError as exc:
            raise ConfigError(
                f'{name} 冲突需交互选择，但 stdin 已关闭（远端内容见 {sidecar_path(name)}）'
            ) from exc
        if choice in ('r', 'remote'):
            return 'remote'
        if choice in ('l', 'local'):
            return 'local'
        if choice in ('m', 'manual'):
            print(
                f'  已退出，未写入。请参考 {sidecar_path(name)} 手动合并进本地文件，'
                '完成后重跑 --push/--pull（冲突时选 l 采用合并结果）。'
            )
            return 'manual'
        print('  无效输入，请输入 r / l / m')


MAX_HISTORY = 3


def record_version(
    name: str,
    content: bytes,
    old_chain: list[dict[str, Any]] | None,
    state: dict[str, Any],
    manifest: dict[str, Any],
) -> None:
    """把 base 快照、本地 state、远端 manifest 三者对齐到同一个新版本。

    每个版本节点只有单一 `parent`，构成一条版本链；链上最多保留 MAX_HISTORY
    个节点（最新在前），更早的历史被丢弃。
    """
    write_base(name, content)
    new_hash = hash_bytes(content)
    parent = old_chain[0]['hash'] if old_chain else None
    new_node = {'hash': new_hash, 'parent': parent}
    chain = [new_node] + (old_chain[: MAX_HISTORY - 1] if old_chain else [])
    state[name] = chain
    manifest[name] = chain


def _push_file(
    name: str,
    ours: bytes,
    base: list[dict[str, Any]] | None,
    base_content: bytes | None,
    theirs: bytes | None,
    manifest: dict[str, Any],
    state: dict[str, Any],
    stamp: str,
    user: str,
    password: str,
) -> str:
    ours_hash = hash_bytes(ours)
    theirs_hash = hash_bytes(theirs) if theirs is not None else None
    local_path = Path.home() / name

    if theirs is None:
        if base is None:
            webdav_put(remote_url(name), user, password, ours)
            record_version(name, ours, None, state, manifest)
            return f'  {name}: 已上传（首次，{short_hash(ours_hash)}）'
        choice = resolve_conflict(name, ours, None, ['远端文件已被删除'], stamp, 'push')
        if choice == 'local':
            webdav_put(remote_url(name), user, password, ours)
            record_version(name, ours, base, state, manifest)
            return f'  {name}: 已重新上传（采用本地，{short_hash(ours_hash)}）'
        if choice == 'remote':
            base_path(name).unlink(missing_ok=True)
            state.pop(name, None)
            manifest.pop(name, None)
            local_path.unlink(missing_ok=True)
            return f'  {name}: 已删除本地（采用远端删除）'
        return f'  {name}: 冲突未解决，已跳过'

    if base is None:
        if ours == theirs:
            record_version(name, theirs, None, state, manifest)
            return f'  {name}: 已一致（{short_hash(theirs_hash)}）'
        choice = resolve_conflict(name, ours, theirs, ['本地与远端各自独立产生，无共同祖先'], stamp, 'push')
        if choice == 'local':
            webdav_put(remote_url(name), user, password, ours)
            record_version(name, ours, None, state, manifest)
            return f'  {name}: 已上传（采用本地，{short_hash(ours_hash)}）'
        if choice == 'remote':
            atomic_write_bytes(local_path, theirs)
            record_version(name, theirs, None, state, manifest)
            return f'  {name}: 本地已回退为远端（{short_hash(theirs_hash)}）'
        return f'  {name}: 冲突未解决，已跳过'

    local_changed = ours_hash != base[0]['hash']
    remote_changed = theirs_hash != base[0]['hash']

    if not local_changed and not remote_changed:
        return f'  {name}: 已一致（{short_hash(ours_hash)}）'
    if local_changed and not remote_changed:
        webdav_put(remote_url(name), user, password, ours)
        record_version(name, ours, base, state, manifest)
        return f'  {name}: 已上传（{short_hash(ours_hash)}）'
    if not local_changed and remote_changed:
        choice = resolve_conflict(name, ours, theirs, ['本地未变、远端有更新'], stamp, 'push')
        if choice == 'local':
            webdav_put(remote_url(name), user, password, ours)
            record_version(name, ours, base, state, manifest)
            return f'  {name}: 已上传覆盖远端（采用本地）'
        if choice == 'remote':
            atomic_write_bytes(local_path, theirs)
            record_version(name, theirs, base, state, manifest)
            return f'  {name}: 本地已更新为远端（{short_hash(theirs_hash)}）'
        return f'  {name}: 冲突未解决，已跳过'

    # 两端都改 → 三路合并；无共同祖先快照则退回交互。
    if base_content is not None:
        merged, conflicts = merge_by_name(name, base_content, ours, theirs)
        if merged is not None and not conflicts:
            atomic_write_bytes(local_path, merged)
            webdav_put(remote_url(name), user, password, merged)
            record_version(name, merged, base, state, manifest)
            return f'  {name}: 已自动合并并上传（{short_hash(hash_bytes(merged))}）'
        choice = resolve_conflict(name, ours, theirs, conflicts, stamp, 'push')
    else:
        choice = resolve_conflict(name, ours, theirs, ['缺少共同祖先快照，无法自动合并'], stamp, 'push')
    if choice == 'local':
        webdav_put(remote_url(name), user, password, ours)
        record_version(name, ours, base, state, manifest)
        return f'  {name}: 已上传（采用本地）'
    if choice == 'remote':
        atomic_write_bytes(local_path, theirs)
        record_version(name, theirs, base, state, manifest)
        return f'  {name}: 本地已回退为远端（{short_hash(theirs_hash)}）'
    return f'  {name}: 冲突未解决，已跳过'


def _pull_file(
    name: str,
    ours: bytes | None,
    base: list[dict[str, Any]] | None,
    base_content: bytes | None,
    theirs: bytes,
    manifest: dict[str, Any],
    state: dict[str, Any],
    stamp: str,
    user: str,
    password: str,
) -> str:
    ours_hash = hash_bytes(ours) if ours is not None else None
    theirs_hash = hash_bytes(theirs)
    local_path = Path.home() / name

    if base is None:
        if ours is None:
            atomic_write_bytes(local_path, theirs)
            record_version(name, theirs, None, state, manifest)
            return f'  {name}: 已下载（首次，{short_hash(theirs_hash)}）'
        if ours == theirs:
            record_version(name, theirs, None, state, manifest)
            return f'  {name}: 已一致（{short_hash(theirs_hash)}）'
        choice = resolve_conflict(name, ours, theirs, ['本地与远端各自独立产生，无共同祖先'], stamp, 'pull')
        if choice == 'remote':
            atomic_write_bytes(local_path, theirs)
            record_version(name, theirs, None, state, manifest)
            return f'  {name}: 已下载（采用远端）'
        if choice == 'local':
            return f'  {name}: 保留本地，未下载'
        return f'  {name}: 冲突未解决，已跳过'

    local_changed = ours_hash != base[0]['hash'] if ours is not None else True
    remote_changed = theirs_hash != base[0]['hash']

    if not remote_changed:
        if local_changed:
            choice = resolve_conflict(name, ours or b'', theirs, ['远端无更新、本地有未推送改动'], stamp, 'pull')
            if choice == 'remote':
                atomic_write_bytes(local_path, theirs)
                record_version(name, theirs, base, state, manifest)
                return f'  {name}: 本地已回退为远端'
            if choice == 'local':
                return f'  {name}: 保留本地（远端无更新）'
            return f'  {name}: 冲突未解决，已跳过'
        return f'  {name}: 已一致（{short_hash(theirs_hash)}）'
    if not local_changed:
        atomic_write_bytes(local_path, theirs)
        record_version(name, theirs, base, state, manifest)
        return f'  {name}: 已下载（{short_hash(theirs_hash)}）'

    # 两端都改 → 三路合并；无共同祖先快照则退回交互。
    if base_content is not None:
        merged, conflicts = merge_by_name(name, base_content, ours or b'', theirs)
        if merged is not None and not conflicts:
            atomic_write_bytes(local_path, merged)
            record_version(name, merged, base, state, manifest)
            return f'  {name}: 已自动合并（{short_hash(hash_bytes(merged))}）'
        choice = resolve_conflict(name, ours or b'', theirs, conflicts, stamp, 'pull')
    else:
        choice = resolve_conflict(name, ours or b'', theirs, ['缺少共同祖先快照，无法自动合并'], stamp, 'pull')
    if choice == 'remote':
        atomic_write_bytes(local_path, theirs)
        record_version(name, theirs, base, state, manifest)
        return f'  {name}: 已下载（采用远端）'
    if choice == 'local':
        return f'  {name}: 保留本地（采用本地）'
    return f'  {name}: 冲突未解决，已跳过'


def push_remote(user: str, password: str) -> list[str]:
    local_paths = [path for path in (CONFIG_PATH, ENV_PATH) if path.exists()]
    if not local_paths:
        raise ConfigError(f'没有可上传的文件: {CONFIG_PATH}、{ENV_PATH} 均不存在')
    webdav_mkcol(remote_dir_url(), user, password)
    manifest = load_remote_manifest(user, password)
    state = load_sync_state()
    stamp = datetime.now().strftime('%Y%m%d-%H%M%S')
    results: list[str] = []
    for path in local_paths:
        name = path.name
        ours = path.read_bytes()
        base = state.get(name)
        base_content = read_base(name) if base is not None else None
        theirs = remote_get(name, user, password)
        results.append(
            _push_file(name, ours, base, base_content, theirs, manifest, state, stamp, user, password)
        )
    save_sync_state(state)
    save_remote_manifest(user, password, manifest)
    return results


def pull_remote(user: str, password: str) -> list[str]:
    webdav_mkcol(remote_dir_url(), user, password)
    manifest = load_remote_manifest(user, password)
    state = load_sync_state()
    stamp = datetime.now().strftime('%Y%m%d-%H%M%S')
    results: list[str] = []
    for name in SYNC_NAMES:
        theirs = remote_get(name, user, password)
        if theirs is None:
            continue
        local_path = Path.home() / name
        ours = local_path.read_bytes() if local_path.exists() else None
        base = state.get(name)
        base_content = read_base(name) if base is not None else None
        results.append(
            _pull_file(name, ours, base, base_content, theirs, manifest, state, stamp, user, password)
        )
    if not results:
        return ['  远端无文件可下载']
    save_sync_state(state)
    save_remote_manifest(user, password, manifest)
    return results


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
    current = load_jsonc(path) if path.exists() else {}
    managed_keys = set(result) | {'provider', 'model'}
    preserved = {key: value for key, value in current.items() if key not in managed_keys}
    result = deep_merge(preserved, result)
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
                results = push_remote(user, password)
                print('推送结果:')
            else:
                results = pull_remote(user, password)
                print('拉取结果:')
            for line in results:
                print(line)
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
