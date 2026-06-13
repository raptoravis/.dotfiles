# Handoff: 在 install 脚本中注册 chrome-devtools MCP

**Generated**: 2026-06-13
**Branch**: main
**Status**: Ready for Review (改动完成，未提交)

## Goal

在三个 install 脚本（linux / mac / windows）中新增 **chrome-devtools MCP** 的注册，与现有 context7 / codegraph / github MCP 注册保持对称。

## Completed

- [x] `install-linux.sh`：为 Claude Code & Codex 加 `mcp add chrome-devtools`；为 opencode & MiMo Code 写入 JSON 配置
- [x] `install-mac.sh`：同上（与 linux 对称）
- [x] `install-windows.ps1`：同上（PowerShell 写法）
- [x] sanity check：`bash -n` 两个 shell 脚本通过；PowerShell parser 校验 `ps1 OK`

## Not Yet Done

- [ ] git commit / push（用户习惯：停在 unstaged，等显式 "commit"/"提交"/"push" 指令再执行）

## Key Decisions

| Decision | Rationale |
|----------|-----------|
| chrome-devtools 走本地 stdio（`npx -y chrome-devtools-mcp@latest`） | 它不是 remote HTTP server，路径与 context7/codegraph 一致，不像 github 走 remote URL |
| Claude/Codex 用 CLI `mcp add`；opencode/MiMo 用 JSON 合并 | 沿用脚本既有模式 — opencode/MiMo 没有 `mcp add` CLI，直接写 JSON `mcp` 节点 |
| 插入位置紧跟 context7 注册块之后 | 保持三脚本结构对称，便于维护 |
| 复用现有 `register_json_mcp` / `Register-JsonMcp` 辅助函数 | 幂等合并，不重复造轮子 |

## Current State

**Working**: 三脚本语法均通过校验，逻辑与现有 MCP 注册块同构。

**Uncommitted Changes**: `install-linux.sh` / `install-mac.sh` / `install-windows.ps1` 各 +21 行（共 57 insertions, 6 deletions），全部 unstaged。

## Files to Know

| File | Why It Matters |
|------|----------------|
| `install-linux.sh` | Linux/WSL 引导；chrome-devtools 注册见 context7 块之后 + JSON 合并块 |
| `install-mac.sh` | macOS 引导；与 linux 对称，必须同步修改 |
| `install-windows.ps1` | Windows 主机引导；PowerShell 等价写法，必须同步修改 |

## Code Context

**CLI 注册（bash，Claude & Codex）**：
```bash
claude mcp add chrome-devtools -- npx -y chrome-devtools-mcp@latest 2>/dev/null \
  || log "  chrome-devtools MCP already registered for claude (...)"
codex mcp add chrome-devtools -- npx -y chrome-devtools-mcp@latest 2>/dev/null \
  || log "  chrome-devtools MCP already registered for codex (...)"
```

**JSON 合并（opencode / MiMo）**：
```bash
CDT_LOCAL_JSON='{"chrome-devtools":{"type":"local","command":["npx","-y","chrome-devtools-mcp@latest"],"enabled":true}}'
register_json_mcp "$HOME/.config/opencode/opencode.json" "$CDT_LOCAL_JSON"
register_json_mcp "$HOME/.config/mimocode/mimocode.json" "$CDT_LOCAL_JSON"
```

**PowerShell 等价**：
```powershell
claude mcp add chrome-devtools -- npx -y 'chrome-devtools-mcp@latest' 2>$null
$CdtLocalJson = '{"chrome-devtools":{"type":"local","command":["npx","-y","chrome-devtools-mcp@latest"],"enabled":true}}'
Register-JsonMcp "$HOME\.config\opencode\opencode.json" $CdtLocalJson
```

**非显而易见点**：`register_json_mcp` / `Register-JsonMcp` 仅在 key 不存在时合并（幂等），且依赖 `node` 在 PATH。

## Resume Instructions

1. 若用户要提交：`git add install-linux.sh install-mac.sh install-windows.ps1`
2. commit message 沿用仓库中文 conventional 风格，例如：
   `install: 新增 chrome-devtools MCP 注册（claude/codex/opencode/mimo）`
3. 等用户显式说 push 再 `git push`（不要连贯走完）。
4. 如需端到端验证（可选）：在装好 claude CLI 的机器上跑对应 install 脚本，然后 `claude mcp list` 应出现 `chrome-devtools`。
   - Expected: 列表含 `chrome-devtools`，首次调用时 npx 拉取并启动 Chrome DevTools server
   - If fail: 确认 `node`/`npx` 在 PATH，且 Chrome 已安装

## Warnings

- **三脚本必须对称** —— CLAUDE.md 明确要求，改一个就要改另两个。
- 用户的 git 习惯：代码改完停在 unstaged/staged，**不要自动 commit/push**，等显式指令。
- 输出语言：中文优先。
