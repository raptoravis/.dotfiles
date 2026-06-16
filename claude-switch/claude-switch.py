#!/usr/bin/env python3
"""Switch the `env` block in ~/.claude/settings.json between auth/sub/api modes."""
import argparse
import json
import re
import urllib.request
from pathlib import Path

README_URL = "https://raw.githubusercontent.com/alistaitsacle/free-llm-api-keys/main/README.md"

ENVS = {
    "auth": {
        "ANTHROPIC_BASE_URL": "https://api.anthropic.com",
        "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
    },
    "sub": {
        "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
    },
    "api": {
        "ANTHROPIC_BASE_URL": "https://api.deepseek.com/anthropic",
        "ANTHROPIC_MODEL": "deepseek-v4-pro[1m]",
        "ANTHROPIC_DEFAULT_HAIKU_MODEL": "deepseek-v4-flash",
        "ANTHROPIC_DEFAULT_SONNET_MODEL": "deepseek-v4-flash",
        "ANTHROPIC_DEFAULT_OPUS_MODEL": "deepseek-v4-pro[1m]",
        "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
    },
}

# Which README section to scrape for each provider
HINTS = {"claude": r"claude", "deepseek": r"deepseek.*v4.*pro"}


def _fetch_key(provider: str) -> str | None:
    """Scrape the first usable API key from the free-keys repo README."""
    try:
        with urllib.request.urlopen(README_URL, timeout=10) as r:
            text = r.read().decode("utf-8")
    except Exception as e:
        print(f"[WARN] fetch failed: {e}")
        return None

    pattern = re.compile(rf"^###\s+[^\n]*{HINTS[provider]}[^\n]*$", re.M | re.I)
    m = pattern.search(text)
    if not m:
        print(f"[WARN] no matching section for provider={provider}")
        return None

    tail = text[m.end():]
    table_m = re.search(r"^\|.*\|$", tail, re.M)
    if not table_m:
        print("[WARN] no table found after section header")
        return None

    lines = tail[table_m.start():].splitlines()
    for line in lines[2:]:
        line = line.strip()
        if not line.startswith("|"):
            break
        cells = [c.strip().strip("`") for c in line.split("|")[1:-1]]
        if cells and cells[0].startswith("sk-"):
            print(f"auto-fetched: {cells[0][:20]}...")
            return cells[0]

    print("[WARN] no key found in table")
    return None


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--mode", required=True, choices=list(ENVS))
    p.add_argument("--provider", choices=list(HINTS), help="provider for --mode api (claude or deepseek)")
    p.add_argument("--token", help="ANTHROPIC_AUTH_TOKEN (fetched from free-keys repo if omitted)")
    args = p.parse_args()

    if args.mode == "api" and not args.provider:
        p.error("--mode api requires --provider {claude,deepseek}")

    env = dict(ENVS[args.mode])
    token = args.token

    if not token and args.mode != "sub":
        provider = "claude" if args.mode == "auth" else args.provider
        token = _fetch_key(provider)

    if token:
        key = "ANTHROPIC_AUTH_TOKEN" if args.mode == "auth" else "ANTHROPIC_API_KEY"
        env[key] = token

    settings = Path.home() / ".claude" / "settings.json"
    data = json.loads(settings.read_text(encoding="utf-8"))
    data["env"] = env
    settings.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"env -> {args.mode}")


if __name__ == "__main__":
    main()
