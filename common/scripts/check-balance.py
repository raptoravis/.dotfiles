#!/usr/bin/env python3
"""
查 LLM/SaaS 账户余额，密钥从 ~/.env 读取。

Supported providers: DeepSeek, SiliconFlow, ElevenLabs.
GLM (智谱): 无公开余额 API，做 key 自检 + 网关 ping + reset 倒计时推算。
(DashScope / Tripo3D / Gemini have no programmatic balance API.)

Usage:
    check-balance                    # 查全部（含 GLM 自检）
    check-balance --ds              # 只查 DeepSeek
    check-balance --sf              # 只查 SiliconFlow
    check-balance --el              # 只查 ElevenLabs
    check-balance --glm             # 只做 GLM 自检 + reset 推算
    check-balance --glm-ping        # GLM 只 ping 网关验 key
    check-balance --key sk-xxx      # DeepSeek 密钥直传
    check-balance --sf-key sf-xxx   # SiliconFlow 密钥直传
    check-balance --el-key el-xxx   # ElevenLabs 密钥直传
    check-balance --glm-key xxx.yyy # GLM key 直传
    check-balance --glm-window "2026-07-09 22:00"  # 记录 5h 窗口起点
    check-balance --glm-week "2026-07-01"          # 记录周窗口起点

Returns exit code 0 on success, 1 on error.
"""

import argparse
import base64
import hashlib
import hmac
import json
import os
import sys
import time

# Force UTF-8 output on Windows (avoids GBK encoding errors with emoji/中文)
if sys.platform == "win32":
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
    os.system("chcp 65001 >nul 2>&1")

import urllib.error
import urllib.request
from datetime import datetime, timezone, timedelta
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

UNSUPPORTED = {
    "DASHSCOPE_API_KEY": "web console only: https://bailian.console.aliyun.com",
    "TRIPO_API_KEY": "web console only: https://platform.tripo3d.ai",
    "GEMINI_API_KEY": "web console only: https://aistudio.google.com/billing",
}

# ── GLM (智谱) 配置 ───────────────────────────────────────────────
# ⚠️ 智谱 GLM Coding Plan 的「账户余额 / 5h 窗口额度 / 每周窗口额度」
# 目前都没有对外开放的查询 API（候选接口实测全部 404），anthropic 网关
# 响应 header 也不含任何 rate-limit / reset 字段。因此 GLM 走「自检」路线：
#   1. 生成 JWT、ping 网关验 key 可用性
#   2. 透明复验所有候选余额/用量接口（让你自己看到确实查不到）
#   3. 基于你提供的窗口起点本地推算 5h/7d reset 倒计时
GLM_DEFAULT_BASE = "https://open.bigmodel.cn/api/anthropic"
GLM_STATE_FILE = os.path.expanduser("~/.glm-window.json")
GLM_CN_TZ = timezone(timedelta(hours=8))  # 北京时间，便于和智谱控制台对齐

# 候选的余额/用量查询接口（实测全部 404，保留是为了让用户可复验，
# 也是为了将来智谱若开放接口能第一时间发现）
GLM_CANDIDATE_ENDPOINTS = [
    "https://open.bigmodel.cn/api/paas/v4/users/self/balance",
    "https://open.bigmodel.cn/api/paas/v4/users/self",
    "https://open.bigmodel.cn/api/paas/v4/users/self/quota",
    "https://open.bigmodel.cn/api/paas/v4/users/self/usage",
    "https://open.bigmodel.cn/api/paas/v4/billing/balance",
    "https://open.bigmodel.cn/api/coding/paas/v4/users/self/balance",
    "https://open.bigmodel.cn/api/coding/paas/v4/users/self",
    "https://open.bigmodel.cn/api/paas/v4/resource-package",
]


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


# ── GLM (智谱) 自检 ───────────────────────────────────────────────

