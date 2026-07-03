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

# planning

**不要进入 plan mode，不要调用 `EnterPlanMode` 工具，不要用 `ExitPlanMode` 等批准。** 直接动手实现用户的要求。

- 只有当用户明确说"先给我方案" / "先计划一下" / "plan" 时，才用普通对话文本写出方案，仍然不调用 `EnterPlanMode`/`ExitPlanMode`
- **Why:** 用户已设 `permissions.defaultMode: bypassPermissions`，权限层已全自动；唯一还在卡的是模型自愿进 plan mode 等批准，这违背"尽量自动推进"的意图
- 不影响在动手前用 2-3 句话说明意图再继续 —— 那是普通文本，不是 plan mode

<!-- CODEGRAPH_START -->
## CodeGraph

This project has a CodeGraph MCP server (`codegraph_*` tools) configured. CodeGraph is a tree-sitter-parsed knowledge graph of every symbol, edge, and file. Reads are sub-millisecond and return structural information grep cannot.

### When to prefer codegraph over native search

Use codegraph for **structural** questions — what calls what, what would break, where is X defined, what is X's signature. Use native grep/read only for **literal text** queries (string contents, comments, log messages) or after you already have a specific file open.

| Question | Tool |
|---|---|
| "Where is X defined?" / "Find symbol named X" | `codegraph_search` |
| "What calls function Y?" | `codegraph_callers` |
| "What does Y call?" | `codegraph_callees` |
| "What would break if I changed Z?" | `codegraph_impact` |
| "Show me Y's signature / source / docstring" | `codegraph_node` |
| "Give me focused context for a task/area" | `codegraph_context` |
| "See several related symbols' source at once" | `codegraph_explore` |
| "What files exist under path/" | `codegraph_files` |
| "Is the index healthy?" | `codegraph_status` |

### Rules of thumb

- **Answer directly — don't delegate exploration.** For "how does X work" / architecture / trace questions, answer with 2-3 codegraph calls: `codegraph_context` first, then ONE `codegraph_explore` for the source of the symbols it surfaces. Codegraph IS the pre-built index, so spawning a separate file-reading sub-task/agent — or running a grep + read loop — repeats work codegraph already did and costs more for the same answer.
- **Trust codegraph results.** They come from a full AST parse. Do NOT re-verify them with grep — that's slower, less accurate, and wastes context.
- **Don't grep first** when looking up a symbol by name. `codegraph_search` is faster and returns kind + location + signature in one call.
- **Don't chain `codegraph_search` + `codegraph_node`** when you just want context — `codegraph_context` is one call.
- **Don't loop `codegraph_node` over many symbols** — one `codegraph_explore` call returns several symbols' source grouped in a single capped call, while each separate node/Read call re-reads the whole context and costs far more.
- **Index lag**: the file watcher debounces ~500ms behind writes; don't re-query immediately after editing a file in the same turn.

### If `.codegraph/` doesn't exist

The MCP server returns "not initialized." Ask the user: *"I notice this project doesn't have CodeGraph initialized. Want me to run `codegraph init -i` to build the index?"*
<!-- CODEGRAPH_END -->