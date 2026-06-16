#!/usr/bin/env python3
"""Switch the `env` block in ~/.claude/settings.json between auth/sub/api modes."""
import argparse
import json
import os
import re
import urllib.error
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
    # OpenRouter free models (anthropic-compatible endpoint, Bearer auth, your own key)
    "or": {
        "ANTHROPIC_BASE_URL": "https://openrouter.ai/api",
        "ANTHROPIC_MODEL": "openrouter/free",
        "ANTHROPIC_DEFAULT_HAIKU_MODEL": "openrouter/free",
        "ANTHROPIC_DEFAULT_SONNET_MODEL": "openrouter/free",
        "ANTHROPIC_DEFAULT_OPUS_MODEL": "openrouter/free",
        "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
    },
}

OPENROUTER_MODELS_URL = "https://openrouter.ai/api/v1/models"
MODEL_KEYS = ("ANTHROPIC_MODEL", "ANTHROPIC_DEFAULT_HAIKU_MODEL",
              "ANTHROPIC_DEFAULT_SONNET_MODEL", "ANTHROPIC_DEFAULT_OPUS_MODEL")

# Which README section to scrape for each provider + base URL used to validate keys
HINTS = {"claude": r"claude", "deepseek": r"deepseek.*v4.*pro"}
BASE_URLS = {"claude": "https://api.anthropic.com", "deepseek": "https://api.deepseek.com/anthropic"}


def _key_works(key: str, base_url: str) -> bool:
    """Ping the anthropic-compatible /v1/messages endpoint; a non-auth response means the key is live."""
    body = json.dumps({"model": "claude-3-5-haiku-latest", "max_tokens": 1,
                       "messages": [{"role": "user", "content": "hi"}]}).encode()
    req = urllib.request.Request(
        f"{base_url}/v1/messages", data=body, method="POST",
        headers={"x-api-key": key, "authorization": f"Bearer {key}",
                 "anthropic-version": "2023-06-01", "content-type": "application/json"},
    )
    try:
        urllib.request.urlopen(req, timeout=10)
        return True
    except urllib.error.HTTPError as e:
        # 401/403 = bad key; anything else (400 bad model, 429 rate limit, ...) means the key authenticated
        return e.code not in (401, 403)
    except Exception:
        return False


def _list_free_models() -> None:
    """Print OpenRouter free models that support tool use (required by Claude Code)."""
    try:
        with urllib.request.urlopen(OPENROUTER_MODELS_URL, timeout=20) as r:
            data = json.load(r)["data"]
    except Exception as e:
        print(f"[WARN] fetch failed: {e}")
        return
    for m in data:
        pr = m.get("pricing", {})
        free = str(pr.get("prompt")) in ("0", "0.0") and str(pr.get("completion")) in ("0", "0.0")
        if free and "tools" in (m.get("supported_parameters") or []):
            print(m["id"])


def _fetch_key(provider: str) -> str | None:
    """Scrape the first *working* API key from the free-keys repo README."""
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

    base_url = BASE_URLS[provider]
    lines = tail[table_m.start():].splitlines()
    for line in lines[2:]:
        line = line.strip()
        if not line.startswith("|"):
            break
        cells = [c.strip().strip("`") for c in line.split("|")[1:-1]]
        if cells and cells[0].startswith("sk-"):
            key = cells[0]
            if _key_works(key, base_url):
                print(f"auto-fetched (verified): {key[:20]}...")
                return key
            print(f"[WARN] key not usable, skipping: {key[:20]}...")

    print("[WARN] no working key found in table")
    return None


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--mode", required=True, choices=list(ENVS))
    p.add_argument("--provider", choices=list(HINTS), help="provider for --mode api (claude or deepseek)")
    p.add_argument("--token", help="API key/token (auto-fetched for auth/api; from $OPENROUTER_API_KEY for or)")
    p.add_argument("--model", help="override all model envs (e.g. qwen/qwen3-coder:free for --mode or)")
    p.add_argument("--list-free", action="store_true", help="list OpenRouter free models with tool support, then exit")
    p.add_argument("--test", action="store_true", help="write settings.t.json instead of settings.json")
    args = p.parse_args()

    if args.list_free:
        _list_free_models()
        return

    if args.mode == "api" and not args.provider:
        p.error("--mode api requires --provider {claude,deepseek}")

    env = dict(ENVS[args.mode])
    token = args.token

    if not token:
        if args.mode == "or":
            token = os.environ.get("OPENROUTER_API_KEY")
            if not token:
                print("[WARN] no key: set $OPENROUTER_API_KEY or pass --token (free at https://openrouter.ai/keys)")
        elif args.mode != "sub":
            provider = "claude" if args.mode == "auth" else args.provider
            token = _fetch_key(provider)

    if token:
        # OpenRouter + auth use Bearer (ANTHROPIC_AUTH_TOKEN); deepseek api uses x-api-key (ANTHROPIC_API_KEY)
        key = "ANTHROPIC_API_KEY" if args.mode == "api" else "ANTHROPIC_AUTH_TOKEN"
        env[key] = token

    if args.model:
        for k in MODEL_KEYS:
            if k in env:
                env[k] = args.model

    base = Path.home() / ".claude" / "settings.json"
    settings = base.with_name("settings.t.json") if args.test else base
    if args.test and not settings.exists():
        settings.write_text(base.read_text(encoding="utf-8"), encoding="utf-8")
    data = json.loads(settings.read_text(encoding="utf-8"))
    data["env"] = env
    settings.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"env -> {args.mode}")


if __name__ == "__main__":
    main()
