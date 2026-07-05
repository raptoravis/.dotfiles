#!/usr/bin/env python3
"""
查 LLM/SaaS 账户余额，密钥从 ~/.env 读取。

Supported providers: DeepSeek, SiliconFlow, ElevenLabs.
(DashScope / Tripo3D / Gemini have no programmatic balance API.)

Usage:
    check-balance                    # 查全部
    check-balance --ds              # 只查 DeepSeek
    check-balance --sf              # 只查 SiliconFlow
    check-balance --el              # 只查 ElevenLabs
    check-balance --key sk-xxx      # DeepSeek 密钥直传
    check-balance --sf-key sf-xxx   # SiliconFlow 密钥直传
    check-balance --el-key el-xxx   # ElevenLabs 密钥直传

Returns exit code 0 on success, 1 on error.
"""

import argparse
import json
import os
import sys

# Force UTF-8 output on Windows (avoids GBK encoding errors with emoji)
if sys.platform == "win32":
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
import urllib.error
import urllib.request
from datetime import datetime
from pathlib import Path

# ── 各 Provider 配置 ──────────────────────────────────────────────

PROVIDERS = {
    "deepseek": {
        "env_key": "DEEPSEEK_API_KEY",
        "url": "https://api.deepseek.com/user/balance",
        "parse": lambda d: (
            d.get("balance_infos", []),
            d.get("is_available", False),
        ),
        "fmt_infos": lambda infos, cur: (
            f"  Total       {infos.get('total_balance', '0.00'):>12s}  {cur}\n"
            f"  Granted     {infos.get('granted_balance', '0.00'):>12s}  {cur}\n"
            f"  Topped up   {infos.get('topped_up_balance', '0.00'):>12s}  {cur}"
        ),
    },
    "siliconflow": {
        "env_key": "SILICONFLOW_API_KEY",
        "url": "https://api.siliconflow.cn/v1/user/info",
        "parse": lambda d: (
            d.get("data", {}),
            d.get("status", False) and d.get("data", {}).get("balance", "0") != "0",
        ),
        "fmt_infos": lambda infos, cur: (
            f"  Balance      {infos.get('balance', '0.00'):>12s}  {cur}\n"
            f"  Recharged    {infos.get('chargeBalance', '0.00'):>12s}  {cur}\n"
            f"  Total        {infos.get('totalBalance', '0.00'):>12s}  {cur}"
        ),
    },
    "elevenlabs": {
        "env_key": "ELEVENLABS_API_KEY",
        "url": "https://api.elevenlabs.io/v1/user",
        "header_name": "xi-api-key",
        "parse": lambda d: (
            d.get("subscription", {}),
            d.get("subscription", {}).get("status") not in (None, "blocked"),
        ),
        "fmt_infos": lambda sub, cur: (
            f"  Tier         {str(sub.get('tier', 'unknown')):>12s}\n"
            f"  Characters   {str(sub.get('character_count', 'N/A')):>12s}  / {sub.get('character_limit', 'N/A')}\n"
            f"  Status       {str(sub.get('status', 'unknown')):>12s}\n"
            f"  Voice slots  {str(sub.get('voice_slots_used', 'N/A')):>12s}  / {sub.get('voice_limit', 'N/A')}"
        ),
    },
}


# ── 工具函数 ─────────────────────────────────────────────────────

def die(msg: str) -> None:
    print(f"❌ {msg}", file=sys.stderr)
    sys.exit(1)


def read_api_key(env_key: str, env_path: Path) -> str:
    """读 ~/.env 或环境变量中的密钥，优先级：环境变量 > ~/.env。"""
    key = os.environ.get(env_key)
    if key:
        return key

    if not env_path.exists():
        die(f"{env_path} not found.  Set {env_key}=sk-... in ~/.env or export it.")

    for line in env_path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line.startswith(f"{env_key}="):
            key = line.removeprefix(f"{env_key}=").strip("\"'")
            break

    if not key:
        die(f"{env_key} not found in {env_path}")
    return key


def api_get(url: str, api_key: str, header_name: str | None = None) -> dict:
    """发起 GET 请求并返回 JSON。"""
    headers: dict[str, str] = {"Accept": "application/json"}
    if header_name:
        headers[header_name] = api_key
    else:
        headers["Authorization"] = f"Bearer {api_key}"
    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")[:500]
        try:
            # Try to return the error body as JSON so the caller can display it
            return json.loads(body)
        except json.JSONDecodeError:
            die(f"API Error {e.code}: {body}")
    except urllib.error.URLError as e:
        die(f"Network error: {e.reason}")


