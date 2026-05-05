# language

回答语言优先级：**中文 > 英文 > 不要用任何其他语言**。

- 解释、说明、对话文本：默认用中文
- 代码、命令、文件名、变量名、报错原文、API 名、库名：保持原样不翻译
- 即使用户消息里夹杂了日语/韩语/俄语等其他语言的字符，回复仍然只用中文或英文
- 用户明确说 "answer in English" / "用英文" 时才切换
- 写解释段落、commit summary 文字描述、答疑、收尾 summary 时强制中文。绝对不要因为"讲技术内部细节方便"就切英文。代码块里的 comment不在此约束内（跟随项目代码风格）。

# git-commit-push

代码改完 + 跑完 sanity check 后**停在 unstaged / staged 状态**，等用户显式发 "commit" / "提交" / "push" / "推" / "ff-merge" 等指令再执行 git add / commit / push / merge / checkout。

- **Why:** push 是共享状态、回滚代价大；用户多次明确希望分阶段确认而不是连贯走完
- 仅当用户在同一指令里写了"commit + push + ff-merge"这种连写时，按字面授权范围执行；他说 "commit" 就只 commit 不 push
- 不影响纯 local 操作（编辑文件 / mkdir / 装依赖 / 跑测试）— 那些可以照常做

# graphify

- **graphify** (`~/.claude/skills/graphify/SKILL.md`) — any input to knowledge graph. Trigger: `/graphify`
- 当用户输入 `/graphify` 时，调用 Skill 工具 (`skill: "graphify"`)，先于其它任何动作

## 三种 graphify 操作的分工（重要 — 不要混淆）

| 操作 | 在哪执行 | 用什么 | 调 LLM？ |
|---|---|---|---|
| **首次构建图谱** | Claude Code 里 | 输入 slash command `/graphify .`（触发 skill，会派子代理） | ✅ 几分钟，按 token 计费 |
| **增量更新** | 命令行 / hook | shell 命令 `graphify update .` | ❌ 纯 AST，几秒 |
| **查询图** | 命令行 / Bash 工具 | `graphify query "..."` / `path` / `explain` | ❌ 本地 BFS，毫秒 |

注意：`graphify .`（无 `update`）**不是** shell 命令，shell 里跑会报 `unknown command '.'`。只有 `/graphify .` 这个 slash command 才能触发首次构建。

## 自动行为约定（由全局 hooks 触发）

- **SessionStart hook** 会在你进入新项目时检测：
  - 是 git 仓库 + 有 `graphify-out/graph.json` → 提示你优先读 `graphify-out/GRAPH_REPORT.md`
  - 是 git 仓库 + 没有 `graphify-out/` → 提示用户可以输入 `/graphify .` 初始化（不自动跑，避免烧 token）
  - 不是 git 仓库（如 `~`、`/tmp`） → 静默跳过
- **PostToolUse hook** 在你 Edit / Write / MultiEdit 改完文件后，会异步跑 `graphify update .`（仅当 `graphify-out/graph.json` 已存在）—— 你不用手动跑

## 何时建议用户初始化 graphify

只在以下情况才建议用户在 Claude 里输入 `/graphify .`：
- 用户问架构、跨模块依赖、"X 和 Y 怎么关联"、"调用链是什么"等需要图视角的问题
- 项目较大（grep/glob 已经不够用），且没有 `graphify-out/`
- 不要在脚本仓库、配置仓库、临时仓库里建议初始化

@RTK.md
