#!/usr/bin/env python3
"""
查 DeepSeek 和/或 SiliconFlow 账户余额，密钥从 ~/.env 读取。

Usage:
    check-balance                    # 查两个账户
    check-balance --ds              # 只查 DeepSeek
    check-balance --sf              # 只查 SiliconFlow
    check-balance --key sk-xxx      # DeepSeek 密钥直传
    check-balance --sf-key sf-xxx   # SiliconFlow 密钥直传

Returns exit code 0 on success, 1 on error.
"""

import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from datetime import datetime
from pathlib import Path

# ── 各 Provider 配置 ──────────────────────────────────────────────

PROVIDERS = {
    "deepseek": {
        "env_key": "DS_API_KEY",
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
        "env_key": "DS_VISION_API_KEY",
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


def api_get(url: str, api_key: str) -> dict:
    """发起 GET 请求并返回 JSON。"""
    req = urllib.request.Request(
        url,
        headers={
            "Authorization": f"Bearer {api_key}",
            "Accept": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        if e.code == 401:
            die("Invalid API key (401 Unauthorized)")
        elif e.code == 403:
            die("API key lacks permission (403 Forbidden)")
        else:
            body = e.read().decode("utf-8", errors="replace")[:500]
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
    data = api_get(cfg["url"], api_key)
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


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Check DeepSeek and SiliconFlow account balance"
    )
    parser.add_argument("--ds", action="store_true", help="only check DeepSeek")
    parser.add_argument("--sf", action="store_true", help="only check SiliconFlow")
    parser.add_argument("--key", "-k", help="DeepSeek DS_API_KEY directly")
    parser.add_argument("--sf-key", help="SiliconFlow API key directly")
    args = parser.parse_args()

    env_path = Path.home() / ".env"
    only_ds = args.ds and not args.sf
    only_sf = args.sf and not args.ds

    if not only_sf:  # check DeepSeek
        key = args.key if args.key else read_api_key("DS_API_KEY", env_path)
        check_one(key, PROVIDERS["deepseek"], "DeepSeek")

    if not only_ds:  # check SiliconFlow
        key = args.sf_key if args.sf_key else read_api_key("DS_VISION_API_KEY", env_path)
        check_one(key, PROVIDERS["siliconflow"], "SiliconFlow")


if __name__ == "__main__":
    main()