# ── 渲染 ─────────────────────────────────────────────────────────

def check_one(
    api_key: str,
    cfg: dict,
    label: str,
    currency_fallback: str = "CNY",
) -> None:
    """查一个 provider 并打印结果。"""
    data = api_get(cfg["url"], api_key, cfg.get("header_name"))
    if "detail" in data:
        detail = data["detail"]
        if isinstance(detail, dict):
            err_msg = detail.get("message", detail.get("status", str(detail)))
        else:
            err_msg = str(detail)
        now = datetime.now().astimezone().strftime("%Y-%m-%d %H:%M:%S %Z")
        head = f"{label}  balance  ({now})"
        line = f"Error: {err_msg}"
        width = max(len(head) + 4, len(line) + 4, 42)
        print(f"╭─ {head} {'─' * (width - len(head) - 3)}╮")
        print(f"│  {line:<{width - 2}s} │")
        print(f"│  {'─' * width:<{width}s} │")
        print(f"│  {'[WARN] API error':<{width - 2}s} │")
        print(f"╰{'─' * width}╯")
        return
    infos, available = cfg["parse"](data)
    now = datetime.now().astimezone().strftime("%Y-%m-%d %H:%M:%S %Z")

    head = f"{label}  balance  ({now})"
    sep = "─" * (len(head) + 4)

    print(f"╭─ {head} ─╮")
    if not infos:
        print("│  (no balance info returned)                │")
    else:
        if isinstance(infos, dict):
            currency = currency_fallback
            print(f"│  {currency:<28s} {'':>10s} │")
            for line in cfg["fmt_infos"](infos, currency).split("\n"):
                print(f"│  {line:<38s} │")
        else:
            for info in infos:
                currency = info.get("currency", currency_fallback)
                print(f"│  {currency:<28s} {'':>10s} │")
                for line in cfg["fmt_infos"](info, currency).split("\n"):
                    print(f"│  {line:<38s} │")

    icon = "✅  Available" if available else "⚠️  Depleted / Insufficient"
    print(f"│  {sep:<38s} │")
    print(f"│  {icon:<38s} │")
    print(f"╰{'─' * 42}╯")


UNSUPPORTED = {
    "DASHSCOPE_API_KEY": "web console only: https://bailian.console.aliyun.com",
    "TRIPO_API_KEY": "web console only: https://platform.tripo3d.ai",
    "GEMINI_API_KEY": "web console only: https://aistudio.google.com/billing",
}


def show_unsupported(env_path: Path) -> None:
    """打印 .env 中存在但无 API 可查的 key。"""
    if not env_path.exists():
        return
    found: list[tuple[str, str]] = []
    env_text = env_path.read_text(encoding="utf-8")
    for key_name, note in UNSUPPORTED.items():
        if f"{key_name}=" in env_text:
            found.append((key_name, note))
    if not found:
        return
    print()
    for key_name, note in found:
        print(f"💡 {key_name} found in ~/.env — {note}")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Check LLM/SaaS account balance (DeepSeek, SiliconFlow, ElevenLabs)"
    )
    parser.add_argument("--ds", action="store_true", help="only check DeepSeek")
    parser.add_argument("--sf", action="store_true", help="only check SiliconFlow")
    parser.add_argument("--el", action="store_true", help="only check ElevenLabs")
    parser.add_argument("--key", "-k", help="DeepSeek DEEPSEEK_API_KEY directly")
    parser.add_argument("--sf-key", help="SiliconFlow API key directly")
    parser.add_argument("--el-key", help="ElevenLabs API key directly")
    args = parser.parse_args()

    env_path = Path.home() / ".env"
    check_all = not (args.ds or args.sf or args.el)

    if check_all or args.ds:
        key = args.key if args.key else read_api_key("DEEPSEEK_API_KEY", env_path)
        check_one(key, PROVIDERS["deepseek"], "DeepSeek")

    if check_all or args.sf:
        key = args.sf_key if args.sf_key else read_api_key("SILICONFLOW_API_KEY", env_path)
        check_one(key, PROVIDERS["siliconflow"], "SiliconFlow")

    if check_all or args.el:
        key = args.el_key if args.el_key else read_api_key("ELEVENLABS_API_KEY", env_path)
        check_one(key, PROVIDERS["elevenlabs"], "ElevenLabs", currency_fallback="USD")

    show_unsupported(env_path)


if __name__ == "__main__":
    main()