def glm_load_key(cli_key, env_path: Path):
    """读取 GLM key，优先级：命令行 > 环境变量 > ~/.env > ~/.claude/settings.json。"""
    if cli_key:
        return cli_key, "(命令行参数)"
    for env_name in ("GLM_API_KEY", "ZAI_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY"):
        v = os.environ.get(env_name)
        if v and v.strip():
            return v, f"$ENV:{env_name}"
    if env_path.exists():
        for line in env_path.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line.startswith("GLM_API_KEY="):
                v = line.removeprefix("GLM_API_KEY=").strip("\"'")
                if v:
                    return v, "~/.env [GLM_API_KEY]"
                break
    # 最后回退到 ~/.claude/settings.json
    p = os.path.expanduser("~/.claude/settings.json")
    if os.path.exists(p):
        try:
            env = json.load(open(p, encoding="utf-8")).get("env", {})
            for k in ("ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY", "GLM_API_KEY"):
                if env.get(k):
                    return env[k], f"~/.claude/settings.json [{k}]"
        except Exception:
            pass
    return None, None


def glm_load_base() -> str:
    p = os.path.expanduser("~/.claude/settings.json")
    if os.path.exists(p):
        try:
            env = json.load(open(p, encoding="utf-8")).get("env", {})
            if env.get("ANTHROPIC_BASE_URL"):
                return env["ANTHROPIC_BASE_URL"].rstrip("/")
        except Exception:
            pass
    return GLM_DEFAULT_BASE


def _glm_b64(d):
    return base64.b64encode(json.dumps(d, separators=(",", ":")).encode()).decode().rstrip("=")


def _glm_b64url(b):
    return base64.urlsafe_b64encode(b).decode().rstrip("=")


def glm_gen_jwt(api_key):
    """智谱 key 形如 {id}.{secret}，用 secret 做 HS256 签名生成短期 token。"""
    api_id, secret = api_key.split(".")
    now_ms = int(round(time.time() * 1000))
    payload = {"api_key": api_id, "exp": now_ms + 3600 * 1000, "timestamp": now_ms}
    header = _glm_b64({"alg": "HS256", "sign_type": "SIGN"})
    py = _glm_b64(payload)
    msg = f"{header}.{py}"
    sig = _glm_b64url(hmac.new(secret.encode(), msg.encode(), hashlib.sha256).digest())
    return f"{msg}.{sig}", api_id


def glm_jwt_exp(jwt_token):
    """解码 JWT 的 exp（token 自身过期时间，不是账户额度 reset）。"""
    try:
        payload = jwt_token.split(".")[1]
        payload += "=" * (-len(payload) % 4)
        claims = json.loads(base64.urlsafe_b64decode(payload))
        exp = claims.get("exp")
        if isinstance(exp, (int, float)):
            return datetime.fromtimestamp(exp / 1000, tz=GLM_CN_TZ)  # 智谱 exp 是毫秒
    except Exception:
        pass
    return None


def glm_http_get(url, token, timeout=15):
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")
    except Exception as e:
        return -1, repr(e)


def glm_ping(base, token):
    """发一个 max_tokens=1 的最小请求，验证 key 是否可用。"""
    url = base.rstrip("/") + "/v1/messages"
    body = json.dumps({
        "model": "glm-4.7",
        "max_tokens": 1,
        "messages": [{"role": "user", "content": "."}],
    }).encode()
    req = urllib.request.Request(url, data=body, method="POST", headers={
        "Authorization": f"Bearer {token}",
        "anthropic-version": "2023-06-01",
        "content-type": "application/json",
    })
    rate_kw = ("rate", "limit", "reset", "retry", "quota", "remain", "window")
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            hdrs = {k: v for k, v in r.headers.items() if any(s in k.lower() for s in rate_kw)}
            return True, hdrs
    except urllib.error.HTTPError as e:
        hdrs = {k: v for k, v in e.headers.items() if any(s in k.lower() for s in rate_kw)}
        body_txt = e.read().decode("utf-8", "replace")[:200]
        return False, {"status": e.code, "body": body_txt, "headers": hdrs}
    except Exception as e:
        return False, {"error": repr(e)}


def glm_load_state():
    if os.path.exists(GLM_STATE_FILE):
        try:
            return json.load(open(GLM_STATE_FILE, encoding="utf-8"))
        except Exception:
            return {}
    return {}


def glm_save_state(state):
    with open(GLM_STATE_FILE, "w", encoding="utf-8") as f:
        json.dump(state, f, ensure_ascii=False, indent=2)


def glm_parse_dt(s):
    """宽松解析 '2026-07-09 22:00' 或 '2026-07-09T22:00:00'，按北京时间。"""
    s = s.strip().replace("T", " ")
    for fmt in ("%Y-%m-%d %H:%M:%S", "%Y-%m-%d %H:%M", "%Y-%m-%d"):
        try:
            return datetime.strptime(s, fmt).replace(tzinfo=GLM_CN_TZ)
        except ValueError:
            continue
    raise ValueError(f"无法解析时间: {s}（示例：2026-07-09 22:00）")


def glm_fmt_countdown(delta):
    total = int(delta.total_seconds())
    if total < 0:
        return f"已过期 {-total // 3600}h{(-total) % 3600 // 60}m"
    return f"{total // 3600}h{(total % 3600) // 60}m{total % 60}s"


def glm_section(title):
    print(f"\n{'=' * 60}\n {title}\n{'=' * 60}")


def check_glm(
    cli_key,
    env_path: Path,
    *,
    ping_only: bool = False,
    no_probe: bool = False,
    window_start: str | None = None,
    week_start: str | None = None,
) -> None:
    """GLM 自检：key/JWT → 网关 ping → 候选接口探测 → 本地 reset 推算。"""
    key, source = glm_load_key(cli_key, env_path)
    if not key:
        die(
            "找不到 GLM API key。请用 --glm-key 指定，或设置 GLM_API_KEY / "
            "ANTHROPIC_AUTH_TOKEN 环境变量，或在 ~/.env 写入 GLM_API_KEY=。"
        )

    glm_section("① GLM Key 信息")
    print(f"  来源        : {source}")
    print(f"  key 长度    : {len(key)} 字符")
    print(f"  格式        : {'{id}.{secret} [OK]' if '.' in key else '[!] 非 id.secret 格式，JWT 可能生成失败'}")
    jwt = None
    try:
        jwt, api_id = glm_gen_jwt(key)
        print(f"  api_id      : {api_id}")
        exp = glm_jwt_exp(jwt)
        if exp:
            print(f"  JWT 过期    : {exp:%Y-%m-%d %H:%M}  (token 自身有效期，不是账户额度 reset)")
        print(f"  [OK] 成功生成 JWT ({len(jwt)} 字符)")
    except Exception as e:
        print(f"  [X] JWT 生成失败: {e}")

    base = glm_load_base()
    print(f"  网关地址    : {base}")

    # ping
    glm_section("② 网关连通性 (ping)")
    ok, info = glm_ping(base, key)
    if ok:
        print("  [OK] key 可用，网关返回 200")
        print(f"  响应中的限流/reset header: {info or '（无 —— 智谱不在 header 里暴露额度）'}")
    else:
        print(f"  [X] 网关请求失败: {info}")

    if ping_only:
        return

    # 探测候选接口
    if not no_probe and jwt:
        glm_section("③ 余额/用量接口探测（透明复验）")
        print("  说明：以下接口智谱均未开放，预期全部 404。保留是为了可复验。\n")
        any_ok = False
        for ep in GLM_CANDIDATE_ENDPOINTS:
            st, body = glm_http_get(ep, jwt)
            tag = "[OK]" if st == 200 else "  "
            print(f"  [{st:>4}] {tag} {ep}")
            if st == 200:
                any_ok = True
                print(f"           ↳ {body[:300]}")
        if not any_ok:
            print("\n  → 全部 404：智谱确实没有公开的余额/额度查询 API。")

    # 本地 reset 推算
    glm_section("④ Reset 时间（本地推算）")
    state = glm_load_state()
    if window_start:
        state["window_start"] = glm_parse_dt(window_start).isoformat()
        glm_save_state(state)
        print(f"  [OK] 已记录 5h 窗口起点: {window_start}")
    if week_start:
        state["week_start"] = glm_parse_dt(week_start).isoformat()
        glm_save_state(state)
        print(f"  [OK] 已记录订阅周期起点: {week_start}")

    now = datetime.now(GLM_CN_TZ)
    ws = state.get("window_start")
    wk = state.get("week_start")
    if ws:
        ws_dt = datetime.fromisoformat(ws)
        # 智谱 5h 窗口为「消耗后 5 小时动态刷新」，按当前窗口起点 +5h 推算下次刷新
        next_reset = ws_dt + timedelta(hours=5)
        while next_reset < now:  # 若已过多个周期，滚动到未来最近一次
            next_reset += timedelta(hours=5)
        print(f"  5h 窗口下次刷新: 约 {next_reset:%Y-%m-%d %H:%M}  (倒计时 {glm_fmt_countdown(next_reset - now)})")
        print("    （基于你提供的窗口起点推算；实际以控制台【用量统计】为准）")
    else:
        print("  5h 窗口  : 尚未设置起点。运行:")
        print('             check-balance --glm-window "2026-07-09 22:00"')
    if wk:
        wk_dt = datetime.fromisoformat(wk)
        next_w = wk_dt + timedelta(days=7)
        while next_w < now:
            next_w += timedelta(days=7)
        print(f"  周窗口下次刷新 : 约 {next_w:%Y-%m-%d %H:%M}  (倒计时 {glm_fmt_countdown(next_w - now)})")
    else:
        print("  周窗口   : 尚未设置。运行:")
        print('             check-balance --glm-week "2026-07-01"')

    # 结论与指路
    glm_section("⑤ 结论")
    print("  智谱 GLM 未公开『余额 / 5h 窗口 / 周窗口 reset』的查询 API，")
    print("  真实数字请到控制台查看：")
    print("    • 用量统计(套餐额度/剩余): https://bigmodel.cn/finance/expensebill/list")
    print("    • 账户余额 / 赠金        : https://bigmodel.cn/finance/wallet")
    print("  本工具对 GLM 的作用：自检 key、透明复验接口、本地推算 reset 倒计时。")


# ── 主流程 ───────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Check LLM/SaaS account balance (DeepSeek, SiliconFlow, ElevenLabs, GLM)"
    )
    parser.add_argument("--ds", action="store_true", help="only check DeepSeek")
    parser.add_argument("--sf", action="store_true", help="only check SiliconFlow")
    parser.add_argument("--el", action="store_true", help="only check ElevenLabs")
    parser.add_argument("--glm", action="store_true", help="only do GLM (智谱) self-check")
    parser.add_argument("--key", "-k", help="DeepSeek DEEPSEEK_API_KEY directly")
    parser.add_argument("--sf-key", help="SiliconFlow API key directly")
    parser.add_argument("--el-key", help="ElevenLabs API key directly")
    parser.add_argument("--glm-key", help="GLM (智谱) API key (id.secret) directly")
    parser.add_argument("--glm-ping", action="store_true", help="GLM: only ping gateway to verify key")
    parser.add_argument("--glm-window", metavar="DATETIME",
                        help="GLM: record 5h window start (e.g. '2026-07-09 22:00')")
    parser.add_argument("--glm-week", metavar="DATE",
                        help="GLM: record subscription cycle start (e.g. '2026-07-01')")
    parser.add_argument("--glm-no-probe", action="store_true", help="GLM: skip candidate endpoint probing")
    args = parser.parse_args()

    env_path = Path.home() / ".env"
    glm_mode = args.glm or args.glm_ping or bool(args.glm_window) or bool(args.glm_week)
    check_all = not (args.ds or args.sf or args.el or glm_mode)

    if check_all or args.ds:
        key = args.key if args.key else read_api_key("DEEPSEEK_API_KEY", env_path)
        check_one(key, PROVIDERS["deepseek"], "DeepSeek")

    if check_all or args.sf:
        key = args.sf_key if args.sf_key else read_api_key("SILICONFLOW_API_KEY", env_path)
        check_one(key, PROVIDERS["siliconflow"], "SiliconFlow")

    if check_all or args.el:
        key = args.el_key if args.el_key else read_api_key("ELEVENLABS_API_KEY", env_path)
        check_one(key, PROVIDERS["elevenlabs"], "ElevenLabs", currency_fallback="USD")

    if glm_mode:
        check_glm(
            args.glm_key,
            env_path,
            ping_only=args.glm_ping,
            no_probe=args.glm_no_probe,
            window_start=args.glm_window,
            week_start=args.glm_week,
        )

    show_unsupported(env_path)


if __name__ == "__main__":
    main()
